# Setup

## 1. App (offline)

```sh
brew install xcodegen
cd ios && xcodegen generate && open Chomp.xcodeproj
```

The app needs no keys to build or play offline.

- Bundle ID: `com.tobyb545.chomp`.
- App group: `group.com.tobyb545.chomp`.
- Capabilities: HealthKit, Sign in with Apple, and the app group.
- Watch app: `CHOMP_EMBED_WATCH=true xcodegen generate`. This needs the watchOS simulator runtime.

## 2. Keys (`ios/Config/Secrets.xcconfig`, gitignored)

```sh
cp ios/Config/Secrets.example.xcconfig ios/Config/Secrets.xcconfig
```

Fill in what you have. `//` starts a comment in xcconfig files, so write URLs as `https:/$()/host`.
Any key you leave empty simply turns that feature off in the app.

## 3. Supabase

You need the Supabase CLI (`brew install supabase/tap/supabase`) and a project in a region
near the UK (e.g. London).

```sh
cd backend
supabase link --project-ref <ref>
supabase db push                                   # migrations
psql "$(supabase db url)" -f supabase/seed/west-byfleet.sql   # the town (or paste it into the SQL editor)
```

**Secrets for the Edge Functions:**

```sh
supabase secrets set CRON_SECRET=$(openssl rand -hex 24) \
  REVENUECAT_WEBHOOK_SECRET=$(openssl rand -hex 24) \
  STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=...
supabase functions deploy resolve-run strava-import
supabase functions deploy ghost-tick spawn-daily revenuecat-webhook --no-verify-jwt
```

**Cron.** pg_cron calls the functions using two Vault secrets. Run this once in the SQL editor:

```sql
select vault.create_secret('https://<ref>.supabase.co/functions/v1', 'chomp_functions_url');
select vault.create_secret('<the CRON_SECRET from above>', 'chomp_cron_secret');
```

**Sign in with Apple:** go to Authentication → Providers → Apple, enable it, and add
`com.tobyb545.chomp` as a client ID. Native sign-in doesn't need the services ID or a key.

**Admins** (they can read flags, reports and `review_queue`):
`insert into admins values ('<your auth user id>');`

**Local development:** `supabase start`, then `supabase db reset` (runs the migrations),
then `supabase test db` (runs the RLS tests).

## 4. RevenueCat

1. Create the app and an entitlement called **`pro`**, with monthly and annual products.
2. Put the public Apple API key in `REVENUECAT_API_KEY`.
3. Add a webhook pointing at `https://<ref>.supabase.co/functions/v1/revenuecat-webhook`,
   with the Authorization header set to `Bearer <REVENUECAT_WEBHOOK_SECRET>`.

The app logs in to RevenueCat with the Supabase user ID, so webhooks map to players.

## 5. Strava (optional, Pro)

1. Create an API application at strava.com/settings/api.
2. Set **Authorization Callback Domain** to `strava`. The app's redirect is `chomp://strava`.
3. Put the client ID in `STRAVA_CLIENT_ID` in both the xcconfig and the function secrets.
   The client secret only goes in the function secrets.

## 6. Adding a town

```sh
python3 tools/ingest/ingest.py <slug> [--refresh]   # needs tools/ingest/areas/<slug>.json
```

This writes `data/areas/<slug>.json` (bundled into the app) and
`backend/supabase/seed/<slug>.sql`. Rerunning it after OSM edits carries ownership over to
re-split segments through `segment_lineage`.

## 7. Changing game rules

Edit `shared/rules.json`, then run `tools/sync-rules.sh`. Then run the Swift tests, then
`cd backend && npm test`, then the Swift tests again, so the parity fixtures are regenerated.
