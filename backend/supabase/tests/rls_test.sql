-- pgTAP: row-level security and the public read model.
-- Run with `supabase test db` against a local stack (`supabase start`).
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

-- Every public table has RLS on.
select is(
  (select count(*)::int from pg_tables t join pg_class c on c.relname = t.tablename and c.relnamespace = 'public'::regnamespace
    where t.schemaname = 'public' and not c.relrowsecurity),
  0, 'RLS is enabled on every public table');

-- Fixtures (as the table owner).
insert into public.areas (slug, name, boundary) values
  ('t', 'Testville', ST_Multi(ST_GeomFromText('POLYGON((0 0,0 0.01,0.01 0.01,0.01 0,0 0))', 4326)));
insert into public.segments (id, area_slug, geom, length_m, name, highway, kind, start_node, end_node) values
  ('s1', 't', ST_GeomFromText('LINESTRING(0.001 0.001,0.002 0.001)', 4326), 70, 'High Street', 'residential', 'road', 1, 2),
  ('s2', 't', ST_GeomFromText('LINESTRING(0.002 0.001,0.003 0.001)', 4326), 70, 'Low Street', 'residential', 'road', 2, 3);
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'c@example.com');
insert into public.profiles (id, display_name, color_hex) values
  ('11111111-1111-1111-1111-111111111111', 'Alice', 'C6FF00'),
  ('22222222-2222-2222-2222-222222222222', 'Bob', '00E5FF');
insert into public.profiles (id, display_name, color_hex, is_private) values
  ('33333333-3333-3333-3333-333333333333', 'Cara', 'FF2BD6', true);
insert into public.segment_ownership values
  ('s1', 't', 'player', '11111111-1111-1111-1111-111111111111', null, now() - interval '1 day', now() - interval '1 day'),
  ('s2', 't', 'player', '33333333-3333-3333-3333-333333333333', null, now() - interval '1 day', now() - interval '1 day');
insert into public.runs (id, user_id, area_slug, source, started_at, ended_at) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 't', 'live', now() - interval '1 hour', now());

-- The feed mirrors public owners only.
select is((select owner_name from public.segment_ownership_feed where segment_id = 's1'), 'Alice', 'feed mirrors a public owner');
select is((select count(*)::int from public.segment_ownership_feed where segment_id = 's2'), 0, 'private players stay off the feed');
select is((select captured_at from public.segment_ownership_feed where segment_id = 's1'),
          date_trunc('hour', now() - interval '1 day'), 'feed times are rounded to the hour');

-- As Bob.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

select is((select count(*)::int from public.runs), 0, 'players cannot see other players'' runs');
select is((select count(*)::int from public.segment_ownership), 0, 'raw ownership is not readable');
select is((select count(*)::int from public.segment_ownership_public where area_slug = 't'), 1, 'public view hides private players');
select is((select count(*)::int from public.segment_ownership_feed), 1, 'feed is readable');
select throws_ok($$insert into public.segment_ownership values ('s2', 't', 'player', '22222222-2222-2222-2222-222222222222', null, now(), now())$$,
  '42501', null, 'clients cannot write ownership');
select throws_ok($$insert into public.captures (run_id, user_id, segment_id, kind, coverage_ratio, at)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '22222222-2222-2222-2222-222222222222', 's1', 'captured', 1, now())$$,
  '42501', null, 'clients cannot write captures');
select throws_ok($$insert into public.reports (reporter_id, reported_user_id, reason) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'spoof')$$,
  '42501', null, 'cannot file a report as someone else');
select lives_ok($$insert into public.reports (reporter_id, reported_user_id, reason) values
  ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'gps_spoofing')$$, 'can file a report as yourself');
select is((select count(*)::int from public.reports), 0, 'reports are not readable by players');
select is((select streets_held from public.leaderboard('town', 't') where display_name = 'Alice'), 1, 'leaderboard counts live streets');
select is((select count(*)::int from public.leaderboard('town', 't') where display_name = 'Cara'), 0, 'leaderboard hides private players');
select throws_ok($$select public.create_club('Runners', 'C6FF00')$$, 'P0001', 'Clubs are part of Chomp Pro', 'clubs need Pro');

select * from finish();
rollback;
