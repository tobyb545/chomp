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
supabase db push                                   # migrations (also creates the public `tiles` bucket)
```

**Secrets for the Edge Functions:**

```sh
supabase secrets set CRON_SECRET=$(openssl rand -hex 24) \
  REVENUECAT_WEBHOOK_SECRET=$(openssl rand -hex 24) \
  STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=...
supabase functions deploy resolve-run strava-import
supabase functions deploy ghost-tick revenuecat-webhook --no-verify-jwt
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

## 6. Map data

There's nothing to load. Streets come from OpenStreetMap one zoom-14 tile (~1.5 km) at a
time, built by the same code on the phone (`ChompKit/Map/Tiles.swift`) and the server
(`_shared/chomp/tiles.ts`); the parity tests check they're identical. The server stores tiles
in `map_tiles`/`segments` and publishes them to the public `tiles` bucket, which the app reads
before asking Overpass. Tiles are rebuilt after 30 days; streets that disappear are marked
inactive rather than deleted.

Overpass is free but slow (10–40 s per 3×3 tiles) and sometimes busy. If it becomes a
problem, run your own Overpass instance and put its URL first in `WorldStore.swift` and
`_shared/world.ts`.

## 7. Changing game rules

Edit `shared/rules.json`, then run `tools/sync-rules.sh`. Then run the Swift tests, then
`cd backend && npm test`, then the Swift tests again, so the parity fixtures are regenerated.
