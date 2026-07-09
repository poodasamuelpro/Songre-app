// =============================================================================
// Edge Function : lire-notifications  (v2 — _shared/cors.ts + bug fix §4)
// Déploiement   : supabase functions deploy lire-notifications
//
// Endpoints supportés :
//   GET  /lire-notifications              → liste des notifications (paginée)
//   GET  /lire-notifications?limit=20&offset=0&non_lues_seulement=true
//   POST /lire-notifications
//        Body: { action: "marquer_lue", id: "uuid" }
//        Body: { action: "tout_marquer_lu" }
//
// Correctif §4 : ajout de { count: "exact" } sur .update() pour que
//   updatedCount soit non-null et que le 404 se déclenche correctement.
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";

// ── Helpers ───────────────────────────────────────────────────────────────────

function clampInt(value: string | null, def: number, min: number, max: number): number {
  if (!value) return def;
  const n = parseInt(value, 10);
  if (isNaN(n)) return def;
  return Math.max(min, Math.min(max, n));
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "GET, POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "GET" && req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  // ── Vérification de l'authentification JWT ────────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return jsonResponse({ error: "Token d'authentification manquant." }, 401, corsHeaders);
  }

  const jwtToken = authHeader.replace("Bearer ", "").trim();
  if (!jwtToken) {
    return jsonResponse({ error: "Token d'authentification vide." }, 401, corsHeaders);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // Vérifier le JWT et extraire l'utilisateur
  const { data: userData, error: userError } = await adminClient.auth.getUser(jwtToken);

  if (userError || !userData?.user) {
    console.warn("[lire-notif] JWT invalide:", userError?.message);
    return jsonResponse({ error: "Session invalide ou expirée." }, 401, corsHeaders);
  }

  const userId = userData.user.id;

  // ── GET : lire les notifications ──────────────────────────────────────────
  if (req.method === "GET") {
    const url = new URL(req.url);
    const params = url.searchParams;

    const limit = clampInt(params.get("limit"), 30, 1, 100);
    const offset = clampInt(params.get("offset"), 0, 0, 10000);
    const nonLuesSeulement = params.get("non_lues_seulement") === "true";

    let query = adminClient
      .from("notifications_envoyees")
      .select("id, user_id, demande_id, type, lu, created_at", { count: "exact" })
      .eq("user_id", userId)
      .order("created_at", { ascending: false })
      .range(offset, offset + limit - 1);

    if (nonLuesSeulement) {
      query = query.eq("lu", false);
    }

    const { data: notifications, error: notifError, count } = await query;

    if (notifError) {
      console.error("[lire-notif] Erreur lecture notifications:", notifError);
      return jsonResponse({ error: "Erreur lors de la lecture des notifications." }, 500, corsHeaders);
    }

    // Compter les non-lues séparément (pour le badge)
    const { count: nonLuesCount, error: countError } = await adminClient
      .from("notifications_envoyees")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .eq("lu", false);

    if (countError) {
      console.warn("[lire-notif] Erreur comptage non-lues:", countError);
    }

    return jsonResponse({
      success: true,
      data: notifications ?? [],
      total: count ?? 0,
      non_lues: nonLuesCount ?? 0,
      limit,
      offset,
    }, 200, corsHeaders);
  }

  // ── POST : actions (marquer lue / tout marquer lu) ────────────────────────
  if (req.method === "POST") {
    let body: { action: string; id?: string };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "Body JSON invalide." }, 400, corsHeaders);
    }

    const { action, id } = body;

    if (!action) {
      return jsonResponse({ error: "Champ 'action' requis." }, 400, corsHeaders);
    }

    // Action : marquer une notification précise comme lue
    if (action === "marquer_lue") {
      if (!id) {
        return jsonResponse({ error: "Champ 'id' requis pour marquer_lue." }, 400, corsHeaders);
      }

      const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
      if (!uuidRegex.test(id)) {
        return jsonResponse({ error: "Format 'id' invalide." }, 400, corsHeaders);
      }

      // §4 CORRECTIF : ajout de { count: "exact" } pour que updatedCount soit non-null
      const { error: updateError, count: updatedCount } = await adminClient
        .from("notifications_envoyees")
        .update({ lu: true }, { count: "exact" })   // ← CORRECTIF §4
        .eq("id", id)
        .eq("user_id", userId);

      if (updateError) {
        console.error("[lire-notif] Erreur marquer_lue:", updateError);
        return jsonResponse({ error: "Erreur lors du marquage." }, 500, corsHeaders);
      }

      if (updatedCount === 0) {
        // Notification introuvable ou n'appartient pas à cet utilisateur
        return jsonResponse({ error: "Notification introuvable." }, 404, corsHeaders);
      }

      return jsonResponse({ success: true, action: "marquer_lue", id }, 200, corsHeaders);
    }

    // Action : tout marquer comme lu
    if (action === "tout_marquer_lu") {
      const { error: updateAllError } = await adminClient
        .from("notifications_envoyees")
        .update({ lu: true })
        .eq("user_id", userId)
        .eq("lu", false);

      if (updateAllError) {
        console.error("[lire-notif] Erreur tout_marquer_lu:", updateAllError);
        return jsonResponse({ error: "Erreur lors du marquage global." }, 500, corsHeaders);
      }

      return jsonResponse({ success: true, action: "tout_marquer_lu" }, 200, corsHeaders);
    }

    return jsonResponse({ error: `Action inconnue: ${action}` }, 400, corsHeaders);
  }

  return jsonResponse({ error: "Requête non gérée." }, 400, corsHeaders);
});
