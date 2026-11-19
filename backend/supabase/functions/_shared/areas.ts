import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { Area, type AreaFile } from "./chomp/mod.ts";

// Areas are immutable between ingests; cache per isolate for 10 minutes.
const cache = new Map<string, { area: Area; at: number }>();

export async function loadArea(db: SupabaseClient, slug: string): Promise<Area | null> {
  const hit = cache.get(slug);
  if (hit && Date.now() - hit.at < 600_000) return hit.area;
  const { data, error } = await db.rpc("area_bundle", { p_slug: slug });
  if (error || !data) return null;
  const area = new Area(data as AreaFile);
  cache.set(slug, { area, at: Date.now() });
  return area;
}
