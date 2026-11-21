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
- [x] **Set `contactEmail`** in `website/assets/site.js`. Still to do: `appStoreUrl` once the app is live.
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

- [x] **R2 bucket** `chomp-tiles` with public access turned on (r2.dev URL to start;
      a custom domain before launch, since r2.dev is rate-limited).
- [x] **R2 API token**: Object Read & Write, this bucket only.
- [x] **GitHub secrets**: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`.
- [x] **Run the workflow** once: Actions → Street tiles → Run workflow.
- [x] **Point the app and server at it**: `CHOMP_TILES_URL` in `ios/Config/App.xcconfig`
      (written `https:/$()/host`), and `supabase secrets set CHOMP_TILES_URL=https://host`.

## Importing runs

- **Run file import** (GPX/TCX/FIT, Settings → History → Import a run file, or Share → Chomp) is the
  default way to add runs recorded elsewhere. It needs no setup.
- [ ] *(Optional)* **Strava API app**: since June 2026 the developer needs a paid Strava subscription, and new apps are limited to 10 athletes until Strava reviews them. The button only appears when `STRAVA_CLIENT_ID` is set: create a Strava API app with the callback domain `strava`. Set
  `STRAVA_CLIENT_ID` in the xcconfig and the function secrets, and `STRAVA_CLIENT_SECRET` in
  the function secrets only.

## Push notifications

- [x] **Apple Developer → Keys**: create an APNs key and download the .p8 file.
- [x] **Set Supabase secrets**: `APNS_KEY` (the .p8 contents), `APNS_KEY_ID`,
  `APNS_TEAM_ID=7KYR2X9MJA`, `APNS_TOPIC=com.tobyb545.chomp`.
- [x] **Deploy `send-push`** (done; it sends nothing until the APNs secrets above are set).

## Chomp Pro: subscriptions

Prices: **£2.99 a month** or **£29.99 a year** (about 16% off monthly). The app reads the
products from RevenueCat, so the IDs below aren't in the code; keep them exactly as written.

- [ ] **App Store Connect → Business**: sign the Paid Apps agreement, and add banking and tax
  details. Purchases (even test ones) don't work until it says Active.
- [ ] **Subscriptions**: Chomp → Monetization → Subscriptions → create the group `Chomp Pro`, then:
  - `chomp_pro_monthly`, reference name "Chomp Pro Monthly", 1 month, UK price £2.99
  - `chomp_pro_annual`, reference name "Chomp Pro Annual", 1 year, UK price £29.99
  Give each a display name and description, and a review screenshot (the paywall).
- [ ] **App Store Connect → Users and Access → Integrations → In-App Purchase**: create a key,
  download the .p8 (once only) and note the Key ID and Issuer ID.
- [ ] **RevenueCat**: new project "Chomp" → add an App Store app, bundle ID `com.tobyb545.chomp`,
  upload the In-App Purchase key. Then:
  - Products: import `chomp_pro_monthly` and `chomp_pro_annual`
  - Entitlements: create `pro` and attach both products
  - Offerings: the `default` offering (set as current) with a Monthly package (chomp_pro_monthly)
    and an Annual package (chomp_pro_annual)
- [ ] **RevenueCat public Apple key** (`appl_…`, Project settings → API keys): put it in
  `REVENUECAT_API_KEY` in `ios/Config/Secrets.xcconfig` and in Codemagic's `chomp_secrets` group.
  While it's empty the paywall says "Purchases aren't configured in this build yet".
- [ ] **Webhook** (RevenueCat → Integrations → Webhooks): URL
  `https://kboxrdjdwbhqxkqahmbx.supabase.co/functions/v1/revenuecat-webhook`, Authorization header
  `Bearer <secret>`. Make a new secret in your own Terminal and set it on Supabase:
  `S=$(openssl rand -hex 24); supabase secrets set REVENUECAT_WEBHOOK_SECRET=$S --remote=kboxrdjdwbhqxkqahmbx --yes; echo $S`
- [ ] **Test** in a TestFlight build: TestFlight purchases are free test purchases on your own Apple
  account, so no Sandbox account is needed (and subscriptions renew every few minutes). Buy monthly,
  check Pro unlocks, Restore purchases works, and RevenueCat shows the webhook as delivered.
  (Settings → Developer only appears on iPhones with Developer Mode on; it's only needed for builds
  run straight from Xcode.)
- [ ] **First review**: attach both subscriptions to the app version before submitting it.
  The App Store description must link Apple's standard Terms of Use (EULA); the subscription block at
  the end of the description in `docs/APP_STORE.md` does this. Paste the whole description, for every localization.

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
