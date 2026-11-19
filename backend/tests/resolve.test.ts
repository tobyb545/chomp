// resolve-run's pure core: upload validation, late uploads, shadow restriction,
// and the response shape. Also writes shared/fixtures/server-response.json,
// which ChompKitTests decodes as RunOutcome to prove the app can read it.
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { test } from "node:test";
import { Area, encodePolyline, type TileFile } from "../supabase/functions/_shared/chomp/mod.ts";
import { iso, resolveUpload, toWorld, type Upload, validate } from "../supabase/functions/_shared/resolve.ts";

const root = new URL("../../", import.meta.url);
const area = Area.fromTiles(JSON.parse(readFileSync(new URL("shared/fixtures/tiles-west-byfleet.json", root), "utf8")) as TileFile[]);
const fx = JSON.parse(readFileSync(new URL("shared/fixtures/parity.json", root), "utf8"));
const rows: number[][] = fx.runs[0].trace;
const emptyWorld = { ownership: [], pellets: [], capturesToday: 0, blockAwards: {}, conquered: [] as string[] };

function upload(overrides: Partial<Upload> = {}): Upload {
  return {
    runId: "6F9619FF-8B86-4D11-B42D-00C04FC964FF",
    startedAt: iso(rows[0][2]), endedAt: iso(rows[rows.length - 1][2]), source: "live",
    polyline: encodePolyline(rows.map(([lat, lon]) => ({ lat, lon }))),
    timestamps: rows.map((r) => r[2]), accuracies: rows.map((r) => r[3]), speeds: rows.map((r) => r[4]),
    signals: { motion: [{ start: iso(rows[0][2]), end: iso(rows[rows.length - 1][2]), activity: "running", confidence: 2 }], cadence: [], heartRate: [] },
    clientVersion: "1.0", ...overrides,
  };
}
const now = rows[rows.length - 1][2] + 120;

test("rejects malformed uploads", () => {
  assert.equal(validate(upload({ runId: "nope" }), now).ok, false);
  assert.equal(validate(upload({ timestamps: [1, 2] }), now).ok, false);
  assert.equal(validate(upload({ endedAt: iso(rows[0][2] - 10) }), now).ok, false);
  assert.equal(validate(upload({ endedAt: iso(now + 3600) }), now).ok, false, "future runs");
  assert.equal(validate(upload({ startedAt: iso(rows[0][2] - 13 * 3600) }), now).ok, false, "over 12 h");
});

test("resolves a clean run and writes the client fixture", () => {
  const u = upload(), v = validate(u, now);
  assert.ok(v.ok);
  const r = resolveUpload(area, u, v, "user-1", toWorld("user-1", emptyWorld), { now, shadowRestricted: false, tracePath: "x" });
  assert.equal(r.status, "resolved");
  assert.equal(r.payload.runId, "6f9619ff-8b86-4d11-b42d-00c04fc964ff");
  // One ownership write per coin collected.
  const coins = Object.values(fx.runs[0].coins as Record<string, number[]>).reduce((n, c) => n + c.length, 0);
  assert.ok(coins > 0);
  assert.equal(r.payload.ownership.length, coins);
  assert.ok(r.payload.ownership.every((w) => /#\d+$/.test(w.s)));
  assert.ok(r.payload.distance > 2500 && r.payload.distance < 4500, `distance ${r.payload.distance}`);
  assert.match(r.clientOutcome.captures[0].at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  mkdirSync(new URL("shared/fixtures/", root), { recursive: true });
  // Exercise every optional field the app must decode: a frenzy window, a steal with previousOwner, a rejection reason.
  const sample = structuredClone(r.clientOutcome);
  sample.frenzyWindows.push({ start: sample.captures[0].at, duration: 600 });
  sample.captures.push({ ...sample.captures[0], segmentID: "steal", kind: "stolen", multiplier: 2, previousOwner: { kind: "ghost", id: "bot-dusk" } });
  sample.captures.push({ ...sample.captures[0], segmentID: "reject", kind: "rejected", points: 0, reason: "Too fast to be running" });
  sample.flags.push({ rule: "speed", severity: 1, detail: "30s above 25 km/h" });
  writeFileSync(new URL("shared/fixtures/server-response.json", root), JSON.stringify({ status: r.status, outcome: sample }, null, 1));
});

test("every ownership write carries its tile", () => {
  const u = upload(), v = validate(u, now);
  assert.ok(v.ok);
  const r = resolveUpload(area, u, v, "user-1", toWorld("user-1", emptyWorld), { now, shadowRestricted: false, tracePath: "x" });
  assert.ok(r.payload.ownership.length > 0);
  for (const w of r.payload.ownership) assert.match(w.t ?? "", /^14\/\d+\/\d+$/);
});

test("a recent Strava run collects coins; an old one doesn't", () => {
  const st = upload({ source: "strava_import" }), sv = validate(st, now);
  assert.ok(sv.ok);
  assert.ok(resolveUpload(area, st, sv, "user-1", toWorld("user-1", emptyWorld), { now, shadowRestricted: false, tracePath: "x" }).payload.ownership.length > 0);
  const later = now + 8 * 86_400, lv = validate(st, later);
  assert.ok(lv.ok);
  assert.equal(resolveUpload(area, st, lv, "user-1", toWorld("user-1", emptyWorld), { now: later, shadowRestricted: false, tracePath: "x" }).payload.ownership.length, 0);
});

test("late uploads count for exploration only", () => {
  const late = now + 8 * 86_400;
  const u = upload(), v = validate(u, late);
  assert.ok(v.ok);
  const r = resolveUpload(area, u, v, "user-1", toWorld("user-1", emptyWorld), { now: late, shadowRestricted: false, tracePath: "x" });
  assert.equal(r.payload.ownership.length, 0);
  assert.ok(r.payload.coverage.length > 0);
  assert.equal(r.payload.stats.late, true);
});

test("shadow-restricted runs never touch the shared map", () => {
  const u = upload(), v = validate(u, now);
  assert.ok(v.ok);
  const r = resolveUpload(area, u, v, "user-1", toWorld("user-1", emptyWorld), { now, shadowRestricted: true, tracePath: "x" });
  assert.equal(r.payload.ownership.length, 0);
  assert.ok(r.clientOutcome.points > 0, "the player still sees a normal result");
});

test("driving is sent to review with no captures", () => {
  const u = upload({ signals: { motion: [{ start: iso(rows[0][2]), end: iso(rows[rows.length - 1][2]), activity: "automotive", confidence: 2 }] } });
  const v = validate(u, now);
  assert.ok(v.ok);
  const r = resolveUpload(area, u, v, "user-1", toWorld("user-1", emptyWorld), { now, shadowRestricted: false, tracePath: "x" });
  assert.equal(r.status, "under_review");
  assert.equal(r.payload.ownership.length, 0);
});

test("streets never fade while decay is off", async () => {
  const { strength } = await import("../supabase/functions/_shared/chomp/engine.ts");
  const { rules, decaySeconds } = await import("../supabase/functions/_shared/chomp/rules.ts");
  assert.equal(rules.decay.enabled, false);
  assert.equal(decaySeconds(rules), Infinity);
  const fiveYears = 5 * 365 * 86_400;
  assert.equal(strength({ owner: { kind: "player", id: "p" }, capturedAt: 0, lastVisitedAt: 0 } as any, fiveYears, decaySeconds(rules)), 1);
  assert.ok(strength({ owner: { kind: "player", id: "p" }, capturedAt: 0, lastVisitedAt: 0 } as any, 22 * 86_400, 21 * 86_400) === 0,
    "with decay on, 21 days still fades");
});

test("imported runs skip the identical-accuracy check, live runs don't", async () => {
  const { evaluate, rules } = await import("../supabase/functions/_shared/chomp/mod.ts");
  // Garmin-style: a point every second, the same made-up accuracy throughout.
  const trace = Array.from({ length: 600 }, (_, i) => ({
    coordinate: { lat: 51.34 + i * 0.000027, lon: -0.51 + Math.sin(i / 40) * 0.0002 }, t: 1_795_000_000 + i, accuracy: 10, speed: -1,
  }));
  const none = { motion: [], cadence: [], heartRate: [] };
  assert.ok(evaluate(trace, none, rules.antiCheat, rules.matching).flags.some((f) => f.rule === "synthetic"));
  const imported = evaluate(trace, none, rules.antiCheat, rules.matching, true);
  assert.ok(!imported.flags.some((f) => f.rule === "synthetic"));
  assert.equal(imported.verdict, "accepted");
});
