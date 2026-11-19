// Server-side bots for online towns (port of ChompKit/Game/Ghosts.swift's walk).
// Bots are always labelled as bots; they keep quiet towns lively.
import type { Area } from "./area.ts";
import { type Ownership, type OwnerRef, sameOwner, strength } from "./engine.ts";
import { type Rules, decaySeconds } from "./rules.ts";
import { SeededRandom } from "./spawns.ts";
import { coinCount, coinSegment, coinsOf } from "./coins.ts";

export interface Ghost { id: string; name: string; colorHex: string; aggression: number; segmentsPerDay: number; cursorNode: number }

export const GHOST_NAMES = ["Dusk", "Rook", "Moth", "Fennel", "Pike", "Wren"];
export const GHOST_COLOURS = ["7C8CFF", "FF6FA1", "5CE1E6", "FFB15C", "B58CFF", "9CFF7A"];

/** Bots for one district (`key`, e.g. "12/2042/1365"). */
export function makeGhosts(area: Area, rules: Rules, key: string = area.slug): Ghost[] {
  const rng = new SeededRandom(`ghosts|${key}|server`);
  const nodes = [...area.graph.adjacency.keys()].sort((a, b) => a - b);
  const g = rules.ghosts;
  return GHOST_NAMES.slice(0, g.perArea).map((n, i) => ({
    id: `bot-${key.replaceAll("/", "-")}-${n.toLowerCase()}`,
    name: `Bot ${n}`,
    colorHex: GHOST_COLOURS[i % GHOST_COLOURS.length],
    aggression: 0.3 + rng.unit() * 0.5,
    segmentsPerDay: g.segmentsPerDayMin + rng.int(Math.max(1, g.segmentsPerDayMax - g.segmentsPerDayMin + 1)),
    cursorNode: nodes[rng.int(nodes.length)],
  }));
}

export interface Raid { segmentID: string; from: OwnerRef; at: number }

/**
 * Moves one bot `steps` streets between `start` and `end`, mutating `ownership`.
 * Players' streets are targeted in proportion to aggression; returns writes and raids.
 */
export function walkGhost(area: Area, rules: Rules, ghost: Ghost, steps: number, start: number, end: number,
  ownership: Map<string, Ownership>, seed: string): { writes: Map<string, Ownership>; raids: Raid[]; cursor: number } {
  const rng = new SeededRandom(seed);
  const decay = decaySeconds(rules);
  const me: OwnerRef = { kind: "ghost", id: ghost.id };
  const cap = Math.trunc(area.segments.reduce((n, s) => n + coinCount(s.length, rules.tokens.metresPerToken), 0) * 0.06); // in coins
  const liveAt = (o: Ownership | undefined) => !!o && strength(o, end, decay) > 0;
  let held = [...ownership.values()].filter((o) => sameOwner(o.owner, me) && liveAt(o)).length;
  const players = [...new Set([...ownership.entries()].filter(([, o]) => o.owner.kind === "player" && liveAt(o)).map(([k]) => coinSegment(k)))].sort();
  const writes = new Map<string, Ownership>();
  const raids: Raid[] = [];
  const nodes = [...area.graph.adjacency.keys()].sort((a, b) => a - b);
  let node = ghost.cursorNode;

  for (let step = 0; step < steps; step++) {
    if (players.length && rng.unit() < ghost.aggression * 0.12) {
      const seg = area.segment(players[rng.int(players.length)]);
      if (seg) node = rng.unit() < 0.5 ? seg.startNode : seg.endNode;
    }
    const options = area.graph.neighbours(node);
    if (!options.length) { node = nodes[rng.int(nodes.length)]; continue; }
    const weights = options.map((e) => {
      const owners = coinsOf(rules, area.segments[e.segment]).map((id) => ownership.get(id)).filter(liveAt).map((o) => o!.owner);
      if (!owners.length) return held >= cap ? 0.15 : 1.5;
      if (owners.some((o) => o.kind === "player")) return 1 + 4 * ghost.aggression;
      if (owners.every((o) => sameOwner(o, me))) return 0.35;
      return 0.6;
    });
    let x = rng.unit() * weights.reduce((a, b) => a + b, 0);
    let pick = options[0];
    for (let i = 0; i < options.length; i++) { x -= weights[i]; if (x <= 0) { pick = options[i]; break; } }
    const seg = area.segments[pick.segment];
    const t = start + (end - start) * (step + 1) / steps;
    // A bot runs the whole street, so it takes every coin on it.
    let raidedFrom: OwnerRef | undefined;
    for (const id of coinsOf(rules, seg)) {
      const prev = ownership.get(id);
      let next: Ownership;
      if (prev && sameOwner(prev.owner, me)) {
        next = { ...prev, lastVisitedAt: t };
      } else {
        if (prev && prev.owner.kind === "player" && strength(prev, t, decay) > 0) raidedFrom ??= prev.owner;
        next = { owner: me, capturedAt: t, lastVisitedAt: t };
        held++;
      }
      ownership.set(id, next);
      writes.set(id, next);
    }
    if (raidedFrom) raids.push({ segmentID: seg.id, from: raidedFrom, at: t });
    node = pick.other;
  }
  return { writes, raids, cursor: node };
}
