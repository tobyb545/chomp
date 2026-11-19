-- Club battles. A player belongs to at most one club. Every coin they collect
-- while in it counts towards the club's tally (captures are stamped with the
-- club at the time, so switching clubs doesn't move past coins). Clubs rank
-- nearby (same ~25 km region) and worldwide.

-- One club per player: keep each player's most recent membership.
delete from public.memberships m
 using public.memberships newer
 where newer.user_id = m.user_id and (newer.joined_at, newer.club_id::text) > (m.joined_at, m.club_id::text);
create unique index if not exists memberships_one_club_idx on public.memberships (user_id);

-- Captures remember the club they were made for.
alter table public.captures add column if not exists club_id uuid references public.clubs(id) on delete set null;
create index if not exists captures_club_idx on public.captures (club_id) where club_id is not null;

create or replace function public.stamp_capture_club() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.club_id is null and new.kind in ('captured', 'stolen') then
    select club_id into new.club_id from public.memberships where user_id = new.user_id;
  end if;
  return new;
end $$;
drop trigger if exists captures_stamp_club on public.captures;
create trigger captures_stamp_club before insert on public.captures
  for each row execute function public.stamp_capture_club();

-- Coins a capture earned (captures before coins took the whole street).
create or replace function public.capture_tokens(p_tokens int, p_length double precision)
returns int language sql stable as $$
  select coalesce(p_tokens, greatest(1, round(p_length /
    coalesce((select (value->>'metresPerToken')::float8 from public.game_config where key = 'tokens'), 10)))::int)
$$;

-- Leaving: the longest-standing member takes over an owned club; an empty club is deleted.
create or replace function public.leave_club() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_club uuid; v_role text; v_next uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select club_id, role into v_club, v_role from public.memberships where user_id = auth.uid();
  if v_club is null then return; end if;
  delete from public.memberships where user_id = auth.uid();
  select user_id into v_next from public.memberships where club_id = v_club order by joined_at limit 1;
  if v_next is null then
    delete from public.clubs where id = v_club;
  elsif v_role = 'owner' then
    update public.memberships set role = 'owner' where club_id = v_club and user_id = v_next;
    update public.clubs set owner_id = v_next where id = v_club;
  end if;
end $$;

-- Creating or joining a club leaves the one you're in.
create or replace function public.create_club(p_name text, p_color text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.has_pro(auth.uid()) then raise exception 'Starting a club is part of Chomp Pro. Anyone can join one.'; end if;
  perform public.leave_club();
  insert into public.clubs (name, color_hex, owner_id) values (trim(p_name), upper(p_color), auth.uid()) returning id into v_id;
  insert into public.memberships (club_id, user_id, role) values (v_id, auth.uid(), 'owner');
  return v_id;
end $$;

create or replace function public.join_club(p_code text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select id into v_id from public.clubs where invite_code = upper(trim(p_code));
  if v_id is null then raise exception 'No club with that code'; end if;
  if exists (select 1 from public.memberships where user_id = auth.uid() and club_id = v_id) then return v_id; end if;
  perform public.leave_club();
  insert into public.memberships (club_id, user_id) values (v_id, auth.uid());
  return v_id;
end $$;

-- Your club, its tally and rank, and what each member has added.
create or replace function public.my_club()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with mine as (
    select c.* , m.role from public.memberships m join public.clubs c on c.id = m.club_id where m.user_id = auth.uid()
  ),
  tallies as (
    select cp.club_id, sum(public.capture_tokens(cp.tokens, s.length_m))::int as tokens
      from public.captures cp join public.segments s on s.id = cp.segment_id
     where cp.club_id is not null and cp.kind in ('captured', 'stolen')
     group by cp.club_id
  )
  select case when not exists (select 1 from mine) then null else (
    select jsonb_build_object(
      'id', c.id, 'name', c.name, 'color_hex', c.color_hex, 'invite_code', c.invite_code, 'role', c.role,
      'tokens', coalesce((select t.tokens from tallies t where t.club_id = c.id), 0),
      'rank', (select count(*) + 1 from tallies t where t.tokens > coalesce((select t2.tokens from tallies t2 where t2.club_id = c.id), 0)),
      'clubs', (select count(*) from public.clubs),
      'members', coalesce((
        select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.display_name, 'color_hex', p.color_hex, 'role', m.role,
                 'tokens', coalesce((select sum(public.capture_tokens(cp.tokens, s.length_m))::int
                                       from public.captures cp join public.segments s on s.id = cp.segment_id
                                      where cp.club_id = c.id and cp.user_id = m.user_id and cp.kind in ('captured', 'stolen')), 0))
               order by m.joined_at)
          from public.memberships m join public.profiles p on p.id = m.user_id
         where m.club_id = c.id), '[]'::jsonb)
    ) from mine c) end
$$;

-- Club leaderboard. 'nearby' counts coins collected in the same ~25 km region as p_tile.
create or replace function public.club_leaderboard(p_scope text, p_tile text)
returns table (club_id uuid, name text, color_hex text, members int, tokens int, is_mine boolean)
language sql stable security definer set search_path = public, extensions as $$
  select c.id, c.name, c.color_hex,
         (select count(*)::int from public.memberships m where m.club_id = c.id),
         sum(public.capture_tokens(cp.tokens, s.length_m))::int,
         exists (select 1 from public.memberships m where m.club_id = c.id and m.user_id = auth.uid())
    from public.captures cp
    join public.segments s on s.id = cp.segment_id
    join public.clubs c on c.id = cp.club_id
   where cp.kind in ('captured', 'stolen')
     and (p_scope = 'global' or (p_scope = 'nearby' and public.tile_region(s.tile) = public.tile_region(p_tile)))
   group by c.id, c.name, c.color_hex
   order by 5 desc
   limit 100
$$;

grant execute on function public.leave_club(), public.my_club(), public.club_leaderboard(text, text),
  public.create_club(text, text), public.join_club(text) to authenticated;
revoke execute on function public.leave_club(), public.my_club(), public.club_leaderboard(text, text) from anon;
revoke execute on function public.stamp_capture_club() from public, anon, authenticated;
