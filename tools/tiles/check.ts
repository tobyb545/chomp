// Checks prebuilt tiles against ones built from Overpass: the 3x3 tiles around
// West Byfleet in shared/fixtures/osm-west-byfleet.json. Build Surrey first:
//   python3 tools/tiles/extract.py surrey-latest.osm.pbf /tmp/ex
//   node --experimental-strip-types tools/tiles/build.ts /tmp/ex /tmp/out
//   node --experimental-strip-types tools/tiles/check.ts /tmp/out
// Expect every segment ID to match (a few may differ if OpenStreetMap changed between the two).
import { readFileSync, existsSync } from "node:fs";
import { buildTile, subset, TileKey, type OverpassResponse } from "../../backend/supabase/functions/_shared/chomp/mod.ts";
const osm = JSON.parse(readFileSync(new URL("../../shared/fixtures/osm-west-byfleet.json", import.meta.url), "utf8")) as OverpassResponse;
console.log("fixture OSM date:", osm.osm3s?.timestamp_osm_base);
const lats: number[] = [], lons: number[] = [];
for (const e of osm.elements) if (e.type === "node" && e.lat) { lats.push(e.lat); lons.push(e.lon!); }
const c = TileKey.containing({ lat: (Math.min(...lats) + Math.max(...lats)) / 2, lon: (Math.min(...lons) + Math.max(...lons)) / 2 });
let same = 0, onlyOld = 0, onlyNew = 0, coinsOld = 0, coinsNew = 0;
for (const k of c.neighbourhood(1)) {
  const f = `${process.argv[2]}/v1/${k.fileName}.json`;
  if (!existsSync(f)) { console.log(k.toString(), "missing from new build"); continue; }
  const a = buildTile(k, subset(osm, k)), b = JSON.parse(readFileSync(f, "utf8"));
  const A = new Map(a.segments.map((s) => [s.id, s])), B = new Map(b.segments.map((s: any) => [s.id, s]));
  let s = 0, geomDiff = 0;
  for (const [id, seg] of A) if (B.has(id)) { s++; if (JSON.stringify(seg.coords) !== JSON.stringify((B.get(id) as any).coords)) geomDiff++; }
  same += s; onlyOld += A.size - s; onlyNew += B.size - s;
  console.log(k.toString(), `fixture ${A.size}, new ${B.size}, same id ${s} (${geomDiff} reshaped), pois ${a.pois.length}/${b.pois.length}`);
}
console.log(`total: ${same} shared, ${onlyOld} only in fixture, ${onlyNew} only in new build`);
