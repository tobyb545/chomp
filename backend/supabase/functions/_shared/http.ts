import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

/** Service-role client: bypasses RLS. Only ever used server-side. */
export function admin(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
}

/** The signed-in caller, from the request's JWT. */
export async function caller(req: Request, db: SupabaseClient): Promise<string | null> {
  const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data, error } = await db.auth.getUser(token);
  return error || !data.user ? null : data.user.id;
}

/** Shared-secret check for cron / webhook callers. */
export function hasSecret(req: Request, name: string): boolean {
  const want = Deno.env.get(name);
  const got = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  return !!want && got === want;
}
