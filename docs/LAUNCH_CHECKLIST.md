# What's left to set up

Status as of 19 Nov 2026, checked against the live Supabase project. Details for each step are
in [SETUP.md](SETUP.md).

## Website (built in `website/`)

- [ ] **Turn on GitHub Pages**: repo Settings → Pages → Source: **GitHub Actions**. The
  `Website` workflow publishes `website/` on every push to main (or run it from the Actions tab).
- [ ] **Pick the address.** A project site lives at `https://tobyb545.github.io/<repo-name>/`,
  so the current repo name (`pacman-run`) would appear in every invite link. Rename the repo
  (e.g. `chomp`) or use a custom domain before sharing links.
- [ ] **Set `CHOMP_WEB_URL`** in `ios/Config/App.xcconfig` (written `https:/$()/host/path`).
  Invite and club links then point at the website, and the paywall and Settings show the
  Terms, Privacy and Contact links that Apple requires for subscriptions.
- [ ] **Set `contactEmail`** (and `appStoreUrl` once live) in `website/assets/site.js`.
- [ ] **Optional, custom domain only: universal links**, so links open the app directly.
  This needs the site at the domain root (it serves `.well-known/apple-app-site-association`)
  plus the Associated Domains capability (`applinks:<domain>`) in the app. Until then the
  invite page's "Open in Chomp" button does the same job.

## Supabase: needed for online play

- [ ] **Run four migrations** in the SQL editor, in this order:
  1. `backend/supabase/migrations/20261124000000_push.sql`: push tokens
  2. `backend/supabase/migrations/20261125000000_club_battles.sql`: club battles
  3. `backend/supabase/migrations/20261126000000_quiet_bots.sql`: bot names, retiring bots,
     the name check and the new leaderboard
  4. `backend/supabase/migrations/20261127000000_delete_traces.sql`: lets account deletion
     remove stored run traces

  The earlier migrations, up to `20261123000000_coins.sql`, are already live.
- [ ] **Redeploy the Edge Functions** that changed, plus the new `warm-tiles` (it fills the
  shared street cache, so after the first player in an area everyone else loads it in about a
  second instead of waiting up to a minute for the free map servers):
  `supabase functions deploy resolve-run strava-import` and
  `supabase functions deploy ghost-tick revenuecat-webhook warm-tiles --no-verify-jwt`
- [ ] **Make sure the cron Vault secrets exist** (`chomp_functions_url`, `chomp_cron_secret`).
  Without them, bots never move online. See SETUP.md §3, "Cron".
- [ ] **Sign in with Apple provider**: Authentication → Providers → Apple, enabled, with client ID
  `com.tobyb545.chomp`. Then test it once on your phone: Settings → Sign in with Apple.
- [ ] **Add yourself as an admin**: `insert into admins values ('<your auth user id>');`

## Push notifications

- [ ] **Apple Developer → Keys**: create an APNs key and download the .p8 file.
- [ ] **Set Supabase secrets**: `APNS_KEY` (the .p8 contents), `APNS_KEY_ID`,
  `APNS_TEAM_ID=7KYR2X9MJA`, `APNS_TOPIC=com.tobyb545.chomp`.
- [ ] **Deploy `send-push`**: `supabase functions deploy send-push --no-verify-jwt`.
  It isn't deployed yet.

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

- [ ] **Strava import (Pro)**: create a Strava API app with the callback domain `strava`. Set
  `STRAVA_CLIENT_ID` in the xcconfig and the function secrets, and `STRAVA_CLIENT_SECRET` in
  the function secrets only.
- [ ] **Watch app**: `CHOMP_EMBED_WATCH=true xcodegen generate`.
- [ ] **Push the repo to GitHub.** Commits are local on `main`.
