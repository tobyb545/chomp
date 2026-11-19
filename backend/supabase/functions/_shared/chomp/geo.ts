// Port of ChompKit/Geo/Geo.swift. Times everywhere are epoch seconds.

export interface Coordinate { lat: number; lon: number }
export interface Vec2 { x: number; y: number }

export function distance(a: Coordinate, b: Coordinate): number {
  const r = 6_371_008.8;
  const p1 = a.lat * Math.PI / 180, p2 = b.lat * Math.PI / 180;
  const dp = p2 - p1, dl = (b.lon - a.lon) * Math.PI / 180;
  const h = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

export function offset(c: Coordinate, metres: number, bearingDegrees: number): Coordinate {
  const b = bearingDegrees * Math.PI / 180;
  return {
    lat: c.lat + metres * Math.cos(b) / 110_540,
    lon: c.lon + metres * Math.sin(b) / (111_320 * Math.cos(c.lat * Math.PI / 180)),
  };
}

export const sub = (a: Vec2, b: Vec2): Vec2 => ({ x: a.x - b.x, y: a.y - b.y });
export const add = (a: Vec2, b: Vec2): Vec2 => ({ x: a.x + b.x, y: a.y + b.y });
export const mul = (a: Vec2, k: number): Vec2 => ({ x: a.x * k, y: a.y * k });
export const dot = (a: Vec2, b: Vec2): number => a.x * b.x + a.y * b.y;
export const vdist = (a: Vec2, b: Vec2): number => Math.hypot(a.x - b.x, a.y - b.y);

export class LocalProjection {
  readonly origin: Coordinate;
  readonly kx: number;
  readonly ky = 110_540;
  constructor(origin: Coordinate) {
    this.origin = origin;
    this.kx = 111_320 * Math.cos(origin.lat * Math.PI / 180);
  }
  project(c: Coordinate): Vec2 {
    return { x: (c.lon - this.origin.lon) * this.kx, y: (c.lat - this.origin.lat) * this.ky };
  }
  unproject(v: Vec2): Coordinate {
    return { lat: this.origin.lat + v.y / this.ky, lon: this.origin.lon + v.x / this.kx };
  }
}

export interface LineProjection { distance: number; offset: number; point: Vec2 }

export class Polyline {
  readonly points: Vec2[];
  readonly cumulative: number[];
  constructor(points: Vec2[]) {
    this.points = points;
    const c = [0];
    for (let i = 1; i < points.length; i++) c.push(c[i - 1] + vdist(points[i], points[i - 1]));
    this.cumulative = c;
  }
  get length(): number { return this.cumulative[this.cumulative.length - 1] ?? 0; }

  project(p: Vec2): LineProjection {
    const pts = this.points;
    if (pts.length < 2) {
      const f = pts[0] ?? p;
      return { distance: vdist(f, p), offset: 0, point: f };
    }
    let best: LineProjection = { distance: Infinity, offset: 0, point: pts[0] };
    for (let i = 0; i < pts.length - 1; i++) {
      const a = pts[i], ab = sub(pts[i + 1], a);
      const l2 = dot(ab, ab);
      const t = l2 === 0 ? 0 : Math.max(0, Math.min(1, dot(sub(p, a), ab) / l2));
      const q = add(a, mul(ab, t));
      const d = vdist(q, p);
      if (d < best.distance) {
        best = { distance: d, offset: this.cumulative[i] + t * (this.cumulative[i + 1] - this.cumulative[i]), point: q };
      }
    }
    return best;
  }

  pointAt(off: number): Vec2 {
    const pts = this.points, cum = this.cumulative;
    if (pts.length < 2) return pts[0] ?? { x: 0, y: 0 };
    const o = Math.max(0, Math.min(this.length, off));
    let lo = 0, hi = cum.length - 1;
    while (lo + 1 < hi) {
      const mid = (lo + hi) >> 1;
      if (cum[mid] <= o) lo = mid; else hi = mid;
    }
    const seg = cum[hi] - cum[lo];
    const t = seg === 0 ? 0 : (o - cum[lo]) / seg;
    return add(pts[lo], mul(sub(pts[hi], pts[lo]), t));
  }
}

/** Union of closed intervals, for "how much of this street did I run". */
export class IntervalSet {
  intervals: [number, number][] = [];
  insert(a: number, b: number): void {
    let lo = Math.min(a, b), hi = Math.max(a, b);
    const kept: [number, number][] = [];
    for (const iv of this.intervals) {
      if (iv[1] < lo || iv[0] > hi) kept.push(iv);
      else { lo = Math.min(lo, iv[0]); hi = Math.max(hi, iv[1]); }
    }
    kept.push([lo, hi]);
    kept.sort((x, y) => x[0] - y[0]);
    this.intervals = kept;
  }
  get covered(): number { return this.intervals.reduce((s, iv) => s + iv[1] - iv[0], 0); }
}

export function pointInRing(p: Vec2, ring: Vec2[]): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const a = ring[i], b = ring[j];
    if ((a.y > p.y) !== (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}

/** Google encoded polyline, precision 5 (matches PolylineCodec.swift). */
export function decodePolyline(s: string): Coordinate[] {
  const out: Coordinate[] = [];
  let i = 0, lat = 0, lon = 0;
  const next = (): number => {
    let result = 0, shift = 0, b = 0;
    do {
      b = s.charCodeAt(i++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20 && i < s.length);
    return (result & 1) !== 0 ? ~(result >> 1) : result >> 1;
  };
  while (i < s.length) {
    lat += next();
    if (i >= s.length) break;
    lon += next();
    out.push({ lat: lat / 1e5, lon: lon / 1e5 });
  }
  return out;
}

export function encodePolyline(coords: Coordinate[]): string {
  let out = "", pLat = 0, pLon = 0;
  const enc = (v: number) => {
    let x = v < 0 ? ~(v << 1) : v << 1;
    while (x >= 0x20) { out += String.fromCharCode((0x20 | (x & 0x1f)) + 63); x >>= 5; }
    out += String.fromCharCode(x + 63);
  };
  for (const c of coords) {
    const la = Math.round(c.lat * 1e5), lo = Math.round(c.lon * 1e5);
    enc(la - pLat); enc(lo - pLon);
    pLat = la; pLon = lo;
  }
  return out;
}

/** Binary min-heap keyed by number. */
export class MinHeap<T> {
  private items: [number, T][] = [];
  get size(): number { return this.items.length; }
  push(k: number, v: T): void {
    const it = this.items;
    it.push([k, v]);
    let i = it.length - 1;
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (it[i][0] < it[p][0]) { [it[i], it[p]] = [it[p], it[i]]; i = p; } else break;
    }
  }
  pop(): [number, T] | undefined {
    const it = this.items;
    if (!it.length) return undefined;
    const top = it[0], last = it.pop()!;
    if (it.length) {
      it[0] = last;
      let i = 0;
      for (;;) {
        const l = 2 * i + 1, r = l + 1;
        let m = i;
        if (l < it.length && it[l][0] < it[m][0]) m = l;
        if (r < it.length && it[r][0] < it[m][0]) m = r;
        if (m === i) break;
        [it[i], it[m]] = [it[m], it[i]];
        i = m;
      }
    }
    return top;
  }
}
