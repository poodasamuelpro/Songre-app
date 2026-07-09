// =============================================================================
// Edge Function : mdp-modifie-auth  (D3 — Cas 9)
// Déploiement   : supabase functions deploy mdp-modifie-auth
//
// Déclenchement : Webhook Supabase Auth — Event "USER_UPDATED"
//   Configuration dans Supabase Dashboard :
//     Database → Webhooks → Table auth.users, UPDATE
//     (filtrer sur updated_at IS NOT NULL pour éviter les faux déclenchements)
//
//   Alternativement : via Supabase Auth Hook "custom access token" ou
//   l'appel direct depuis Flutter après updatePassword() réussi.
//
//   NOTE sur le choix d'implémentation :
//     Option A (retenue) — Webhook Auth sur event UPDATE auth.users
//       Avantage : déclenchement côté serveur, indépendant de Flutter
//       Limite : se déclenche sur TOUT update user, pas seulement mdp
//       → On filtre via un drapeau dans le header ou en vérifiant
//         que encrypted_password a changé (non accessible depuis le payload)
//
//     Option B — Appel depuis Flutter après updatePassword() réussi
//       Avantage : 100% certain que c'est un changement de mdp
//       → Implémenté aussi dans change_password_screen.dart
//
//   Solution hybride : cette EF accepte les deux modes :
//     - Mode A : webhook (x-webhook-secret + type UPDATE)
//     - Mode B : appel explicite (JWT utilisateur + body {action:"mdp_modifie"})
//
// Variables d'environnement :
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY
//   WEBHOOK_SECRET
//   + Variables email/FCM (_shared/)
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { notifierUtilisateur } from "../_shared/notifier.ts";

// ── Types ─────────────────────────────────────────────────────────────────────

interface AuthUpdatePayload {
  type: "UPDATE";
  table: string;
  schema: string;
  record: {
    id: string;
    email: string | null;
    updated_at: string;
    raw_user_meta_data?: Record<string, unknown>;
  };
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? serviceRoleKey;

  const webhookSecret = Deno.env.get("WEBHOOK_SECRET") ?? "";
  const receivedSecret = req.headers.get("x-webhook-secret") ?? "";
  const authHeader = req.headers.get("Authorization") ?? "";

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // ── Mode A : Webhook DB (x-webhook-secret) ────────────────────────────────
  if (receivedSecret && webhookSecret && receivedSecret === webhookSecret) {
    let payload: AuthUpdatePayload;
    try {
      payload = await req.json() as AuthUpdatePayload;
    } catch {
      return jsonResponse({ error: "Payload JSON invalide." }, 400, corsHeaders);
    }

    // Filtrer sur les updates d'auth.users seulement
    if (payload.type !== "UPDATE" || payload.table !== "users") {
      return jsonResponse({ skipped: true }, 200, corsHeaders);
    }

    const updatedUser = payload.record;
    if (!updatedUser.id) {
      return jsonResponse({ skipped: "user_id manquant" }, 200, corsHeaders);
    }

    const dateHeure = new Date(updatedUser.updated_at).toLocaleString("fr-FR", {
      timeZone: "Africa/Ouagadougou",
    });

    const result = await notifierUtilisateur(
      adminClient,
      updatedUser.id,
      "mdp_modifie",
      { date_heure: dateHeure },
    );

    console.log(`[mdp-modifie] Webhook mode: user ${updatedUser.id}, email=${result.emailSent}`);
    return jsonResponse({
      success: true,
      mode: "webhook",
      emailSent: result.emailSent,
    }, 200, corsHeaders);
  }

  // ── Mode B : Appel explicite depuis Flutter (JWT utilisateur) ─────────────
  if (authHeader.startsWith("Bearer ")) {
    const jwt = authHeader.substring(7);

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false },
    });

    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      return jsonResponse({ error: "JWT invalide ou expiré." }, 401, corsHeaders);
    }

    // Vérifier que le body contient bien l'action attendue
    let body: { action?: string } = {};
    try {
      body = await req.json();
    } catch {
      // Body vide accepté
    }

    if (body.action !== "mdp_modifie") {
      return jsonResponse({ error: "Action 'mdp_modifie' requise." }, 400, corsHeaders);
    }

    const dateHeure = new Date().toLocaleString("fr-FR", {
      timeZone: "Africa/Ouagadougou",
    });

    const result = await notifierUtilisateur(
      adminClient,
      user.id,
      "mdp_modifie",
      { date_heure: dateHeure },
    );

    console.log(`[mdp-modifie] Explicit mode: user ${user.id}, email=${result.emailSent}`);
    return jsonResponse({
      success: true,
      mode: "explicit",
      emailSent: result.emailSent,
      fcmSent: result.fcmSent,
    }, 200, corsHeaders);
  }

  return jsonResponse({ error: "Authentification requise." }, 401, corsHeaders);
});
