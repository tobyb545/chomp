// Builds street tiles from extract.py's output with the same buildTile the
// server uses, so the files are identical to ones built from Overpass.
//
// Usage: node --experimental-strip-types tools/tiles/build.ts <extract-dir> <out-dir> [only-tile...]
// Writes <out-dir>/v<TILE_FORMAT>/14_<x>_<y>.json and <out-dir>/v<TILE_FORMAT>/index.json.
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { buildTile, type OsmElement, TILE_FORMAT, TileKey } from "../../backend/supabase/functions/_shared/chomp/mod.ts";

type Way = [number, Record<string, string>, [number, number, number][]];
interface Line { t: [number, number][]; w?: Way; p?: OsmElement }

const [src, dest, ...only] = process.argv.slice(2);
if (!src || !dest) {
  console.error("usage: build.ts <extract-dir> <out-dir> [14/x/y ...]");
  process.exit(1);
}
const meta = JSON.parse(readFileSync(join(src, "meta.json"), "utf8"));
const outDir = join(dest, `v${TILE_FORMAT}`);
mkdirSync(outDir, { recursive: true });
const wanted = only.length ? new Set(only) : null;
const generatedAt = new Date();
const started = Date.now();
let built = 0, segments = 0, bytes = 0;
const index: string[] = [];

for (const file of readdirSync(join(src, "blocks")).filter((f) => f.endsWith(".jsonl")).sort()) {
  // Everything for one block (16x16 tiles), grouped by tile.
  const byTile = new Map<string, { ways: Way[]; pois: OsmElement[] }>();
  for (const raw of readFileSync(join(src, "blocks", file), "utf8").split("\n")) {
    if (!raw) continue;
    const line = JSON.parse(raw) as Line;
    for (const [x, y] of line.t) {
      const k = `14/${x}/${y}`;
      if (wanted && !wanted.has(k)) continue;
      let g = byTile.get(k);
      if (!g) byTile.set(k, (g = { ways: [], pois: [] }));
      if (line.w) g.ways.push(line.w);
      if (line.p) g.pois.push(line.p);
    }
  }
  for (const [k, g] of byTile) {
    // Shaped like Overpass's reply: ways with node IDs, then the nodes, then landmarks.
    const elements: OsmElement[] = [];
    const nodes = new Map<number, [number, number]>();
    for (const [id, tags, ns] of g.ways) {
      elements.push({ type: "way", id, nodes: ns.map((n) => n[0]), tags });
      for (const [ref, lat, lon] of ns) nodes.set(ref, [lat, lon]);
    }
    for (const [id, [lat, lon]] of nodes) elements.push({ type: "node", id, lat, lon });
    elements.push(...g.pois);
    const key = TileKey.parse(k)!;
    const tile = buildTile(key, { osm3s: { timestamp_osm_base: meta.osmTimestamp }, elements }, generatedAt);
    if (tile.segments.length === 0 && tile.pois.length === 0) continue;
    const json = JSON.stringify(tile);
    writeFileSync(join(outDir, `${key.fileName}.json`), json);
    index.push(k);
    built++; segments += tile.segments.length; bytes += json.length;
  }
}
writeFileSync(join(outDir, "index.json"), JSON.stringify({ osmTimestamp: meta.osmTimestamp, generatedAt: generatedAt.toISOString(), tiles: index.sort() }));
console.error(`${built} tiles, ${segments} segments, ${(bytes / 1e6).toFixed(1)} MB in ${((Date.now() - started) / 1000).toFixed(0)}s`);
