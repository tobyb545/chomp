#!/usr/bin/env python3
"""
Chomp OSM ingestion.

Turns OpenStreetMap highways for one area into game "segments": stretches of
runnable street between two junctions, each with a stable ID. Also derives city
blocks (faces of the street graph) and landmark POIs for power pellets.

Pure standard library (Python 3.9+), so it runs anywhere:

    python3 tools/ingest/ingest.py west-byfleet            # uses cache if present
    python3 tools/ingest/ingest.py west-byfleet --refresh  # re-download OSM + boundary

Inputs:  tools/ingest/areas/<slug>.json  (area definition)
Outputs: data/areas/<slug>.json          (bundled into the iOS app)
         backend/supabase/seed/<slug>.sql (loads the same data into PostGIS)

Re-running after OSM edits keeps segment IDs stable where geometry is unchanged
and writes a lineage map (old ID -> new ID) for segments that were re-split, so
ownership can be carried over instead of silently wiped.
"""
import argparse
import hashlib
import json
import math
import os
import sys
import time
import urllib.parse
import urllib.error
import urllib.request
from collections import defaultdict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HERE = os.path.dirname(os.path.abspath(__file__))
USER_AGENT = "chomp-ingest/1.0 (OSM street segment builder)"
OVERPASS = "https://overpass-api.de/api/interpreter"
ONS_BUA_2022 = ("https://services1.arcgis.com/ESMARspQHYMw9BZ9/arcgis/rest/services/"
                "BUA_2022_GB/FeatureServer/0/query")

# ----------------------------------------------------------------------------
# Which OSM ways are runnable
# ----------------------------------------------------------------------------
ROAD_CLASSES = {
    "trunk", "trunk_link", "primary", "primary_link", "secondary", "secondary_link",
    "tertiary", "tertiary_link", "unclassified", "residential", "living_street", "service",
}
PATH_CLASSES = {"pedestrian", "footway", "path", "track", "cycleway", "steps", "bridleway"}
RUNNABLE = ROAD_CLASSES | PATH_CLASSES
EXCLUDED_SERVICE = {"driveway", "parking_aisle", "drive-through", "emergency_access"}
NO_ACCESS = {"private", "no"}
FOOT_OK = {"yes", "designated", "permissive"}

SIDEWALK_NEAR_ROAD_METRES = 14.0
SIDEWALK_BEARING_TOLERANCE = 25.0
SIDEWALK_SHARE = 0.75
MIN_DEAD_END_METRES = 10.0
BLOCK_MIN_M2 = 1000.0
BLOCK_MAX_M2 = 250_000.0
LINEAGE_OVERLAP = 0.7
LINEAGE_BUFFER_METRES = 6.0


def kind_for(highway):
    return "road" if highway in ROAD_CLASSES else "path"


def is_runnable(tags):
    hw = tags.get("highway")
    if hw not in RUNNABLE:
        return False
    if tags.get("area") == "yes":
        return False
    foot = tags.get("foot")
    if foot in {"no", "private"}:
        return False
    if tags.get("access") in NO_ACCESS and foot not in FOOT_OK:
        return False
    if hw == "service" and tags.get("service") in EXCLUDED_SERVICE:
        return False
    if hw == "cycleway" and foot not in FOOT_OK and tags.get("segregated") is None and foot == "no":
        return False
    if tags.get("indoor") == "yes":
        return False
    # Pavements mapped as separate ways credit the road they run beside.
    if hw == "footway" and tags.get("footway") in {"sidewalk", "crossing", "traffic_island"}:
        return False
    if hw in {"path", "cycleway"} and tags.get("footway") == "sidewalk":
        return False
    return True


# ----------------------------------------------------------------------------
# Geometry helpers (local equirectangular projection; accurate to <0.5% at town scale)
# ----------------------------------------------------------------------------
class Projector:
    def __init__(self, lat0, lon0):
        self.lat0 = lat0
        self.lon0 = lon0
        self.kx = 111_320.0 * math.cos(math.radians(lat0))
        self.ky = 110_540.0

    def xy(self, lon, lat):
        return ((lon - self.lon0) * self.kx, (lat - self.lat0) * self.ky)


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def polyline_length(pts):
    return sum(dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def point_segment_distance(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    l2 = dx * dx + dy * dy
    if l2 == 0:
        return dist(p, a), 0.0
    t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2))
    q = (a[0] + t * dx, a[1] + t * dy)
    return dist(p, q), t


def bearing(a, b):
    return math.degrees(math.atan2(b[0] - a[0], b[1] - a[1])) % 360.0


def bearing_diff_undirected(a, b):
    d = abs(a - b) % 180.0
    return min(d, 180.0 - d)


def sample_along(pts, step):
    """Points every `step` metres along the polyline (plus its end), with local bearing."""
    out = []
    carry = 0.0
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        seg = dist(a, b)
        if seg == 0:
            continue
        brg = bearing(a, b)
        t = carry
        while t <= seg:
            f = t / seg
            out.append(((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f), brg))
            t += step
        carry = t - seg
    if len(pts) >= 2:
        out.append((pts[-1], bearing(pts[-2], pts[-1])))
    return out


def point_in_ring(pt, ring):
    x, y = pt
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi + 1e-300) + xi:
            inside = not inside
        j = i
    return inside


def point_in_multipolygon(pt, polygons):
    for poly in polygons:
        if point_in_ring(pt, poly[0]) and not any(point_in_ring(pt, h) for h in poly[1:]):
            return True
    return False


def signed_area(ring):
    a = 0.0
    for i in range(len(ring) - 1):
        a += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1]
    return a / 2.0


class GridIndex:
    """Uniform grid over projected line pieces for fast proximity queries."""

    def __init__(self, cell=50.0):
        self.cell = cell
        self.cells = defaultdict(list)

    def _keys(self, a, b, pad):
        x0, x1 = sorted((a[0], b[0]))
        y0, y1 = sorted((a[1], b[1]))
        c = self.cell
        for gx in range(int(math.floor((x0 - pad) / c)), int(math.floor((x1 + pad) / c)) + 1):
            for gy in range(int(math.floor((y0 - pad) / c)), int(math.floor((y1 + pad) / c)) + 1):
                yield (gx, gy)

    def insert_polyline(self, key, pts):
        for i in range(len(pts) - 1):
            for k in self._keys(pts[i], pts[i + 1], 0):
                self.cells[k].append((key, pts[i], pts[i + 1]))

    def near(self, p, radius):
        c = self.cell
        seen = []
        for gx in range(int(math.floor((p[0] - radius) / c)), int(math.floor((p[0] + radius) / c)) + 1):
            for gy in range(int(math.floor((p[1] - radius) / c)), int(math.floor((p[1] + radius) / c)) + 1):
                seen.extend(self.cells.get((gx, gy), ()))
        return seen


# ----------------------------------------------------------------------------
# Fetching (cached)
# ----------------------------------------------------------------------------
def _curl(url, data):
    """Fallback for Python installs without a CA bundle (e.g. python.org builds on macOS)."""
    import subprocess
    cmd = ["curl", "-sSf", "--max-time", "180", "-A", USER_AGENT, url]
    if data is not None:
        cmd += ["--data-binary", "@-"]
    return subprocess.run(cmd, input=data, capture_output=True, check=True).stdout


def http_get(url, data=None):
    import ssl
    req = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            try:
                with urllib.request.urlopen(req, timeout=180) as r:
                    return r.read()
            except urllib.error.URLError as e:
                if isinstance(e.reason, ssl.SSLError):
                    return _curl(url, data)
                raise
        except Exception as e:  # noqa: BLE001 - retry any transient failure
            if attempt == 3:
                raise
            wait = 5 * (attempt + 1)
            print(f"  fetch failed ({e}); retrying in {wait}s", file=sys.stderr)
            time.sleep(wait)


def cached(path, refresh, fetch):
    if os.path.exists(path) and not refresh:
        with open(path) as f:
            return json.load(f)
    data = fetch()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f)
    return data


def fetch_boundary(cfg):
    b = cfg["boundary"]
    if b["source"] == "ons_bua_2022":
        q = urllib.parse.urlencode({
            "where": f"BUA22CD='{b['code']}'", "outFields": "BUA22CD,BUA22NM",
            "outSR": "4326", "f": "geojson",
        })
        return json.loads(http_get(f"{ONS_BUA_2022}?{q}"))
    if b["source"] == "geojson":
        with open(os.path.join(HERE, b["path"])) as f:
            return json.load(f)
    raise SystemExit(f"Unknown boundary source {b['source']}")


def overpass(query):
    return json.loads(http_get(OVERPASS, urllib.parse.urlencode({"data": query}).encode()))


def boundary_polygons(gj):
    feats = gj["features"] if gj.get("type") == "FeatureCollection" else [gj]
    polys = []
    for f in feats:
        g = f["geometry"] if "geometry" in f else f
        if g["type"] == "Polygon":
            polys.append(g["coordinates"])
        elif g["type"] == "MultiPolygon":
            polys.extend(g["coordinates"])
    if not polys:
        raise SystemExit("Boundary has no polygon geometry")
    return polys


# ----------------------------------------------------------------------------
# Main pipeline
# ----------------------------------------------------------------------------
def build(slug, refresh):
    cfg_path = os.path.join(HERE, "areas", f"{slug}.json")
    with open(cfg_path) as f:
        cfg = json.load(f)
    cache = os.path.join(HERE, "cache")

    print(f"[1/7] Boundary ({cfg['boundary']['source']})")
    bgj = cached(os.path.join(cache, f"{slug}.boundary.json"), refresh, lambda: fetch_boundary(cfg))
    polys_ll = boundary_polygons(bgj)
    all_pts = [p for poly in polys_ll for ring in poly for p in ring]
    lon0 = sum(p[0] for p in all_pts) / len(all_pts)
    lat0 = sum(p[1] for p in all_pts) / len(all_pts)
    proj = Projector(lat0, lon0)
    polys = [[[proj.xy(*p) for p in ring] for ring in poly] for poly in polys_ll]

    buf = cfg.get("bboxBufferMetres", 300)
    dlat = buf / 110_540.0
    dlon = buf / proj.kx
    s = min(p[1] for p in all_pts) - dlat
    w = min(p[0] for p in all_pts) - dlon
    n = max(p[1] for p in all_pts) + dlat
    e = max(p[0] for p in all_pts) + dlon
    bbox = f"{s:.5f},{w:.5f},{n:.5f},{e:.5f}"
    bbox_wsen = [round(w, 6), round(s, 6), round(e, 6), round(n, 6)]

    print(f"[2/7] OSM highways in {bbox}")
    osm = cached(os.path.join(cache, f"{slug}.highways.json"), refresh, lambda: overpass(
        f'[out:json][timeout:180];(way["highway"]({bbox}););out body;>;out skel qt;'))
    print("[3/7] OSM landmarks")
    poi_osm = cached(os.path.join(cache, f"{slug}.pois.json"), refresh, lambda: overpass(
        f'[out:json][timeout:180];('
        f'nwr["leisure"="park"]["name"]({bbox});'
        f'nwr["railway"="station"]["name"]({bbox});'
        f'nwr["amenity"="place_of_worship"]["name"]({bbox});'
        f'nwr["amenity"="library"]["name"]({bbox});'
        f'nwr["leisure"="playground"]["name"]({bbox});'
        f'nwr["leisure"="common"]["name"]({bbox});'
        f'nwr["historic"]["name"]({bbox});'
        f'nwr["amenity"="community_centre"]["name"]({bbox});'
        f'nwr["leisure"="nature_reserve"]["name"]({bbox});'
        f');out center tags;'))

    nodes = {}
    ways = []
    for el in osm["elements"]:
        if el["type"] == "node":
            nodes[el["id"]] = (el["lon"], el["lat"])
        elif el["type"] == "way":
            ways.append(el)

    print("[4/7] Filtering runnable ways and folding pavements into roads")
    kept = [w for w in ways if is_runnable(w.get("tags", {})) and all(n in nodes for n in w["nodes"])]
    # Untagged parallel pavements: a footway/path that hugs a road along most of its length.
    road_index = GridIndex(40.0)
    for w in kept:
        if kind_for(w["tags"]["highway"]) == "road":
            road_index.insert_polyline(w["id"], [proj.xy(*nodes[n]) for n in w["nodes"]])
    folded = 0
    final_ways = []
    for w in kept:
        tags = w["tags"]
        if tags["highway"] in {"footway", "path", "cycleway"} and "name" not in tags:
            pts = [proj.xy(*nodes[n]) for n in w["nodes"]]
            samples = sample_along(pts, 8.0)
            if len(samples) >= 3:
                hugging = 0
                for p, brg in samples:
                    for _, a, b in road_index.near(p, SIDEWALK_NEAR_ROAD_METRES):
                        d, _ = point_segment_distance(p, a, b)
                        if d <= SIDEWALK_NEAR_ROAD_METRES and \
                                bearing_diff_undirected(brg, bearing(a, b)) <= SIDEWALK_BEARING_TOLERANCE:
                            hugging += 1
                            break
                if hugging / len(samples) >= SIDEWALK_SHARE:
                    folded += 1
                    continue
        final_ways.append(w)
    print(f"      {len(ways)} highway ways -> {len(final_ways)} runnable ({folded} pavements folded into roads)")

    # Graph
    adj = defaultdict(set)
    edge_way = {}
    way_by_id = {w["id"]: w for w in final_ways}
    for w in final_ways:
        ns = w["nodes"]
        for i in range(len(ns) - 1):
            a, b = ns[i], ns[i + 1]
            if a == b:
                continue
            adj[a].add(b)
            adj[b].add(a)
            edge_way[(a, b)] = w["id"]
            edge_way[(b, a)] = w["id"]

    def wkey(wid):
        t = way_by_id[wid]["tags"]
        return (t.get("name", ""), kind_for(t["highway"]))

    split = set()
    for nid, nbrs in adj.items():
        if len(nbrs) != 2:
            split.add(nid)
        else:
            a, b = tuple(nbrs)
            if wkey(edge_way[(nid, a)]) != wkey(edge_way[(nid, b)]):
                split.add(nid)

    print("[5/7] Splitting into junction-to-junction segments")
    visited = set()
    chains = []

    def walk(start, nxt):
        chain = [start, nxt]
        visited.add((start, nxt))
        visited.add((nxt, start))
        prev, cur = start, nxt
        while cur not in split:
            options = [x for x in adj[cur] if x != prev]
            if not options:
                break
            nx = options[0]
            if (cur, nx) in visited:
                break
            visited.add((cur, nx))
            visited.add((nx, cur))
            chain.append(nx)
            prev, cur = cur, nx
            if cur == start:
                break
        return chain

    for nid in sorted(split):
        for nb in sorted(adj[nid]):
            if (nid, nb) not in visited:
                chains.append(walk(nid, nb))
    for (a, b) in sorted(edge_way):  # isolated loops with no junction at all
        if (a, b) not in visited:
            split.add(a)
            chains.append(walk(a, b))

    def canonical(chain):
        fwd = (chain[0], chain[1], chain[-2], chain[-1])
        rev = (chain[-1], chain[-2], chain[1], chain[0])
        return chain if fwd <= rev else list(reversed(chain))

    segments = []
    used_ids = set()
    for ch in chains:
        ch = canonical(ch)
        ll = [nodes[n] for n in ch]
        xy = [proj.xy(*p) for p in ll]
        length = polyline_length(xy)
        if length < 0.5:
            continue
        wids = []
        for i in range(len(ch) - 1):
            wid = edge_way[(ch[i], ch[i + 1])]
            if not wids or wids[-1] != wid:
                wids.append(wid)
        tags = way_by_id[wids[0]]["tags"]
        key = f"{ch[0]}-{ch[1]}-{ch[-2]}-{ch[-1]}"
        sid = "s" + hashlib.sha1(key.encode()).hexdigest()[:11]
        while sid in used_ids:  # vanishingly rare; deterministic tiebreak
            sid = "s" + hashlib.sha1((key + sid).encode()).hexdigest()[:11]
        used_ids.add(sid)
        segments.append({
            "id": sid, "nodes": ch, "ll": ll, "xy": xy, "length": length,
            "name": tags.get("name") or tags.get("ref") or "",
            "highway": tags["highway"], "kind": kind_for(tags["highway"]), "ways": wids,
        })

    # Drop tiny dead-end stubs (e.g. the last few metres of a footway into a hedge).
    node_deg = {k: len(v) for k, v in adj.items()}
    segments = [sg for sg in segments if not (
        sg["length"] < MIN_DEAD_END_METRES and (node_deg[sg["nodes"][0]] == 1 or node_deg[sg["nodes"][-1]] == 1))]

    # Clip to boundary by length-midpoint.
    def midpoint(xy):
        half = polyline_length(xy) / 2
        acc = 0.0
        for i in range(len(xy) - 1):
            d = dist(xy[i], xy[i + 1])
            if acc + d >= half and d > 0:
                f = (half - acc) / d
                return (xy[i][0] + (xy[i + 1][0] - xy[i][0]) * f, xy[i][1] + (xy[i + 1][1] - xy[i][1]) * f)
            acc += d
        return xy[0]

    segments = [sg for sg in segments if point_in_multipolygon(midpoint(sg["xy"]), polys)]
    seg_by_id = {sg["id"]: sg for sg in segments}
    total_len = sum(sg["length"] for sg in segments)
    named = sum(1 for sg in segments if sg["name"])
    print(f"      {len(segments)} segments, {total_len / 1000:.1f} km ({named} named)")

    print("[6/7] Tracing city blocks")
    blocks = trace_blocks(segments)
    print(f"      {len(blocks)} blocks")

    print("[7/7] Landmarks, lineage and output")
    pois = []
    seen_poi = set()
    for el in poi_osm["elements"]:
        tags = el.get("tags", {})
        if el["type"] == "node":
            lon, lat = el["lon"], el["lat"]
        elif "center" in el:
            lon, lat = el["center"]["lon"], el["center"]["lat"]
        else:
            continue
        if not point_in_multipolygon(proj.xy(lon, lat), polys):
            continue
        kind = ("station" if tags.get("railway") == "station" else
                "worship" if tags.get("amenity") == "place_of_worship" else
                "park" if tags.get("leisure") in {"park", "common", "nature_reserve"} else
                "playground" if tags.get("leisure") == "playground" else
                "library" if tags.get("amenity") == "library" else
                "community" if tags.get("amenity") == "community_centre" else "historic")
        name = tags.get("name", "").strip()
        dedupe = (name.lower(), kind)
        if not name or dedupe in seen_poi:
            continue
        seen_poi.add(dedupe)
        pois.append({"id": f"{el['type'][0]}{el['id']}", "name": name, "kind": kind,
                     "lon": round(lon, 6), "lat": round(lat, 6)})
    pois.sort(key=lambda p: p["id"])

    out_path = os.path.join(ROOT, "data", "areas", f"{slug}.json")
    lineage = compute_lineage(out_path, segments, proj)

    area = {
        "formatVersion": 1,
        "slug": slug, "name": cfg["name"], "longName": cfg.get("longName", cfg["name"]),
        "county": cfg.get("county", ""), "country": cfg.get("country", ""),
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "osmTimestamp": osm.get("osm3s", {}).get("timestamp_osm_base", ""),
        "attribution": "© OpenStreetMap contributors (ODbL); boundary: ONS BUA 2022 (OGL v3)",
        "center": [round(lon0, 6), round(lat0, 6)],
        "bbox": bbox_wsen,
        "boundary": [[[[round(x, 6), round(y, 6)] for x, y in ring] for ring in poly] for poly in polys_ll],
        "totalLengthMetres": round(total_len, 1),
        "segments": [{
            "id": sg["id"], "name": sg["name"], "kind": sg["kind"], "highway": sg["highway"],
            "length": round(sg["length"], 1),
            "a": sg["nodes"][0], "b": sg["nodes"][-1],
            "ways": sg["ways"],
            "coords": [[round(x, 6), round(y, 6)] for x, y in sg["ll"]],
        } for sg in segments],
        "blocks": blocks,
        "pois": pois,
        "lineage": lineage,
    }
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(area, f, separators=(",", ":"))
    print(f"      wrote {os.path.relpath(out_path, ROOT)} ({os.path.getsize(out_path) / 1024:.0f} KB)")

    sql_path = os.path.join(ROOT, "backend", "supabase", "seed", f"{slug}.sql")
    write_sql(sql_path, area)
    print(f"      wrote {os.path.relpath(sql_path, ROOT)}")
    _ = seg_by_id


def trace_blocks(segments):
    """Faces of the (approximately planar) segment graph via half-edge traversal."""
    out_edges = defaultdict(list)  # node -> [(angle, seg_index, forward)]
    for i, sg in enumerate(segments):
        xy = sg["xy"]
        a, b = sg["nodes"][0], sg["nodes"][-1]
        if a == b:
            continue  # self-loops (cul-de-sac rings) are blocks on their own; handled below
        start_dir = _direction(xy, from_start=True)
        end_dir = _direction(xy, from_start=False)
        out_edges[a].append((start_dir, i, True))
        out_edges[b].append((end_dir, i, False))
    for k in out_edges:
        out_edges[k].sort()

    def head(i, fwd):
        sg = segments[i]
        return sg["nodes"][-1] if fwd else sg["nodes"][0]

    visited = set()
    blocks = []
    for node in list(out_edges):
        for _, i0, f0 in out_edges[node]:
            if (i0, f0) in visited:
                continue
            face = []
            i, f = i0, f0
            guard = 0
            while (i, f) not in visited and guard < 5000:
                visited.add((i, f))
                face.append((i, f))
                v = head(i, f)
                lst = out_edges[v]
                # position of the reverse half-edge at v, then take the next one clockwise
                idx = next(k for k, (_, j, g) in enumerate(lst) if j == i and g == (not f))
                _, i, f = lst[(idx - 1) % len(lst)]
                guard += 1
            if not face or (i, f) != (i0, f0):
                continue
            ring = []
            for j, g in face:
                pts = segments[j]["xy"] if g else list(reversed(segments[j]["xy"]))
                ring.extend(pts if not ring else pts[1:])
            if len(ring) < 4:
                continue
            area = signed_area(ring + [ring[0]])
            if area <= 0:
                continue  # outer / clockwise faces
            if not (BLOCK_MIN_M2 <= area <= BLOCK_MAX_M2):
                continue
            counts = defaultdict(int)
            for j, _ in face:
                counts[j] += 1
            bounding = sorted({segments[j]["id"] for j, c in counts.items() if c == 1})
            if len(bounding) < 2:
                continue
            ll_ring = []
            for j, g in face:
                pts = segments[j]["ll"] if g else list(reversed(segments[j]["ll"]))
                ll_ring.extend(pts if not ll_ring else pts[1:])
            ll_ring.append(ll_ring[0])
            key = "-".join(bounding)
            blocks.append({
                "id": "b" + hashlib.sha1(key.encode()).hexdigest()[:11],
                "segments": bounding,
                "areaM2": round(area, 0),
                "ring": [[round(x, 6), round(y, 6)] for x, y in ll_ring],
            })
    uniq = {}
    for b in blocks:
        uniq.setdefault(b["id"], b)
    return sorted(uniq.values(), key=lambda b: b["id"])


def _direction(xy, from_start):
    """Angle of the segment leaving its endpoint, measured a few metres along."""
    pts = xy if from_start else list(reversed(xy))
    origin = pts[0]
    acc = 0.0
    target = pts[1]
    for k in range(1, len(pts)):
        acc += dist(pts[k - 1], pts[k])
        target = pts[k]
        if acc >= 6.0:
            break
    return math.atan2(target[1] - origin[1], target[0] - origin[0])


def compute_lineage(prev_path, segments, proj):
    if not os.path.exists(prev_path):
        return {}
    with open(prev_path) as f:
        prev = json.load(f)
    lineage = dict(prev.get("lineage", {}))
    new_ids = {sg["id"] for sg in segments}
    gone = [s for s in prev.get("segments", []) if s["id"] not in new_ids]
    if not gone:
        return lineage
    idx = GridIndex(40.0)
    for sg in segments:
        idx.insert_polyline(sg["id"], sg["xy"])
    mapped = 0
    for old in gone:
        xy = [proj.xy(*p) for p in old["coords"]]
        samples = sample_along(xy, 5.0)
        votes = defaultdict(int)
        for p, _ in samples:
            best = None
            for key, a, b in idx.near(p, LINEAGE_BUFFER_METRES):
                d, _ = point_segment_distance(p, a, b)
                if d <= LINEAGE_BUFFER_METRES and (best is None or d < best[0]):
                    best = (d, key)
            if best:
                votes[best[1]] += 1
        if votes:
            new_id, n = max(votes.items(), key=lambda kv: kv[1])
            if n / max(1, len(samples)) >= LINEAGE_OVERLAP:
                lineage[old["id"]] = new_id
                mapped += 1
    # Collapse chains a->b->c into a->c.
    for k in list(lineage):
        seen = {k}
        v = lineage[k]
        while v in lineage and v not in seen:
            seen.add(v)
            v = lineage[v]
        lineage[k] = v
    print(f"      lineage: {len(gone)} segment IDs changed, {mapped} carried over to new segments")
    return lineage


def sql_str(s):
    return "'" + str(s).replace("'", "''") + "'"


def write_sql(path, area):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    slug = area["slug"]
    with open(path, "w") as f:
        f.write(f"-- Generated by tools/ingest/ingest.py for {slug}. Do not edit by hand.\n")
        f.write(f"-- {area['attribution']}\nbegin;\n")
        polys = ",".join("((" + "),(".join(",".join(f"{x} {y}" for x, y in ring) for ring in poly) + "))"
                         for poly in area["boundary"])
        f.write(
            "insert into public.areas (slug, name, long_name, county, country, boundary, total_length_m, osm_timestamp)\n"
            f"values ({sql_str(slug)}, {sql_str(area['name'])}, {sql_str(area['longName'])}, "
            f"{sql_str(area['county'])}, {sql_str(area['country'])}, "
            f"ST_GeomFromText('MULTIPOLYGON({polys})', 4326), {area['totalLengthMetres']}, "
            f"nullif({sql_str(area['osmTimestamp'])}, '')::timestamptz)\n"
            "on conflict (slug) do update set name = excluded.name, long_name = excluded.long_name,\n"
            "  boundary = excluded.boundary, total_length_m = excluded.total_length_m, osm_timestamp = excluded.osm_timestamp;\n\n")
        f.write(f"update public.segments set active = false where area_slug = {sql_str(slug)};\n")
        rows = []
        for s in area["segments"]:
            line = ",".join(f"{x} {y}" for x, y in s["coords"])
            rows.append(
                f"({sql_str(s['id'])}, {sql_str(slug)}, ST_GeomFromText('LINESTRING({line})', 4326), "
                f"{s['length']}, {sql_str(s['name'])}, {sql_str(s['highway'])}, {sql_str(s['kind'])}, "
                f"'{{{','.join(str(w) for w in s['ways'])}}}', {s['a']}, {s['b']}, true)")
        for i in range(0, len(rows), 500):
            f.write("insert into public.segments (id, area_slug, geom, length_m, name, highway, kind, osm_way_ids, "
                    "start_node, end_node, active) values\n")
            f.write(",\n".join(rows[i:i + 500]))
            f.write("\non conflict (id) do update set geom = excluded.geom, length_m = excluded.length_m, "
                    "name = excluded.name, highway = excluded.highway, kind = excluded.kind, "
                    "osm_way_ids = excluded.osm_way_ids, active = true;\n")
        f.write(f"\ndelete from public.blocks where area_slug = {sql_str(slug)};\n")
        for b in area["blocks"]:
            ring = ",".join(f"{x} {y}" for x, y in b["ring"])
            f.write(f"insert into public.blocks (id, area_slug, geom, area_m2) values ({sql_str(b['id'])}, "
                    f"{sql_str(slug)}, ST_GeomFromText('POLYGON(({ring}))', 4326), {b['areaM2']});\n")
            f.write("insert into public.block_segments (block_id, segment_id) values " +
                    ",".join(f"({sql_str(b['id'])}, {sql_str(s)})" for s in b["segments"]) + ";\n")
        f.write(f"\ndelete from public.pois where area_slug = {sql_str(slug)};\n")
        for p in area["pois"]:
            f.write(f"insert into public.pois (id, area_slug, name, kind, location) values ({sql_str(p['id'])}, "
                    f"{sql_str(slug)}, {sql_str(p['name'])}, {sql_str(p['kind'])}, "
                    f"ST_SetSRID(ST_MakePoint({p['lon']}, {p['lat']}), 4326));\n")
        for old, new in sorted(area["lineage"].items()):
            f.write(f"insert into public.segment_lineage (old_id, new_id) values ({sql_str(old)}, {sql_str(new)}) "
                    f"on conflict (old_id) do update set new_id = excluded.new_id;\n")
        f.write("select public.apply_segment_lineage();\ncommit;\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("slug")
    ap.add_argument("--refresh", action="store_true", help="re-download boundary and OSM data")
    args = ap.parse_args()
    build(args.slug, args.refresh)
