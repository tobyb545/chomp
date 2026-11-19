-- Bots fill quiet places until real runners are active there.
--  * Bots have ordinary runner names and appear on the nearby leaderboard like anyone else.
--  * Nobody can take a bot's name, and new bots skip names players already use.
--  * ghost-tick retires a district's bots once enough real runners are active in it,
--    releasing their coins over about a week (release_ghost_coins).

-- Old bots were named "Bot …". Remove them; ghost-tick recreates them with new names.
delete from public.segment_ownership where owner_kind = 'ghost';
delete from public.ai_ghosts;
create unique index if not exists ai_ghosts_name_district_idx on public.ai_ghosts (district, lower(name));

-- Names are unique across players (profiles_name_uniq) and can't match a bot.
create or replace function public.reserve_bot_names() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if exists (select 1 from public.ai_ghosts g where lower(g.name) = lower(new.display_name)) then
    raise exception 'That name is taken' using errcode = '23505';
  end if;
  return new;
end $$;
drop trigger if exists profiles_reserve_bot_names on public.profiles;
create trigger profiles_reserve_bot_names before insert or update of display_name on public.profiles
  for each row execute function public.reserve_bot_names();

-- Lets the app say "taken" before signing in. Ignores the caller's own name.
create or replace function public.name_available(p_name text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select char_length(trim(p_name)) between 2 and 20
     and not exists (select 1 from public.profiles p
                      where lower(p.display_name) = lower(trim(p_name)) and p.id is distinct from auth.uid())
     and not exists (select 1 from public.ai_ghosts g where lower(g.name) = lower(trim(p_name)))
$$;
grant execute on function public.name_available(text) to anon, authenticated;

-- Real runners who captured anything in a district (zoom-12 tile) in the last p_days.
create or replace function public.district_active_players(p_district text, p_days int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select count(distinct c.user_id)::int
    from public.captures c
    join public.segments s on s.id = c.segment_id
    left join public.user_trust t on t.user_id = c.user_id
   where c.at > now() - make_interval(days => p_days)
     and c.kind in ('captured', 'stolen', 'refreshed')
     and public.tile_parent(s.tile, 12) = p_district
     and not coalesce(t.shadow_restricted, false)
$$;

-- A retiring bot lets go of its oldest coins. Returns how many it still holds.
create or replace function public.release_ghost_coins(p_ghost text, p_limit int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare v_left int;
begin
  delete from public.segment_ownership
   where segment_id in (select segment_id from public.segment_ownership
                         where owner_kind = 'ghost' and owner_id = p_ghost
                         order by captured_at limit greatest(p_limit, 0));
  select count(*) into v_left from public.segment_ownership where owner_kind = 'ghost' and owner_id = p_ghost;
  if v_left = 0 then delete from public.ai_ghosts where id = p_ghost; end if;
  return v_left;
end $$;
revoke execute on function public.district_active_players(text, int), public.release_ghost_coins(text, int),
  public.reserve_bot_names() from public, anon, authenticated;

-- Bot raids read like any other lost coins.
create or replace function public.apply_ghost_moves(p jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare w jsonb; v_old public.segment_ownership; v_tile text; v_street text; v_seen text[] := '{}';
begin
  update public.ai_ghosts set cursor_node = (p->>'cursor')::bigint, next_tick_at = to_timestamp((p->>'nextTick')::float8)
   where id = p->>'ghost';
  for w in select * from jsonb_array_elements(p->'moves') loop
    v_street := split_part(w->>'s', '#', 1);
    v_tile := coalesce(w->>'t', (select tile from public.segments where id = v_street));
    select * into v_old from public.segment_ownership where segment_id = w->>'s' for update;
    if v_old.segment_id is null then
      insert into public.segment_ownership (segment_id, tile, owner_kind, owner_id, club_id, captured_at, last_visited_at)
      values (w->>'s', v_tile, 'ghost', p->>'ghost', null, to_timestamp((w->>'c')::float8), to_timestamp((w->>'v')::float8));
    elsif v_old.owner_kind = 'ghost' and v_old.owner_id = p->>'ghost' then
      update public.segment_ownership set last_visited_at = greatest(last_visited_at, to_timestamp((w->>'v')::float8)) where segment_id = w->>'s';
    elsif v_old.last_visited_at < to_timestamp((w->>'c')::float8) then
      update public.segment_ownership set owner_kind = 'ghost', owner_id = p->>'ghost', club_id = null,
             captured_at = to_timestamp((w->>'c')::float8), last_visited_at = to_timestamp((w->>'v')::float8)
       where segment_id = w->>'s';
      if not ((v_old.owner_id || ':' || v_street) = any(v_seen)) then
        v_seen := v_seen || (v_old.owner_id || ':' || v_street);
        insert into public.ownership_events (segment_id, tile, from_kind, from_id, to_kind, to_id, cause)
        values (v_street, v_tile, v_old.owner_kind, v_old.owner_id, 'ghost', p->>'ghost', 'ghost');
      end if;
    end if;
  end loop;
  insert into public.notification_outbox (user_id, kind, title, body)
  select (r->>'user')::uuid, 'raid', 'Coins lost', r->>'message' from jsonb_array_elements(p->'raids') r;
end $$;
revoke execute on function public.apply_ghost_moves(jsonb) from public, anon, authenticated;

-- Leaderboards: bots count on 'nearby' only, by the coins they hold there.
create or replace function public.leaderboard(p_scope text, p_tile text)
returns table (user_id text, display_name text, color_hex text, tokens int)
language sql stable security definer set search_path = public, extensions as $$
  with per_token as (
    select coalesce((select (value->>'metresPerToken')::float8 from public.game_config where key = 'tokens'), 10) as m
  ),
  scored as (
    select c.user_id::text as owner_id, coalesce(c.tokens, greatest(1, round(s.length_m / pt.m))::int) as tokens,
           public.tile_region(s.tile) as region
      from public.captures c
      join public.segments s on s.id = c.segment_id
      cross join per_token pt
     where c.kind in ('captured', 'stolen')
  ),
  scoped as (
    select x.* from scored x
     where case p_scope
             when 'nearby' then x.region = public.tile_region(p_tile)
             when 'global' then true
             when 'friends' then x.owner_id = auth.uid()::text or exists (
               select 1 from public.friendships f where f.status = 'accepted'
                  and ((f.user_a = auth.uid() and f.user_b::text = x.owner_id) or (f.user_b = auth.uid() and f.user_a::text = x.owner_id)))
             when 'club' then exists (
               select 1 from public.memberships m1 join public.memberships m2 on m1.club_id = m2.club_id
                where m1.user_id = auth.uid() and m2.user_id::text = x.owner_id)
             else false end
  ),
  players as (
    select x.owner_id, p.display_name, p.color_hex, sum(x.tokens)::int as tokens
      from scoped x
      join public.profiles p on p.id::text = x.owner_id and not p.is_private
      left join public.user_trust t on t.user_id = p.id
     where not coalesce(t.shadow_restricted, false)
     group by x.owner_id, p.display_name, p.color_hex
  ),
  bots as (
    select so.owner_id, g.name as display_name, g.color_hex,
           sum(case when so.segment_id like '%#%' then 1
                    else greatest(1, round(coalesce(s.length_m, 0) / pt.m))::int end)::int as tokens
      from public.segment_ownership so
      join public.ai_ghosts g on g.id = so.owner_id
      left join public.segments s on s.id = split_part(so.segment_id, '#', 1)
      cross join per_token pt
     where p_scope = 'nearby' and so.owner_kind = 'ghost' and public.tile_region(so.tile) = public.tile_region(p_tile)
     group by so.owner_id, g.name, g.color_hex
  )
  select * from (select * from players union all select * from bots) a
   order by a.tokens desc
   limit 100
$$;
