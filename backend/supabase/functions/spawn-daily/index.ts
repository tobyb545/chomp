// Daily at 00:05 UK time: records today's power pellets and bonus streets.
// They're deterministic (clients compute the same ones offline); the tables
// make them visible to admin tools and let events add extra bonus streets.
import { admin, hasSecret, json } from "../_shared/http.ts";
import { loadArea } from "../_shared/areas.ts";
import { bonusStreets, powerPellets, rules, startOfDay, nextDay } from "../_shared/chomp/mod.ts";

const ts = (t: number) => new Date(t * 1000).toISOString();

Deno.serve(async (req) => {
  if (!hasSecret(req, "CRON_SECRET")) return json({ error: "forbidden" }, 403);
  const db = admin();
  const now = Date.now() / 1000;
  const { data: areas } = await db.from("areas").select("slug");
  for (const { slug } of areas ?? []) {
    const area = await loadArea(db, slug);
    if (!area) continue;
    const pellets = powerPellets(area, now, rules).map((p) => ({
      id: p.id, area_slug: slug, poi_id: p.landmark.id, active_from: ts(p.activeFrom), active_until: ts(p.activeUntil),
    }));
    await db.from("power_pellets").upsert(pellets);
    const day = startOfDay(now);
    await db.from("bonus_streets").delete().eq("area_slug", slug).gte("starts_at", ts(day)).lt("starts_at", ts(nextDay(day)));
    await db.from("bonus_streets").insert(bonusStreets(area, now, rules).map((b) => ({
      area_slug: slug, street_name: b.streetName, multiplier: b.multiplier, starts_at: ts(b.startsAt), ends_at: ts(b.endsAt),
    })));
  }
  return json({ ok: true });
});
