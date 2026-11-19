// The app calls this when the shared tile cache doesn't have the streets around
// a player yet. It answers straight away and builds the tiles in the background
// (one Overpass request), publishing them to the public `tiles` bucket. The
// first player in a new area still waits for Overpass; everyone after loads
// the area from the bucket in about a second.
import { admin, cors, json } from "../_shared/http.ts";
import { loadTiles } from "../_shared/world.ts";
import { parseWarm } from "../_shared/warm.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: unknown;
  try { body = await req.json(); } catch { return json({ error: "Bad JSON" }, 400); }
  const keys = parseWarm(body);
  if (!keys) return json({ error: "Send up to 9 neighbouring tiles" }, 400);

  const work = loadTiles(admin(), keys, 9).catch((e) => console.error("warm-tiles", (e as Error).message));
  if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(work);
  else await work;
  return json({ ok: true }, 202);
});
