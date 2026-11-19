// Port of ChompKit/Map/Area.swift.
import { type Coordinate, LocalProjection, MinHeap, Polyline, type Vec2, pointInRing } from "./geo.ts";

/** JSON written by tools/ingest/ingest.py (and by the area_bundle() SQL function). */
export interface AreaFile {
  slug: string;
  name: string;
  longName: string;
  county: string;
  country: string;
  center: number[];
  boundary: number[][][][];
  segments: { id: string; name: string; kind: string; highway: string; length: number; a: number; b: number; coords: number[][] }[];
  blocks: { id: string; segments: string[]; areaM2: number; ring?: number[][] }[];
  pois: { id: string; name: string; kind: string; lon: number; lat: number }[];
  lineage?: Record<string, string>;
}

export interface Segment {
  id: string;
  index: number;
  name: string;
  isPath: boolean;
  highway: string;
  length: number;
  startNode: number;
  endNode: number;
  coordinates: Coordinate[];
  polyline: Polyline;
}

export interface Block { id: string; segmentIDs: string[]; areaM2: number }
export interface Landmark { id: string; name: string; kind: string; coordinate: Coordinate }

export function displayName(s: Segment): string {
  if (s.name) return s.name;
  switch (s.highway) {
    case "footway": case "path": case "pedestrian": case "steps": return "Footpath";
    case "cycleway": return "Cycle path";
    case "track": case "bridleway": return "Track";
    case "service": return "Service road";
    default: return "Unnamed street";
  }
}

export interface Edge { segment: number; other: number }
export interface PathTree { dist: Map<number, number>; prev: Map<number, [number, number]> }

export class SegmentGraph {
  readonly adjacency = new Map<number, Edge[]>();
  constructor(segments: Segment[]) {
    const add = (n: number, e: Edge) => {
      const l = this.adjacency.get(n);
      if (l) l.push(e); else this.adjacency.set(n, [e]);
    };
    for (const s of segments) {
      add(s.startNode, { segment: s.index, other: s.endNode });
      add(s.endNode, { segment: s.index, other: s.startNode });
    }
  }
  neighbours(n: number): Edge[] { return this.adjacency.get(n) ?? []; }

  shortestPaths(sources: [number, number][], segments: Segment[], limit: number): PathTree {
    const dist = new Map<number, number>();
    const prev = new Map<number, [number, number]>();
    const heap = new MinHeap<number>();
    for (const [node, cost] of sources) {
      if (cost <= limit && cost < (dist.get(node) ?? Infinity)) { dist.set(node, cost); heap.push(cost, node); }
    }
    for (let top = heap.pop(); top; top = heap.pop()) {
      const [d, n] = top;
      if (d > (dist.get(n) ?? Infinity)) continue;
      for (const e of this.neighbours(n)) {
        const nd = d + segments[e.segment].length;
        if (nd <= limit && nd < (dist.get(e.other) ?? Infinity)) {
          dist.set(e.other, nd);
          prev.set(e.other, [n, e.segment]);
          heap.push(nd, e.other);
        }
      }
    }
    return { dist, prev };
  }
}

export class SpatialIndex {
  private readonly cells = new Map<string, number[]>();
  private readonly cell: number;
  constructor(segments: Segment[], cell: number) {
    this.cell = cell;
    const sets = new Map<string, Set<number>>();
    for (const s of segments) {
      const pts = s.polyline.points;
      for (let i = 0; i + 1 < pts.length; i++) {
        const a = pts[i], b = pts[i + 1];
        for (let gx = Math.floor(Math.min(a.x, b.x) / cell); gx <= Math.floor(Math.max(a.x, b.x) / cell); gx++) {
          for (let gy = Math.floor(Math.min(a.y, b.y) / cell); gy <= Math.floor(Math.max(a.y, b.y) / cell); gy++) {
            const k = `${gx},${gy}`;
            let set = sets.get(k);
            if (!set) sets.set(k, set = new Set());
            set.add(s.index);
          }
        }
      }
    }
    for (const [k, v] of sets) this.cells.set(k, [...v]);
  }
  near(p: Vec2, radius: number): Set<number> {
    const out = new Set<number>(), c = this.cell;
    for (let gx = Math.floor((p.x - radius) / c); gx <= Math.floor((p.x + radius) / c); gx++) {
      for (let gy = Math.floor((p.y - radius) / c); gy <= Math.floor((p.y + radius) / c); gy++) {
        for (const s of this.cells.get(`${gx},${gy}`) ?? []) out.add(s);
      }
    }
    return out;
  }
}

export class Area {
  readonly slug: string;
  readonly name: string;
  readonly projection: LocalProjection;
  readonly segments: Segment[];
  readonly blocks: Block[];
  readonly landmarks: Landmark[];
  readonly totalLength: number;
  readonly graph: SegmentGraph;
  readonly index: SpatialIndex;
  readonly blockByID: Map<string, Block>;
  private readonly indexByID: Map<string, number>;
  private readonly boundary: Vec2[][][];

  constructor(file: AreaFile) {
    this.slug = file.slug;
    this.name = file.name;
    const proj = new LocalProjection({ lat: file.center[1], lon: file.center[0] });
    this.projection = proj;
    this.segments = file.segments.map((s, i) => {
      const coords = s.coords.map((c) => ({ lat: c[1], lon: c[0] }));
      return {
        id: s.id, index: i, name: s.name, isPath: s.kind === "path", highway: s.highway, length: s.length,
        startNode: s.a, endNode: s.b, coordinates: coords, polyline: new Polyline(coords.map((c) => proj.project(c))),
      };
    });
    this.indexByID = new Map(this.segments.map((s) => [s.id, s.index]));
    this.blocks = file.blocks.map((b) => ({ id: b.id, segmentIDs: b.segments, areaM2: b.areaM2 }));
    this.blockByID = new Map(this.blocks.map((b) => [b.id, b]));
    this.landmarks = file.pois.map((p) => ({ id: p.id, name: p.name, kind: p.kind, coordinate: { lat: p.lat, lon: p.lon } }));
    this.totalLength = this.segments.reduce((s, x) => s + x.length, 0);
    this.graph = new SegmentGraph(this.segments);
    this.index = new SpatialIndex(this.segments, 60);
    this.boundary = file.boundary.map((poly) => poly.map((ring) => ring.map((c) => proj.project({ lat: c[1], lon: c[0] }))));
  }

  segment(id: string): Segment | undefined {
    const i = this.indexByID.get(id);
    return i === undefined ? undefined : this.segments[i];
  }

  contains(c: Coordinate): boolean {
    const p = this.projection.project(c);
    return this.boundary.some((poly) => poly.length > 0 && pointInRing(p, poly[0]) && !poly.slice(1).some((h) => pointInRing(p, h)));
  }
}
