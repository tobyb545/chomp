import { TileKey } from "./chomp/mod.ts";

/** At most a 3x3 block of neighbouring tiles per call, so one call is one Overpass request. */
export function parseWarm(body: unknown): TileKey[] | null {
  const raw = (body as { tiles?: unknown })?.tiles;
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > 9) return null;
  const keys = raw.map((s) => (typeof s === "string" ? TileKey.parse(s) : null));
  if (keys.some((k) => !k)) return null;
  const ks = keys as TileKey[];
  const xs = ks.map((k) => k.x), ys = ks.map((k) => k.y);
  if (Math.max(...xs) - Math.min(...xs) > 2 || Math.max(...ys) - Math.min(...ys) > 2) return null;
  return [...new Map(ks.map((k) => [k.toString(), k])).values()];
}
