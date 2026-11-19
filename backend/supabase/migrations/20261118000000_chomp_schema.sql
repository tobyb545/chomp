-- Chomp schema: PostGIS street segments, ownership, runs, anti-cheat, social.
-- Clients never write ownership, captures or run results: only the
-- resolve-run Edge Function (service role) does. RLS is on for every table.

create extension if not exists postgis with schema extensions;
create extension if not exists pg_cron;

-- "14/x/y" → parent "12/x/y" (district) and "10/x/y" (region).
create or replace function public.tile_parent(p_tile text, p_zoom int) returns text
language sql immutable as $$
  select p_zoom || '/' || (split_part(p_tile, '/', 2)::int >> (14 - p_zoom)) || '/' || (split_part(p_tile, '/', 3)::int >> (14 - p_zoom))
$$;
create or replace function public.tile_region(p_tile text) returns text language sql immutable as $$ select public.tile_parent(p_tile, 10) $$;

-- ---------------------------------------------------------------------------
-- Map data: zoom-14 tiles (~1.5 km) built on demand from OpenStreetMap by the
-- Edge Functions' StreetBuilder (same code as the app) and stored via
-- store_map_tile(). The game works anywhere; there are no fixed towns.
-- ---------------------------------------------------------------------------
create table public.map_tiles (
  key             text primary key,                 -- "14/x/y"
  district        text not null,                    -- "12/x/y": bots live per district (~6 km)
  region          text not null,                    -- "10/x/y": "Nearby" leaderboards (~25 km)
  boundary        geometry(Polygon, 4326) not null,
  data            jsonb not null,                   -- the TileFile, served to the matcher
  segment_count   int not null default 0,
  total_length_m  double precision not null default 0,
  osm_timestamp   timestamptz,
  built_at        timestamptz not null default now()
);
create index map_tiles_boundary_gix on public.map_tiles using gist (boundary);
create index map_tiles_district_idx on public.map_tiles (district);
create index map_tiles_region_idx on public.map_tiles (region);

create table public.segments (
  id           text primary key,
  tile         text not null references public.map_tiles(key) on delete cascade,
  geom         geometry(LineString, 4326) not null,
  length_m     double precision not null,
  name         text not null default '',
  highway      text not null,
  kind         text not null check (kind in ('road', 'path')),
  start_node   bigint not null,
  end_node     bigint not null,
  active       boolean not null default true
);
create index segments_geom_gix on public.segments using gist (geom);
create index segments_tile_idx on public.segments (tile) where active;

create table public.segment_lineage (
  old_id      text primary key,
  new_id      text not null,
  created_at  timestamptz not null default now()
);

create table public.blocks (
  id         text primary key,
  tile       text not null references public.map_tiles(key) on delete cascade,
  geom       geometry(Polygon, 4326) not null,
  area_m2    double precision not null
);
create table public.block_segments (
  block_id    text not null references public.blocks(id) on delete cascade,
  segment_id  text not null,  -- may belong to a neighbouring tile not built yet
  primary key (block_id, segment_id)
);
create index block_segments_segment_idx on public.block_segments (segment_id);

create table public.pois (
  id         text primary key,
  tile       text not null references public.map_tiles(key) on delete cascade,
  name       text not null,
  kind       text not null,
  location   geometry(Point, 4326) not null
);

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  display_name  text not null check (char_length(display_name) between 2 and 20),
  color_hex     text not null default 'C6FF00' check (color_hex ~ '^[0-9A-Fa-f]{6}$'),
  is_private    boolean not null default false,
  created_at    timestamptz not null default now()
);
create unique index profiles_name_uniq on public.profiles (lower(display_name));

create table public.clubs (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (char_length(name) between 3 and 30),
  color_hex    text not null check (color_hex ~ '^[0-9A-Fa-f]{6}$'),
  owner_id     uuid not null references public.profiles(id) on delete cascade,
  invite_code  text not null unique default upper(substr(md5(random()::text), 1, 6)),
  created_at   timestamptz not null default now()
);

create table public.memberships (
  club_id    uuid not null references public.clubs(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  role       text not null default 'member' check (role in ('owner', 'admin', 'member')),
  joined_at  timestamptz not null default now(),
  primary key (club_id, user_id)
);
create index memberships_user_idx on public.memberships (user_id);

create table public.friendships (
  user_a      uuid not null references public.profiles(id) on delete cascade,
  user_b      uuid not null references public.profiles(id) on delete cascade,
  status      text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at  timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a <> user_b)
);

create table public.user_relations (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  target_id   uuid not null references public.profiles(id) on delete cascade,
  kind        text not null check (kind in ('block', 'mute')),
  created_at  timestamptz not null default now(),
  primary key (user_id, target_id, kind)
);

create table public.entitlements (
  user_id      uuid not null references public.profiles(id) on delete cascade,
  entitlement  text not null,
  expires_at   timestamptz,
  updated_at   timestamptz not null default now(),
  primary key (user_id, entitlement)
);

-- Pro from the App Store (RevenueCat: 'pro') or earned through invites ('pro_invite').
create or replace function public.has_pro(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.entitlements e where e.user_id = p_user and e.entitlement in ('pro', 'pro_invite')
                   and (e.expires_at is null or e.expires_at > now()))
$$;
revoke execute on function public.has_pro(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Game state
-- ---------------------------------------------------------------------------
create type public.owner_kind as enum ('player', 'ghost');

create table public.ai_ghosts (
  id            text primary key,
  district      text not null,
  name          text not null,
  color_hex     text not null,
  personality   jsonb not null default '{}',
  cursor_node   bigint,
  next_tick_at  timestamptz not null default now()
);

create table public.segment_ownership (
  segment_id       text primary key references public.segments(id) on delete cascade,
  tile             text not null,
  owner_kind       public.owner_kind not null,
  owner_id         text not null,           -- profiles.id::text or ai_ghosts.id
  club_id          uuid references public.clubs(id) on delete set null,
  captured_at      timestamptz not null,
  last_visited_at  timestamptz not null
);
create index segment_ownership_owner_idx on public.segment_ownership (owner_kind, owner_id);
create index segment_ownership_tile_idx on public.segment_ownership (tile);

-- Strength is derived, never stored: 1 when fresh, 0 at the decay horizon.
create or replace function public.ownership_strength(last_visited timestamptz, decay_days double precision default 21)
returns double precision language sql immutable as $$
  select greatest(0, least(1, 1 - extract(epoch from (now() - last_visited)) / (decay_days * 86400)))
$$;

create table public.ownership_events (
  id          bigint generated always as identity primary key,
  segment_id  text not null references public.segments(id) on delete cascade,
  tile        text not null,
  from_kind   public.owner_kind,
  from_id     text,
  to_kind     public.owner_kind,
  to_id       text,
  cause       text not null check (cause in ('capture', 'flip', 'frenzy', 'decay', 'ghost', 'lineage')),
  run_id      uuid,
  at          timestamptz not null default now()
);
create index ownership_events_to_idx on public.ownership_events (to_id, at desc);
create index ownership_events_from_idx on public.ownership_events (from_id, at desc);

create table public.personal_coverage (
  user_id      uuid not null references public.profiles(id) on delete cascade,
  segment_id   text not null references public.segments(id) on delete cascade,
  first_at     timestamptz not null,
  last_at      timestamptz not null,
  times_run    int not null default 1,
  source       text not null default 'live' check (source in ('live', 'import')),
  primary key (user_id, segment_id)
);

create table public.runs (
  id               uuid primary key,
  user_id          uuid not null references public.profiles(id) on delete cascade,
  source           text not null check (source in ('live', 'health_import', 'strava_import')),
  started_at       timestamptz not null,
  ended_at         timestamptz not null,
  distance_m       double precision not null default 0,
  status           text not null default 'processing'
                   check (status in ('processing', 'resolved', 'under_review', 'rejected')),
  matched_polyline text,
  stats            jsonb not null default '{}',
  points           int not null default 0,
  client_version   text,
  created_at       timestamptz not null default now()
);
create index runs_user_idx on public.runs (user_id, started_at desc);

-- Raw (already privacy-trimmed) traces live in Storage bucket "traces", owner-only.
create table public.run_traces (
  run_id        uuid primary key references public.runs(id) on delete cascade,
  storage_path  text not null,
  point_count   int not null
);

create table public.captures (
  id              bigint generated always as identity primary key,
  run_id          uuid not null references public.runs(id) on delete cascade,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  segment_id      text not null references public.segments(id) on delete cascade,
  kind            text not null check (kind in ('captured', 'stolen', 'refreshed', 'rejected', 'partial')),
  coverage_ratio  double precision not null,
  points          int not null default 0,
  multiplier      double precision not null default 1,
  previous_owner  text,
  reject_reason   text,
  at              timestamptz not null
);
create index captures_run_idx on public.captures (run_id);
create index captures_user_day_idx on public.captures (user_id, at);

-- Daily spawns are deterministic per tile (same seed on client and server),
-- so they aren't stored; only collections are.
create table public.pellet_collections (
  pellet_id     text not null,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  run_id        uuid references public.runs(id) on delete set null,
  collected_at  timestamptz not null,
  primary key (pellet_id, user_id)
);

create table public.block_awards (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  block_id    text not null references public.blocks(id) on delete cascade,
  awarded_at  timestamptz not null,
  points      int not null,
  primary key (user_id, block_id, awarded_at)
);

create table public.local_bosses (
  region      text not null,             -- "10/x/y"
  week_start  date not null,
  user_id     uuid references public.profiles(id) on delete set null,
  streets     int not null,
  primary key (region, week_start)
);

-- ---------------------------------------------------------------------------
-- Trust & safety
-- ---------------------------------------------------------------------------
create table public.flags (
  id          bigint generated always as identity primary key,
  run_id      uuid references public.runs(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  rule        text not null,
  severity    smallint not null check (severity between 0 and 2),
  details     jsonb not null default '{}',
  created_at  timestamptz not null default now()
);
create index flags_user_idx on public.flags (user_id, created_at desc);

create table public.reports (
  id                bigint generated always as identity primary key,
  reporter_id       uuid not null references public.profiles(id) on delete cascade,
  reported_user_id  uuid not null references public.profiles(id) on delete cascade,
  run_id            uuid references public.runs(id) on delete set null,
  reason            text not null,
  notes             text not null default '',
  status            text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  created_at        timestamptz not null default now(),
  check (reporter_id <> reported_user_id)
);

create table public.user_trust (
  user_id            uuid primary key references public.profiles(id) on delete cascade,
  score              double precision not null default 1,
  shadow_restricted  boolean not null default false,
  notes              text not null default '',
  updated_at         timestamptz not null default now()
);

create table public.admins (user_id uuid primary key references auth.users(id) on delete cascade);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

-- Human review queue: runs held back plus reported players, newest first.
create or replace view public.review_queue with (security_invoker = true) as
  select 'run'::text as item_type, r.id::text as item_id, r.user_id, p.display_name, r.created_at,
         (select jsonb_agg(jsonb_build_object('rule', f.rule, 'severity', f.severity, 'details', f.details))
            from public.flags f where f.run_id = r.id) as evidence
    from public.runs r join public.profiles p on p.id = r.user_id
   where r.status = 'under_review'
  union all
  select 'report', rp.id::text, rp.reported_user_id, p.display_name, rp.created_at,
         jsonb_build_object('reason', rp.reason, 'notes', rp.notes, 'reporter', rp.reporter_id)
    from public.reports rp join public.profiles p on p.id = rp.reported_user_id
   where rp.status = 'open';

create table public.game_config (
  key    text primary key,
  value  jsonb not null
);

-- ---------------------------------------------------------------------------
-- Public read model. Never exposes runs, traces, start/end points or times
-- finer than the hour.
-- ---------------------------------------------------------------------------
create or replace view public.segment_ownership_public with (security_invoker = false) as
  select so.segment_id, so.tile, so.owner_kind::text as owner_kind, so.owner_id,
         coalesce(p.display_name, g.name, 'Rival') as owner_name,
         coalesce(p.color_hex, g.color_hex, '8888AA') as owner_color,
         date_trunc('hour', so.captured_at) as captured_at,
         date_trunc('hour', so.last_visited_at) as last_visited_at
    from public.segment_ownership so
    left join public.profiles p on so.owner_kind = 'player' and p.id::text = so.owner_id
    left join public.ai_ghosts g on so.owner_kind = 'ghost' and g.id = so.owner_id
    left join public.user_trust t on so.owner_kind = 'player' and t.user_id::text = so.owner_id
   where public.ownership_strength(so.last_visited_at) > 0
     and (p.id is null or not p.is_private)
     -- Shadow-restricted players' streets are visible only to themselves.
     and (coalesce(t.shadow_restricted, false) = false or so.owner_id = auth.uid()::text)
     -- Hide players the viewer has blocked.
     and not exists (select 1 from public.user_relations ur
                      where ur.user_id = auth.uid() and ur.kind = 'block' and ur.target_id::text = so.owner_id);
grant select on public.segment_ownership_public to anon, authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.map_tiles enable row level security;
alter table public.segments enable row level security;
alter table public.segment_lineage enable row level security;
alter table public.blocks enable row level security;
alter table public.block_segments enable row level security;
alter table public.pois enable row level security;
alter table public.profiles enable row level security;
alter table public.clubs enable row level security;
alter table public.memberships enable row level security;
alter table public.friendships enable row level security;
alter table public.user_relations enable row level security;
alter table public.entitlements enable row level security;
alter table public.ai_ghosts enable row level security;
alter table public.segment_ownership enable row level security;
alter table public.ownership_events enable row level security;
alter table public.personal_coverage enable row level security;
alter table public.runs enable row level security;
alter table public.run_traces enable row level security;
alter table public.captures enable row level security;
alter table public.pellet_collections enable row level security;
alter table public.block_awards enable row level security;
alter table public.local_bosses enable row level security;
alter table public.flags enable row level security;
alter table public.reports enable row level security;
alter table public.user_trust enable row level security;
alter table public.admins enable row level security;
alter table public.game_config enable row level security;

-- Map data and config: readable by everyone, written only by the service role.
create policy "Map tiles are public" on public.map_tiles for select using (true);
create policy "Segments are public" on public.segments for select using (true);
create policy "Segment lineage is public" on public.segment_lineage for select using (true);
create policy "Blocks are public" on public.blocks for select using (true);
create policy "Block segments are public" on public.block_segments for select using (true);
create policy "Landmarks are public" on public.pois for select using (true);
create policy "Bots are public" on public.ai_ghosts for select using (true);
create policy "Local bosses are public" on public.local_bosses for select using (true);
create policy "Game config is public" on public.game_config for select using (true);

-- Ownership itself is read through segment_ownership_public; the raw table is admin-only.
create policy "Admins can read raw ownership" on public.segment_ownership for select using (public.is_admin());

-- Ownership events: you can see events involving you (rounded via the app), nothing else.
create policy "Players see events involving them" on public.ownership_events for select
  using (to_id = auth.uid()::text or from_id = auth.uid()::text);

-- Profiles: public profiles readable; you manage your own.
create policy "Public profiles are readable" on public.profiles for select using (not is_private or id = auth.uid());
create policy "Players create their own profile" on public.profiles for insert with check (id = auth.uid());
create policy "Players update their own profile" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- Clubs
create policy "Clubs are readable by signed-in players" on public.clubs for select to authenticated using (true);
create policy "Club owners update their club" on public.clubs for update using (owner_id = auth.uid());
create policy "Club owners delete their club" on public.clubs for delete using (owner_id = auth.uid());
-- Helper avoids a policy that queries its own table (Postgres rejects that as infinite recursion).
create or replace function public.is_club_member(p_club uuid) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from public.memberships where club_id = p_club and user_id = auth.uid())
$$;
create policy "Members see their club rosters" on public.memberships for select
  using (user_id = auth.uid() or public.is_club_member(club_id));
create policy "Players can leave clubs" on public.memberships for delete using (user_id = auth.uid());

-- Friends, blocks, mutes: only your own rows.
create policy "Players see their own friendships" on public.friendships for select using (auth.uid() in (user_a, user_b));
create policy "Players remove their own friendships" on public.friendships for delete using (auth.uid() in (user_a, user_b));
create policy "Players see their own blocks and mutes" on public.user_relations for select using (user_id = auth.uid());
create policy "Players add their own blocks and mutes" on public.user_relations for insert with check (user_id = auth.uid());
create policy "Players update their own blocks and mutes" on public.user_relations for update using (user_id = auth.uid());
create policy "Players remove their own blocks and mutes" on public.user_relations for delete using (user_id = auth.uid());

-- Private data: owner-only reads; all writes via the service role.
create policy "Players read their own entitlements" on public.entitlements for select using (user_id = auth.uid());
create policy "Players read their own coverage" on public.personal_coverage for select using (user_id = auth.uid());
create policy "Players read their own runs" on public.runs for select using (user_id = auth.uid());
create policy "Players read their own traces" on public.run_traces for select
  using (exists (select 1 from public.runs r where r.id = run_id and r.user_id = auth.uid()));
create policy "Players read their own captures" on public.captures for select using (user_id = auth.uid());
create policy "Players read their own pellet collections" on public.pellet_collections for select using (user_id = auth.uid());
create policy "Players read their own block awards" on public.block_awards for select using (user_id = auth.uid());

-- Reports: anyone signed in can file; only admins read.
create policy "Players file reports as themselves" on public.reports for insert with check (reporter_id = auth.uid());
create policy "Admins read reports" on public.reports for select using (public.is_admin());
create policy "Admins update reports" on public.reports for update using (public.is_admin());

-- Flags & trust: admin-only (players are never told about shadow restrictions).
create policy "Admins read flags" on public.flags for select using (public.is_admin());
create policy "Admins read trust" on public.user_trust for select using (public.is_admin());
create policy "Admins update trust" on public.user_trust for update using (public.is_admin());
create policy "Admins see the admin list" on public.admins for select using (public.is_admin());

-- ---------------------------------------------------------------------------
-- RPCs used by the app
-- ---------------------------------------------------------------------------

-- Re-points ownership/coverage after a tile rebuild re-splits segments.
create or replace function public.apply_segment_lineage() returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into public.segment_ownership (segment_id, tile, owner_kind, owner_id, club_id, captured_at, last_visited_at)
  select l.new_id, s.tile, so.owner_kind, so.owner_id, so.club_id, so.captured_at, so.last_visited_at
    from public.segment_lineage l
    join public.segment_ownership so on so.segment_id = l.old_id
    join public.segments s on s.id = l.new_id
  on conflict (segment_id) do update
    set last_visited_at = greatest(segment_ownership.last_visited_at, excluded.last_visited_at)
    where excluded.last_visited_at > segment_ownership.last_visited_at;
  delete from public.segment_ownership so using public.segment_lineage l where so.segment_id = l.old_id;

  insert into public.personal_coverage (user_id, segment_id, first_at, last_at, times_run, source)
  select pc.user_id, l.new_id, pc.first_at, pc.last_at, pc.times_run, pc.source
    from public.segment_lineage l join public.personal_coverage pc on pc.segment_id = l.old_id
    join public.segments s on s.id = l.new_id
  on conflict (user_id, segment_id) do nothing;
  delete from public.personal_coverage pc using public.segment_lineage l where pc.segment_id = l.old_id;
end $$;

-- Leaderboards rank by tokens captured: every street a player captured or
-- stole earns its tokens (one per metresPerToken of street, at least one),
-- the same dots the app draws. Private and shadow-restricted players excluded.
-- 'nearby' = captures on streets in the same zoom-10 region (~25 km) as p_tile.
create or replace function public.leaderboard(p_scope text, p_tile text)
returns table (user_id text, display_name text, color_hex text, tokens int)
language sql stable security definer set search_path = public, extensions as $$
  with per_token as (
    select coalesce((select (value->>'metresPerToken')::float8 from public.game_config where key = 'tokens'), 10) as m
  ),
  scored as (
    select c.user_id::text as owner_id, greatest(1, round(s.length_m / pt.m))::int as tokens, public.tile_region(s.tile) as region
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

create or replace function public.my_clubs()
returns table (id uuid, name text, color_hex text, member_count int, invite_code text)
language sql stable security definer set search_path = public, extensions as $$
  select c.id, c.name, c.color_hex, (select count(*)::int from public.memberships m2 where m2.club_id = c.id),
         case when m.role in ('owner', 'admin') then c.invite_code end
    from public.clubs c join public.memberships m on m.club_id = c.id
   where m.user_id = auth.uid()
$$;

create or replace function public.create_club(p_name text, p_color text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.has_pro(auth.uid()) then
    raise exception 'Clubs are part of Chomp Pro';
  end if;
  insert into public.clubs (name, color_hex, owner_id) values (p_name, p_color, auth.uid()) returning id into v_id;
  insert into public.memberships (club_id, user_id, role) values (v_id, auth.uid(), 'owner');
  return v_id;
end $$;

create or replace function public.join_club(p_code text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select id into v_id from public.clubs where invite_code = upper(p_code);
  if v_id is null then raise exception 'No club with that code'; end if;
  insert into public.memberships (club_id, user_id) values (v_id, auth.uid()) on conflict do nothing;
  return v_id;
end $$;

create or replace function public.my_friends()
returns table (id uuid, display_name text, color_hex text, streets_held int)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.display_name, p.color_hex,
         (select count(*)::int from public.segment_ownership so
           where so.owner_kind = 'player' and so.owner_id = p.id::text and public.ownership_strength(so.last_visited_at) > 0)
    from public.friendships f
    join public.profiles p on p.id = case when f.user_a = auth.uid() then f.user_b else f.user_a end
   where f.status = 'accepted' and auth.uid() in (f.user_a, f.user_b)
$$;

create or replace function public.request_friend(p_handle text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_target uuid;
begin
  select id into v_target from public.profiles where lower(display_name) = lower(p_handle) and not is_private;
  if v_target is null then raise exception 'No runner with that name'; end if;
  if v_target = auth.uid() then raise exception 'That''s you'; end if;
  if exists (select 1 from public.user_relations where user_id = v_target and target_id = auth.uid() and kind = 'block') then
    return; -- silently ignore: don't reveal blocks
  end if;
  -- If they already asked us, accept; otherwise create a pending request.
  update public.friendships set status = 'accepted' where user_a = v_target and user_b = auth.uid();
  if not found then
    insert into public.friendships (user_a, user_b) values (auth.uid(), v_target) on conflict do nothing;
  end if;
end $$;

create or replace function public.delete_own_account() returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from public.segment_ownership where owner_kind = 'player' and owner_id = auth.uid()::text;
  delete from public.clubs where owner_id = auth.uid();
  delete from auth.users where id = auth.uid();  -- cascades to profiles and everything keyed on it
end $$;

grant execute on function public.leaderboard(text, text), public.my_clubs(), public.create_club(text, text),
  public.join_club(text), public.my_friends(), public.request_friend(text), public.delete_own_account()
  to authenticated;
revoke execute on function public.apply_segment_lineage() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Scheduled jobs
-- ---------------------------------------------------------------------------

-- Faded streets go neutral (logged so rivals' feeds can show it).
create or replace function public.decay_sweep() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  with gone as (
    delete from public.segment_ownership so
     where public.ownership_strength(so.last_visited_at,
             coalesce((select (value->>'days')::double precision from public.game_config where key = 'decay'), 21)) <= 0
    returning so.segment_id, so.tile, so.owner_kind, so.owner_id
  )
  insert into public.ownership_events (segment_id, tile, from_kind, from_id, cause)
  select segment_id, tile, owner_kind, owner_id, 'decay' from gone;
  get diagnostics n = row_count;
  return n;
end $$;

-- Weekly local boss per region (~25 km): most streets held at Monday 00:00 UK time.
create or replace function public.crown_local_bosses() returns void
language sql security definer set search_path = public, extensions as $$
  insert into public.local_bosses (region, week_start, user_id, streets)
  select distinct on (r.region) r.region, (now() at time zone 'Europe/London')::date, r.owner_id::uuid, r.n
    from (select public.tile_region(so.tile) as region, so.owner_id, count(*)::int as n
            from public.segment_ownership so
            join public.profiles p on p.id::text = so.owner_id and not p.is_private
           where so.owner_kind = 'player' and public.ownership_strength(so.last_visited_at) > 0
           group by 1, 2) r
   order by r.region, r.n desc
  on conflict (region, week_start) do update set user_id = excluded.user_id, streets = excluded.streets
$$;

select cron.schedule('chomp-decay', '15 * * * *', $$select public.decay_sweep()$$);
select cron.schedule('chomp-local-boss', '0 0 * * 1', $$select public.crown_local_bosses()$$);

insert into public.game_config (key, value) values
  ('decay', '{"days": 21}'),
  ('capture', '{"coverageThreshold": 0.8, "frenzyRivalCoverageThreshold": 0.4}'),
  ('tokens', '{"metresPerToken": 10}')
on conflict (key) do nothing;

-- Districts where players hold live streets: where the server runs bots.
create or replace view public.active_districts with (security_invoker = false) as
  select public.tile_parent(so.tile, 12) as district, count(*) as player_streets
    from public.segment_ownership so
   where so.owner_kind = 'player' and public.ownership_strength(so.last_visited_at) > 0
   group by 1
   order by 2 desc;
revoke all on public.active_districts from anon, authenticated;
