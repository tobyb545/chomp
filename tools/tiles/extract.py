#!/usr/bin/env python3
"""Cuts an OpenStreetMap extract (.osm.pbf) into per-tile inputs for build.ts.

For every zoom-14 tile it gathers what the app's Overpass query would return
(backend/supabase/functions/_shared/chomp/tiles.ts, overpassQuery + subset):

  * every highway way with a node inside the tile's fetch box (the tile plus
    400 m), with all of its nodes
  * named landmarks (parks, stations, churches...) whose point or centre is in
    the tile

Output: <out>/blocks/<bx>_<by>.jsonl, one file per zoom-10 block (16x16 tiles),
one JSON object per line: {"t": [[x, y], ...], "w": [id, tags, [[node, lat, lon], ...]]}
for a way, or {"t": [[x, y]], "p": {Overpass-style element}} for a landmark.
Plus <out>/meta.json with the extract's timestamp.

Needs pyosmium (pip install osmium). Usage: extract.py region.osm.pbf out/
"""
import json
import math
import os
import resource
import sys
import time

import osmium

ZOOM = 14
N = 2 ** ZOOM
BUFFER_METRES = 400
BLOCK_SHIFT = 4  # zoom-10 blocks

POI_RULES = [  # same as overpassQuery, all need a name
    ("leisure", {"park", "playground", "common", "nature_reserve"}),
    ("railway", {"station"}),
    ("amenity", {"place_of_worship", "library", "community_centre"}),
    ("historic", None),  # any value
]


def is_poi(tags):
    if "name" not in tags:
        return False
    for key, values in POI_RULES:
        v = tags.get(key)
        if v is not None and (values is None or v in values):
            return True
    return False


def tile_x(lon):
    return math.floor((lon + 180) / 360 * N)


def tile_y(lat):
    r = math.radians(lat)
    return math.floor((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * N)


def tile_lon(x):
    return x / N * 360 - 180


def tile_lat(y):
    return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / N))))


_boxes = {}


def fetch_box(x, y):
    """(south, west, north, east): tiles.ts fetchBox, the tile plus BUFFER_METRES."""
    b = _boxes.get((x, y))
    if b is None:
        north, south = tile_lat(y), tile_lat(y + 1)
        west, east = tile_lon(x), tile_lon(x + 1)
        kx = 111_320 * math.cos(math.radians((north + south) / 2))
        dlat, dlon = BUFFER_METRES / 110_540, BUFFER_METRES / kx
        b = (south - dlat, west - dlon, north + dlat, east + dlon)
        _boxes[(x, y)] = b
    return b


def tiles_for_node(lat, lon):
    """Every tile whose fetch box contains the point (1 to 4 of them)."""
    out = []
    pad_lat = BUFFER_METRES / 110_540 * 1.01
    pad_lon = BUFFER_METRES / (111_320 * math.cos(math.radians(lat))) * 1.05
    for x in range(tile_x(lon - pad_lon), tile_x(lon + pad_lon) + 1):
        for y in range(tile_y(lat + pad_lat), tile_y(lat - pad_lat) + 1):
            s, w, n, e = fetch_box(x, y)
            if s <= lat <= n and w <= lon <= e:
                out.append((x, y))
    return out


class Blocks:
    """One append-only JSONL file per zoom-10 block."""

    def __init__(self, root):
        self.root = os.path.join(root, "blocks")
        os.makedirs(self.root, exist_ok=True)
        self.files = {}

    def write(self, tiles, payload):
        by_block = {}
        for x, y in tiles:
            by_block.setdefault((x >> BLOCK_SHIFT, y >> BLOCK_SHIFT), []).append([x, y])
        for block, ts in by_block.items():
            f = self.files.get(block)
            if f is None:
                f = open(os.path.join(self.root, f"{block[0]}_{block[1]}.jsonl"), "w")
                self.files[block] = f
            payload["t"] = ts
            f.write(json.dumps(payload, separators=(",", ":"), ensure_ascii=False))
            f.write("\n")

    def close(self):
        for f in self.files.values():
            f.close()


def main(pbf, out):
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = 8192 if hard == resource.RLIM_INFINITY else min(hard, 8192)
    if soft < want:
        resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
    os.makedirs(out, exist_ok=True)
    started = time.time()

    header = osmium.io.Reader(pbf, osmium.osm.osm_entity_bits.NOTHING)
    stamp = header.header().get("osmosis_replication_timestamp", "")
    header.close()

    # Pass 1: landmark relations (multipolygon parks etc.) and the members they need.
    rel_tags, rel_ways, rel_nodes = {}, {}, {}
    for r in osmium.FileProcessor(pbf, osmium.osm.RELATION):
        tags = dict(r.tags)
        if is_poi(tags):
            rel_tags[r.id] = tags
            for m in r.members:
                if m.type == "w":
                    rel_ways.setdefault(m.ref, []).append(r.id)
                elif m.type == "n":
                    rel_nodes.setdefault(m.ref, []).append(r.id)
    rel_bbox = {}

    def grow(rid, lat, lon):
        b = rel_bbox.get(rid)
        rel_bbox[rid] = (lat, lon, lat, lon) if b is None else (min(b[0], lat), min(b[1], lon), max(b[2], lat), max(b[3], lon))

    # Pass 2: nodes and ways, with node locations.
    blocks = Blocks(out)
    ways = pois = 0
    for o in osmium.FileProcessor(pbf, osmium.osm.NODE | osmium.osm.WAY).with_locations("flex_mem"):
        if o.is_node():
            if o.id in rel_nodes and o.location.valid():
                for rid in rel_nodes[o.id]:
                    grow(rid, o.location.lat, o.location.lon)
            if len(o.tags) == 0 or not o.location.valid():
                continue
            tags = dict(o.tags)
            if is_poi(tags):
                lat, lon = o.location.lat, o.location.lon
                blocks.write([(tile_x(lon), tile_y(lat))], {"p": {"type": "node", "id": o.id, "lat": lat, "lon": lon, "tags": tags}})
                pois += 1
            continue
        # Way
        tags = dict(o.tags)
        highway = "highway" in tags
        poi = is_poi(tags)
        member_of = rel_ways.get(o.id)
        if not (highway or poi or member_of):
            continue
        nodes = [(n.ref, n.lat, n.lon) for n in o.nodes if n.location.valid()]
        if len(nodes) != len(o.nodes) or not nodes:
            continue  # clipped at the extract edge: Overpass would have all of it
        if member_of:
            for rid in member_of:
                for _, lat, lon in nodes:
                    grow(rid, lat, lon)
        if poi:
            lats, lons = [n[1] for n in nodes], [n[2] for n in nodes]
            c = {"lat": (min(lats) + max(lats)) / 2, "lon": (min(lons) + max(lons)) / 2}
            blocks.write([(tile_x(c["lon"]), tile_y(c["lat"]))], {"p": {"type": "way", "id": o.id, "center": c, "tags": tags}})
            pois += 1
        if highway:
            tiles = set()
            for _, lat, lon in nodes:
                tiles.update(tiles_for_node(lat, lon))
            blocks.write(sorted(tiles), {"w": [o.id, tags, [[ref, round(lat, 7), round(lon, 7)] for ref, lat, lon in nodes]]})
            ways += 1

    for rid, (s, w, n, e) in rel_bbox.items():
        c = {"lat": (s + n) / 2, "lon": (w + e) / 2}
        blocks.write([(tile_x(c["lon"]), tile_y(c["lat"]))], {"p": {"type": "relation", "id": rid, "center": c, "tags": rel_tags[rid]}})
        pois += 1

    blocks.close()
    with open(os.path.join(out, "meta.json"), "w") as f:
        json.dump({"osmTimestamp": stamp, "source": os.path.basename(pbf), "ways": ways, "pois": pois,
                   "blocks": len(blocks.files)}, f)
    print(f"{ways} highway ways, {pois} landmarks, {len(blocks.files)} blocks in {time.time() - started:.0f}s", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
