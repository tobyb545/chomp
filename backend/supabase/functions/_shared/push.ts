// Pure core of send-push (no I/O beyond WebCrypto), so it can be tested under Node.
// APNs token auth: an ES256 JWT signed with the team's .p8 key, reused for up to an hour.

export interface OutboxRow { id: number; user_id: string; kind: string; title: string; body: string; created_at: string }
export interface PushToken { token: string; user_id: string; environment: "sandbox" | "production"; kinds: string[] }
export interface Message { userID: string; kind: string; title: string; body: string; ids: number[]; collapseID: string }

const b64url = (bytes: Uint8Array) => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const b64urlText = (t: string) => b64url(new TextEncoder().encode(t));

/** Imports an APNs .p8 key (PKCS#8 PEM). Accepts literal "\n" sequences, as secrets often store it. */
export async function importApnsKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/\\n/g, "\n").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

export async function apnsJWT(key: CryptoKey, keyID: string, teamID: string, nowSeconds: number): Promise<string> {
  const head = b64urlText(JSON.stringify({ alg: "ES256", kid: keyID }));
  const claims = b64urlText(JSON.stringify({ iss: teamID, iat: Math.floor(nowSeconds) }));
  // WebCrypto ECDSA signatures are already raw r||s, which is what JWS ES256 wants.
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${claims}`)));
  return `${head}.${claims}.${b64url(sig)}`;
}

/** Lost coins and bot raids pile up fast: one push per user per kind, summarising the rest. */
export function groupOutbox(rows: OutboxRow[]): Message[] {
  const by = new Map<string, OutboxRow[]>();
  for (const r of [...rows].sort((a, b) => a.created_at.localeCompare(b.created_at) || a.id - b.id)) {
    const k = `${r.user_id}|${r.kind}`;
    by.set(k, [...(by.get(k) ?? []), r]);
  }
  return [...by.values()].map((group) => {
    const latest = group[group.length - 1];
    const more = group.length - 1;
    let body = latest.body;
    if (more > 0 && (latest.kind === "lost" || latest.kind === "raid")) {
      body += ` (and ${more} more ${latest.kind === "lost" ? `street${more === 1 ? "" : "s"}` : `raid${more === 1 ? "" : "s"}`})`;
    }
    return { userID: latest.user_id, kind: latest.kind, title: latest.title, body, ids: group.map((g) => g.id), collapseID: `chomp-${latest.kind}` };
  });
}

export function apnsPayload(m: Message): string {
  return JSON.stringify({ aps: { alert: { title: m.title, body: m.body }, sound: "default", "thread-id": m.kind }, kind: m.kind });
}

export const apnsHost = (env: PushToken["environment"]) =>
  env === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";

/** APNs answers that mean the token is dead and should be forgotten. */
export const isDeadToken = (status: number, reason?: string) =>
  status === 410 || (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"));
