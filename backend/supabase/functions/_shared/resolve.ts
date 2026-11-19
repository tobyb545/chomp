// Pure core of resolve-run (no I/O), so it can be tested under Node.
import {
  type Area, type CaptureRecord, coinSegment, decodePolyline, distance, encodePolyline, evaluate, GameEngine, MapMatcher, type MotionActivity,
  type Ownership, type RunOutcome, type RunSignals, rules, startOfDay, nextDay, type TracePoint, type World,
} from "./chomp/mod.ts";

export const MAX_POINTS = 30_000;
export const MAX_DURATION_S = 12 * 3600;
/** Runs added long after they ended (late upload, Health import) only count for exploration. */
export const LATE_UPLOAD_S = rules.imports.captureWindowHours * 3600;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** RunUpload as encoded by the iOS app (JSONEncoder, .iso8601 dates). */
export interface Upload {
  runId: string; startedAt: string; endedAt: string; source: string; polyline: string;
  timestamps: number[]; accuracies: number[]; speeds: number[]; clientVersion?: string;
  signals?: {
    motion?: { start: string; end: string; activity: string; confidence: number }[];
    cadence?: { timestamp: string; stepsPerMinute: number }[];
    heartRate?: { timestamp: string; bpm: number }[];
  };
}

export interface WorldRow {
  ownership: { s: string; k: "player" | "ghost"; o: string; c: number; v: number }[];
  pellets: string[]; capturesToday: number; blockAwards: Record<string, number>; conquered: string[];
}

const secs = (iso: string) => Date.parse(iso) / 1000;
/** Swift's JSONDecoder .iso8601 rejects fractional seconds. */
export const iso = (t: number) => new Date(Math.round(t) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

/** RunOutcome in the exact Codable shape the iOS app decodes. */
export function forClient(o: RunOutcome) {
  return {
    runID: o.runID.toUpperCase(),
    captures: o.captures.map((c: CaptureRecord) => ({ ...c, at: iso(c.at) })),
    points: o.points, blockBonus: o.blockBonus, blocksCompleted: o.blocksCompleted, pelletsCollected: o.pelletsCollected,
    frenzyWindows: o.frenzyWindows.map((w) => ({ start: iso(w.start), duration: w.end - w.start })),
    verdict: o.verdict, flags: o.flags, conqueredTown: o.conqueredTown,
  };
}

export type Validated = { ok: true; runId: string; startedAt: number; endedAt: number; trace: TracePoint[]; signals: RunSignals } | { ok: false; error: string };

export function validate(u: Upload, now: number): Validated {
  if (!UUID.test(u?.runId ?? "")) return { ok: false, error: "Bad run id" };
  const coords = decodePolyline(u.polyline ?? "");
  const n = coords.length;
  if (!n || n > MAX_POINTS || u.timestamps?.length !== n || u.accuracies?.length !== n || u.speeds?.length !== n) {
    return { ok: false, error: "Trace arrays don't line up" };
  }
  const startedAt = secs(u.startedAt), endedAt = secs(u.endedAt);
  if (!(endedAt >= startedAt) || endedAt - startedAt > MAX_DURATION_S || endedAt > now + 300) return { ok: false, error: "Implausible run times" };
  const trace = coords.map((c, i) => ({ coordinate: c, t: u.timestamps[i], accuracy: u.accuracies[i], speed: u.speeds[i] }))
    .filter((p) => Number.isFinite(p.t) && p.t >= startedAt - 60 && p.t <= endedAt + 60)
    .sort((a, b) => a.t - b.t);
  const signals: RunSignals = {
    motion: (u.signals?.motion ?? []).map((m) => ({ start: secs(m.start), end: secs(m.end), activity: m.activity as MotionActivity, confidence: m.confidence })),
    cadence: (u.signals?.cadence ?? []).map((c) => ({ t: secs(c.timestamp), stepsPerMinute: c.stepsPerMinute })),
    heartRate: (u.signals?.heartRate ?? []).map((h) => ({ t: secs(h.timestamp), bpm: h.bpm })),
  };
  return { ok: true, runId: u.runId.toLowerCase(), startedAt, endedAt, trace, signals };
}

export function dayWindow(endedAt: number): [string, string] {
  const d = startOfDay(endedAt);
  return [new Date(d * 1000).toISOString(), new Date(nextDay(d) * 1000).toISOString()];
}

export function toWorld(userId: string, w: WorldRow): World {
  return {
    playerID: userId,
    ownership: new Map(w.ownership.map((r) => [r.s, { owner: { kind: r.k, id: r.o }, capturedAt: r.c, lastVisitedAt: r.v } satisfies Ownership])),
    collectedPellets: new Set(w.pellets),
    capturesToday: Number(w.capturesToday ?? 0),
    blockAwards: new Map(Object.entries(w.blockAwards ?? {}).map(([k, v]) => [k, Number(v)])),
    conqueredTiles: new Set(w.conquered ?? []),
  };
}

/** Resolves a validated upload against a world snapshot. Returns the response and the apply_run_result payload. */
export function resolveUpload(area: Area, u: Upload, v: Extract<Validated, { ok: true }>, userId: string, world: World,
  opts: { now: number; shadowRestricted: boolean; tracePath: string }) {
  // Any run collects coins if it ended recently enough (live, or a recent
  // Strava run the app added). Strava history never comes through here.
  const isImport = opts.now - v.endedAt > LATE_UPLOAD_S;
  const report = evaluate(v.trace, v.signals, rules.antiCheat, rules.matching);
  const match = new MapMatcher(area, rules.matching).match(v.trace);
  const { outcome, writes } = new GameEngine(area, rules).resolve({ runID: v.runId, startedAt: v.startedAt, endedAt: v.endedAt, isImport }, v.trace, match, report, world);
  const shadow = opts.shadowRestricted;
  const tileOf = (id: string) => { const seg = area.segment(coinSegment(id)); return seg ? area.segmentTile[seg.index] : null; };

  let dist = 0;
  for (let i = 1; i < v.trace.length; i++) {
    const a = v.trace[i - 1], b = v.trace[i];
    const dt = b.t - a.t, d = distance(a.coordinate, b.coordinate);
    if (dt > 0 && d / dt < 15 && b.accuracy >= 0 && b.accuracy <= rules.matching.maxAccuracyMetres) dist += d;
  }
  const status = report.verdict === "underReview" ? "under_review" : "resolved";
  const clientOutcome = forClient(outcome);
  const payload = {
    runId: v.runId, userId,
    source: u.source === "live" ? "live" : u.source === "strava_import" ? "strava_import" : "health_import",
    startedAt: v.startedAt, endedAt: v.endedAt, distance: dist, status, clientVersion: u.clientVersion ?? null,
    matchedPolyline: encodePolyline(match.path.map((m) => m.snapped)),
    stats: { outcome: clientOutcome, matchedChunks: match.chunks, unmatchedPoints: match.unmatchedPoints, late: isImport },
    points: outcome.points + outcome.blockBonus, tracePath: opts.tracePath, pointCount: v.trace.length,
    captures: outcome.captures, flags: outcome.flags, frenzy: outcome.frenzyWindows.length > 0,
    // Each write carries its segment's tile, which the database keys ownership by.
    ownership: shadow ? [] : [...writes.ownership].map(([s, o]) => ({ s, t: tileOf(s), c: o.capturedAt, v: o.lastVisitedAt })),
    coverage: [...writes.coverage].map(([s, t]) => ({ s, t })),
    pellets: writes.pellets, blockAwards: writes.blockAwards, conquered: shadow ? [] : writes.conqueredTiles,
  };
  return { status, clientOutcome, payload };
}
