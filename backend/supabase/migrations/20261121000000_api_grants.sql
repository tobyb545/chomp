-- Table privileges for the Data API. Newer Supabase projects no longer grant
-- these automatically, so without this the app gets "permission denied" even
-- where a row-level security policy allows access. RLS still decides which
-- rows each player can see or change: every table has RLS on, and tables with
-- no policy for an action (ownership, runs, captures, Strava tokens...) stay
-- closed to clients.
grant usage on schema public to anon, authenticated;
grant select on all tables in schema public to anon, authenticated;
grant insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- Server-only view: keep it closed.
revoke all on public.active_districts from anon, authenticated;
