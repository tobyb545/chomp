// send-push's pure core: APNs JWT signing, grouping and payloads.
import assert from "node:assert/strict";
import { test } from "node:test";
import { apnsHost, apnsJWT, apnsPayload, groupOutbox, importApnsKey, isDeadToken, type OutboxRow } from "../supabase/functions/_shared/push.ts";

async function freshKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`, pub: pair.publicKey };
}
const unb64 = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - s.length % 4) % 4)), (c) => c.charCodeAt(0));

test("signs an ES256 JWT APNs accepts (verifies with the public key)", async () => {
  const { pem, pub } = await freshKey();
  const jwt = await apnsJWT(await importApnsKey(pem), "ABC123DEFG", "TEAM123456", 1_790_000_000.7);
  const [h, c, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(new TextDecoder().decode(unb64(h))), { alg: "ES256", kid: "ABC123DEFG" });
  assert.deepEqual(JSON.parse(new TextDecoder().decode(unb64(c))), { iss: "TEAM123456", iat: 1_790_000_000 });
  assert.equal(unb64(s).length, 64, "raw r||s signature");
  assert.ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, unb64(s), new TextEncoder().encode(`${h}.${c}`)));
});

test("accepts a key pasted with literal \\n sequences", async () => {
  const { pem } = await freshKey();
  await importApnsKey(pem.replace(/\n/g, "\\n"));
});

test("groups a user's pile of lost coins into one push per kind", () => {
  const row = (id: number, user: string, kind: string, body: string, t: string): OutboxRow =>
    ({ id, user_id: user, kind, title: kind === "lost" ? "Coins lost" : "Coins lost", body, created_at: t });
  const msgs = groupOutbox([
    row(1, "u1", "lost", "Ana just took your coins on High Street", "2026-11-19T10:00:00Z"),
    row(2, "u1", "lost", "Ana just took your coins on Mill Lane", "2026-11-19T10:01:00Z"),
    row(3, "u1", "raid", "Jess M took 2 of your streets", "2026-11-19T10:02:00Z"),
    row(4, "u2", "lost", "Ben just took your coins on Oak Road", "2026-11-19T10:03:00Z"),
    row(5, "u1", "lost", "Ana just took your coins on Station Road", "2026-11-19T10:04:00Z"),
  ]);
  assert.equal(msgs.length, 3);
  const u1 = msgs.find((m) => m.userID === "u1" && m.kind === "lost")!;
  assert.equal(u1.body, "Ana just took your coins on Station Road (and 2 more streets)");
  assert.deepEqual(u1.ids, [1, 2, 5]);
  assert.equal(msgs.find((m) => m.kind === "raid")!.body, "Jess M took 2 of your streets");
  assert.equal(msgs.find((m) => m.userID === "u2")!.body, "Ben just took your coins on Oak Road");
});

test("payload, hosts and dead tokens", () => {
  const p = JSON.parse(apnsPayload({ userID: "u", kind: "lost", title: "Coins lost", body: "b", ids: [1], collapseID: "chomp-lost" }));
  assert.deepEqual(p.aps.alert, { title: "Coins lost", body: "b" });
  assert.equal(p.aps["thread-id"], "lost");
  assert.equal(apnsHost("sandbox"), "https://api.sandbox.push.apple.com");
  assert.equal(apnsHost("production"), "https://api.push.apple.com");
  assert.ok(isDeadToken(410) && isDeadToken(400, "BadDeviceToken") && !isDeadToken(400, "PayloadTooLarge") && !isDeadToken(500));
});
