// Port of ChompKit/Matching/MapMatcher.swift (Newson & Krumm HMM over Chomp's segment graph).
import type { Area, PathTree } from "./area.ts";
import { type Coordinate, IntervalSet, type Vec2, vdist } from "./geo.ts";
import type { Rules } from "./rules.ts";

export interface TracePoint {
  coordinate: Coordinate;
  /** epoch seconds */
  t: number;
  /** metres; negative = invalid */
  accuracy: number;
  /** m/s; negative = unknown */
  speed: number;
}

export interface CoveragePiece { segment: number; from: number; to: number; start: number; end: number }
export interface MatchedPoint { traceIndex: number; segment: number; offset: number; snapped: Coordinate; t: number }
export interface MatchResult { pieces: CoveragePiece[]; path: MatchedPoint[]; unmatchedPoints: number; chunks: number; usedPoints: number }

export function coverageOf(pieces: CoveragePiece[]): Map<number, IntervalSet> {
  const out = new Map<number, IntervalSet>();
  for (const p of pieces) {
    let s = out.get(p.segment);
    if (!s) out.set(p.segment, s = new IntervalSet());
    s.insert(p.from, p.to);
  }
  return out;
}

interface Candidate { segment: number; offset: number; distance: number; point: Vec2 }
type Part = [number, number, number];
interface Route { length: number; parts: Part[] }
interface Kept { i: number; p: TracePoint; v: Vec2 }
interface Layer { point: Kept; cands: Candidate[]; score: number[]; back: number[]; routes: (Route | null)[] }

export class MapMatcher {
  readonly area: Area;
  readonly rules: Rules["matching"];
  constructor(area: Area, rules: Rules["matching"]) {
    this.area = area;
    this.rules = rules;
  }

  match(trace: TracePoint[]): MatchResult {
    const r = this.rules, proj = this.area.projection;
    const kept: Kept[] = [];
    trace.forEach((p, i) => {
      if (!(p.accuracy >= 0 && p.accuracy <= r.maxAccuracyMetres)) return;
      const v = proj.project(p.coordinate);
      const last = kept[kept.length - 1];
      if (last) {
        const dt = p.t - last.p.t;
        if (dt <= 0) return;
        if (vdist(v, last.v) < r.minPointSpacingMetres && dt < 10) return;
      }
      kept.push({ i, p, v });
    });
    const result: MatchResult = { pieces: [], path: [], unmatchedPoints: 0, chunks: 0, usedPoints: kept.length };
    if (!kept.length) return result;

    const chunks: Kept[][] = [[kept[0]]];
    for (let k = 1; k < kept.length; k++) {
      const prev = kept[k - 1], cur = kept[k];
      if (cur.p.t - prev.p.t > r.maxGapSeconds || vdist(cur.v, prev.v) > r.maxGapMetres) chunks.push([cur]);
      else chunks[chunks.length - 1].push(cur);
    }
    for (const c of chunks) this.matchChunk(c, result);
    return result;
  }

  private candidates(v: Vec2): Candidate[] {
    const out: Candidate[] = [];
    for (const s of this.area.index.near(v, this.rules.candidateRadiusMetres)) {
      const pr = this.area.segments[s].polyline.project(v);
      if (pr.distance <= this.rules.candidateRadiusMetres) out.push({ segment: s, offset: pr.offset, distance: pr.distance, point: pr.point });
    }
    // Ties (a point exactly at a junction) broken by index, as in Swift.
    out.sort((a, b) => a.distance - b.distance || a.segment - b.segment);
    return out.slice(0, this.rules.maxCandidatesPerPoint);
  }

  private route(a: Candidate, b: Candidate, limit: number, cache: Map<number, PathTree>, key: number): Route | null {
    const segs = this.area.segments;
    if (a.segment === b.segment) return { length: Math.abs(b.offset - a.offset), parts: [[a.segment, a.offset, b.offset]] };
    const sa = segs[a.segment], sb = segs[b.segment];
    let tree = cache.get(key);
    if (!tree) {
      tree = this.area.graph.shortestPaths([[sa.startNode, a.offset], [sa.endNode, sa.length - a.offset]], segs, limit);
      cache.set(key, tree);
    }
    const ds = tree.dist.get(sb.startNode), de = tree.dist.get(sb.endNode);
    const viaStart = ds === undefined ? Infinity : ds + b.offset;
    const viaEnd = de === undefined ? Infinity : de + (sb.length - b.offset);
    const total = Math.min(viaStart, viaEnd);
    if (!Number.isFinite(total) || total > limit) return null;
    const entry = viaStart <= viaEnd ? sb.startNode : sb.endNode;

    const middle: Part[] = [];
    let node = entry;
    for (let guard = 0; guard < 512; guard++) {
      const pv = tree.prev.get(node);
      if (!pv) break;
      const [p, seg] = pv, s = segs[seg];
      middle.push(s.startNode === p ? [seg, 0, s.length] : [seg, s.length, 0]);
      node = p;
    }
    middle.reverse();
    const exitViaStart = sa.startNode === sa.endNode ? a.offset <= sa.length - a.offset : node === sa.startNode;
    const first: Part = exitViaStart ? [a.segment, a.offset, 0] : [a.segment, a.offset, sa.length];
    const last: Part = entry === sb.startNode ? [b.segment, 0, b.offset] : [b.segment, sb.length, b.offset];
    return { length: total, parts: [first, ...middle, last] };
  }

  private matchChunk(chunk: Kept[], result: MatchResult): void {
    const sigma = this.rules.gpsSigmaMetres, beta = this.rules.transitionBeta, proj = this.area.projection;
    let layers: Layer[] = [];

    const flush = () => {
      const last = layers[layers.length - 1];
      if (!last || !last.cands.length) { layers = []; return; }
      result.chunks++;
      let idx = 0;
      last.score.forEach((s, i) => { if (s > last.score[idx]) idx = i; });
      const chosen: [number, number][] = [];
      for (let l = layers.length - 1; l >= 0; l--) { chosen.push([l, idx]); idx = layers[l].back[idx]; }
      chosen.reverse();
      chosen.forEach(([li, ci], n) => {
        const layer = layers[li], cand = layer.cands[ci];
        result.path.push({ traceIndex: layer.point.i, segment: cand.segment, offset: cand.offset, snapped: proj.unproject(cand.point), t: layer.point.p.t });
        if (n === 0) return;
        const t0 = layers[chosen[n - 1][0]].point.p.t, t1 = layer.point.p.t;
        const r = layer.routes[ci];
        if (!r) return;
        let acc = 0;
        const total = Math.max(r.length, 0.0001), span = t1 - t0;
        for (const [seg, f, to] of r.parts) {
          const len = Math.abs(to - f);
          const s = t0 + span * acc / total;
          acc += len;
          const e = t0 + span * Math.min(1, acc / total);
          if (len > 0 || r.parts.length === 1) result.pieces.push({ segment: seg, from: Math.min(f, to), to: Math.max(f, to), start: s, end: e });
        }
      });
      layers = [];
    };

    for (const item of chunk) {
      const cands = this.candidates(item.v);
      if (!cands.length) { result.unmatchedPoints++; flush(); continue; }
      const emission = cands.map((c) => -0.5 * (c.distance / sigma) ** 2);
      const fresh = (): Layer => ({ point: item, cands, score: emission, back: cands.map(() => -1), routes: cands.map(() => null) });
      const prev = layers[layers.length - 1];
      if (!prev) { layers.push(fresh()); continue; }
      const gc = vdist(item.v, prev.point.v);
      const limit = gc * 2 + 60;
      const cache = new Map<number, PathTree>();
      const score = cands.map(() => -Infinity), back = cands.map(() => -1);
      const routes: (Route | null)[] = cands.map(() => null);
      cands.forEach((cj, j) => {
        prev.cands.forEach((ci, i) => {
          if (!Number.isFinite(prev.score[i])) return;
          const r = this.route(ci, cj, limit, cache, i);
          if (!r) return;
          const s = prev.score[i] + emission[j] - Math.abs(r.length - gc) / beta;
          if (s > score[j]) { score[j] = s; back[j] = i; routes[j] = r; }
        });
      });
      if (score.every((s) => !Number.isFinite(s))) { flush(); layers.push(fresh()); continue; }
      const m = Math.max(...score.filter(Number.isFinite));
      layers.push({ point: item, cands, score: score.map((s) => s - m), back, routes });
    }
    flush();
  }
}
