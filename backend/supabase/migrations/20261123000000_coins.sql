-- Coins: ownership is per coin, not per street. Every street is lined with
-- coins (one per tokens.metresPerToken, at least one, evenly spaced) and a run
-- takes the coins it passes. Ownership rows are keyed "<segment id>#<coin>".
-- Mirrors ChompKit/Game/Coins.swift and chomp/coins.ts.
--
-- Run this BEFORE redeploying the Edge Functions that write coin IDs.

-- ---------------------------------------------------------------------------
-- Ownership keyed by coin. street_id is derived and keeps the cascade on segments.
-- ---------------------------------------------------------------------------
alter table public.segment_ownership drop constraint if exists segment_ownership_segment_id_fkey;
alter table public.segment_ownership
  add column if not exists street_id text generated always as (split_part(segment_id, '#', 1)) stored
  references public.segments(id) on delete cascade;
create index if not exists segment_ownership_street_idx on public.segment_ownership (street_id);

alter table public.segment_ownership_feed drop constraint if exists segment_ownership_feed_segment_id_fkey;

-- Existing whole-street ownership: the owner now holds every coin on the street.
with per_token as (
  select coalesce((select (value->>'metresPerToken')::float8 from public.game_config where key = 'tokens'), 10) as m
)
insert into public.segment_ownership (segment_id, tile, owner_kind, owner_id, club_id, captured_at, last_visited_at)
select so.segment_id || '#' || k, so.tile, so.owner_kind, so.owner_id, so.club_id, so.captured_at, so.last_visited_at
  from public.segment_ownership so
  join public.segments s on s.id = so.segment_id
  cross join per_token pt
  cross join lateral generate_series(0, greatest(1, round(s.length_m / pt.m))::int - 1) k
 where position('#' in so.segment_id) = 0
on conflict (segment_id) do nothing;
delete from public.segment_ownership where position('#' in segment_id) = 0;

-- ---------------------------------------------------------------------------
-- Captures record how many coins they took; leaderboards sum coins.
-- ---------------------------------------------------------------------------
alter table public.captures add column if not exists tokens int;

create or replace function public.leaderboard(p_scope text, p_tile text)
returns table (user_id text, display_name text, color_hex text, tokens int)
language sql stable security definer set search_path = public, extensions as $$
  with per_token as (
    select coalesce((select (value->>'metresPerToken')::float8 from public.game_config where key = 'tokens'), 10) as m
  ),
  scored as (
    -- Captures from before coins took the whole street.
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
  )
  select x.owner_id, p.display_name, p.color_hex, sum(x.tokens)::int
    from scoped x
    join public.profiles p on p.id::text = x.owner_id and not p.is_private
    left join public.user_trust t on t.user_id = p.id
   where not coalesce(t.shadow_restricted, false)
   group by x.owner_id, p.display_name, p.color_hex
   order by sum(x.tokens) desc
   limit 100
$$;

-- ---------------------------------------------------------------------------
-- Applying a run: one write per coin. Events and "street lost" notifications
-- stay per street (one per street per run, not one per coin).
-- ---------------------------------------------------------------------------
create or replace function public.apply_run_result(p jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_run uuid := (p->>'runId')::uuid;
  v_user uuid := (p->>'userId')::uuid;
  w jsonb;
  v_street text;
  v_tile text;
  v_old public.segment_ownership;
  v_seen text[] := '{}';
begin
  insert into public.runs (id, user_id, source, started_at, ended_at, distance_m, status, matched_polyline, stats, points, client_version)
  values (v_run, v_user, p->>'source', to_timestamp((p->>'startedAt')::float8), to_timestamp((p->>'endedAt')::float8),
          (p->>'distance')::float8, p->>'status', p->>'matchedPolyline', p->'stats', (p->>'points')::int, p->>'clientVersion')
  on conflict (id) do nothing;
  if not found then return; end if;  -- idempotent: already applied

  insert into public.run_traces (run_id, storage_path, point_count) values (v_run, p->>'tracePath', (p->>'pointCount')::int);

  insert into public.captures (run_id, user_id, segment_id, kind, coverage_ratio, points, multiplier, previous_owner, reject_reason, at, tokens)
  select v_run, v_user, c->>'segmentID', c->>'kind', (c->>'coverage')::float8, (c->>'points')::int, (c->>'multiplier')::float8,
         c->'previousOwner'->>'id', c->>'reason', to_timestamp((c->>'at')::float8), (c->>'tokens')::int
    from jsonb_array_elements(p->'captures') c where c->>'kind' <> 'partial';

  insert into public.flags (run_id, user_id, rule, severity, details)
  select v_run, v_user, f->>'rule', (f->>'severity')::smallint, jsonb_build_object('detail', f->>'detail')
    from jsonb_array_elements(p->'flags') f;

  for w in select * from jsonb_array_elements(p->'ownership') loop
    v_street := split_part(w->>'s', '#', 1);
    v_tile := coalesce(w->>'t', (select tile from public.segments where id = v_street));
    select * into v_old from public.segment_ownership where segment_id = w->>'s' for update;
    if v_old.segment_id is null then
      insert into public.segment_ownership (segment_id, tile, owner_kind, owner_id, club_id, captured_at, last_visited_at)
      values (w->>'s', v_tile, 'player', v_user::text, null, to_timestamp((w->>'c')::float8), to_timestamp((w->>'v')::float8));
      if not (('c:' || v_street) = any(v_seen)) then
        v_seen := v_seen || ('c:' || v_street);
        insert into public.ownership_events (segment_id, tile, to_kind, to_id, cause, run_id)
        values (v_street, v_tile, 'player', v_user::text, case when (p->>'frenzy')::boolean then 'frenzy' else 'capture' end, v_run);
      end if;
    elsif v_old.owner_kind = 'player' and v_old.owner_id = v_user::text then
      update public.segment_ownership set last_visited_at = greatest(last_visited_at, to_timestamp((w->>'v')::float8))
       where segment_id = w->>'s';
    elsif v_old.captured_at < to_timestamp((w->>'c')::float8) then
      update public.segment_ownership set owner_kind = 'player', owner_id = v_user::text, club_id = null,
             captured_at = to_timestamp((w->>'c')::float8), last_visited_at = to_timestamp((w->>'v')::float8)
       where segment_id = w->>'s';
      if not (('f:' || v_old.owner_id || ':' || v_street) = any(v_seen)) then
        v_seen := v_seen || ('f:' || v_old.owner_id || ':' || v_street);
        insert into public.ownership_events (segment_id, tile, from_kind, from_id, to_kind, to_id, cause, run_id)
        values (v_street, v_tile, v_old.owner_kind, v_old.owner_id, 'player', v_user::text, 'flip', v_run);
        if v_old.owner_kind = 'player' then
          insert into public.notification_outbox (user_id, kind, title, body)
          select v_old.owner_id::uuid, 'lost', 'Coins lost', (select display_name from public.profiles where id = v_user)
                 || ' just took your coins on ' || coalesce(nullif((select name from public.segments where id = v_street), ''), 'one of your streets')
          where not exists (select 1 from public.user_relations ur where ur.user_id = v_old.owner_id::uuid
                              and ur.target_id = v_user and ur.kind in ('block', 'mute'));
        end if;
      end if;
    end if;
  end loop;

  insert into public.personal_coverage (user_id, segment_id, first_at, last_at, times_run, source)
  select v_user, c->>'s', to_timestamp((c->>'t')::float8), to_timestamp((c->>'t')::float8), 1,
         case when p->>'source' = 'live' then 'live' else 'import' end
    from jsonb_array_elements(p->'coverage') c
  on conflict (user_id, segment_id) do update set
    first_at = least(personal_coverage.first_at, excluded.first_at),
    last_at = greatest(personal_coverage.last_at, excluded.last_at),
    times_run = personal_coverage.times_run + 1,
    source = case when personal_coverage.source = 'live' or excluded.source = 'live' then 'live' else 'import' end;

  insert into public.pellet_collections (pellet_id, user_id, run_id, collected_at)
  select x->>'id', v_user, v_run, to_timestamp((x->>'t')::float8) from jsonb_array_elements(p->'pellets') x
  on conflict do nothing;

  insert into public.block_awards (user_id, block_id, awarded_at, points)
  select v_user, x->>'id', to_timestamp((x->>'t')::float8), (x->>'points')::int from jsonb_array_elements(p->'blockAwards') x
  on conflict do nothing;

  insert into public.badges (user_id, badge)
  select v_user, 'conquered:' || t from jsonb_array_elements_text(coalesce(p->'conquered', '[]'::jsonb)) t
  on conflict do nothing;
end $$;

-- Bot moves: one per coin; one event per street.
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
  select (r->>'user')::uuid, 'raid', 'Bot raid', r->>'message' from jsonb_array_elements(p->'raids') r;
end $$;

revoke execute on function public.apply_run_result(jsonb), public.apply_ghost_moves(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Map rebuilds that re-split streets: the new street's coins go to whoever
-- held most coins on the old one (latest capture breaks ties).
-- ---------------------------------------------------------------------------
create or replace function public.apply_segment_lineage() returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  with per_token as (
    select coalesce((select (value->>'metresPerToken')::float8 from public.game_config where key = 'tokens'), 10) as m
  ),
  counts as (
    select l.new_id, so.owner_kind, so.owner_id, count(*) as n, max(so.captured_at) as captured_at,
           max(so.last_visited_at) as last_visited_at
      from public.segment_lineage l
      join public.segment_ownership so on so.street_id = l.old_id
     group by 1, 2, 3
  ),
  winner as (
    select distinct on (new_id) * from counts order by new_id, n desc, captured_at desc
  )
  insert into public.segment_ownership (segment_id, tile, owner_kind, owner_id, club_id, captured_at, last_visited_at)
  select w.new_id || '#' || k, s.tile, w.owner_kind, w.owner_id, null, w.captured_at, w.last_visited_at
    from winner w
    join public.segments s on s.id = w.new_id
    cross join per_token pt
    cross join lateral generate_series(0, greatest(1, round(s.length_m / pt.m))::int - 1) k
  on conflict (segment_id) do update
    set last_visited_at = greatest(segment_ownership.last_visited_at, excluded.last_visited_at)
    where excluded.last_visited_at > segment_ownership.last_visited_at;
  delete from public.segment_ownership so using public.segment_lineage l
   where so.street_id = l.old_id and so.street_id <> all (select new_id from public.segment_lineage);

  insert into public.personal_coverage (user_id, segment_id, first_at, last_at, times_run, source)
  select pc.user_id, l.new_id, pc.first_at, pc.last_at, pc.times_run, pc.source
    from public.segment_lineage l join public.personal_coverage pc on pc.segment_id = l.old_id
    join public.segments s on s.id = l.new_id
  on conflict (user_id, segment_id) do nothing;
  delete from public.personal_coverage pc using public.segment_lineage l where pc.segment_id = l.old_id;
end $$;
revoke execute on function public.apply_segment_lineage() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- "Streets held" counts streets with at least one of your coins.
-- ---------------------------------------------------------------------------
create or replace function public.my_friends()
returns table (id uuid, display_name text, color_hex text, streets_held int)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.display_name, p.color_hex,
         (select count(distinct so.street_id)::int from public.segment_ownership so
           where so.owner_kind = 'player' and so.owner_id = p.id::text and public.ownership_strength(so.last_visited_at) > 0)
    from public.friendships f
    join public.profiles p on p.id = case when f.user_a = auth.uid() then f.user_b else f.user_a end
   where f.status = 'accepted' and auth.uid() in (f.user_a, f.user_b)
$$;

create or replace function public.crown_local_bosses() returns void
language sql security definer set search_path = public, extensions as $$
  insert into public.local_bosses (region, week_start, user_id, streets)
  select distinct on (r.region) r.region, (now() at time zone 'Europe/London')::date, r.owner_id::uuid, r.n
    from (select public.tile_region(so.tile) as region, so.owner_id, count(distinct so.street_id)::int as n
            from public.segment_ownership so
            join public.profiles p on p.id::text = so.owner_id and not p.is_private
           where so.owner_kind = 'player' and public.ownership_strength(so.last_visited_at) > 0
           group by 1, 2) r
   order by r.region, r.n desc
  on conflict (region, week_start) do update set user_id = excluded.user_id, streets = excluded.streets
$$;

create or replace view public.active_districts with (security_invoker = false) as
  select public.tile_parent(so.tile, 12) as district, count(distinct so.street_id) as player_streets
    from public.segment_ownership so
   where so.owner_kind = 'player' and public.ownership_strength(so.last_visited_at) > 0
   group by 1
   order by 2 desc;
revoke all on public.active_districts from anon, authenticated;

-- Fading (when switched back on) logs one event per street.
create or replace function public.decay_sweep() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  if coalesce((select (value->>'enabled')::boolean from public.game_config where key = 'decay'), true) = false then
    return 0;
  end if;
  with gone as (
    delete from public.segment_ownership so
     where public.ownership_strength(so.last_visited_at,
             coalesce((select (value->>'days')::double precision from public.game_config where key = 'decay'), 21)) <= 0
    returning so.street_id, so.tile, so.owner_kind, so.owner_id
  )
  insert into public.ownership_events (segment_id, tile, from_kind, from_id, cause)
  select distinct street_id, tile, owner_kind, owner_id, 'decay' from gone;
  get diagnostics n = row_count;
  return n;
end $$;

update public.game_config set value = value || '{"coinReachMetres": 5}' where key = 'capture';
