// =============================================================================
// Edge Function : lire-notifications
// Déploiement   : supabase functions deploy lire-notifications
//
// Rôle : Retourner les notifications de l'utilisateur connecté depuis
//        public.notifications_envoyees, avec pagination et marquage de lecture.
//
// Endpoints supportés :
//   GET  /lire-notifications              → liste des notifications (paginée)
//   GET  /lire-notifications?limit=20&offset=0&non_lues_seulement=true
//   POST /lire-notifications              → marquer notification(s) comme lue(s)
//        Body: { action: "marquer_lue", id: "uuid" }
//        Body: { action: "tout_marquer_lu" }
//
// Sécurité :
//   - Authentification JWT Supabase obligatoire (Bearer token)
//   - L'utilisateur ne peut accéder qu'à SES notifications (RLS + filtre user_id)
//   - CORS restrictif via ALLOWED_ORIGIN
//
// Schéma notifications_envoyees (réel) :
//   id uuid PK, user_id uuid, demande_id uuid?, type enum, lu boolean, created_at
//
// Variables d'environnement :
//   SUPABASE_URL                 — injectée automatiquement
//   SUPABASE_ANON_KEY            — injectée automatiquement
//   SUPABASE_SERVICE_ROLE_KEY    — injectée automatiquement
//   ALLOWED_ORIGIN               — domaine de prod, ex: "https://songre.bf"
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── CORS restrictif ──────────────────────────────────────────────────────────

function getCorsHeaders(): Record<string, string> {
  const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN") ?? "https://songre.bf";
  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Max-Age": "86400",
  };
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...getCorsHeaders() },
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function clampInt(value: string | null, def: number, min: number, max: number): number {
  if (!value) return def;
  const n = parseInt(value, 10);
  if (isNaN(n)) return def;
  return Math.max(min, Math.min(max, n));
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  // ── Preflight CORS ────────────────────────────────────────────────────────
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: getCorsHeaders() });
  }

  if (req.method !== "GET" && req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405);
  }

  // ── Vérification de l'authentification JWT ────────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return jsonResponse({ error: "Token d'authentification manquant." }, 401);
  }

  const jwtToken = authHeader.replace("Bearer ", "").trim();
  if (!jwtToken) {
    return jsonResponse({ error: "Token d'authentification vide." }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Client admin pour vérifier le JWT et effectuer les opérations
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // Vérifier le JWT et extraire l'utilisateur
  const { data: userData, error: userError } = await adminClient.auth.getUser(jwtToken);

  if (userError || !userData?.user) {
    console.warn("[lire-notif] JWT invalide:", userError?.message);
    return jsonResponse({ error: "Session invalide ou expirée." }, 401);
  }

  const userId = userData.user.id;

  // ── GET : lire les notifications ──────────────────────────────────────────
  if (req.method === "GET") {
    const url = new URL(req.url);
    const params = url.searchParams;

    const limit = clampInt(params.get("limit"), 30, 1, 100);
    const offset = clampInt(params.get("offset"), 0, 0, 10000);
    const nonLuesSeulement = params.get("non_lues_seulement") === "true";

    // Requête sur public.notifications_envoyees
    // Schéma réel : {id, user_id, demande_id, type, lu, created_at}
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
      return jsonResponse({ error: "Erreur lors de la lecture des notifications." }, 500);
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
    }, 200);
  }

  // ── POST : actions (marquer lue / tout marquer lu) ────────────────────────
  if (req.method === "POST") {
    let body: { action: string; id?: string };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "Body JSON invalide." }, 400);
    }

    const { action, id } = body;

    if (!action) {
      return jsonResponse({ error: "Champ 'action' requis." }, 400);
    }

    // Action : marquer une notification précise comme lue
    if (action === "marquer_lue") {
      if (!id) {
        return jsonResponse({ error: "Champ 'id' requis pour marquer_lue." }, 400);
      }

      // Valider l'UUID (format basique)
      const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
      if (!uuidRegex.test(id)) {
        return jsonResponse({ error: "Format 'id' invalide." }, 400);
      }

      // UPDATE avec filtre user_id → seul l'auteur peut marquer la sienne
      const { error: updateError, count: updatedCount } = await adminClient
        .from("notifications_envoyees")
        .update({ lu: true })
        .eq("id", id)
        .eq("user_id", userId); // Sécurité : ne peut modifier que SES notifications

      if (updateError) {
        console.error("[lire-notif] Erreur marquer_lue:", updateError);
        return jsonResponse({ error: "Erreur lors du marquage." }, 500);
      }

      if (updatedCount === 0) {
        // Notification introuvable ou n'appartient pas à cet utilisateur
        return jsonResponse({ error: "Notification introuvable." }, 404);
      }

      return jsonResponse({ success: true, action: "marquer_lue", id }, 200);
    }

    // Action : tout marquer comme lu
    if (action === "tout_marquer_lu") {
      const { error: updateAllError } = await adminClient
        .from("notifications_envoyees")
        .update({ lu: true })
        .eq("user_id", userId)
        .eq("lu", false); // Seulement les non-lues (optimisation)

      if (updateAllError) {
        console.error("[lire-notif] Erreur tout_marquer_lu:", updateAllError);
        return jsonResponse({ error: "Erreur lors du marquage global." }, 500);
      }

      return jsonResponse({ success: true, action: "tout_marquer_lu" }, 200);
    }

    return jsonResponse({ error: `Action inconnue: ${action}` }, 400);
  }

  // Ne devrait jamais arriver (méthodes filtrées plus haut)
  return jsonResponse({ error: "Requête non gérée." }, 400);
});
