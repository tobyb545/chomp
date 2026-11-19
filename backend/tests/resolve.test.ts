// resolve-run's pure core: upload validation, late uploads, shadow restriction,
// and the response shape. Also writes shared/fixtures/server-response.json,
// which ChompKitTests decodes as RunOutcome to prove the app can read it.
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { test } from "node:test";
import { Area, type AreaFile, encodePolyline } from "../supabase/functions/_shared/chomp/mod.ts";
import { iso, resolveUpload, toWorld, type Upload, validate } from "../supabase/functions/_shared/resolve.ts";

const root = new URL("../../", import.meta.url);
const area = new Area(JSON.parse(readFileSync(new URL("data/areas/west-byfleet.json", root), "utf8")) as AreaFile);
const fx = JSON.parse(readFileSync(new URL("shared/fixtures/parity.json", root), "utf8"));
const rows: number[][] = fx.runs[0].trace;
const emptyWorld = { ownership: [], pellets: [], capturesToday: 0, blockAwards: {}, conquered: false };

function upload(overrides: Partial<Upload> = {}): Upload {
  return {
    runId: "6F9619FF-8B86-4D11-B42D-00C04FC964FF", areaSlug: area.slug,
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
  assert.equal(r.payload.ownership.length, fx.runs[0].captures && Object.values(fx.runs[0].captures).filter((k) => k === "captured").length);
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

test("late uploads count for exploration only", () => {
  const u = upload(), v = validate(u, now + 3 * 86_400);
  assert.ok(v.ok);
  const r = resolveUpload(area, u, v, "user-1", toWorld("user-1", emptyWorld), { now: now + 3 * 86_400, shadowRestricted: false, tracePath: "x" });
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
