// =============================================================================
// Edge Function : reponse-donneur  (D3 — Cas 2, fusionné avec P2 téléphone)
//
// Contexte P2 (2026-07-13) :
//   Le champ `telephone_chiffre` a été ajouté à public.profils_donneurs.
//   Quand un donneur a renseigné son téléphone, l'application Flutter
//   l'affiche désormais au demandeur après réponse confirmée.
//
// Fusion avec le correctif prénom déjà validé précédemment :
//   Les clés `prenom` ne doivent JAMAIS être envoyées vides ("") dans
//   templateData, car `data["prenom"] ?? "Demandeur"` ne remplace que
//   null/undefined, jamais une chaîne vide — "" écrase silencieusement
//   le message par défaut ("Bonjour ," au lieu de "Bonjour Demandeur,").
//   On omet donc complètement la clé si on n'a pas de vraie valeur.
//
// Déclenchement : Webhook base de données Supabase
//   Table    : public.reponses_donneurs
//   Événement : INSERT
//
// Flux :
//   1. Valider WEBHOOK_SECRET
//   2. Extraire la réponse du donneur (INSERT)
//   3. Lire telephone_chiffre du donneur → déterminer has_telephone
//   4. Notifier le DEMANDEUR : type "reponse_recue" + has_telephone dans FCM data
//   5. Notifier le DONNEUR LUI-MÊME : type "reponse_encouragement"
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

  // ── [P2] Vérifier si le donneur a un téléphone enregistré ─────────────────
  // On ne déchiffre pas côté EF (pas de clé AES disponible ici).
  // On vérifie seulement la présence de la colonne pour enrichir la notif FCM.
  let hasTelephone = false;
  try {
    const { data: profilDonneurData } = await adminClient
      .from("profils_donneurs")
      .select("telephone_chiffre")
      .eq("user_id", reponse.donneur_id)
      .maybeSingle();

    hasTelephone = !!(
      profilDonneurData?.telephone_chiffre &&
      (profilDonneurData.telephone_chiffre as string).trim().length > 0
    );
  } catch (err) {
    // Non bloquant — si la colonne n'existe pas encore (migration non appliquée),
    // on continue avec hasTelephone = false (comportement identique à l'original).
    console.warn("[reponse-donneur] telephone_chiffre non disponible:", err);
  }

  // Compter le nombre de réponses pour ce message
  const { count: nbReponses } = await adminClient
    .from("reponses_donneurs")
    .select("id", { count: "exact", head: true })
    .eq("demande_id", reponse.demande_id)
    .neq("statut", "annule");

  // ── CORRECTIF PRÉNOM ──────────────────────────────────────────────────────
  // Ne JAMAIS inclure "prenom: ''" — omettre la clé entièrement permet à
  // renderTemplate() d'appliquer son message par défaut ("Demandeur"/"Donneur")
  // via l'opérateur ?? côté _shared/email.ts.
  const templateDataDemandeur: Record<string, string> = {
    nb_reponses: String(nbReponses ?? 1),
    groupe_sanguin: demandeData.groupe_sanguin_recherche ?? "",
    // [P2] Indicateur de présence de téléphone donneur.
    // Utilisable par le template email si besoin d'un message conditionnel.
    has_telephone: hasTelephone ? "true" : "false",
  };

  const templateDataDonneur: Record<string, string> = {};

  // ── [P2] Corps FCM adapté selon présence du téléphone ─────────────────────
  // Si le donneur a fourni son numéro, le message FCM guide le demandeur
  // vers la consultation du contact directement dans l'app.
  const fcmCorpsDemandeur = hasTelephone
    ? "Ouvrez l'app pour consulter son numéro de téléphone et l'appeler."
    : "Ouvrez l'app pour consulter ses coordonnées et l'appeler.";

  // ── Notifier le DEMANDEUR : "reponse_recue" ───────────────────────────────
  const resultDemandeur = await notifierUtilisateur(
    adminClient,
    demandeData.auteur_id,
    "reponse_recue",
    templateDataDemandeur,
    {
      demandeId: reponse.demande_id,
      // [P2] Corps FCM personnalisé selon disponibilité du téléphone
      fcmCorps: fcmCorpsDemandeur,
      // Données FCM supplémentaires pour l'app Flutter (décision d'affichage côté client)
      fcmData: {
        has_telephone: hasTelephone ? "true" : "false",
        demande_id: reponse.demande_id,
      },
    },
  );

  // ── Notifier le DONNEUR : "reponse_encouragement" ────────────────────────
  // Inchangé par rapport à l'original.
  const resultDonneur = await notifierUtilisateur(
    adminClient,
    reponse.donneur_id,
    "reponse_encouragement",
    templateDataDonneur,
    { demandeId: reponse.demande_id },
  );

  console.log(
    `[reponse-donneur] Demande ${reponse.demande_id}: ` +
    `has_telephone=${hasTelephone}, ` +
    `demandeur notifié=${resultDemandeur.emailSent || resultDemandeur.fcmSent}, ` +
    `donneur notifié=${resultDonneur.emailSent || resultDonneur.fcmSent}`,
  );

  return jsonResponse({
    success: true,
    has_telephone: hasTelephone,
    demandeur: { emailSent: resultDemandeur.emailSent, fcmSent: resultDemandeur.fcmSent },
    donneur: { emailSent: resultDonneur.emailSent, fcmSent: resultDonneur.fcmSent },
  }, 200, corsHeaders);
});
