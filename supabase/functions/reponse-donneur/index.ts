// =============================================================================
// Edge Function : reponse-donneur  (D3 — Cas 2)
// Déploiement   : supabase functions deploy reponse-donneur
//
// Déclenchement : Webhook base de données Supabase
//   Table    : public.reponses_donneurs
//   Événement : INSERT
//
// Flux :
//   1. Valider WEBHOOK_SECRET
//   2. Extraire la réponse du donneur (INSERT)
//   3. Notifier le DEMANDEUR : type "reponse_recue" — qq a répondu à ta demande
//   4. Notifier le DONNEUR LUI-MÊME : type "reponse_encouragement" — merci, contacte vite
//
// Variables d'environnement :
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — injectées automatiquement
//   WEBHOOK_SECRET — OBLIGATOIRE
//   + Variables email et FCM (voir _shared/)
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { notifierUtilisateur } from "../_shared/notifier.ts";

// ── Schéma public.reponses_donneurs ──────────────────────────────────────────

interface ReponseDonneurRecord {
  id: string;
  donneur_id: string;
  demande_id: string;
  statut: string;  // "en_attente" | "confirme" | "annule"
  created_at: string;
}

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: ReponseDonneurRecord;
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req);
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  // ── Validation WEBHOOK_SECRET ─────────────────────────────────────────────
  const webhookSecret = Deno.env.get("WEBHOOK_SECRET");
  if (!webhookSecret || webhookSecret.trim().length === 0) {
    console.error("[reponse-donneur] WEBHOOK_SECRET manquant.");
    return jsonResponse({ error: "Configuration serveur incomplète." }, 500, corsHeaders);
  }

  const receivedSecret = req.headers.get("x-webhook-secret");
  if (receivedSecret !== webhookSecret) {
    return jsonResponse({ error: "Unauthorized." }, 401, corsHeaders);
  }

  // ── Parser le payload ─────────────────────────────────────────────────────
  let payload: WebhookPayload;
  try {
    payload = await req.json() as WebhookPayload;
  } catch {
    return jsonResponse({ error: "Payload JSON invalide." }, 400, corsHeaders);
  }

  // N'agir que sur les INSERTs dans reponses_donneurs
  if (payload.type !== "INSERT" || payload.table !== "reponses_donneurs") {
    return jsonResponse({ skipped: true }, 200, corsHeaders);
  }

  const reponse = payload.record;

  // ── Client admin ──────────────────────────────────────────────────────────
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // ── Récupérer l'auteur de la demande ──────────────────────────────────────
  const { data: demandeData, error: demandeError } = await adminClient
    .from("demandes_sang")
    .select("id, auteur_id, groupe_sanguin_recherche, ville_id, ville_libre")
    .eq("id", reponse.demande_id)
    .maybeSingle();

  if (demandeError || !demandeData) {
    console.error("[reponse-donneur] Demande introuvable:", reponse.demande_id);
    return jsonResponse({ error: "Demande introuvable." }, 404, corsHeaders);
  }

  // Compter le nombre de réponses pour ce message
  const { count: nbReponses } = await adminClient
    .from("reponses_donneurs")
    .select("id", { count: "exact", head: true })
    .eq("demande_id", reponse.demande_id)
    .neq("statut", "annule");

  const templateDataDemandeur: Record<string, string> = {
    prenom: "", // Sera complété via getUserById côté notifierUtilisateur
    nb_reponses: String(nbReponses ?? 1),
    groupe_sanguin: demandeData.groupe_sanguin_recherche ?? "",
  };

  const templateDataDonneur: Record<string, string> = {
    prenom: "",
  };

  // ── Notifier le DEMANDEUR : "reponse_recue" ───────────────────────────────
  const resultDemandeur = await notifierUtilisateur(
    adminClient,
    demandeData.auteur_id,
    "reponse_recue",
    templateDataDemandeur,
    { demandeId: reponse.demande_id },
  );

  // ── Notifier le DONNEUR : "reponse_encouragement" ────────────────────────
  const resultDonneur = await notifierUtilisateur(
    adminClient,
    reponse.donneur_id,
    "reponse_encouragement",
    templateDataDonneur,
    { demandeId: reponse.demande_id },
  );

  console.log(
    `[reponse-donneur] Demande ${reponse.demande_id}: ` +
    `demandeur notifié=${resultDemandeur.emailSent || resultDemandeur.fcmSent}, ` +
    `donneur notifié=${resultDonneur.emailSent || resultDonneur.fcmSent}`,
  );

  return jsonResponse({
    success: true,
    demandeur: { emailSent: resultDemandeur.emailSent, fcmSent: resultDemandeur.fcmSent },
    donneur: { emailSent: resultDonneur.emailSent, fcmSent: resultDonneur.fcmSent },
  }, 200, corsHeaders);
});
