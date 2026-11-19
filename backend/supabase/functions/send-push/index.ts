// Every minute (pg_cron → this function): drains notification_outbox to APNs.
// Needs the secrets APNS_KEY (.p8 contents), APNS_KEY_ID, APNS_TEAM_ID and
// APNS_TOPIC (the app's bundle ID). Until they're set it does nothing.
import { admin, hasSecret, json } from "../_shared/http.ts";
import { apnsHost, apnsJWT, apnsPayload, groupOutbox, importApnsKey, isDeadToken, type OutboxRow, type PushToken } from "../_shared/push.ts";

const BATCH = 500;
let cached: { jwt: string; at: number } | undefined;

Deno.serve(async (req) => {
  if (!hasSecret(req, "CRON_SECRET")) return json({ error: "forbidden" }, 403);
  const pem = Deno.env.get("APNS_KEY"), keyID = Deno.env.get("APNS_KEY_ID"), teamID = Deno.env.get("APNS_TEAM_ID");
  const topic = Deno.env.get("APNS_TOPIC") ?? "com.tobyb545.chomp";
  if (!pem || !keyID || !teamID) return json({ skipped: "APNs secrets not set" });

  const db = admin();
  const { data: rows, error } = await db.rpc("claim_push_batch", { p_limit: BATCH });
  if (error) return json({ error: error.message }, 500);
  const outbox = (rows ?? []) as OutboxRow[];
  if (!outbox.length) return json({ sent: 0 });

  const users = [...new Set(outbox.map((r) => r.user_id))];
  const { data: tokenRows } = await db.from("push_tokens").select("token, user_id, environment, kinds").in("user_id", users);
  const tokens = (tokenRows ?? []) as PushToken[];

  const now = Date.now() / 1000;
  if (!cached || now - cached.at > 45 * 60) cached = { jwt: await apnsJWT(await importApnsKey(pem), keyID, teamID, now), at: now };

  let sent = 0, failed = 0;
  const dead: string[] = [];
  for (const m of groupOutbox(outbox)) {
    for (const t of tokens.filter((t) => t.user_id === m.userID && t.kinds.includes(m.kind))) {
      const res = await fetch(`${apnsHost(t.environment)}/3/device/${t.token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${cached.jwt}`, "apns-topic": topic, "apns-push-type": "alert",
          "apns-priority": "10", "apns-collapse-id": m.collapseID, "content-type": "application/json",
        },
        body: apnsPayload(m),
      });
      if (res.ok) { sent++; continue; }
      failed++;
      const reason = ((await res.json().catch(() => ({}))) as { reason?: string }).reason;
      if (isDeadToken(res.status, reason)) dead.push(t.token);
      if (res.status === 403) cached = undefined;  // expired or rejected JWT: re-sign next time
    }
  }
  if (dead.length) await db.from("push_tokens").delete().in("token", dead);
  return json({ messages: outbox.length, sent, failed, removed: dead.length });
});
