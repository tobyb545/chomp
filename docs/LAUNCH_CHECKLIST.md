# What's left to set up

Status as of 19 Nov 2026, checked against the live Supabase project. Details for each step are
in [SETUP.md](SETUP.md).

## Website (built in `website/`)

- [x] **GitHub Pages** is on (Source: GitHub Actions). The `Website` workflow publishes
  `website/` on every push to main. Live at https://tobyb545.github.io/chomp/ (repo renamed
  from `pacman-run`). A custom domain later would also let invite links open the app directly.
- [x] **Set `CHOMP_WEB_URL`** in `ios/Config/App.xcconfig` (written `https:/$()/host/path`).
  Invite and club links then point at the website, and the paywall and Settings show the
  Terms, Privacy and Contact links that Apple requires for subscriptions.
- [ ] **Set `contactEmail`** (and `appStoreUrl` once live) in `website/assets/site.js`.
- [ ] **Optional, custom domain only: universal links**, so links open the app directly.
  This needs the site at the domain root (it serves `.well-known/apple-app-site-association`)
  plus the Associated Domains capability (`applinks:<domain>`) in the app. Until then the
  invite page's "Open in Chomp" button does the same job.

## Supabase: needed for online play

- [x] **Run five migrations** (done 19 Nov) in the SQL editor, in this order:
  1. `backend/supabase/migrations/20261124000000_push.sql`: push tokens
  2. `backend/supabase/migrations/20261125000000_club_battles.sql`: club battles
  3. `backend/supabase/migrations/20261126000000_quiet_bots.sql`: bot names, retiring bots,
     the name check and the new leaderboard
  4. `backend/supabase/migrations/20261127000000_delete_traces.sql`: lets account deletion
     remove stored run traces
  5. `backend/supabase/migrations/20261128000000_coins_only.sql`: friends show coins held

  The earlier migrations, up to `20261123000000_coins.sql`, are already live.
- [x] **Redeploy the Edge Functions** (all six deployed 19 Nov). This Mac has no Docker, so deploys need `--use-api`, and this CLI version needs `--remote=<ref>`, plus the new `warm-tiles` (it fills the
  shared street cache, so after the first player in an area everyone else loads it in about a
  second instead of waiting up to a minute for the free map servers):
  `supabase functions deploy resolve-run strava-import --remote=kboxrdjdwbhqxkqahmbx --use-api --yes` and
  `supabase functions deploy ghost-tick revenuecat-webhook warm-tiles send-push --remote=kboxrdjdwbhqxkqahmbx --no-verify-jwt --use-api --yes`
- [ ] **Make sure the cron Vault secrets exist** (`chomp_functions_url`, `chomp_cron_secret`).
  Without them, bots never move online. See SETUP.md §3, "Cron".
- [ ] **Sign in with Apple provider**: Authentication → Providers → Apple, enabled, with client ID
  `com.tobyb545.chomp`. Then test it once on your phone: Settings → Sign in with Apple.
- [ ] **Email sign-in**: Authentication → Providers → Email, enabled. Then Authentication →
  Emails → **Magic Link** template: replace the link with the code, e.g.
  `<h2>Your Chomp code</h2><p>Enter this code in the app: <strong>{{ .Token }}</strong></p>`.
  The app asks for the code; a link won't open it.
- [ ] **Custom SMTP for email** (Authentication → Emails → SMTP settings, e.g. Resend or
  Postmark). Supabase's built-in sender only allows a few emails an hour, which is fine for
  testing but not for launch.
- [ ] **Add yourself as an admin**: `insert into admins values ('<your auth user id>');`

## Street tiles (Cloudflare R2)

Coins load from prebuilt tiles instead of the public Overpass servers, which are slow
and often down. `.github/workflows/tiles.yml` builds the UK monthly from a Geofabrik
extract (`tools/tiles/`) and uploads about 0.7 GB, gzipped, to R2's free tier.

- [ ] **R2 bucket** `chomp-tiles` with public access turned on (r2.dev URL to start;
      a custom domain before launch, since r2.dev is rate-limited).
- [ ] **R2 API token**: Object Read & Write, this bucket only.
- [ ] **GitHub secrets**: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`.
- [ ] **Run the workflow** once: Actions → Street tiles → Run workflow.
- [ ] **Point the app and server at it**: `CHOMP_TILES_URL` in `ios/Config/App.xcconfig`
      (written `https:/$()/host`), and `supabase secrets set CHOMP_TILES_URL=https://host`.

## Importing runs

- **Run file import** (GPX/TCX/FIT, Settings → History → Import a run file, or Share → Chomp) is the
  default way to add runs recorded elsewhere. It needs no setup.
- [ ] *(Optional)* **Strava API app**: since June 2026 the developer needs a paid Strava subscription, and new apps are limited to 10 athletes until Strava reviews them. The button only appears when `STRAVA_CLIENT_ID` is set: create a Strava API app with the callback domain `strava`. Set
  `STRAVA_CLIENT_ID` in the xcconfig and the function secrets, and `STRAVA_CLIENT_SECRET` in
  the function secrets only.

## Push notifications

- [ ] **Apple Developer → Keys**: create an APNs key and download the .p8 file.
- [ ] **Set Supabase secrets**: `APNS_KEY` (the .p8 contents), `APNS_KEY_ID`,
  `APNS_TEAM_ID=7KYR2X9MJA`, `APNS_TOPIC=com.tobyb545.chomp`.
- [x] **Deploy `send-push`** (done; it sends nothing until the APNs secrets above are set).

## Chomp Pro: subscriptions

- [ ] **App Store Connect → Agreements**: sign the Paid Apps agreement, and add banking and tax details.
- [ ] **Create subscription products** (monthly and annual) in one subscription group.
- [ ] **RevenueCat**: create the app, an entitlement called `pro`, and attach both products.
- [ ] **Put the RevenueCat public Apple key** in `REVENUECAT_API_KEY` in
  `ios/Config/Secrets.xcconfig`. It's empty now, so the paywall says "not configured".
- [ ] **Add the RevenueCat webhook**: `.../functions/v1/revenuecat-webhook` with
  `Authorization: Bearer <REVENUECAT_WEBHOOK_SECRET>`.

## App Store listing

- [ ] **Privacy policy, terms and support URLs**: use the website's `/privacy/`, `/terms/` and
  `/contact/` pages once it's live. Have someone review the policy and terms before launch.
- [ ] **Create the app record** for `com.tobyb545.chomp`. Paste the text from
  `docs/APP_STORE.md` and upload `docs/screenshots/`.
- [ ] **App Privacy questionnaire**: answers are in `docs/APP_STORE.md`.
- [ ] **Review notes**: a demo account, or a TestFlight build, for the reviewer.
- [ ] **Archive and upload**: Product → Archive in Xcode, then Distribute → App Store Connect.
  Test through TestFlight first.

## Optional

- [ ] **Watch app**: `CHOMP_EMBED_WATCH=true xcodegen generate`.
- [ ] **Push the repo to GitHub.** Commits are local on `main`.
