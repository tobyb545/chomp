// Hourly (pg_cron → this function): moves the bots a few streets. Bots live per
// district (4x4 map tiles, about 6 km) wherever players hold streets. They're there
// so a lone runner has rivals: once RETIRE_AT_PLAYERS real runners have been active
// in a district recently, its bots stop running and let go of their coins over about
// a week. If the district goes quiet again, new bots appear.
import { admin, hasSecret, json } from "../_shared/http.ts";
import { districtTiles, loadTiles } from "../_shared/world.ts";
import { Area, coinSegment, type Ghost, GHOST_DISPLAY_NAMES, makeGhosts, type Ownership, rules, SeededRandom, walkGhost } from "../_shared/chomp/mod.ts";

const TICK_S = 3600;
const MAX_DISTRICTS_PER_TICK = 40;
/** Real runners active in a district (last ACTIVE_DAYS) before its bots retire. */
const RETIRE_AT_PLAYERS = 2;
const ACTIVE_DAYS = 14;
/** A retiring bot releases this share of its coins per hourly tick (about a week). */
const RELEASE_PER_TICK = 1 / 168;

Deno.serve(async (req) => {
  if (!hasSecret(req, "CRON_SECRET")) return json({ error: "forbidden" }, 403);
  const db = admin();
  const now = Date.now() / 1000;
  // Districts with live player territory (from the active_districts view).
  const { data: districts } = await db.from("active_districts").select("district").limit(MAX_DISTRICTS_PER_TICK);
  const summary: Record<string, number> = {};

  for (const { district } of districts ?? []) {
    const { data: active } = await db.rpc("district_active_players", { p_district: district, p_days: ACTIVE_DAYS });
    if ((active ?? 0) >= RETIRE_AT_PLAYERS) {
      // Busy enough: bots step back quietly.
      const { data: retiring } = await db.from("ai_ghosts").select("id").eq("district", district);
      for (const { id } of retiring ?? []) {
        const { count } = await db.from("segment_ownership").select("segment_id", { count: "exact", head: true })
          .eq("owner_kind", "ghost").eq("owner_id", id);
        const { error } = await db.rpc("release_ghost_coins", { p_ghost: id, p_limit: Math.max(5, Math.ceil((count ?? 0) * RELEASE_PER_TICK)) });
        if (error) console.error("release_ghost_coins", district, id, error.message);
      }
      summary[district] = 0;
      continue;
    }
    const keys = districtTiles(district);
    // Bots only walk tiles that already exist; they never trigger Overpass downloads.
    const tiles = await loadTiles(db, keys, 0);
    if (!tiles.length) continue;
    const area = Area.fromTiles(tiles);
    const tileKeys = tiles.map((t) => t.key);
    let { data: ghosts } = await db.from("ai_ghosts").select("*").eq("district", district);
    if (!ghosts?.length) {
      // Skip names players (or other bots) already use.
      const lower = GHOST_DISPLAY_NAMES.map((n) => n.toLowerCase());
      const [{ data: people }, { data: bots }] = await Promise.all([
        db.from("profiles").select("display_name").in("display_name", GHOST_DISPLAY_NAMES),
        db.from("ai_ghosts").select("name").in("name", GHOST_DISPLAY_NAMES),
      ]);
      const taken = new Set<string>([...(people ?? []).map((p) => p.display_name.toLowerCase()), ...(bots ?? []).map((b) => b.name.toLowerCase())]
        .filter((n) => lower.includes(n)));
      const fresh = makeGhosts(area, rules, district, taken).map((g) => ({
        id: g.id, district, name: g.name, color_hex: g.colorHex, cursor_node: g.cursorNode,
        personality: { aggression: g.aggression, segmentsPerDay: g.segmentsPerDay }, next_tick_at: new Date(now * 1000).toISOString(),
      }));
      await db.from("ai_ghosts").insert(fresh);
      ghosts = fresh;
    }
    const { data: rows } = await db.from("segment_ownership").select("segment_id, owner_kind, owner_id, captured_at, last_visited_at").in("tile", tileKeys);
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
        return { user, message: `${g.name} took ${segs.length} of your street${segs.length === 1 ? "" : "s"}${top ? ` on ${top}` : ""}` };
      });

      const tileOf = (id: string) => { const s = area.segment(coinSegment(id)); return s ? area.segmentTile[s.index] : null; };
      const { error } = await db.rpc("apply_ghost_moves", { p: {
        ghost: g.id, cursor: result.cursor, nextTick: now + TICK_S,
        moves: [...result.writes].map(([s, o]) => ({ s, t: tileOf(s), c: o.capturedAt, v: o.lastVisitedAt })), raids,
      } });
      if (error) console.error("apply_ghost_moves", district, g.id, error.message);
      moved += result.writes.size;
    }
    summary[district] = moved;
  }
  return json({ ok: true, moved: summary });
});
