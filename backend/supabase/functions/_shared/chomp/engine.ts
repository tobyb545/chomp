// Port of ChompKit/Game/GameEngine.swift's run resolution, over a server-side
// snapshot of the area (World). Pure: returns the decisions plus the writes to make.
import { type Area, displayName } from "./area.ts";
import { type AntiCheatFlag, type AntiCheatReport, type Interval, type RunVerdict, isExcluded, mergeIntervals } from "./anticheat.ts";
import { distance, IntervalSet } from "./geo.ts";
import { type CoveragePiece, coverageOf, type MatchResult, type TracePoint } from "./matcher.ts";
import { type Rules, decaySeconds } from "./rules.ts";
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
  /** Ownership of every segment in the area that has an owner. */
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
  /** segment → when the player crossed the threshold on it */
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

  completedBlocks(owner: OwnerRef, ownership: Map<string, Ownership>, now: number): string[] {
    if (this.rules.blocks.enabled === false) return [];
    return this.area.blocks.filter((b) => b.segmentIDs.every((id) => {
      const o = this.live(ownership.get(id), now);
      return !!o && sameOwner(o.owner, owner);
    })).map((b) => b.id);
  }

  tileHeldFraction(tile: string, owner: OwnerRef, ownership: Map<string, Ownership>, now: number): number {
    const total = this.area.lengthByTile.get(tile) ?? 0;
    if (total <= 0) return 0;
    let metres = 0;
    for (const s of this.area.segmentsIn(tile)) {
      const o = this.live(ownership.get(s.id), now);
      if (o && sameOwner(o.owner, owner)) metres += s.length;
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

    interface Progress { set: IntervalSet; crossed?: number; frenzyCrossed?: number; last: number }
    const progress = new Map<number, Progress>();
    for (const p of [...pieces].sort((a, b) => a.end - b.end)) {
      let pr = progress.get(p.segment);
      if (!pr) progress.set(p.segment, pr = { set: new IntervalSet(), last: -Infinity });
      pr.set.insert(p.from, p.to);
      pr.last = Math.max(pr.last, p.end);
      const len = this.area.segments[p.segment].length;
      const ratio = len > 0 ? pr.set.covered / len : 0;
      if (pr.crossed === undefined && ratio >= threshold) pr.crossed = p.end;
      if (pr.frenzyCrossed === undefined && ratio >= r.capture.frenzyRivalCoverageThreshold && inFrenzy(p.end)) pr.frenzyCrossed = p.end;
    }

    let capturesToday = world.capturesToday, capturesThisRun = 0, points = 0;
    const records: CaptureRecord[] = [];
    const completeBefore = new Set(this.completedBlocks(me, ownership, run.startedAt));
    const key = (pr: Progress) => pr.crossed ?? pr.frenzyCrossed ?? pr.last;
    const ordered = [...progress.entries()].sort((a, b) => key(a[1]) - key(b[1]));

    for (const [segIndex, pr] of ordered) {
      const seg = this.area.segments[segIndex];
      const ratio = Math.min(1, seg.length > 0 ? pr.set.covered / seg.length : 0);
      const current = ownership.get(seg.id);
      const currentLive = this.live(current, pr.last);
      const at = key(pr);
      if (pr.crossed !== undefined) writes.coverage.set(seg.id, at);

      const record = (kind: CaptureKind, pts = 0, mult = 1, reason?: string) =>
        records.push({ segmentID: seg.id, streetName: displayName(seg), kind, coverage: ratio, points: pts, multiplier: mult,
          previousOwner: currentLive?.owner, at, reason });

      const isMine = sameOwner(currentLive?.owner, me);
      const isRival = !!currentLive && !isMine;
      if (!(pr.crossed !== undefined || (isRival && pr.frenzyCrossed !== undefined))) { record("partial"); continue; }
      if (run.isImport) { record("rejected", 0, 1, "Imported runs count for exploration only"); continue; }
      if (report.verdict === "underReview") { record("rejected", 0, 1, "Run is under review"); continue; }
      // Later capture wins: an after-the-fact run can't retake a street run since.
      if (isRival && currentLive!.capturedAt > at) { record("rejected", 0, 1, "Someone ran it more recently"); continue; }
      if (isMine) {
        const o = { ...current!, lastVisitedAt: Math.max(current!.lastVisitedAt, at) };
        ownership.set(seg.id, o);
        writes.ownership.set(seg.id, o);
        record("refreshed");
        continue;
      }
      if (capturesThisRun >= r.antiCheat.maxCapturesPerRun || capturesToday >= r.antiCheat.maxCapturesPerDay) {
        record("rejected", 0, 1, "Daily capture limit reached");
        continue;
      }
      const mult = (inFrenzy(at) ? r.frenzy.multiplier : 1) * bonusMultiplier(seg.id, at);
      const pts = Math.max(r.capture.minimumPointsPerSegment, Math.round(seg.length * r.capture.pointsPerMetre * mult));
      const o: Ownership = { owner: me, capturedAt: at, lastVisitedAt: at };
      ownership.set(seg.id, o);
      writes.ownership.set(seg.id, o);
      capturesThisRun++;
      capturesToday++;
      points += pts;
      record(isRival ? "stolen" : "captured", pts, mult);
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
