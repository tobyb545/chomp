-- Support for the Edge Functions: area bundles, atomic run application,
-- a public realtime feed, bots, badges, Strava tokens and the trace bucket.

-- ---------------------------------------------------------------------------
-- Public ownership feed for Realtime. Realtime honours RLS, and the raw
-- ownership table is private, so a trigger mirrors the public columns here.
-- Private and shadow-restricted players never appear in the feed.
-- ---------------------------------------------------------------------------
create table public.segment_ownership_feed (
  segment_id       text primary key references public.segments(id) on delete cascade,
  area_slug        text not null,
  owner_kind       text not null,
  owner_id         text not null,
  owner_name       text not null,
  owner_color      text not null,
  captured_at      timestamptz not null,
  last_visited_at  timestamptz not null
);
create index segment_ownership_feed_area_idx on public.segment_ownership_feed (area_slug);
alter table public.segment_ownership_feed enable row level security;
create policy "Ownership feed is public" on public.segment_ownership_feed for select using (true);

create or replace function public.mirror_ownership() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_name text; v_color text; v_hidden boolean := false;
begin
  if tg_op = 'DELETE' then
    delete from public.segment_ownership_feed where segment_id = old.segment_id;
    return old;
  end if;
  if new.owner_kind = 'player' then
    select p.display_name, p.color_hex, p.is_private or coalesce(t.shadow_restricted, false)
      into v_name, v_color, v_hidden
      from public.profiles p left join public.user_trust t on t.user_id = p.id
     where p.id::text = new.owner_id;
  else
    select g.name, g.color_hex into v_name, v_color from public.ai_ghosts g where g.id = new.owner_id;
  end if;
  if coalesce(v_hidden, false) then
    delete from public.segment_ownership_feed where segment_id = new.segment_id;
  else
    insert into public.segment_ownership_feed values (new.segment_id, new.area_slug, new.owner_kind::text, new.owner_id,
      coalesce(v_name, 'Rival'), coalesce(v_color, '8888AA'),
      date_trunc('hour', new.captured_at), date_trunc('hour', new.last_visited_at))
    on conflict (segment_id) do update set owner_kind = excluded.owner_kind, owner_id = excluded.owner_id,
      owner_name = excluded.owner_name, owner_color = excluded.owner_color,
      captured_at = excluded.captured_at, last_visited_at = excluded.last_visited_at;
  end if;
  return new;
end $$;
create trigger segment_ownership_mirror after insert or update or delete on public.segment_ownership
  for each row execute function public.mirror_ownership();

alter publication supabase_realtime add table public.segment_ownership_feed;

create table public.badges (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  badge       text not null,
  awarded_at  timestamptz not null default now(),
  primary key (user_id, badge)
);
alter table public.badges enable row level security;
create policy "Badges are public" on public.badges for select using (true);

create table public.strava_tokens (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  athlete_id     bigint not null,
  access_token   text not null,
  refresh_token  text not null,
  expires_at     timestamptz not null,
  last_import_at timestamptz
);
alter table public.strava_tokens enable row level security;  -- no policies: service role only

-- Outbox the push sender drains (APNs). Rows are written by resolve-run and ghost-tick.
create table public.notification_outbox (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  kind        text not null,
  title       text not null,
  body        text not null,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index notification_outbox_pending_idx on public.notification_outbox (created_at) where sent_at is null;
alter table public.notification_outbox enable row level security;

-- Private bucket for privacy-trimmed traces: owner can read their own folder.
insert into storage.buckets (id, name, public) values ('traces', 'traces', false) on conflict (id) do nothing;
create policy "Players read their own traces" on storage.objects for select
  using (bucket_id = 'traces' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------------
-- Area bundle in the same JSON shape as data/areas/<slug>.json, for the matcher.
-- ---------------------------------------------------------------------------
create or replace function public.area_bundle(p_slug text) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'slug', a.slug, 'name', a.name, 'longName', a.long_name, 'county', a.county, 'country', a.country,
    'center', jsonb_build_array(ST_X(ST_Centroid(a.boundary)), ST_Y(ST_Centroid(a.boundary))),
    'boundary', (ST_AsGeoJSON(a.boundary)::jsonb)->'coordinates',
    'segments', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'kind', s.kind, 'highway', s.highway, 'length', s.length_m,
        'a', s.start_node, 'b', s.end_node, 'coords', (ST_AsGeoJSON(s.geom)::jsonb)->'coordinates') order by s.id)
      from public.segments s where s.area_slug = a.slug and s.active), '[]'::jsonb),
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'areaM2', b.area_m2,
        'segments', (select jsonb_agg(bs.segment_id) from public.block_segments bs where bs.block_id = b.id)))
      from public.blocks b where b.area_slug = a.slug), '[]'::jsonb),
    'pois', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind,
        'lon', ST_X(p.location), 'lat', ST_Y(p.location))) from public.pois p where p.area_slug = a.slug), '[]'::jsonb))
  from public.areas a where a.slug = p_slug
$$;

-- Everything the engine needs to know about a town and a player, in one call.
create or replace function public.run_world(p_area text, p_user uuid, p_day_start timestamptz, p_day_end timestamptz)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'ownership', coalesce((select jsonb_agg(jsonb_build_object('s', so.segment_id, 'k', so.owner_kind, 'o', so.owner_id,
        'c', extract(epoch from so.captured_at), 'v', extract(epoch from so.last_visited_at)))
      from public.segment_ownership so where so.area_slug = p_area), '[]'::jsonb),
    'pellets', coalesce((select jsonb_agg(pc.pellet_id) from public.pellet_collections pc
      where pc.user_id = p_user and pc.collected_at > now() - interval '3 days'), '[]'::jsonb),
    'capturesToday', (select count(*) from public.captures c
      where c.user_id = p_user and c.kind in ('captured', 'stolen') and c.at >= p_day_start and c.at < p_day_end),
    'blockAwards', coalesce((select jsonb_object_agg(block_id, extract(epoch from last)) from (
        select ba.block_id, max(ba.awarded_at) as last from public.block_awards ba where ba.user_id = p_user group by ba.block_id) x), '{}'::jsonb),
    'conquered', exists (select 1 from public.badges b where b.user_id = p_user and b.badge = 'conquered:' || p_area)
  )
$$;

-- Applies a resolved run atomically. Ownership writes use "later capture wins",
-- so two runs resolving at once can't clobber each other.
create or replace function public.apply_run_result(p jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_run uuid := (p->>'runId')::uuid;
  v_user uuid := (p->>'userId')::uuid;
  v_area text := p->>'area';
  w jsonb;
  v_old public.segment_ownership;
begin
  insert into public.runs (id, user_id, area_slug, source, started_at, ended_at, distance_m, status, matched_polyline, stats, points, client_version)
  values (v_run, v_user, v_area, p->>'source', to_timestamp((p->>'startedAt')::float8), to_timestamp((p->>'endedAt')::float8),
          (p->>'distance')::float8, p->>'status', p->>'matchedPolyline', p->'stats', (p->>'points')::int, p->>'clientVersion')
  on conflict (id) do nothing;
  if not found then return; end if;  -- idempotent: already applied

  insert into public.run_traces (run_id, storage_path, point_count) values (v_run, p->>'tracePath', (p->>'pointCount')::int);

  insert into public.captures (run_id, user_id, segment_id, kind, coverage_ratio, points, multiplier, previous_owner, reject_reason, at)
  select v_run, v_user, c->>'segmentID', c->>'kind', (c->>'coverage')::float8, (c->>'points')::int, (c->>'multiplier')::float8,
         c->'previousOwner'->>'id', c->>'reason', to_timestamp((c->>'at')::float8)
    from jsonb_array_elements(p->'captures') c where c->>'kind' <> 'partial';

  insert into public.flags (run_id, user_id, rule, severity, details)
  select v_run, v_user, f->>'rule', (f->>'severity')::smallint, jsonb_build_object('detail', f->>'detail')
    from jsonb_array_elements(p->'flags') f;

  for w in select * from jsonb_array_elements(p->'ownership') loop
    select * into v_old from public.segment_ownership where segment_id = w->>'s' for update;
    if v_old.segment_id is null then
      insert into public.segment_ownership values (w->>'s', v_area, 'player', v_user::text, null,
        to_timestamp((w->>'c')::float8), to_timestamp((w->>'v')::float8));
      insert into public.ownership_events (segment_id, area_slug, to_kind, to_id, cause, run_id)
      values (w->>'s', v_area, 'player', v_user::text, case when (p->>'frenzy')::boolean then 'frenzy' else 'capture' end, v_run);
    elsif v_old.owner_kind = 'player' and v_old.owner_id = v_user::text then
      update public.segment_ownership set last_visited_at = greatest(last_visited_at, to_timestamp((w->>'v')::float8))
       where segment_id = w->>'s';
    elsif v_old.captured_at < to_timestamp((w->>'c')::float8) then
      update public.segment_ownership set owner_kind = 'player', owner_id = v_user::text, club_id = null,
             captured_at = to_timestamp((w->>'c')::float8), last_visited_at = to_timestamp((w->>'v')::float8)
       where segment_id = w->>'s';
      insert into public.ownership_events (segment_id, area_slug, from_kind, from_id, to_kind, to_id, cause, run_id)
      values (w->>'s', v_area, v_old.owner_kind, v_old.owner_id, 'player', v_user::text, 'flip', v_run);
      if v_old.owner_kind = 'player' then
        insert into public.notification_outbox (user_id, kind, title, body)
        select v_old.owner_id::uuid, 'lost', 'Street lost', (select display_name from public.profiles where id = v_user)
               || ' just ate ' || coalesce(nullif((select name from public.segments where id = w->>'s'), ''), 'one of your streets')
        where not exists (select 1 from public.user_relations ur where ur.user_id = v_old.owner_id::uuid
                            and ur.target_id = v_user and ur.kind in ('block', 'mute'));
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

  if (p->>'conquered')::boolean then
    insert into public.badges (user_id, badge) values (v_user, 'conquered:' || v_area) on conflict do nothing;
  end if;
end $$;

-- Bot moves from ghost-tick. Bots only take a player's street if they got there later.
create or replace function public.apply_ghost_moves(p jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare w jsonb; v_old public.segment_ownership;
begin
  update public.ai_ghosts set cursor_node = (p->>'cursor')::bigint, next_tick_at = to_timestamp((p->>'nextTick')::float8)
   where id = p->>'ghost';
  for w in select * from jsonb_array_elements(p->'moves') loop
    select * into v_old from public.segment_ownership where segment_id = w->>'s' for update;
    if v_old.segment_id is null then
      insert into public.segment_ownership values (w->>'s', p->>'area', 'ghost', p->>'ghost', null,
        to_timestamp((w->>'c')::float8), to_timestamp((w->>'v')::float8));
    elsif v_old.owner_kind = 'ghost' and v_old.owner_id = p->>'ghost' then
      update public.segment_ownership set last_visited_at = greatest(last_visited_at, to_timestamp((w->>'v')::float8)) where segment_id = w->>'s';
    elsif v_old.last_visited_at < to_timestamp((w->>'c')::float8) then
      update public.segment_ownership set owner_kind = 'ghost', owner_id = p->>'ghost', club_id = null,
             captured_at = to_timestamp((w->>'c')::float8), last_visited_at = to_timestamp((w->>'v')::float8)
       where segment_id = w->>'s';
      insert into public.ownership_events (segment_id, area_slug, from_kind, from_id, to_kind, to_id, cause)
      values (w->>'s', p->>'area', v_old.owner_kind, v_old.owner_id, 'ghost', p->>'ghost', 'ghost');
    end if;
  end loop;
  insert into public.notification_outbox (user_id, kind, title, body)
  select (r->>'user')::uuid, 'raid', 'Bot raid', r->>'message' from jsonb_array_elements(p->'raids') r;
end $$;

revoke execute on function public.area_bundle(text), public.run_world(text, uuid, timestamptz, timestamptz),
  public.apply_run_result(jsonb), public.apply_ghost_moves(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Scheduled Edge Functions. The URL and secret live in Supabase Vault (see
-- docs/SETUP.md), so nothing secret is committed; until they're set the calls no-op.
-- ---------------------------------------------------------------------------
create extension if not exists pg_net;

create or replace function public.call_chomp_function(p_name text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_url text; v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'chomp_functions_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'chomp_cron_secret';
  if v_url is null or v_secret is null then return; end if;
  perform net.http_post(url := v_url || '/' || p_name, headers := jsonb_build_object('Authorization', 'Bearer ' || v_secret, 'Content-Type', 'application/json'), body := '{}'::jsonb);
end $$;
revoke execute on function public.call_chomp_function(text) from public, anon, authenticated;

select cron.schedule('chomp-ghost-tick', '5 * * * *', $$select public.call_chomp_function('ghost-tick')$$);
select cron.schedule('chomp-spawn-daily', '5 0 * * *', $$select public.call_chomp_function('spawn-daily')$$);
