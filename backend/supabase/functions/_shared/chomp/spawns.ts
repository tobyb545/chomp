// Port of ChompKit/Game/DailySpawns.swift. Deterministic, so every client and
// the server agree on today's power pellets and bonus streets.
import type { Area, Landmark } from "./area.ts";
import type { Rules } from "./rules.ts";

const MASK = (1n << 64n) - 1n;

/** SplitMix64 seeded by FNV-1a 64 of a string. */
export class SeededRandom {
  private state: bigint;
  constructor(seed: string | bigint) {
    if (typeof seed === "bigint") { this.state = seed & MASK; return; }
    let h = 0xcbf29ce484222325n;
    for (const b of new TextEncoder().encode(seed)) { h ^= BigInt(b); h = (h * 0x100000001b3n) & MASK; }
    this.state = h;
  }
  next(): bigint {
    this.state = (this.state + 0x9e3779b97f4a7c15n) & MASK;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & MASK;
    return z ^ (z >> 31n);
  }
  unit(): number { return Number(this.next() >> 11n) / 2 ** 53; }
  int(upper: number): number { return upper <= 0 ? 0 : Number(this.next() % BigInt(upper)); }
}

// ---- Europe/London calendar helpers (epoch seconds) ----
const fmt = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/London", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
});
function londonParts(t: number) {
  const o: Record<string, number> = {};
  for (const p of fmt.formatToParts(new Date(t * 1000))) if (p.type !== "literal") o[p.type] = Number(p.value);
  return o as { year: number; month: number; day: number; hour: number; minute: number; second: number };
}
/** Offset of London from UTC at instant t, in seconds. */
function londonOffset(t: number): number {
  const p = londonParts(t);
  return (Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) / 1000) - Math.floor(t);
}
export function dayKey(t: number): string {
  const p = londonParts(t);
  return `${p.year}-${String(p.month).padStart(2, "0")}-${String(p.day).padStart(2, "0")}`;
}
/** Instant of London midnight for the calendar day of y-m-d. */
function midnight(y: number, m: number, d: number): number {
  const guess = Date.UTC(y, m - 1, d) / 1000;
  let t = guess - londonOffset(guess);
  t = guess - londonOffset(t);
  return t;
}
export function startOfDay(t: number): number {
  const p = londonParts(t);
  return midnight(p.year, p.month, p.day);
}
export function nextDay(dayStart: number): number {
  const p = londonParts(dayStart + 36 * 3600);
  return midnight(p.year, p.month, p.day);
}

export interface PowerPellet { id: string; landmark: Landmark; activeFrom: number; activeUntil: number }
export interface BonusStreet { segmentIDs: string[]; streetName: string; multiplier: number; startsAt: number; endsAt: number }

export function powerPellets(area: Area, t: number, rules: Rules): PowerPellet[] {
  const key = dayKey(t);
  const rng = new SeededRandom(`pellets|${area.slug}|${key}`);
  const pool = [...area.landmarks].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const start = startOfDay(t), end = nextDay(start);
  const out: PowerPellet[] = [];
  const n = Math.min(rules.powerPellets.perDay, pool.length);
  for (let k = 0; k < n; k++) {
    const lm = pool.splice(rng.int(pool.length), 1)[0];
    out.push({ id: `${key}|${lm.id}`, landmark: lm, activeFrom: start, activeUntil: end });
  }
  return out;
}

export function bonusStreets(area: Area, t: number, rules: Rules): BonusStreet[] {
  const key = dayKey(t);
  const rng = new SeededRandom(`bonus|${area.slug}|${key}`);
  const pool = area.segments.filter((s) => s.name && s.length >= 80 && !s.isPath).sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  if (!pool.length) return [];
  const day = startOfDay(t);
  const windows: [number, number, number][] = [[6, 8, 3], [17, 20, 2], [12, 14, 2]];
  const used = new Set<string>();
  return windows.slice(0, rules.bonusStreets.perDay).map(([h0, h1, mult]) => {
    let s = pool[rng.int(pool.length)];
    for (let tries = 0; used.has(s.name) && tries < 10; tries++) s = pool[rng.int(pool.length)];
    used.add(s.name);
    return {
      segmentIDs: area.segments.filter((x) => x.name === s.name).map((x) => x.id),
      streetName: s.name, multiplier: mult, startsAt: day + h0 * 3600, endsAt: day + h1 * 3600,
    };
  });
}
