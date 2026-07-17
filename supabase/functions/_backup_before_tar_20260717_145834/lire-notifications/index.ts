import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";

function clampInt(value: string | null, def: number, min: number, max: number): number {
  if (!value) return def;
  const n = parseInt(value, 10);
  if (isNaN(n)) return def;
  return Math.max(min, Math.min(max, n));
}

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "GET, POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "GET" && req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return jsonResponse({ error: "Token d'authentification manquant." }, 401, corsHeaders);
  }

  const jwtToken = authHeader.replace("Bearer ", "").trim();
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  const { data: userData, error: userError } = await adminClient.auth.getUser(jwtToken);
  if (userError || !userData?.user) {
    return jsonResponse({ error: "Session invalide ou expirée." }, 401, corsHeaders);
  }

  const userId = userData.user.id;

  if (req.method === "GET") {
    const url = new URL(req.url);
    const limit = clampInt(url.searchParams.get("limit"), 30, 1, 100);
    const offset = clampInt(url.searchParams.get("offset"), 0, 0, 10000);
    const nonLuesSeulement = url.searchParams.get("non_lues_seulement") === "true";

    let query = adminClient
      .from("notifications_envoyees")
      .select("id, user_id, demande_id, type, lu, created_at", { count: "exact" })
      .eq("user_id", userId)
      .order("created_at", { ascending: false })
      .range(offset, offset + limit - 1);

    if (nonLuesSeulement) query = query.eq("lu", false);

    const { data: notifications, count } = await query;
    const { count: nonLuesCount } = await adminClient
      .from("notifications_envoyees")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .eq("lu", false);

    return jsonResponse({
      success: true,
      data: notifications ?? [],
      total: count ?? 0,
      non_lues: nonLuesCount ?? 0,
      limit,
      offset,
    }, 200, corsHeaders);
  }

  if (req.method === "POST") {
    const body = await req.json();
    const { action, id } = body;

    if (action === "marquer_lue") {
      const { count: updatedCount } = await adminClient
        .from("notifications_envoyees")
        .update({ lu: true }, { count: "exact" })
        .eq("id", id)
        .eq("user_id", userId);

      if (updatedCount === 0) return jsonResponse({ error: "Notification introuvable." }, 404, corsHeaders);
      return jsonResponse({ success: true, action: "marquer_lue", id }, 200, corsHeaders);
    }

    if (action === "tout_marquer_lu") {
      await adminClient.from("notifications_envoyees").update({ lu: true }).eq("user_id", userId).eq("lu", false);
      return jsonResponse({ success: true, action: "tout_marquer_lu" }, 200, corsHeaders);
    }
  }

  return jsonResponse({ error: "Requête non gérée." }, 400, corsHeaders);
});
