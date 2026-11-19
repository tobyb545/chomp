// Port of ChompKit/Game/Coins.swift. Streets are lined with coins, one per
// token, evenly spaced; coins are the unit of ownership.
import type { Rules } from "./rules.ts";

export const coinCount = (length: number, metresPerToken: number) => Math.max(1, Math.round(length / metresPerToken));
/** Distance along the street of coin `i` of `n`. */
export const coinOffset = (i: number, n: number, length: number) => length * (i + 0.5) / n;
export const coinID = (segment: string, i: number) => `${segment}#${i}`;
/** The street a coin is on. A plain street ID maps to itself. */
export const coinSegment = (key: string) => { const h = key.lastIndexOf("#"); return h < 0 ? key : key.slice(0, h); };
export const coinIndex = (key: string) => { const h = key.lastIndexOf("#"); return h < 0 ? undefined : Number(key.slice(h + 1)); };
export const isCoin = (key: string) => key.includes("#");

export const coinsOf = (r: Rules, seg: { id: string; length: number }) =>
  Array.from({ length: coinCount(seg.length, r.tokens.metresPerToken) }, (_, i) => coinID(seg.id, i));
export const coinReach = (r: Rules) => (r.capture as { coinReachMetres?: number }).coinReachMetres ?? 5;
