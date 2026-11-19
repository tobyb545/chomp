-- Invite a friend: the friend gets a month of Pro when they join with your
-- code, and you get a month when they finish their first real run (so made-up
-- accounts earn nothing). Free months live in entitlements as 'pro_invite',
-- separate from the App Store's 'pro' row that RevenueCat's webhook manages.

create table public.invite_codes (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  code        text not null unique check (code ~ '^[A-HJKMNP-Z2-9]{6}$'),
  created_at  timestamptz not null default now()
);

create table public.referrals (
  invitee_id   uuid primary key references public.profiles(id) on delete cascade,  -- one code per person, ever
  inviter_id   uuid not null references public.profiles(id) on delete cascade,
  code         text not null,
  joined_at    timestamptz not null default now(),
  rewarded_at  timestamptz,  -- when the inviter got their month
  check (invitee_id <> inviter_id)
);
create index referrals_inviter_idx on public.referrals (inviter_id);

alter table public.invite_codes enable row level security;
alter table public.referrals enable row level security;
-- No policies: read and written only through the functions below.

-- Inviters earn at most this many free months.
insert into public.game_config (key, value) values ('invites', '{"maxRewardedPerInviter": 12, "inviteeAccountMaxAgeDays": 30, "freeDays": 30}')
on conflict (key) do nothing;

-- Adds free days on top of any free Pro still running.
create or replace function public.grant_invite_pro(p_user uuid, p_days int) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v_until timestamptz;
begin
  insert into public.entitlements (user_id, entitlement, expires_at, updated_at)
  values (p_user, 'pro_invite', now() + make_interval(days => p_days), now())
  on conflict (user_id, entitlement) do update
    set expires_at = greatest(entitlements.expires_at, now()) + make_interval(days => p_days), updated_at = now()
  returning expires_at into v_until;
  return v_until;
end $$;

-- Your invite code (made on first ask) and how it's doing.
create or replace function public.my_invite() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me uuid := auth.uid();
  v_code text;
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  i int;
begin
  if v_me is null then raise exception 'chomp: Sign in first'; end if;
  select code into v_code from public.invite_codes where user_id = v_me;
  while v_code is null loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    begin
      insert into public.invite_codes (user_id, code) values (v_me, v_code);
    exception when unique_violation then
      select code into v_code from public.invite_codes where user_id = v_me;  -- raced ourselves, or the code was taken
    end;
  end loop;
  return jsonb_build_object(
    'code', v_code,
    'joined', (select count(*) from public.referrals where inviter_id = v_me),
    'rewarded', (select count(*) from public.referrals where inviter_id = v_me and rewarded_at is not null),
    'pending', (select count(*) from public.referrals where inviter_id = v_me and rewarded_at is null),
    'redeemed_code', (select code from public.referrals where invitee_id = v_me));
end $$;

-- Uses a friend's code. Returns when your free Pro ends.
create or replace function public.redeem_invite(p_code text) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_inviter uuid;
  v_cfg jsonb := coalesce((select value from public.game_config where key = 'invites'), '{}');
  v_joined timestamptz;
begin
  if v_me is null then raise exception 'chomp: Sign in first'; end if;
  select user_id into v_inviter from public.invite_codes where code = upper(trim(p_code));
  if v_inviter is null then raise exception 'chomp: That code doesn''t exist. Check it with your friend.'; end if;
  if v_inviter = v_me then raise exception 'chomp: That''s your own code. Send it to a friend instead!'; end if;
  if exists (select 1 from public.referrals where invitee_id = v_me) then
    raise exception 'chomp: You''ve already used an invite code.';
  end if;
  select created_at into v_joined from public.profiles where id = v_me;
  if v_joined < now() - make_interval(days => coalesce((v_cfg->>'inviteeAccountMaxAgeDays')::int, 30)) then
    raise exception 'chomp: Invite codes are for new players, within 30 days of joining.';
  end if;
  if exists (select 1 from public.user_relations ur where ur.user_id = v_inviter and ur.target_id = v_me and ur.kind = 'block') then
    raise exception 'chomp: That code doesn''t exist. Check it with your friend.';
  end if;
  insert into public.referrals (invitee_id, inviter_id, code) values (v_me, v_inviter, upper(trim(p_code)));
  return public.grant_invite_pro(v_me, coalesce((v_cfg->>'freeDays')::int, 30));
end $$;

-- The inviter's month: on the friend's first resolved live run.
create or replace function public.reward_inviter() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_ref public.referrals;
  v_cfg jsonb := coalesce((select value from public.game_config where key = 'invites'), '{}');
begin
  if new.status <> 'resolved' or new.source <> 'live' then return new; end if;
  select * into v_ref from public.referrals where invitee_id = new.user_id and rewarded_at is null for update;
  if v_ref.invitee_id is null then return new; end if;
  update public.referrals set rewarded_at = now() where invitee_id = new.user_id;
  if (select count(*) from public.referrals where inviter_id = v_ref.inviter_id and rewarded_at is not null)
       > coalesce((v_cfg->>'maxRewardedPerInviter')::int, 12) then
    return new;  -- counted, but no more free months
  end if;
  perform public.grant_invite_pro(v_ref.inviter_id, coalesce((v_cfg->>'freeDays')::int, 30));
  insert into public.notification_outbox (user_id, kind, title, body)
  values (v_ref.inviter_id, 'invite', 'A free month of Pro',
          coalesce((select display_name from public.profiles where id = new.user_id), 'Your friend')
            || ' finished their first run. Enjoy a month of Chomp Pro on us.');
  return new;
end $$;
create trigger runs_reward_inviter after insert or update of status on public.runs
  for each row execute function public.reward_inviter();

revoke execute on function public.grant_invite_pro(uuid, int), public.reward_inviter() from public, anon, authenticated;
revoke execute on function public.my_invite(), public.redeem_invite(text) from public, anon;
grant execute on function public.my_invite(), public.redeem_invite(text) to authenticated;
