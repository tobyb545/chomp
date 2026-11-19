// Port of ChompKit/Map/Tiles.swift: zoom-14 map tiles and the StreetBuilder
// that turns OpenStreetMap highways into game segments. Must stay bit-for-bit
// identical to the Swift version (backend/tests/parity.test.ts checks it).
import { createHash } from "node:crypto";
import { type Coordinate, LocalProjection, type Vec2 } from "./geo.ts";

export const ZOOM = 14;
const N = 2 ** ZOOM;

export class TileKey {
  readonly x: number;
  readonly y: number;
  constructor(x: number, y: number) { this.x = x; this.y = y; }

  static containing(c: Coordinate): TileKey {
    const latR = c.lat * Math.PI / 180;
    return new TileKey(Math.floor((c.lon + 180) / 360 * N), Math.floor((1 - Math.log(Math.tan(latR) + 1 / Math.cos(latR)) / Math.PI) / 2 * N));
  }
  static parse(s: string): TileKey | null {
    const p = s.split("/").map(Number);
    return p.length === 3 && p[0] === ZOOM && p.every(Number.isInteger) ? new TileKey(p[1], p[2]) : null;
  }
  toString(): string { return `${ZOOM}/${this.x}/${this.y}`; }
  get fileName(): string { return `${ZOOM}_${this.x}_${this.y}`; }

  static lon(x: number) { return x / N * 360 - 180; }
  static lat(y: number) { return Math.atan(Math.sinh(Math.PI * (1 - 2 * y / N))) * 180 / Math.PI; }
  get west() { return TileKey.lon(this.x); }
  get east() { return TileKey.lon(this.x + 1); }
  get north() { return TileKey.lat(this.y); }
  get south() { return TileKey.lat(this.y + 1); }
  get center(): Coordinate { return { lat: (this.north + this.south) / 2, lon: (this.west + this.east) / 2 }; }
  contains(c: Coordinate): boolean { const k = TileKey.containing(c); return k.x === this.x && k.y === this.y; }

  neighbourhood(radius = 1): TileKey[] {
    const out: TileKey[] = [];
    for (let dx = -radius; dx <= radius; dx++) for (let dy = -radius; dy <= radius; dy++) out.push(new TileKey(this.x + dx, this.y + dy));
    return sortTiles(out);
  }

  /** Every tile within `margin` metres of a point (same rule as Swift's TileKey.covering). */
  static covering(coords: Coordinate[], margin = 250): TileKey[] {
    const seen = new Map<string, TileKey>();
    const dirs = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]];
    for (const c of coords) {
      for (const [dx, dy] of dirs) {
        const k = TileKey.containing({ lat: c.lat + dy * margin / 110_540, lon: c.lon + dx * margin / (111_320 * Math.cos(c.lat * Math.PI / 180)) });
        seen.set(k.toString(), k);
      }
    }
    return sortTiles([...seen.values()]);
  }
}

export const sortTiles = (t: TileKey[]) => t.sort((a, b) => (a.toString() < b.toString() ? -1 : a.toString() > b.toString() ? 1 : 0));

export interface SegmentRecord { id: string; name: string; kind: string; highway: string; length: number; a: number; b: number; coords: number[][] }
export interface BlockRecord { id: string; segments: string[]; areaM2: number; ring: number[][] }
export interface POIRecord { id: string; name: string; kind: string; lon: number; lat: number }
export interface TileFile {
  formatVersion: number; key: string; generatedAt: string; osmTimestamp: string;
  segments: SegmentRecord[]; blocks: BlockRecord[]; pois: POIRecord[];
}
export const TILE_FORMAT = 1;

export interface OsmElement {
  type: string; id: number; lat?: number; lon?: number; nodes?: number[]; tags?: Record<string, string>; center?: { lat: number; lon: number };
}
export interface OverpassResponse { osm3s?: { timestamp_osm_base?: string }; elements: OsmElement[] }

// ---------------------------------------------------------------------------

export const BUFFER_METRES = 400;
const ROAD = new Set(["trunk", "trunk_link", "primary", "primary_link", "secondary", "secondary_link",
  "tertiary", "tertiary_link", "unclassified", "residential", "living_street", "service"]);
const PATH = new Set(["pedestrian", "footway", "path", "track", "cycleway", "steps", "bridleway"]);
const EXCLUDED_SERVICE = new Set(["driveway", "parking_aisle", "drive-through", "emergency_access"]);
const FOOT_OK = new Set(["yes", "designated", "permissive"]);
const SIDEWALK_NEAR = 14, SIDEWALK_BEARING = 25, SIDEWALK_SHARE = 0.75;
const MIN_DEAD_END = 10, BLOCK_MIN = 1000, BLOCK_MAX = 250_000;

export function fetchBox(tile: TileKey) {
  const proj = new LocalProjection(tile.center);
  const dlat = BUFFER_METRES / proj.ky, dlon = BUFFER_METRES / proj.kx;
  return { south: tile.south - dlat, west: tile.west - dlon, north: tile.north + dlat, east: tile.east + dlon };
}

const f5 = (v: number) => v.toFixed(5);

export function overpassQuery(tiles: TileKey[]): string {
  const boxes = tiles.map(fetchBox);
  const hb = `${f5(Math.min(...boxes.map((b) => b.south)))},${f5(Math.min(...boxes.map((b) => b.west)))},${f5(Math.max(...boxes.map((b) => b.north)))},${f5(Math.max(...boxes.map((b) => b.east)))}`;
  const tb = `${f5(Math.min(...tiles.map((t) => t.south)))},${f5(Math.min(...tiles.map((t) => t.west)))},${f5(Math.max(...tiles.map((t) => t.north)))},${f5(Math.max(...tiles.map((t) => t.east)))}`;
  const poi = [
    'nwr["leisure"="park"]["name"]', 'nwr["railway"="station"]["name"]', 'nwr["amenity"="place_of_worship"]["name"]',
    'nwr["amenity"="library"]["name"]', 'nwr["leisure"="playground"]["name"]', 'nwr["leisure"="common"]["name"]',
    'nwr["historic"]["name"]', 'nwr["amenity"="community_centre"]["name"]', 'nwr["leisure"="nature_reserve"]["name"]',
  ].map((q) => `${q}(${tb});`).join("");
  return `[out:json][timeout:90];(way["highway"](${hb}););out body;>;out skel qt;(${poi});out center tags;`;
}

/** What Overpass returns for one tile's query, cut from a batched response. */
export function subset(osm: OverpassResponse, tile: TileKey): OverpassResponse {
  const b = fetchBox(tile);
  const at = new Map<number, [number, number]>();
  for (const e of osm.elements) if (e.type === "node" && e.lat !== undefined && e.lon !== undefined) at.set(e.id, [e.lat, e.lon]);
  const elements = osm.elements.filter((e) => {
    if (e.type !== "way" || !e.nodes) return true;
    return e.nodes.some((n) => { const p = at.get(n); return !!p && p[0] >= b.south && p[0] <= b.north && p[1] >= b.west && p[1] <= b.east; });
  });
  return { osm3s: osm.osm3s, elements };
}

const kindOf = (hw: string) => (ROAD.has(hw) ? "road" : "path");

function isRunnable(t: Record<string, string>): boolean {
  const hw = t.highway;
  if (!hw || !(ROAD.has(hw) || PATH.has(hw))) return false;
  if (t.area === "yes") return false;
  const foot = t.foot;
  if (foot === "no" || foot === "private") return false;
  if ((t.access === "private" || t.access === "no") && !(foot !== undefined && FOOT_OK.has(foot))) return false;
  if (hw === "service" && t.service !== undefined && EXCLUDED_SERVICE.has(t.service)) return false;
  if (t.indoor === "yes") return false;
  if (hw === "footway" && t.footway !== undefined && ["sidewalk", "crossing", "traffic_island"].includes(t.footway)) return false;
  if ((hw === "path" || hw === "cycleway") && t.footway === "sidewalk") return false;
  return true;
}

function dist(a: Vec2, b: Vec2) { const dx = a.x - b.x, dy = a.y - b.y; return Math.sqrt(dx * dx + dy * dy); }
function polylineLength(p: Vec2[]) { let s = 0; for (let i = 0; i < p.length - 1; i++) s += dist(p[i], p[i + 1]); return s; }
function pointSegmentDistance(p: Vec2, a: Vec2, b: Vec2) {
  const dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy;
  if (l2 === 0) return dist(p, a);
  const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2));
  return dist(p, { x: a.x + t * dx, y: a.y + t * dy });
}
function bearing(a: Vec2, b: Vec2) { const m = (Math.atan2(b.x - a.x, b.y - a.y) * 180 / Math.PI) % 360; return m < 0 ? m + 360 : m; }
function bearingDiff(a: number, b: number) { const d = Math.abs(a - b) % 180; return Math.min(d, 180 - d); }
function sampleAlong(pts: Vec2[], step: number): [Vec2, number][] {
  const out: [Vec2, number][] = [];
  let carry = 0;
  for (let i = 0; i < pts.length - 1; i++) {
    const a = pts[i], b = pts[i + 1], seg = dist(a, b);
    if (seg === 0) continue;
    const brg = bearing(a, b);
    let t = carry;
    while (t <= seg) { const f = t / seg; out.push([{ x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f }, brg]); t += step; }
    carry = t - seg;
  }
  if (pts.length >= 2) out.push([pts[pts.length - 1], bearing(pts[pts.length - 2], pts[pts.length - 1])]);
  return out;
}
function ringArea(r: Vec2[]) { let a = 0; for (let i = 0; i < r.length - 1; i++) a += r[i].x * r[i + 1].y - r[i + 1].x * r[i].y; return a / 2; }
function midpoint(xy: Vec2[]): Vec2 {
  const half = polylineLength(xy) / 2;
  let acc = 0;
  for (let i = 0; i < xy.length - 1; i++) {
    const d = dist(xy[i], xy[i + 1]);
    if (acc + d >= half && d > 0) { const f = (half - acc) / d; return { x: xy[i].x + (xy[i + 1].x - xy[i].x) * f, y: xy[i].y + (xy[i + 1].y - xy[i].y) * f }; }
    acc += d;
  }
  return xy[0];
}
/** Swift's .rounded() (half away from zero). */
const roundAway = (v: number) => Math.sign(v) * Math.round(Math.abs(v));
const r6 = (v: number) => roundAway(v * 1e6) / 1e6;
const r1 = (v: number) => roundAway(v * 10) / 10;
const sha11 = (s: string) => createHash("sha1").update(s).digest("hex").slice(0, 11);
const nonEmpty = (s?: string) => (s ? s : undefined);
const cmpNum = (a: number, b: number) => a - b;

class Grid {
  readonly cell: number;
  readonly cells = new Map<string, [Vec2, Vec2][]>();
  constructor(cell: number) { this.cell = cell; }
  insert(pts: Vec2[]) {
    const c = this.cell;
    for (let i = 0; i < pts.length - 1; i++) {
      const a = pts[i], b = pts[i + 1];
      for (let gx = Math.floor(Math.min(a.x, b.x) / c); gx <= Math.floor(Math.max(a.x, b.x) / c); gx++) {
        for (let gy = Math.floor(Math.min(a.y, b.y) / c); gy <= Math.floor(Math.max(a.y, b.y) / c); gy++) {
          const k = `${gx},${gy}`;
          const l = this.cells.get(k);
          if (l) l.push([a, b]); else this.cells.set(k, [[a, b]]);
        }
      }
    }
  }
  near(p: Vec2, r: number): [Vec2, Vec2][] {
    const out: [Vec2, Vec2][] = [], c = this.cell;
    for (let gx = Math.floor((p.x - r) / c); gx <= Math.floor((p.x + r) / c); gx++) {
      for (let gy = Math.floor((p.y - r) / c); gy <= Math.floor((p.y + r) / c); gy++) out.push(...(this.cells.get(`${gx},${gy}`) ?? []));
    }
    return out;
  }
}

interface Built { id: string; nodes: number[]; ll: Coordinate[]; xy: Vec2[]; length: number; name: string; highway: string; kind: string }

export function buildSegments(osm: OverpassResponse, proj: LocalProjection): Built[] {
  const nodes = new Map<number, Coordinate>();
  const ways: OsmElement[] = [];
  const seenWay = new Set<number>();
  for (const el of osm.elements) {
    if (el.type === "node" && el.lat !== undefined && el.lon !== undefined) nodes.set(el.id, { lat: el.lat, lon: el.lon });
    else if (el.type === "way" && el.nodes && el.tags?.highway !== undefined && !seenWay.has(el.id)) { seenWay.add(el.id); ways.push(el); }
  }
  const kept = ways.filter((w) => isRunnable(w.tags ?? {}) && w.nodes!.every((n) => nodes.has(n)));

  const roads = new Grid(40);
  for (const w of kept) if (kindOf(w.tags!.highway) === "road") roads.insert(w.nodes!.map((n) => proj.project(nodes.get(n)!)));
  const finalWays: OsmElement[] = [];
  for (const w of kept) {
    const t = w.tags!;
    if (["footway", "path", "cycleway"].includes(t.highway) && t.name === undefined) {
      const samples = sampleAlong(w.nodes!.map((n) => proj.project(nodes.get(n)!)), 8);
      if (samples.length >= 3) {
        let hugging = 0;
        for (const [p, brg] of samples) {
          for (const [a, b] of roads.near(p, SIDEWALK_NEAR)) {
            if (pointSegmentDistance(p, a, b) <= SIDEWALK_NEAR && bearingDiff(brg, bearing(a, b)) <= SIDEWALK_BEARING) { hugging++; break; }
          }
        }
        if (hugging / samples.length >= SIDEWALK_SHARE) continue;
      }
    }
    finalWays.push(w);
  }

  const adj = new Map<number, Set<number>>();
  const edgeWay = new Map<string, number>();
  const wayByID = new Map<number, OsmElement>();
  const ek = (a: number, b: number) => `${a},${b}`;
  for (const w of finalWays) {
    wayByID.set(w.id, w);
    const ns = w.nodes!;
    for (let i = 0; i < ns.length - 1; i++) {
      const a = ns[i], b = ns[i + 1];
      if (a === b) continue;
      if (!adj.has(a)) adj.set(a, new Set());
      if (!adj.has(b)) adj.set(b, new Set());
      adj.get(a)!.add(b);
      adj.get(b)!.add(a);
      edgeWay.set(ek(a, b), w.id);
      edgeWay.set(ek(b, a), w.id);
    }
  }
  const wkey = (wid: number) => { const t = wayByID.get(wid)!.tags!; return `${t.name ?? ""}\u0001${kindOf(t.highway)}`; };
  const split = new Set<number>();
  for (const [nid, nbrs] of adj) {
    if (nbrs.size !== 2) { split.add(nid); continue; }
    const [p, q] = [...nbrs];
    if (wkey(edgeWay.get(ek(nid, p))!) !== wkey(edgeWay.get(ek(nid, q))!)) split.add(nid);
  }

  const visited = new Set<string>();
  const walk = (start: number, next: number): number[] => {
    const chain = [start, next];
    visited.add(ek(start, next)); visited.add(ek(next, start));
    let prev = start, cur = next;
    while (!split.has(cur)) {
      let nx: number | undefined;
      for (const x of adj.get(cur)!) if (x !== prev) { nx = x; break; }
      if (nx === undefined) break;
      if (visited.has(ek(cur, nx))) break;
      visited.add(ek(cur, nx)); visited.add(ek(nx, cur));
      chain.push(nx);
      prev = cur; cur = nx;
      if (cur === start) break;
    }
    return chain;
  };
  const chains: number[][] = [];
  for (const nid of [...split].sort(cmpNum)) {
    for (const nb of [...adj.get(nid)!].sort(cmpNum)) if (!visited.has(ek(nid, nb))) chains.push(walk(nid, nb));
  }
  const edges = [...edgeWay.keys()].map((k) => k.split(",").map(Number)).sort((x, y) => x[0] - y[0] || x[1] - y[1]);
  for (const [a, b] of edges) if (!visited.has(ek(a, b))) { split.add(a); chains.push(walk(a, b)); }

  const lexLE = (x: number[], y: number[]) => { for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i] < y[i]; return true; };
  const out: Built[] = [];
  const used = new Set<string>();
  for (const raw of chains) {
    const n = raw.length;
    const ch = lexLE([raw[0], raw[1], raw[n - 2], raw[n - 1]], [raw[n - 1], raw[n - 2], raw[1], raw[0]]) ? raw : [...raw].reverse();
    const ll = ch.map((x) => nodes.get(x)!);
    const xy = ll.map((c) => proj.project(c));
    const length = polylineLength(xy);
    if (length < 0.5) continue;
    const tags = wayByID.get(edgeWay.get(ek(ch[0], ch[1]))!)!.tags!;
    const key = `${ch[0]}-${ch[1]}-${ch[n - 2]}-${ch[n - 1]}`;
    let sid = "s" + sha11(key);
    while (used.has(sid)) sid = "s" + sha11(key + sid);
    used.add(sid);
    out.push({ id: sid, nodes: ch, ll, xy, length, name: nonEmpty(tags.name) ?? nonEmpty(tags.ref) ?? "", highway: tags.highway, kind: kindOf(tags.highway) });
  }
  return out.filter((s) => !(s.length < MIN_DEAD_END && (adj.get(s.nodes[0])!.size === 1 || adj.get(s.nodes[s.nodes.length - 1])!.size === 1)));
}

function direction(xy: Vec2[], fromStart: boolean) {
  const pts = fromStart ? xy : [...xy].reverse();
  const origin = pts[0];
  let acc = 0, target = pts[1];
  for (let k = 1; k < pts.length; k++) { acc += dist(pts[k - 1], pts[k]); target = pts[k]; if (acc >= 6) break; }
  return Math.atan2(target.y - origin.y, target.x - origin.x);
}

interface BuiltBlock { id: string; segments: string[]; areaM2: number; ring: Coordinate[] }

export function traceBlocks(segs: Built[]): BuiltBlock[] {
  interface Half { angle: number; seg: number; fwd: boolean }
  const outEdges = new Map<number, Half[]>();
  const add = (n: number, h: Half) => { const l = outEdges.get(n); if (l) l.push(h); else outEdges.set(n, [h]); };
  segs.forEach((s, i) => {
    const a = s.nodes[0], b = s.nodes[s.nodes.length - 1];
    if (a === b) return;
    add(a, { angle: direction(s.xy, true), seg: i, fwd: true });
    add(b, { angle: direction(s.xy, false), seg: i, fwd: false });
  });
  for (const l of outEdges.values()) l.sort((p, q) => (p.angle - q.angle) || (p.seg - q.seg) || (Number(p.fwd) - Number(q.fwd)));
  const head = (i: number, f: boolean) => (f ? segs[i].nodes[segs[i].nodes.length - 1] : segs[i].nodes[0]);
  const hk = (i: number, f: boolean) => `${i}${f ? "+" : "-"}`;

  const visited = new Set<string>();
  const blocks: BuiltBlock[] = [];
  for (const lst0 of outEdges.values()) {
    for (const start of lst0) {
      if (visited.has(hk(start.seg, start.fwd))) continue;
      const face: { seg: number; fwd: boolean }[] = [];
      let cur = { seg: start.seg, fwd: start.fwd };
      let guard = 0;
      while (!visited.has(hk(cur.seg, cur.fwd)) && guard < 5000) {
        visited.add(hk(cur.seg, cur.fwd));
        face.push(cur);
        const lst = outEdges.get(head(cur.seg, cur.fwd))!;
        const idx = lst.findIndex((h) => h.seg === cur.seg && h.fwd === !cur.fwd);
        const nx = lst[(idx - 1 + lst.length) % lst.length];
        cur = { seg: nx.seg, fwd: nx.fwd };
        guard++;
      }
      if (!face.length || cur.seg !== start.seg || cur.fwd !== start.fwd) continue;
      const ring: Vec2[] = [], llRing: Coordinate[] = [];
      for (const h of face) {
        const pts = h.fwd ? segs[h.seg].xy : [...segs[h.seg].xy].reverse();
        const ll = h.fwd ? segs[h.seg].ll : [...segs[h.seg].ll].reverse();
        ring.push(...(ring.length ? pts.slice(1) : pts));
        llRing.push(...(llRing.length ? ll.slice(1) : ll));
      }
      if (ring.length < 4) continue;
      const area = ringArea([...ring, ring[0]]);
      if (area <= 0 || area < BLOCK_MIN || area > BLOCK_MAX) continue;
      const counts = new Map<number, number>();
      for (const h of face) counts.set(h.seg, (counts.get(h.seg) ?? 0) + 1);
      const bounding = [...new Set([...counts].filter(([, c]) => c === 1).map(([s]) => segs[s].id))].sort();
      if (bounding.length < 2) continue;
      llRing.push(llRing[0]);
      blocks.push({ id: "b" + sha11(bounding.join("-")), segments: bounding, areaM2: roundAway(area), ring: llRing });
    }
  }
  const uniq = new Map<string, BuiltBlock>();
  for (const b of blocks) if (!uniq.has(b.id)) uniq.set(b.id, b);
  return [...uniq.values()].sort((a, b) => (a.id < b.id ? -1 : 1));
}

function pois(osm: OverpassResponse, tile: TileKey): POIRecord[] {
  const out: POIRecord[] = [];
  const seen = new Set<string>(), seenID = new Set<string>();
  for (const el of osm.elements) {
    const tags = el.tags;
    if (!tags || tags.name === undefined) continue;
    let lat: number, lon: number;
    if (el.type === "node" && el.lat !== undefined && el.lon !== undefined) { lat = el.lat; lon = el.lon; }
    else if (el.center) { lat = el.center.lat; lon = el.center.lon; }
    else continue;
    let kind: string;
    if (tags.railway === "station") kind = "station";
    else if (tags.amenity === "place_of_worship") kind = "worship";
    else if (["park", "common", "nature_reserve"].includes(tags.leisure ?? "")) kind = "park";
    else if (tags.leisure === "playground") kind = "playground";
    else if (tags.amenity === "library") kind = "library";
    else if (tags.amenity === "community_centre") kind = "community";
    else if (tags.historic !== undefined) kind = "historic";
    else continue;
    if (!tile.contains({ lat, lon })) continue;
    const name = tags.name.trim();
    const id = `${el.type[0]}${el.id}`;
    const dedupe = `${name.toLowerCase()}|${kind}`;
    if (!name || seen.has(dedupe) || seenID.has(id)) continue;
    seen.add(dedupe); seenID.add(id);
    out.push({ id, name, kind, lon: r6(lon), lat: r6(lat) });
  }
  return out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/** Builds a tile from an Overpass response for `overpassQuery([tile])` (or `subset` of a batch). */
export function buildTile(tile: TileKey, osm: OverpassResponse, generatedAt = new Date()): TileFile {
  const proj = new LocalProjection(tile.center);
  const segments = buildSegments(osm, proj);
  const box = fetchBox(tile);
  const inTile = segments.filter((s) => tile.contains(proj.unproject(midpoint(s.xy))));
  const blocks = traceBlocks(segments).filter((b) => {
    const pts = b.ring.slice(0, -1);
    const centroid = { lat: pts.reduce((s, p) => s + p.lat, 0) / pts.length, lon: pts.reduce((s, p) => s + p.lon, 0) / pts.length };
    return b.ring.every((p) => p.lat > box.south && p.lat < box.north && p.lon > box.west && p.lon < box.east) && tile.contains(centroid);
  });
  return {
    formatVersion: TILE_FORMAT, key: tile.toString(), generatedAt: generatedAt.toISOString().replace(/\.\d{3}Z$/, "Z"),
    osmTimestamp: osm.osm3s?.timestamp_osm_base ?? "",
    segments: inTile.map((s) => ({ id: s.id, name: s.name, kind: s.kind, highway: s.highway, length: r1(s.length),
      a: s.nodes[0], b: s.nodes[s.nodes.length - 1], coords: s.ll.map((c) => [r6(c.lon), r6(c.lat)]) })),
    blocks: blocks.map((b) => ({ id: b.id, segments: b.segments, areaM2: b.areaM2, ring: b.ring.map((c) => [r6(c.lon), r6(c.lat)]) })),
    pois: pois(osm, tile),
  };
}
