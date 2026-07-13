// =============================================================================
// Edge Function : bienvenue-auth  (D3 — Cas 8)
// Déploiement   : supabase functions deploy bienvenue-auth
//
// Déclenchement : Webhook Supabase Auth — Event "INSERT" (nouveau compte créé)
//   Configuration dans Supabase Dashboard :
//     Authentication → Hooks → "Auth Hook - Send Email" (ou webhook externe)
//
//   Alternativement : via le hook "After Email Confirmation" sur Auth
//
//   NOTE sur le choix d'implémentation :
//     Option A (retenue) — Webhook Auth sur event "INSERT auth.users"
//       Avantage : déclenchement automatique garanti, pas de code Flutter requis
//       Configuration : Dashboard → Database → Webhooks → Table auth.users, INSERT
//       La table auth.users n'est pas dans le schéma public mais Supabase
//       supporte les webhooks sur cette table via l'UI.
//
//     Option B — Appel direct depuis Flutter après signUp() réussi
//       Inconvénient : si l'appel Flutter échoue, pas de bienvenue.
//       Option A est plus fiable.
//
// Auth : WEBHOOK_SECRET (dans header x-webhook-secret)
//
// Variables d'environnement :
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//   WEBHOOK_SECRET
//   + Variables email/FCM (_shared/)
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { envoyerEmailDirect } from "../_shared/notifier.ts";

// ── Types ─────────────────────────────────────────────────────────────────────

interface AuthWebhookPayload {
  type: string;
  table: string;
  schema: string;
  record: {
    id: string;
    email: string | null;
    email_confirmed_at?: string | null;
    created_at: string;
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

  // ── Validation WEBHOOK_SECRET ─────────────────────────────────────────────
  const webhookSecret = Deno.env.get("WEBHOOK_SECRET");
  if (!webhookSecret || webhookSecret.trim().length === 0) {
    return jsonResponse({ error: "Configuration serveur incomplète." }, 500, corsHeaders);
  }

  const receivedSecret = req.headers.get("x-webhook-secret");
  if (receivedSecret !== webhookSecret) {
    return jsonResponse({ error: "Unauthorized." }, 401, corsHeaders);
  }

  // ── Parser le payload ─────────────────────────────────────────────────────
  let payload: AuthWebhookPayload;
  try {
    payload = await req.json() as AuthWebhookPayload;
  } catch {
    return jsonResponse({ error: "Payload JSON invalide." }, 400, corsHeaders);
  }

  // N'agir que sur les INSERTs dans auth.users
  if (payload.type !== "INSERT" || payload.table !== "users") {
    return jsonResponse({ skipped: "event non pertinent" }, 200, corsHeaders);
  }

  const newUser = payload.record;

  if (!newUser.email) {
    console.warn("[bienvenue-auth] Nouvel utilisateur sans email — ignoré.");
    return jsonResponse({ skipped: "pas d'email" }, 200, corsHeaders);
  }

  // ── Récupérer le prénom depuis les métadonnées ────────────────────────────
  const metaData = newUser.raw_user_meta_data ?? {};
  const prenom = (metaData["full_name"] as string)?.split(" ")?.[0] ??
    (metaData["first_name"] as string) ??
    newUser.email.split("@")[0] ??
    "Donneur";

  // ── Persister dans notifications_envoyees via adminClient ─────────────────
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // ── Correction R-10/2.1.3 (audit 2026-07-09) ────────────────────────────
  // La ligne public.identites DOIT être créée lors de l'inscription pour que
  // programmerSuppression() (PATCH identites?user_id=eq.$userId) fonctionne.
  // Sans cette ligne, la suppression de compte échoue silencieusement.
  // On l'insère ici dans bienvenue-auth (appelé à chaque INSERT auth.users).
  const { error: identiteError } = await adminClient
    .from("identites")
    .upsert(
      { user_id: newUser.id, compte_actif: true },
      { onConflict: "user_id", ignoreDuplicates: true },
    );

  if (identiteError) {
    // Non bloquant — si la table n'existe pas encore, on log et on continue
    console.warn("[bienvenue-auth] Erreur upsert identites:", identiteError.message);
  } else {
    console.log(`[bienvenue-auth] Ligne identites créée/confirmée pour ${newUser.id}`);
  }

  // ── Envoyer l'email de bienvenue ──────────────────────────────────────────
  const emailSent = await envoyerEmailDirect(
    newUser.email,
    "bienvenue",
    { prenom },
  );

  // Persister la notification (non bloquant si erreur)
  if (emailSent) {
    const { error: insertError } = await adminClient
      .from("notifications_envoyees")
      .insert({
        user_id: newUser.id,
        demande_id: null,
        type: "bienvenue",
        lu: false,
      });

    if (insertError) {
      console.warn("[bienvenue-auth] Erreur insert notifications_envoyees:", insertError);
    }
  }

  console.log(
    `[bienvenue-auth] Nouvel utilisateur ${newUser.id}: email envoyé=${emailSent}`,
  );

  return jsonResponse({
    success: true,
    user_id: newUser.id,
    emailSent,
  }, 200, corsHeaders);
});
