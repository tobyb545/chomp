// RevenueCat → entitlements. Pro is cosmetic/convenience only (never affects
// captures), but clubs and Strava import check it server-side.
// The app logs in to RevenueCat with the Supabase user id, so app_user_id is that id.
import { admin, hasSecret, json } from "../_shared/http.ts";

const GRANT = new Set(["INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "PRODUCT_CHANGE", "NON_RENEWING_PURCHASE", "SUBSCRIPTION_EXTENDED", "TEMPORARY_ENTITLEMENT_GRANT"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (!hasSecret(req, "REVENUECAT_WEBHOOK_SECRET")) return json({ error: "forbidden" }, 403);
  const { event } = await req.json();
  if (!event) return json({ error: "no event" }, 400);
  const ids: string[] = [event.app_user_id, ...(event.aliases ?? [])].filter((x) => typeof x === "string" && UUID.test(x));
  if (!ids.length) return json({ ok: true, skipped: "anonymous user" });
  const userId = ids[0].toLowerCase();
  const entitlements: string[] = event.entitlement_ids ?? (event.entitlement_id ? [event.entitlement_id] : ["pro"]);
  const db = admin();

  let expires: string | null | undefined;
  if (GRANT.has(event.type)) expires = event.expiration_at_ms ? new Date(event.expiration_at_ms).toISOString() : null;
  else if (event.type === "EXPIRATION") expires = new Date().toISOString();
  else return json({ ok: true, ignored: event.type });  // CANCELLATION etc: access lasts until expiry

  const { error } = await db.from("entitlements").upsert(entitlements.map((e) => ({
    user_id: userId, entitlement: e, expires_at: expires, updated_at: new Date().toISOString(),
  })));
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true });
});
