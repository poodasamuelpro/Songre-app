// =============================================================================
// Edge Function : don-manuel  (D3 — Cas 4)
// Déploiement   : supabase functions deploy don-manuel
//
// Rôle : Enregistre un don déclaratif (hors application) pour un donneur
//        authentifié, puis envoie la notification "don_enregistre_manuel".
//
// Context : Dans l'app Flutter, profil_screen.dart appelle state.declarerDon()
//   qui appelle SupabaseService.enregistrerDon() via REST direct.
//   Cette EF centralise l'opération côté serveur pour pouvoir déclencher
//   la notification de manière fiable.
//
// Payload POST JSON :
//   { "date_don": "2025-01-15" }   — date ISO YYYY-MM-DD (obligatoire)
//
// Auth : Bearer <access_token> (JWT Supabase authentifié)
//
// Variables d'environnement :
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY
//   + Variables email/FCM (_shared/)
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { notifierUtilisateur } from "../_shared/notifier.ts";

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  // ── Authentification JWT ───────────────────────────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return jsonResponse({ error: "Token manquant." }, 401, corsHeaders);
  }
  const jwt = authHeader.substring(7);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? serviceRoleKey;

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false },
  });

  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return jsonResponse({ error: "JWT invalide ou expiré." }, 401, corsHeaders);
  }

  // ── Parser le body ─────────────────────────────────────────────────────────
  let body: { date_don?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Body JSON invalide." }, 400, corsHeaders);
  }

  const { date_don } = body;

  if (!date_don || typeof date_don !== "string") {
    return jsonResponse({ error: "Champ 'date_don' manquant (format YYYY-MM-DD)." }, 400, corsHeaders);
  }

  // Validation format date
  const dateRegex = /^\d{4}-\d{2}-\d{2}$/;
  if (!dateRegex.test(date_don)) {
    return jsonResponse({ error: "Format 'date_don' invalide. Attendu: YYYY-MM-DD." }, 400, corsHeaders);
  }

  const dateDon = new Date(date_don);
  if (isNaN(dateDon.getTime()) || dateDon > new Date()) {
    return jsonResponse({ error: "Date de don invalide ou dans le futur." }, 400, corsHeaders);
  }

  // ── Mettre à jour public.profils_donneurs (dernier_don_date) ──────────────
  const { error: updateError } = await adminClient
    .from("profils_donneurs")
    .update({ dernier_don_date: date_don })
    .eq("user_id", user.id);

  if (updateError) {
    console.error("[don-manuel] Erreur mise à jour profil:", updateError);
    return jsonResponse({ error: "Erreur lors de la mise à jour du profil." }, 500, corsHeaders);
  }

  // ── Insérer dans public.historique_dons ────────────────────────────────────
  const { error: donError } = await adminClient
    .from("historique_dons")
    .insert({
      donneur_id: user.id,
      demande_id: null,           // Don déclaratif — pas lié à une demande
      date_don: date_don,
      source: "declaratif",
    });

  if (donError) {
    // Non bloquant — le profil a déjà été mis à jour
    console.error("[don-manuel] Erreur insert historique_dons:", donError);
  }

  // ── Envoyer la notification "don_enregistre_manuel" ────────────────────────
  const dateStr = dateDon.toLocaleDateString("fr-FR");

  const notifResult = await notifierUtilisateur(
    adminClient,
    user.id,
    "don_enregistre_manuel",
    { date: dateStr },
    { skipDbInsert: false },
  ).catch((err) => {
    console.error("[don-manuel] Erreur notification:", err);
    return null;
  });

  console.log(
    `[don-manuel] User ${user.id}: don enregistré le ${date_don}, ` +
    `notif email=${notifResult?.emailSent}, fcm=${notifResult?.fcmSent}`,
  );

  return jsonResponse({
    success: true,
    date_don,
    notification: {
      emailSent: notifResult?.emailSent ?? false,
      fcmSent: notifResult?.fcmSent ?? false,
    },
  }, 200, corsHeaders);
});
