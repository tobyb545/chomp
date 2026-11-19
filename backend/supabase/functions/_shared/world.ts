// Street tiles on the server: read from map_tiles, the prebuilt set on Cloudflare
// R2 (tools/tiles), or built from OpenStreetMap (Overpass) with the same StreetBuilder the app uses, then stored. Each built
// tile is also published to the public `tiles` Storage bucket, which the app
// checks before going to Overpass itself, so a busy area is fetched only once.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import {
  Area, buildTile, type OverpassResponse, overpassQuery, subset, TILE_FORMAT, TileKey, type TileFile,
} from "./chomp/mod.ts";

const OVERPASS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
];
const MAX_AGE_S = 30 * 86_400;

// Per-isolate cache; tiles change at most monthly.
const cache = new Map<string, { tile: TileFile; at: number }>();

async function fetchOverpass(keys: TileKey[]): Promise<OverpassResponse> {
  const body = new URLSearchParams({ data: overpassQuery(keys) });
  let last: unknown;
  for (const url of OVERPASS) {
    try {
      const r = await fetch(url, { method: "POST", body, headers: { "User-Agent": "chomp-server/1 (street game tile builder)" },
        signal: AbortSignal.timeout(100_000) });  // a 3x3 query often takes 40-60 s
      if (r.ok) return await r.json();
      last = new Error(`Overpass ${r.status}`);
    } catch (e) { last = e; }
  }
  throw last;
}

/** Prebuilt tiles (tools/tiles, Cloudflare R2), if CHOMP_TILES_URL is set. Missing ones are skipped. */
async function fetchPrebuilt(keys: TileKey[]): Promise<TileFile[]> {
  const base = Deno.env.get("CHOMP_TILES_URL")?.replace(/\/$/, "");
  if (!base) return [];
  const got = await Promise.all(keys.map(async (k) => {
    try {
      const r = await fetch(`${base}/v${TILE_FORMAT}/${k.fileName}.json`, { signal: AbortSignal.timeout(8_000) });
      if (!r.ok) return null;
      const t = await r.json() as TileFile;
      return t.formatVersion === TILE_FORMAT && t.key === k.toString() ? t : null;
    } catch { return null; }
  }));
  return got.filter((t): t is TileFile => t !== null);
}

/** Builds and stores tiles (one Overpass request per 3x3 group). */
async function build(db: SupabaseClient, keys: TileKey[]): Promise<TileFile[]> {
  const out: TileFile[] = [];
  for (let i = 0; i < keys.length; i += 9) {
    const group = keys.slice(i, i + 9);
    const osm = await fetchOverpass(group);
    for (const k of group) {
      const tile = buildTile(k, group.length === 1 ? osm : subset(osm, k));
      out.push(tile);
      await store(db, k, tile);
    }
  }
  return out;
}

async function store(db: SupabaseClient, k: TileKey, tile: TileFile) {
  const { error } = await db.rpc("store_map_tile", { p_key: tile.key, p_data: tile });
  if (error) console.error("store_map_tile", tile.key, error.message);
  const { error: se } = await db.storage.from("tiles").upload(`${k.fileName}.json`, JSON.stringify(tile),
    { contentType: "application/json", upsert: true, cacheControl: "86400" });
  if (se) console.error("tiles bucket", tile.key, se.message);
}

/**
 * Tiles for `keys`. Missing or month-old tiles are built, up to `buildLimit`
 * of them (the rest are skipped, or served stale if we have them).
 */
export async function loadTiles(db: SupabaseClient, keys: TileKey[], buildLimit = 36): Promise<TileFile[]> {
  const now = Date.now() / 1000;
  const found = new Map<string, TileFile>();
  const want = keys.map((k) => k.toString());
  for (const k of want) {
    const hit = cache.get(k);
    if (hit && now - hit.at < 600) found.set(k, hit.tile);
  }
  const ask = want.filter((k) => !found.has(k));
  const stale = new Set<string>();
  if (ask.length) {
    const { data } = await db.from("map_tiles").select("key, data, built_at").in("key", ask);
    for (const row of data ?? []) {
      const t = row.data as TileFile;
      if (t.formatVersion !== TILE_FORMAT) continue;
      found.set(row.key, t);
      cache.set(row.key, { tile: t, at: now });
      if (now - Date.parse(row.built_at) / 1000 > MAX_AGE_S) stale.add(row.key);
    }
  }
  // Missing or stale: the prebuilt set (refreshed monthly) before Overpass.
  const need = keys.filter((k) => !found.has(k.toString()) || stale.has(k.toString()));
  for (const t of await fetchPrebuilt(need)) {
    found.set(t.key, t); stale.delete(t.key); cache.set(t.key, { tile: t, at: now });
  }
  const toBuild = need.filter((k) => !found.has(k.toString()) || stale.has(k.toString())).slice(0, buildLimit);
  if (toBuild.length) {
    try {
      for (const t of await build(db, toBuild)) { found.set(t.key, t); cache.set(t.key, { tile: t, at: now }); }
    } catch (e) {
      console.error("tile build failed", (e as Error).message);  // stale copies (if any) still serve
    }
  }
  return want.flatMap((k) => (found.has(k) ? [found.get(k)!] : []));
}

/** The playable area around a trace: the same tiles the app uses for it. */
export async function areaForTrace(db: SupabaseClient, coords: { lat: number; lon: number }[], buildLimit?: number) {
  const keys = TileKey.covering(coords);
  const tiles = await loadTiles(db, keys, buildLimit);
  return { area: Area.fromTiles(tiles), keys, complete: tiles.length === keys.length };
}

/** Zoom-12 district ("12/x/y") a tile belongs to: 4x4 tiles, about 6 km. Bots live per district. */
export const districtOf = (k: TileKey) => `12/${k.x >> 2}/${k.y >> 2}`;
export function districtTiles(district: string): TileKey[] {
  const [, x, y] = district.split("/").map(Number);
  const out: TileKey[] = [];
  for (let dx = 0; dx < 4; dx++) for (let dy = 0; dy < 4; dy++) out.push(new TileKey(x * 4 + dx, y * 4 + dy));
  return out;
}
