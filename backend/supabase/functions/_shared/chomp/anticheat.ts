// Port of ChompKit/AntiCheat/AntiCheat.swift.
import { distance } from "./geo.ts";
import type { CoveragePiece, TracePoint } from "./matcher.ts";
import type { Rules } from "./rules.ts";

export type MotionActivity = "stationary" | "walking" | "running" | "cycling" | "automotive" | "unknown";
export interface MotionSample { start: number; end: number; activity: MotionActivity; confidence: number }
export interface CadenceSample { t: number; stepsPerMinute: number }
export interface HeartRateSample { t: number; bpm: number }
export interface RunSignals { motion: MotionSample[]; cadence: CadenceSample[]; heartRate: HeartRateSample[] }

/** 0 low, 1 medium, 2 high */
export interface AntiCheatFlag { rule: string; severity: 0 | 1 | 2; detail: string }
export type RunVerdict = "accepted" | "underReview";
export interface Interval { start: number; end: number }
export interface AntiCheatReport { verdict: RunVerdict; flags: AntiCheatFlag[]; excluded: Interval[] }

export const cleanReport: AntiCheatReport = { verdict: "accepted", flags: [], excluded: [] };

const within = (iv: Interval, t: number) => t >= iv.start && t <= iv.end;

export function isExcluded(report: AntiCheatReport, p: CoveragePiece): boolean {
  const mid = p.start + (p.end - p.start) / 2;
  return report.excluded.some((iv) => within(iv, mid) || (within(iv, p.start) && within(iv, p.end)));
}

export function mergeIntervals(xs: Interval[]): Interval[] {
  const s = [...xs].sort((a, b) => a.start - b.start);
  const out: Interval[] = [];
  for (const x of s) {
    const last = out[out.length - 1];
    if (last && x.start <= last.end) last.end = Math.max(last.end, x.end);
    else out.push({ ...x });
  }
  return out;
}

function nearest<T extends { t: number }>(samples: T[], t: number, maxD: number): T | undefined {
  let best: T | undefined, bestD = maxD;
  for (const s of samples) {
    const d = Math.abs(s.t - t);
    if (d <= bestD) { bestD = d; best = s; }
  }
  return best;
}

function straightLineSeconds(pts: TracePoint[]): number {
  if (pts.length <= 10) return 0;
  const heading = (a: TracePoint, b: TracePoint) =>
    Math.atan2(b.coordinate.lon - a.coordinate.lon, b.coordinate.lat - a.coordinate.lat) * 180 / Math.PI;
  let longest = 0, start = 0;
  let refHeading = heading(pts[0], pts[1]);
  let refSpeed = distance(pts[1].coordinate, pts[0].coordinate) / Math.max(0.001, pts[1].t - pts[0].t);
  for (let i = 2; i < pts.length; i++) {
    const dt = Math.max(0.001, pts[i].t - pts[i - 1].t);
    const v = distance(pts[i].coordinate, pts[i - 1].coordinate) / dt;
    let dh = Math.abs(heading(pts[i - 1], pts[i]) - refHeading);
    if (dh > 180) dh = 360 - dh;
    const constant = v > 1 && dh < 0.5 && Math.abs(v - refSpeed) / Math.max(refSpeed, 0.1) < 0.02;
    if (!constant) {
      longest = Math.max(longest, pts[i - 1].t - pts[start].t);
      start = i - 1;
      refHeading = heading(pts[i - 1], pts[i]);
      refSpeed = v;
    }
  }
  return Math.max(longest, pts[pts.length - 1].t - pts[start].t);
}

/** `imported`: from a file or Strava, which don't record GPS accuracy, so the synthetic-trace check can't apply. */
export function evaluate(trace: TracePoint[], signals: RunSignals, rules: Rules["antiCheat"], matching: Rules["matching"], imported = false): AntiCheatReport {
  const flags: AntiCheatFlag[] = [];
  let excluded: Interval[] = [];
  const pts = trace.filter((p) => p.accuracy >= 0 && p.accuracy <= matching.maxAccuracyMetres).sort((a, b) => a.t - b.t);
  if (pts.length < 2) return { verdict: "accepted", flags: [], excluded: [] };

  const legs: { t0: number; t1: number; d: number; v: number }[] = [];
  for (let i = 1; i < pts.length; i++) {
    const dt = pts[i].t - pts[i - 1].t;
    if (dt <= 0) continue;
    const d = distance(pts[i].coordinate, pts[i - 1].coordinate);
    legs.push({ t0: pts[i - 1].t, t1: pts[i].t, d, v: d / dt });
  }

  // 1. Teleports.
  const teleport = rules.teleportSpeedKmh / 3.6;
  const teleports = legs.filter((l) => l.v > teleport && l.d > 50);
  if (teleports.length) {
    flags.push({ rule: "teleport", severity: teleports.length >= 3 ? 2 : 1,
      detail: `${teleports.length} jump(s), fastest ${Math.trunc(Math.max(...teleports.map((l) => l.v)) * 3.6)} km/h` });
    excluded.push(...teleports.map((l) => ({ start: l.t0 - 15, end: l.t1 + 15 })));
  }

  // 2. Sustained speed.
  const maxV = rules.maxSustainedSpeedKmh / 3.6, window = rules.sustainedWindowSeconds;
  let j = 0, dist = 0, fastTime = 0;
  for (let i = 0; i < legs.length; i++) {
    dist += legs[i].d;
    while (legs[i].t1 - legs[j].t0 > window && j < i) { dist -= legs[j].d; j++; }
    const span = legs[i].t1 - legs[j].t0;
    if (span >= window * 0.75 && dist / span > maxV) {
      excluded.push({ start: legs[j].t0, end: legs[i].t1 });
      fastTime += legs[i].t1 - legs[i].t0;
    }
  }
  if (fastTime > 0) {
    flags.push({ rule: "speed", severity: fastTime > 300 ? 1 : 0, detail: `${Math.trunc(fastTime)}s above ${Math.trunc(rules.maxSustainedSpeedKmh)} km/h` });
  }

  // 3. Acceleration.
  let accelRun = 0, accelHits = 0;
  for (let i = 1; i < legs.length; i++) {
    const dt = legs[i].t1 - legs[i - 1].t1;
    if (dt <= 0) continue;
    if (Math.abs(legs[i].v - legs[i - 1].v) / dt > rules.maxAccelerationMps2) {
      accelRun++;
      if (accelRun >= 3) accelHits++;
    } else accelRun = 0;
  }
  if (accelHits > 0) {
    flags.push({ rule: "acceleration", severity: accelHits > 5 ? 2 : 1, detail: `${accelHits} bursts above ${rules.maxAccelerationMps2} m/s²` });
  }

  // 4. Synthetic traces.
  const straight = straightLineSeconds(pts);
  if (straight >= rules.straightLineWindowSeconds) {
    flags.push({ rule: "straight_line", severity: straight > 3 * rules.straightLineWindowSeconds ? 2 : 1,
      detail: `${Math.trunc(straight)}s of machine-straight constant-speed movement` });
  }
  const accs = new Set(pts.map((p) => Math.round(p.accuracy * 10)));
  const intervals = pts.slice(1).map((p, i) => p.t - pts[i].t);
  const regular = intervals.length > 120 && intervals.every((x) => Math.abs(x - intervals[0]) < 0.001);
  if (!imported && pts.length > 120 && accs.size === 1 && regular) {
    flags.push({ rule: "synthetic", severity: 2, detail: "identical accuracy and perfectly regular timestamps" });
  }

  // 5. Motion activity.
  const motion = signals.motion.filter((m) => m.confidence >= 1);
  const totalMotion = motion.reduce((s, m) => s + (m.end - m.start), 0);
  if (totalMotion > 60) {
    const share = (a: MotionActivity) => motion.filter((m) => m.activity === a).reduce((s, m) => s + (m.end - m.start), 0) / totalMotion;
    const auto = share("automotive"), cyc = share("cycling");
    if (auto > rules.maxAutomotiveFraction) flags.push({ rule: "automotive", severity: 2, detail: `${Math.trunc(auto * 100)}% of the run looked like driving` });
    if (cyc > rules.maxCyclingFraction) flags.push({ rule: "cycling", severity: 2, detail: `${Math.trunc(cyc * 100)}% of the run looked like cycling` });
    excluded.push(...motion.filter((m) => (m.activity === "automotive" || m.activity === "cycling") && m.confidence === 2)
      .map((m) => ({ start: m.start, end: Math.max(m.start, m.end) })));
  }

  // 6. Cadence.
  const fastLegs = legs.filter((l) => l.v >= rules.runningSpeedForCadenceCheckMps && l.v <= maxV);
  const fastSeconds = fastLegs.reduce((s, l) => s + (l.t1 - l.t0), 0);
  if (fastSeconds > 120) {
    const cad = fastLegs.map((l) => nearest(signals.cadence, l.t1, 30)?.stepsPerMinute).filter((x): x is number => x !== undefined);
    if (cad.length >= 5) {
      const med = [...cad].sort((a, b) => a - b)[cad.length >> 1];
      if (med < rules.minRunningCadenceSpm) flags.push({ rule: "cadence", severity: 1, detail: `median ${Math.trunc(med)} spm while moving at running pace` });
    } else if (!signals.cadence.length && !signals.motion.length) {
      flags.push({ rule: "no_motion_data", severity: 0, detail: "no pedometer or motion data" });
    }
  }

  // 7. Heart rate.
  if (fastSeconds > 300 && signals.heartRate.length) {
    const hrs = fastLegs.map((l) => nearest(signals.heartRate, l.t1, 20)?.bpm).filter((x): x is number => x !== undefined);
    if (hrs.length >= 10) {
      const avg = hrs.reduce((a, b) => a + b, 0) / hrs.length;
      if (avg < rules.lowHeartRateBpm) flags.push({ rule: "heart_rate", severity: 0, detail: `average ${Math.trunc(avg)} bpm at running pace` });
    }
  }

  const highs = flags.filter((f) => f.severity === 2).length, mediums = flags.filter((f) => f.severity === 1).length;
  excluded = mergeIntervals(excluded);
  return { verdict: highs > 0 || mediums >= 3 ? "underReview" : "accepted", flags, excluded };
}
