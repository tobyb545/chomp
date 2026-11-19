// Checks the server's TypeScript game logic against ChompKit's answers
// (shared/fixtures/parity.json, written by ChompKitTests' ParityFixture).
// Run: node --experimental-strip-types --test backend/tests/
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  Area, bonusStreets, buildTile, subset, TileKey, type TileFile, type OverpassResponse, evaluate, GameEngine, MapMatcher, powerPellets, rules, SeededRandom, coverageOf,
  type TracePoint, makeGhosts, GHOST_DISPLAY_NAMES, walkGhost, type Ownership, decodePolyline, encodePolyline, coinsOf, coinID, coinSegment,
} from "../supabase/functions/_shared/chomp/mod.ts";

const root = new URL("../../", import.meta.url);
const osm = JSON.parse(readFileSync(new URL("shared/fixtures/osm-west-byfleet.json", root), "utf8")) as OverpassResponse;
const swiftTiles = JSON.parse(readFileSync(new URL("shared/fixtures/tiles-west-byfleet.json", root), "utf8")) as TileFile[];
const area = Area.fromTiles(swiftTiles, "West Byfleet");
const fx = JSON.parse(readFileSync(new URL("shared/fixtures/parity.json", root), "utf8"));
const toTrace = (rows: number[][]): TracePoint[] => rows.map(([lat, lon, t, accuracy, speed]) => ({ coordinate: { lat, lon }, t, accuracy, speed }));

test("rules.json copy matches shared/rules.json", () => {
  const shared = JSON.parse(readFileSync(new URL("shared/rules.json", root), "utf8"));
  assert.deepEqual(rules, shared, "run tools/sync-rules.sh");
});

test("StreetBuilder builds exactly the tiles Swift builds", () => {
  const centre = new TileKey(8168, 5460);
  const built = centre.neighbourhood().map((k) => buildTile(k, subset(osm, k)));
  assert.equal(built.length, swiftTiles.length);
  for (const [i, t] of built.entries()) {
    const s = swiftTiles[i];
    assert.equal(t.key, s.key);
    assert.deepEqual(t.segments.map((x) => x.id), s.segments.map((x) => x.id), `segment ids in ${t.key}`);
    assert.deepEqual(t.segments, s.segments, `segments in ${t.key}`);
    assert.deepEqual(t.blocks, s.blocks, `blocks in ${t.key}`);
    assert.deepEqual(t.pois, s.pois, `landmarks in ${t.key}`);
  }
});

test("tile math matches", () => {
  const k = TileKey.containing({ lat: 51.3392, lon: -0.5063 });
  assert.equal(k.toString(), "14/8168/5460");
  assert.deepEqual(TileKey.parse(k.toString()), k);
  assert.ok(TileKey.covering([{ lat: 51.3392, lon: -0.5063 }]).length >= 1);
});

test("SeededRandom matches Swift bit for bit", () => {
  const r = new SeededRandom("chomp");
  assert.deepEqual(fx.rng, fx.rng.map(() => r.next().toString()));
});

test("daily spawns match, including clock-change days", () => {
  for (const day of fx.spawns) {
    const p = powerPellets(area, day.t, rules).map((x) => ({ id: x.id, from: x.activeFrom, until: x.activeUntil }));
    assert.deepEqual(p, day.pellets, `pellets at ${day.t}`);
    const b = bonusStreets(area, day.t, rules).map((x) => ({ street: x.streetName, mult: x.multiplier, starts: x.startsAt, ends: x.endsAt, segments: x.segmentIDs.length }));
    assert.deepEqual(b, day.bonus, `bonus at ${day.t}`);
  }
});

for (const run of fx.runs) {
  test(`run seed ${run.seed}: matching, anti-cheat and captures agree`, () => {
    const trace = toTrace(run.trace);
    const match = new MapMatcher(area, rules.matching).match(trace);
    assert.equal(match.usedPoints, run.used);
    assert.equal(match.chunks, run.chunks);
    assert.equal(match.unmatchedPoints, run.unmatched);
    const cov: Record<string, number> = {};
    for (const [seg, set] of coverageOf(match.pieces)) cov[area.segments[seg].id] = set.covered;
    assert.deepEqual(Object.keys(cov).sort(), Object.keys(run.coverage).sort());
    for (const k of Object.keys(cov)) assert.ok(Math.abs(cov[k] - run.coverage[k]) < 1e-6, `coverage ${k}`);

    const report = evaluate(trace, { motion: [], cadence: [], heartRate: [] }, rules.antiCheat, rules.matching);
    assert.equal(report.verdict, run.verdict);
    assert.deepEqual(report.flags.map((f) => f.rule), run.flags);
    assert.equal(report.excluded.length, run.excluded);

    const engine = new GameEngine(area, rules);
    const { outcome } = engine.resolve(
      { runID: "r", startedAt: trace[0].t, endedAt: trace[trace.length - 1].t, isImport: false }, trace, match, report,
      { playerID: "p1", ownership: new Map(), collectedPellets: new Set(), capturesToday: 0, blockAwards: new Map(), conqueredTiles: new Set<string>() });
    assert.deepEqual(Object.fromEntries(outcome.captures.map((c) => [c.segmentID, c.kind])), run.captures);
    assert.deepEqual(Object.fromEntries(outcome.captures.filter((c) => c.coins).map((c) => [c.segmentID, c.coins])), run.coins);
    assert.equal(outcome.points, run.points);
    assert.equal(outcome.blockBonus, run.blockBonus);
    assert.deepEqual(outcome.pelletsCollected, run.pellets);
  });
}

test("a stolen street needs the rival to hold it", () => {
  const run = fx.runs[0];
  const trace = toTrace(run.trace);
  const match = new MapMatcher(area, rules.matching).match(trace);
  const target = Object.entries(run.captures as Record<string, string>).find(([, k]) => k === "captured")![0];
  const t0 = trace[0].t;
  const seg = area.segment(target)!;
  const ownership = new Map<string, Ownership>(coinsOf(rules, seg).map((id) => [id, { owner: { kind: "player", id: "rival" }, capturedAt: t0 - 3600, lastVisitedAt: t0 - 3600 }]));
  const { outcome, writes } = new GameEngine(area, rules).resolve(
    { runID: "r", startedAt: t0, endedAt: trace[trace.length - 1].t, isImport: false }, trace, match,
    { verdict: "accepted", flags: [], excluded: [] },
    { playerID: "p1", ownership, collectedPellets: new Set(), capturesToday: 0, blockAwards: new Map(), conqueredTiles: new Set<string>() });
  const rec = outcome.captures.find((c) => c.segmentID === target)!;
  assert.equal(rec.kind, "stolen");
  assert.equal(rec.previousOwner?.id, "rival");
  for (const i of rec.coins!) assert.equal(writes.ownership.get(coinID(target, i))?.owner.id, "p1");
  assert.ok(rec.tokens! > 0);
});

test("imports and runs under review never change ownership", () => {
  const trace = toTrace(fx.runs[0].trace);
  const match = new MapMatcher(area, rules.matching).match(trace);
  const engine = new GameEngine(area, rules);
  const world = () => ({ playerID: "p1", ownership: new Map(), collectedPellets: new Set<string>(), capturesToday: 0, blockAwards: new Map(), conqueredTiles: new Set<string>() });
  const ctx = { runID: "r", startedAt: trace[0].t, endedAt: trace[trace.length - 1].t, isImport: true };
  assert.equal(engine.resolve(ctx, trace, match, { verdict: "accepted", flags: [], excluded: [] }, world()).writes.ownership.size, 0);
  assert.equal(engine.resolve({ ...ctx, isImport: false }, trace, match, { verdict: "underReview", flags: [], excluded: [] }, world()).writes.ownership.size, 0);
});

test("daily capture limit holds across runs", () => {
  const trace = toTrace(fx.runs[0].trace);
  const match = new MapMatcher(area, rules.matching).match(trace);
  const { outcome, writes } = new GameEngine(area, rules).resolve(
    { runID: "r", startedAt: trace[0].t, endedAt: trace[trace.length - 1].t, isImport: false }, trace, match,
    { verdict: "accepted", flags: [], excluded: [] },
    { playerID: "p1", ownership: new Map(), collectedPellets: new Set(), capturesToday: rules.antiCheat.maxCapturesPerDay, blockAwards: new Map(), conqueredTiles: new Set<string>() });
  assert.equal(writes.ownership.size, 0);
  assert.ok(outcome.captures.some((c) => c.reason === "Daily capture limit reached"));
});

test("bots walk the graph, respect the cap and raid players", () => {
  const ghosts = makeGhosts(area, rules);
  assert.equal(ghosts.length, rules.ghosts.perArea);
  assert.ok(ghosts.every((g) => GHOST_DISPLAY_NAMES.includes(g.name) && !/bot/i.test(g.name)));
  const taken = new Set(ghosts.slice(0, 3).map((g) => g.name.toLowerCase()));
  assert.ok(makeGhosts(area, rules, area.slug, taken).every((g) => !taken.has(g.name.toLowerCase())));
  assert.ok(GHOST_DISPLAY_NAMES.every((n) => n.length >= 2 && n.length <= 20));
  const ownership = new Map<string, Ownership>();
  const now = 1_790_000_000;
  for (const s of area.segments.slice(0, 400)) for (const id of coinsOf(rules, s)) ownership.set(id, { owner: { kind: "player", id: "p1" }, capturedAt: now - 60, lastVisitedAt: now - 60 });
  const g = { ...ghosts[0], aggression: 0.8, cursorNode: area.segments[0].startNode };
  const { writes, raids } = walkGhost(area, rules, g, 40, now, now + 86_400, ownership, "test");
  const streets = new Set([...writes.keys()].map(coinSegment));
  assert.ok(streets.size > 0 && streets.size <= 40);
  // A bot takes every coin on each street it runs.
  for (const id of streets) for (const c of coinsOf(rules, area.segment(id)!)) assert.ok(writes.has(c));
  assert.ok(raids.length > 0, "an aggressive bot next to player territory should raid");
});

test("polyline codec round-trips", () => {
  const c = [{ lat: 51.338, lon: -0.505 }, { lat: 51.33812, lon: -0.50488 }];
  assert.deepEqual(decodePolyline(encodePolyline(c)), c);
});

test("warm-tiles accepts up to a 3x3 block of tiles", async () => {
  const { parseWarm } = await import("../supabase/functions/_shared/warm.ts");
  assert.equal(parseWarm({ tiles: ["14/8180/5448", "14/8181/5449", "14/8182/5450"] })?.length, 3);
  assert.equal(parseWarm({ tiles: ["14/8180/5448", "14/8180/5448"] })?.length, 1);
  assert.equal(parseWarm({ tiles: ["14/8180/5448", "14/8183/5448"] }), null);  // too far apart
  assert.equal(parseWarm({ tiles: Array(10).fill("14/8180/5448") }), null);
  assert.equal(parseWarm({ tiles: ["12/1/1"] }), null);
  assert.equal(parseWarm({ tiles: [] }), null);
  assert.equal(parseWarm({}), null);
});
