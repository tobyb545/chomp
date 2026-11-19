-- pgTAP: row-level security and the public read model.
-- Run with `supabase test db` against a local stack (`supabase start`).
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

-- Every public table has RLS on.
select is(
  (select count(*)::int from pg_tables t join pg_class c on c.relname = t.tablename and c.relnamespace = 'public'::regnamespace
    where t.schemaname = 'public' and not c.relrowsecurity),
  0, 'RLS is enabled on every public table');

-- Fixtures (as the table owner).
select lives_ok($$select public.store_map_tile('14/8192/8191', '{"formatVersion":1,"key":"14/8192/8191","generatedAt":"2026-11-19T00:00:00Z","osmTimestamp":"",
  "segments":[{"id":"s1","name":"High Street","kind":"road","highway":"residential","length":70,"a":1,"b":2,"coords":[[0.001,0.001],[0.002,0.001]]},
              {"id":"s2","name":"Low Street","kind":"road","highway":"residential","length":70,"a":2,"b":3,"coords":[[0.002,0.001],[0.003,0.001]]}],
  "blocks":[],"pois":[{"id":"n1","name":"Testville Park","kind":"park","lon":0.0015,"lat":0.0015}]}'::jsonb)$$, 'a built tile can be stored');
select is((select count(*)::int from public.segments where tile = '14/8192/8191' and active), 2, 'storing a tile mirrors its streets');
select is((select region from public.map_tiles where key = '14/8192/8191'), '10/512/511', 'tiles know their region');
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
  ('s1', '14/8192/8191', 'player', '11111111-1111-1111-1111-111111111111', null, now() - interval '1 day', now() - interval '1 day'),
  ('s2', '14/8192/8191', 'player', '33333333-3333-3333-3333-333333333333', null, now() - interval '1 day', now() - interval '1 day');
insert into public.runs (id, user_id, source, started_at, ended_at) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'live', now() - interval '1 hour', now());

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
select is((select count(*)::int from public.segment_ownership_public where tile = '14/8192/8191'), 1, 'public view hides private players');
select is((select count(*)::int from public.segment_ownership_feed), 1, 'feed is readable');
select throws_ok($$insert into public.segment_ownership values ('s2', '14/8192/8191', 'player', '22222222-2222-2222-2222-222222222222', null, now(), now())$$,
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
select is((select streets_held from public.leaderboard('nearby', '14/8192/8191') where display_name = 'Alice'), 1, 'leaderboard counts live streets');
select is((select count(*)::int from public.leaderboard('nearby', '14/8192/8191') where display_name = 'Cara'), 0, 'leaderboard hides private players');
select throws_ok($$select public.create_club('Runners', 'C6FF00')$$, 'P0001', 'Clubs are part of Chomp Pro', 'clubs need Pro');

select * from finish();
rollback;
