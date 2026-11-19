// Port of ChompKit/Game/GameEngine.swift's run resolution, over a server-side
// snapshot of the area (World). Pure: returns the decisions plus the writes to make.
import { type Area, displayName } from "./area.ts";
import { type AntiCheatFlag, type AntiCheatReport, type Interval, type RunVerdict, isExcluded, mergeIntervals } from "./anticheat.ts";
import { distance, IntervalSet } from "./geo.ts";
import { type CoveragePiece, coverageOf, type MatchResult, type TracePoint } from "./matcher.ts";
import { type Rules, decaySeconds } from "./rules.ts";
import { coinCount, coinOffset, coinReach, coinsOf } from "./coins.ts";
import { bonusStreets, dayKey, nextDay, type PowerPellet, powerPellets, startOfDay } from "./spawns.ts";

export type OwnerKind = "player" | "ghost";
export interface OwnerRef { kind: OwnerKind; id: string }
export interface Ownership { owner: OwnerRef; capturedAt: number; lastVisitedAt: number }
export const sameOwner = (a?: OwnerRef, b?: OwnerRef) => !!a && !!b && a.kind === b.kind && a.id === b.id;

export function strength(o: Ownership, now: number, decay: number): number {
  return Math.max(0, Math.min(1, 1 - (now - o.lastVisitedAt) / decay));
}

export interface World {
  playerID: string;
  /** Ownership of every coin in the area that has an owner, keyed "<segment>#<i>". */
  ownership: Map<string, Ownership>;
  collectedPellets: Set<string>;
  /** Captures already made on the run's end day (Europe/London). */
  capturesToday: number;
  /** Block → last time this player was awarded it. */
  blockAwards: Map<string, number>;
  /** Tiles this player has already conquered ("14/x/y"). */
  conqueredTiles: Set<string>;
}

export interface RunContext { runID: string; startedAt: number; endedAt: number; isImport: boolean }

export type CaptureKind = "captured" | "stolen" | "refreshed" | "rejected" | "partial";
export interface CaptureRecord {
  segmentID: string; streetName: string; kind: CaptureKind; coverage: number; points: number; multiplier: number;
  previousOwner?: OwnerRef; at: number; reason?: string;
  /** Coins taken on this street, and which. */
  tokens?: number; coins?: number[];
}

export interface RunOutcome {
  runID: string;
  captures: CaptureRecord[];
  points: number;
  blockBonus: number;
  blocksCompleted: string[];
  pelletsCollected: string[];
  frenzyWindows: Interval[];
  verdict: RunVerdict;
  flags: AntiCheatFlag[];
  conqueredTown: boolean;
}

export interface Writes {
  ownership: Map<string, Ownership>;
  /** segment → when the player ran most of it (personal exploration) */
  coverage: Map<string, number>;
  pellets: { id: string; t: number }[];
  blockAwards: { id: string; t: number; points: number }[];
  capturesToday: number;
  /** Tiles conquered by this run. */
  conqueredTiles: string[];
}

export class GameEngine {
  readonly area: Area;
  readonly rules: Rules;
  constructor(area: Area, rules: Rules) {
    this.area = area;
    this.rules = rules;
  }

  private live(o: Ownership | undefined, now: number): Ownership | undefined {
    return o && strength(o, now, decaySeconds(this.rules)) > 0 ? o : undefined;
  }

  /** How many of a street's coins `owner` holds, out of how many. */
  coinsHeld(seg: { id: string; length: number }, owner: OwnerRef, ownership: Map<string, Ownership>, now: number) {
    const ids = coinsOf(this.rules, seg);
    let held = 0;
    for (const id of ids) {
      const o = this.live(ownership.get(id), now);
      if (o && sameOwner(o.owner, owner)) held++;
    }
    return { held, total: ids.length };
  }

  completedBlocks(owner: OwnerRef, ownership: Map<string, Ownership>, now: number): string[] {
    if (this.rules.blocks.enabled === false) return [];
    return this.area.blocks.filter((b) => b.segmentIDs.every((id) => {
      const seg = this.area.segment(id);
      if (!seg) return false;
      const c = this.coinsHeld(seg, owner, ownership, now);
      return c.held === c.total;
    })).map((b) => b.id);
  }

  tileHeldFraction(tile: string, owner: OwnerRef, ownership: Map<string, Ownership>, now: number): number {
    const total = this.area.lengthByTile.get(tile) ?? 0;
    if (total <= 0) return 0;
    let metres = 0;
    for (const s of this.area.segmentsIn(tile)) {
      const c = this.coinsHeld(s, owner, ownership, now);
      metres += s.length * c.held / c.total;
    }
    return metres / total;
  }

  resolve(run: RunContext, trace: TracePoint[], match: MatchResult, report: AntiCheatReport, world: World): { outcome: RunOutcome; writes: Writes } {
    const r = this.rules, me: OwnerRef = { kind: "player", id: world.playerID };
    const decay = decaySeconds(r), threshold = r.capture.coverageThreshold;
    const ownership = new Map(world.ownership);
    const writes: Writes = { ownership: new Map(), coverage: new Map(), pellets: [], blockAwards: [], capturesToday: world.capturesToday, conqueredTiles: [] };
    const pieces = match.pieces.filter((p) => !isExcluded(report, p));
    const excludedPieces = match.pieces.filter((p) => isExcluded(report, p));

    // Power pellets → frenzy.
    const pellets: string[] = [];
    let frenzy: Interval[] = [];
    if (!run.isImport && report.verdict === "accepted") {
      const spawns: PowerPellet[] = [];
      for (let day = startOfDay(run.startedAt); day <= run.endedAt; day = nextDay(day)) spawns.push(...powerPellets(this.area, day, r));
      for (const pellet of spawns) {
        if (world.collectedPellets.has(pellet.id)) continue;
        const hit = trace.find((p) => p.t >= pellet.activeFrom && p.t < pellet.activeUntil && p.accuracy <= r.matching.maxAccuracyMetres &&
          distance(p.coordinate, pellet.landmark.coordinate) <= r.frenzy.collectRadiusMetres);
        if (hit) {
          pellets.push(pellet.id);
          writes.pellets.push({ id: pellet.id, t: hit.t });
          frenzy.push({ start: hit.t, end: hit.t + r.frenzy.durationSeconds });
        }
      }
      frenzy = mergeIntervals(frenzy);
    }
    const inFrenzy = (t: number) => frenzy.some((iv) => t >= iv.start && t <= iv.end);

    const bonuses = bonusStreets(this.area, run.startedAt, r)
      .concat(dayKey(run.startedAt) === dayKey(run.endedAt) ? [] : bonusStreets(this.area, run.endedAt, r));
    const bonusMultiplier = (seg: string, t: number) =>
      Math.max(1, ...bonuses.filter((b) => b.segmentIDs.includes(seg) && t >= b.startsAt && t < b.endsAt).map((b) => b.multiplier));

    interface Progress { set: IntervalSet; crossed?: number; frenzyCrossed?: number; last: number; pieces: CoveragePiece[] }
    const progress = new Map<number, Progress>();
    for (const p of [...pieces].sort((a, b) => a.end - b.end)) {
      let pr = progress.get(p.segment);
      if (!pr) progress.set(p.segment, pr = { set: new IntervalSet(), last: -Infinity, pieces: [] });
      pr.set.insert(p.from, p.to);
      pr.pieces.push(p);
      pr.last = Math.max(pr.last, p.end);
      const len = this.area.segments[p.segment].length;
      const ratio = len > 0 ? pr.set.covered / len : 0;
      if (pr.crossed === undefined && ratio >= threshold) pr.crossed = p.end;
      if (pr.frenzyCrossed === undefined && ratio >= r.capture.frenzyRivalCoverageThreshold && inFrenzy(p.end)) pr.frenzyCrossed = p.end;
    }

    let capturesToday = world.capturesToday, capturesThisRun = 0, points = 0;
    const records: CaptureRecord[] = [];
    const completeBefore = new Set(this.completedBlocks(me, ownership, run.startedAt));
    // Coins the run passed on each street, and when (earliest piece that reached it).
    const reach = coinReach(r);
    const segHits = new Map<number, { index: number; at: number }[]>();
    for (const [segIndex, pr] of progress) {
      const seg = this.area.segments[segIndex];
      const n = coinCount(seg.length, r.tokens.metresPerToken);
      const hits: { index: number; at: number }[] = [];
      for (let i = 0; i < n; i++) {
        const o = coinOffset(i, n, seg.length);
        const p = pr.pieces.find((q) => Math.min(q.from, q.to) - reach <= o && o <= Math.max(q.from, q.to) + reach);
        if (p) hits.push({ index: i, at: p.end });
      }
      segHits.set(segIndex, hits.sort((a, b) => a.at - b.at || a.index - b.index));
    }
    const firstKey = (i: number, pr: Progress) => segHits.get(i)?.[0]?.at ?? pr.last;
    const ordered = [...progress.entries()].sort((a, b) => firstKey(a[0], a[1]) - firstKey(b[0], b[1]) || a[0] - b[0]);

    for (const [segIndex, pr] of ordered) {
      const seg = this.area.segments[segIndex];
      const ratio = Math.min(1, seg.length > 0 ? pr.set.covered / seg.length : 0);
      const hits = segHits.get(segIndex) ?? [];
      const ids = coinsOf(r, seg);
      const liveOwner = (i: number, t: number) => this.live(ownership.get(ids[i]), t);
      const previous = hits.map((h) => liveOwner(h.index, h.at)).find((o) => !!o && !sameOwner(o.owner, me))?.owner;
      const firstAt = hits[0]?.at ?? pr.last;
      // Exploration still means running most of a street.
      if (pr.crossed !== undefined) writes.coverage.set(seg.id, pr.crossed);

      const record = (kind: CaptureKind, at: number, pts = 0, mult = 1, reason?: string, taken?: number[]) => {
        const rec: CaptureRecord = { segmentID: seg.id, streetName: displayName(seg), kind, coverage: ratio, points: pts, multiplier: mult,
          previousOwner: previous, at, reason };
        if (taken) { rec.tokens = taken.length; rec.coins = taken; }
        records.push(rec);
      };

      if (!hits.length) { record("partial", pr.last); continue; }
      if (run.isImport) { record("rejected", firstAt, 0, 1, "Imported runs count for exploration only"); continue; }
      if (report.verdict === "underReview") { record("rejected", firstAt, 0, 1, "Run is under review"); continue; }
      const wouldGain = hits.some((h) => !sameOwner(liveOwner(h.index, h.at)?.owner, me));
      if (wouldGain && (capturesThisRun >= r.antiCheat.maxCapturesPerRun || capturesToday >= r.antiCheat.maxCapturesPerDay)) {
        record("rejected", firstAt, 0, 1, "Daily capture limit reached");
        continue;
      }

      const spacing = seg.length / ids.length;
      const taken: number[] = [];
      let takenAt: number | undefined;
      let stole = false, refreshed = false, blocked = false, pts = 0, maxMult = 1;
      for (const h of hits) {
        const current = liveOwner(h.index, h.at);
        if (current && sameOwner(current.owner, me)) {
          const o = { ...current, lastVisitedAt: Math.max(current.lastVisitedAt, h.at) };
          ownership.set(ids[h.index], o);
          writes.ownership.set(ids[h.index], o);
          refreshed = true;
          continue;
        }
        // Later capture wins: a run added after the fact can't take back coins someone ran since.
        if (current && current.capturedAt > h.at) { blocked = true; continue; }
        const mult = (inFrenzy(h.at) ? r.frenzy.multiplier : 1) * bonusMultiplier(seg.id, h.at);
        maxMult = Math.max(maxMult, mult);
        pts += spacing * r.capture.pointsPerMetre * mult;
        if (current) stole = true;
        const o: Ownership = { owner: me, capturedAt: h.at, lastVisitedAt: h.at };
        ownership.set(ids[h.index], o);
        writes.ownership.set(ids[h.index], o);
        taken.push(h.index);
        takenAt ??= h.at;
      }
      if (taken.length) {
        const p = Math.max(r.capture.minimumPointsPerSegment, Math.round(pts));
        capturesThisRun++;
        capturesToday++;
        points += p;
        record(stole ? "stolen" : "captured", takenAt!, p, maxMult, undefined, taken);
      } else if (refreshed) record("refreshed", firstAt);
      else if (blocked) record("rejected", firstAt, 0, 1, "Someone ran it more recently");
      else record("partial", firstAt);
    }

    for (const p of excludedPieces) {
      const seg = this.area.segments[p.segment];
      if (progress.has(p.segment) || records.some((x) => x.segmentID === seg.id)) continue;
      const cov = coverageOf(excludedPieces.filter((x: CoveragePiece) => x.segment === p.segment)).get(p.segment)?.covered ?? 0;
      const ratio = Math.min(1, cov / Math.max(seg.length, 1));
      if (ratio >= threshold) {
        records.push({ segmentID: seg.id, streetName: displayName(seg), kind: "rejected", coverage: ratio, points: 0, multiplier: 1,
          previousOwner: ownership.get(seg.id)?.owner, at: p.end, reason: "Too fast to be running" });
      }
    }
    writes.capturesToday = capturesToday;

    let blockBonus = 0;
    const newBlocks: string[] = [];
    for (const b of this.completedBlocks(me, ownership, run.endedAt)) {
      if (completeBefore.has(b)) continue;
      const block = this.area.blockByID.get(b);
      if (!block) continue;
      const last = world.blockAwards.get(b);
      if (last !== undefined && run.endedAt - last < r.blocks.reawardCooldownHours * 3600) continue;
      const bonus = r.blocks.bonusBasePoints + Math.trunc(block.areaM2 / 100 * r.blocks.bonusPointsPerHundredSquareMetres);
      blockBonus += bonus;
      newBlocks.push(b);
      writes.blockAwards.push({ id: b, t: run.endedAt, points: bonus });
    }

    const touched = new Set<string>();
    for (const c of records) {
      if (c.kind !== "captured" && c.kind !== "stolen") continue;
      const seg = this.area.segment(c.segmentID);
      if (seg) touched.add(this.area.segmentTile[seg.index]);
    }
    for (const tile of this.rules.blocks.enabled === false ? [] : [...touched].sort()) {
      if (!world.conqueredTiles.has(tile) && this.tileHeldFraction(tile, me, ownership, run.endedAt) >= 0.999) writes.conqueredTiles.push(tile);
    }

    return {
      outcome: {
        runID: run.runID, captures: records, points, blockBonus, blocksCompleted: newBlocks, pelletsCollected: pellets,
        frenzyWindows: frenzy, verdict: report.verdict, flags: report.flags, conqueredTown: writes.conqueredTiles.length > 0,
      },
      writes,
    };
  }
}
