// Strava import (free). The app does OAuth and sends the code here, because the
// client secret can't ship in the app. Older runs are added here as history
// (personal exploration only, never coins). Runs from the last few days go back
// to the app, which adds them like any run (through resolve-run), so they collect coins.
import { admin, caller, cors, json } from "../_shared/http.ts";
import { areaForTrace } from "../_shared/world.ts";
import { GameEngine, MapMatcher, rules, type TracePoint, cleanReport } from "../_shared/chomp/mod.ts";
import { LATE_UPLOAD_S } from "../_shared/resolve.ts";

const MAX_ACTIVITIES = 30; // keeps well inside Strava's 100 requests / 15 min

async function strava(path: string, token: string) {
  const r = await fetch(`https://www.strava.com/api/v3${path}`, { headers: { Authorization: `Bearer ${token}` } });
  if (!r.ok) throw new Error(`Strava ${path}: ${r.status}`);
  return r.json();
}

async function tokenRequest(params: Record<string, string>) {
  const r = await fetch("https://www.strava.com/oauth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: Deno.env.get("STRAVA_CLIENT_ID")!, client_secret: Deno.env.get("STRAVA_CLIENT_SECRET")!, ...params }),
  });
  if (!r.ok) throw new Error(`Strava token exchange failed (${r.status})`);
  return r.json();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const db = admin();
  const userId = await caller(req, db);
  if (!userId) return json({ error: "Sign in first" }, 401);
  const { code } = await req.json().catch(() => ({}));


  try {
    let { data: tok } = await db.from("strava_tokens").select("*").eq("user_id", userId).maybeSingle();
    if (code) {
      const t = await tokenRequest({ code, grant_type: "authorization_code" });
      tok = { user_id: userId, athlete_id: t.athlete.id, access_token: t.access_token, refresh_token: t.refresh_token,
        expires_at: new Date(t.expires_at * 1000).toISOString(), last_import_at: tok?.last_import_at ?? null };
      await db.from("strava_tokens").upsert(tok);
    }
    if (!tok) return json({ error: "Connect Strava first" }, 400);
    if (Date.parse(tok.expires_at) < Date.now() + 60_000) {
      const t = await tokenRequest({ refresh_token: tok.refresh_token, grant_type: "refresh_token" });
      tok = { ...tok, access_token: t.access_token, refresh_token: t.refresh_token, expires_at: new Date(t.expires_at * 1000).toISOString() };
      await db.from("strava_tokens").update(tok).eq("user_id", userId);
    }

    const after = tok.last_import_at ? Math.floor(Date.parse(tok.last_import_at) / 1000) : Math.floor(Date.now() / 1000) - 365 * 86_400;
    const activities = (await strava(`/athlete/activities?after=${after}&per_page=${MAX_ACTIVITIES}`, tok.access_token) as {
      id: number; type: string; sport_type?: string; start_date: string; elapsed_time: number; distance: number; start_latlng?: number[];
    }[]).filter((a) => ["Run", "TrailRun"].includes(a.sport_type ?? a.type) && a.start_latlng?.length === 2);

    let imported = 0, newest = after;
    const recent: { start: number; end: number; points: number[][] }[] = [];
    const nowS = Date.now() / 1000;
    // A year of runs can span a lot of map: cap new tile builds per call so
    // Overpass isn't hammered. Runs left unbuilt get picked up next time.
    let buildBudget = 18;
    for (const a of activities) {
      const start = Date.parse(a.start_date) / 1000;
      newest = Math.max(newest, start + a.elapsed_time);
      const streams = await strava(`/activities/${a.id}/streams?keys=latlng,time&key_by_type=true`, tok.access_token);
      const ll: number[][] = streams.latlng?.data ?? [], tt: number[] = streams.time?.data ?? [];
      if (ll.length < 2) continue;
      // Recent enough to collect coins: hand it back to the app (a little early, so it's still in the window on arrival).
      if (nowS - (start + a.elapsed_time) < LATE_UPLOAD_S - 600) {
        recent.push({ start, end: start + a.elapsed_time, points: ll.map(([lat, lon], i) => [lat, lon, start + (tt[i] ?? i)]) });
        continue;
      }
      const trace: TracePoint[] = ll.map(([lat, lon], i) => ({ coordinate: { lat, lon }, t: start + (tt[i] ?? i), accuracy: 10, speed: -1 }));
      const { area, keys, complete } = await areaForTrace(db, trace.map((p) => p.coordinate), buildBudget);
      buildBudget = Math.max(0, buildBudget - keys.length);
      if (!complete) { newest = Math.min(newest, start - 1); break; }  // retry from here next call
      const matcher = new MapMatcher(area, rules.matching), engine = new GameEngine(area, rules);
      const runId = crypto.randomUUID();
      const { outcome, writes } = engine.resolve({ runID: runId, startedAt: start, endedAt: start + a.elapsed_time, isImport: true },
        trace, matcher.match(trace), cleanReport,
        { playerID: userId, ownership: new Map(), collectedPellets: new Set(), capturesToday: 0, blockAwards: new Map(), conqueredTiles: new Set() });
      const { error } = await db.rpc("apply_run_result", { p: {
        runId, userId, source: "strava_import", startedAt: start, endedAt: start + a.elapsed_time, distance: a.distance,
        status: "resolved", clientVersion: "strava", matchedPolyline: null, stats: { stravaId: a.id }, points: 0,
        tracePath: "", pointCount: trace.length, captures: outcome.captures.filter((c) => c.kind !== "partial"), flags: [],
        frenzy: false, ownership: [], coverage: [...writes.coverage].map(([s, t]) => ({ s, t })), pellets: [], blockAwards: [], conquered: [],
      } });
      if (error) { console.error("strava apply", error.message); continue; }
      imported++;
    }
    await db.from("strava_tokens").update({ last_import_at: new Date(newest * 1000).toISOString() }).eq("user_id", userId);
    return json({ imported, recent, more: activities.length === MAX_ACTIVITIES || buildBudget === 0 });
  } catch (e) {
    return json({ error: (e as Error).message }, 502);
  }
});
