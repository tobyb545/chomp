// Authoritative run resolution. The app sends a privacy-trimmed trace; this
// re-matches it, runs anti-cheat, applies the game rules and writes the result
// atomically (apply_run_result). The app replaces its provisional captures with this answer.
import { admin, caller, cors, json } from "../_shared/http.ts";
import { areaForTrace } from "../_shared/world.ts";
import { dayWindow, resolveUpload, toWorld, type Upload, validate, type WorldRow } from "../_shared/resolve.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const db = admin();
  const userId = await caller(req, db);
  if (!userId) return json({ error: "Sign in to play online" }, 401);

  let u: Upload;
  try { u = await req.json(); } catch { return json({ error: "Bad JSON" }, 400); }
  const now = Date.now() / 1000;
  const v = validate(u, now);
  if (!v.ok) return json({ error: v.error }, 400);

  // Idempotent: a retried upload gets the original answer.
  const { data: existing } = await db.from("runs").select("user_id, status, stats").eq("id", v.runId).maybeSingle();
  if (existing) {
    if (existing.user_id !== userId) return json({ error: "Run id already used" }, 409);
    return json({ status: existing.status, outcome: existing.stats?.outcome ?? null });
  }

  // The streets around the trace, built from OpenStreetMap on first use.
  const { area, keys } = await areaForTrace(db, v.trace.map((p) => p.coordinate));
  if (!area.segments.length) return json({ error: "Couldn't load the map for this run, try again shortly" }, 503);
  const [dayStart, dayEnd] = dayWindow(v.endedAt);
  const { data: w, error: werr } = await db.rpc("run_world", { p_tiles: keys.map(String), p_user: userId, p_day_start: dayStart, p_day_end: dayEnd });
  if (werr || !w) return json({ error: "Couldn't load the map state" }, 500);
  // Shadow-restricted players play on, but their runs never reach the shared map.
  const { data: trust } = await db.from("user_trust").select("shadow_restricted").eq("user_id", userId).maybeSingle();

  const tracePath = `${userId}/${v.runId}.json`;
  const { status, clientOutcome, payload } = resolveUpload(area, u, v, userId, toWorld(userId, w as WorldRow),
    { now, shadowRestricted: !!trust?.shadow_restricted, tracePath });

  const { error: upErr } = await db.storage.from("traces").upload(tracePath,
    JSON.stringify(v.trace.map((p) => [p.coordinate.lat, p.coordinate.lon, p.t, p.accuracy, p.speed])),
    { contentType: "application/json", upsert: true });
  if (upErr) console.error("trace upload failed", upErr.message);

  const { error } = await db.rpc("apply_run_result", { p: payload });
  if (error) {
    console.error("apply_run_result failed", error.message);
    return json({ error: "Couldn't save the run, try again" }, 500);
  }
  return json({ status, outcome: clientOutcome });
});
