-- Push notifications: device tokens, and the send-push Edge Function draining
-- notification_outbox every minute.

create table if not exists public.push_tokens (
  token        text primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  environment  text not null check (environment in ('sandbox', 'production')),
  -- Which outbox kinds this device wants ('lost', 'raid', 'invite').
  kinds        text[] not null default array['lost', 'raid', 'invite'],
  updated_at   timestamptz not null default now()
);
create index if not exists push_tokens_user_idx on public.push_tokens (user_id);
alter table public.push_tokens enable row level security;
-- No client policies: devices register through the RPCs below. Only the server reads it.
revoke all on public.push_tokens from anon, authenticated;
grant all on public.push_tokens to service_role;

-- A device registers (or re-registers) its token. A token moves with whoever signed in last.
create or replace function public.register_push_token(p_token text, p_environment text, p_kinds text[])
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_token !~ '^[0-9a-f]{32,200}$' then raise exception 'bad token'; end if;
  insert into public.push_tokens (token, user_id, environment, kinds, updated_at)
  values (p_token, auth.uid(), p_environment,
          array(select k from unnest(p_kinds) k where k in ('lost', 'raid', 'invite')), now())
  on conflict (token) do update set user_id = excluded.user_id, environment = excluded.environment,
    kinds = excluded.kinds, updated_at = now();
end $$;

create or replace function public.unregister_push_token(p_token text)
returns void language sql security definer set search_path = public, extensions as $$
  delete from public.push_tokens where token = p_token and user_id = auth.uid()
$$;

grant execute on function public.register_push_token(text, text, text[]), public.unregister_push_token(text) to authenticated;
revoke execute on function public.register_push_token(text, text, text[]), public.unregister_push_token(text) from anon;

-- send-push claims a batch: marks rows sent and returns them. Anything older than
-- a day is dropped unsent (stale news), and so are rows for users with no device.
create or replace function public.claim_push_batch(p_limit int)
returns setof public.notification_outbox language plpgsql security definer set search_path = public, extensions as $$
begin
  update public.notification_outbox set sent_at = now()
   where sent_at is null and (created_at < now() - interval '1 day'
     or not exists (select 1 from public.push_tokens t where t.user_id = notification_outbox.user_id));
  return query
    update public.notification_outbox o set sent_at = now()
     where o.id in (select id from public.notification_outbox where sent_at is null order by created_at limit p_limit
                    for update skip locked)
    returning o.*;
end $$;
revoke execute on function public.claim_push_batch(int) from public, anon, authenticated;

-- Every minute. call_chomp_function no-ops until the Vault secrets exist.
select cron.unschedule('chomp-send-push') where exists (select 1 from cron.job where jobname = 'chomp-send-push');
select cron.schedule('chomp-send-push', '* * * * *', $$select public.call_chomp_function('send-push')$$);
