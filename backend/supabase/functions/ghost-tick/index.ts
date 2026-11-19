// Hourly (pg_cron → this function): moves each town's bots a few streets.
// Bots are always named "Bot …" and shown as bots; they keep quiet towns lively.
import { admin, hasSecret, json } from "../_shared/http.ts";
import { loadArea } from "../_shared/areas.ts";
import { type Ghost, makeGhosts, type Ownership, rules, SeededRandom, walkGhost } from "../_shared/chomp/mod.ts";

const TICK_S = 3600;

Deno.serve(async (req) => {
  if (!hasSecret(req, "CRON_SECRET")) return json({ error: "forbidden" }, 403);
  const db = admin();
  const now = Date.now() / 1000;
  const { data: areas } = await db.from("areas").select("slug");
  const summary: Record<string, number> = {};

  for (const { slug } of areas ?? []) {
    const area = await loadArea(db, slug);
    if (!area) continue;
    let { data: ghosts } = await db.from("ai_ghosts").select("*").eq("area_slug", slug);
    if (!ghosts?.length) {
      const fresh = makeGhosts(area, rules).map((g) => ({
        id: g.id, area_slug: slug, name: g.name, color_hex: g.colorHex, cursor_node: g.cursorNode,
        personality: { aggression: g.aggression, segmentsPerDay: g.segmentsPerDay }, next_tick_at: new Date(now * 1000).toISOString(),
      }));
      await db.from("ai_ghosts").insert(fresh);
      ghosts = fresh;
    }
    const { data: rows } = await db.from("segment_ownership").select("segment_id, owner_kind, owner_id, captured_at, last_visited_at").eq("area_slug", slug);
    const ownership = new Map<string, Ownership>((rows ?? []).map((r) => [r.segment_id, {
      owner: { kind: r.owner_kind, id: r.owner_id }, capturedAt: Date.parse(r.captured_at) / 1000, lastVisitedAt: Date.parse(r.last_visited_at) / 1000,
    }]));

    let moved = 0;
    for (const row of ghosts) {
      const due = Date.parse(row.next_tick_at) / 1000;
      if (due > now) continue;
      const last = due - TICK_S;
      const elapsed = Math.min(now - last, rules.ghosts.maxTickHours * 3600);
      const g: Ghost = { id: row.id, name: row.name, colorHex: row.color_hex, aggression: row.personality.aggression,
        segmentsPerDay: row.personality.segmentsPerDay, cursorNode: Number(row.cursor_node) };
      const rng = new SeededRandom(`tick|${g.id}|${Math.trunc(last)}`);
      const expected = g.segmentsPerDay * elapsed / 86_400;
      const steps = Math.trunc(expected) + (rng.unit() < expected - Math.trunc(expected) ? 1 : 0);
      const result = steps > 0
        ? walkGhost(area, rules, g, steps, now - elapsed, now, ownership, `walk|${g.id}|${Math.trunc(last)}`)
        : { writes: new Map<string, Ownership>(), raids: [], cursor: g.cursorNode };

      // One notification per raided player, naming the street they lost most of.
      const byUser = new Map<string, string[]>();
      for (const r of result.raids) byUser.set(r.from.id, [...(byUser.get(r.from.id) ?? []), r.segmentID]);
      const raids = [...byUser].map(([user, segs]) => {
        const names = segs.map((s) => area.segment(s)?.name).filter((x): x is string => !!x);
        const top = names.sort((a, b) => names.filter((x) => x === b).length - names.filter((x) => x === a).length)[0];
        return { user, message: `${g.name} ate ${segs.length} of your street${segs.length === 1 ? "" : "s"}${top ? ` on ${top}` : ""}` };
      });

      const { error } = await db.rpc("apply_ghost_moves", { p: {
        ghost: g.id, area: slug, cursor: result.cursor, nextTick: now + TICK_S,
        moves: [...result.writes].map(([s, o]) => ({ s, c: o.capturedAt, v: o.lastVisitedAt })), raids,
      } });
      if (error) console.error("apply_ghost_moves", slug, g.id, error.message);
      moved += result.writes.size;
    }
    summary[slug] = moved;
  }
  return json({ ok: true, moved: summary });
});
