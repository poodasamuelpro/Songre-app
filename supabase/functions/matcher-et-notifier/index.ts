// =============================================================================
// Edge Function : matcher-et-notifier  (v3 — module _shared/)
// Déploiement   : supabase functions deploy matcher-et-notifier
//
// Déclenchement : Webhook base de données Supabase
//   Table   : public.demandes_sang
//   Événement : INSERT
//
// PÉRIMÈTRE STRICT — les logiques suivantes sont identiques à v2 :
//   - estCompatible / COMPATIBILITE_ABO
//   - estEligible (genre-aware 60/90j)
//   - Logique de matching géographique ville_id / ville_libre
//   - getOAuth2AccessToken, envoyerFcmV1 → maintenant dans _shared/fcm.ts
//   - envoyerEmailRotatif                → maintenant dans _shared/email.ts
//
// Variables d'environnement OBLIGATOIRES :
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  — injectées automatiquement
//   WEBHOOK_SECRET   — OBLIGATOIRE (erreur 500 si absent)
//
// Variables FCM HTTP v1 :
//   FCM_SERVICE_ACCOUNT_JSON, FCM_PROJECT_ID
//
// Variables email rotatif :
//   EMAIL_PROVIDER, EMAIL_FROM
//   BREVO_API_KEY, BREVO_API_KEY_2, RESEND_API_KEY, RESEND_API_KEY_2
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { envoyerEmailRotatif, renderTemplate } from "../_shared/email.ts";
import {
  envoyerFcmV1,
  getFcmAccessTokenFromEnv,
  getFcmTokensForUser,
} from "../_shared/fcm.ts";

// ── Types ─────────────────────────────────────────────────────────────────────

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: DemandeSangRecord;
  old_record: DemandeSangRecord | null;
}

// Schéma réel public.demandes_sang (FK entières)
interface DemandeSangRecord {
  id: string;
  auteur_id: string;
  groupe_sanguin_recherche: string;
  ville_id: number | null;       // INTEGER FK → villes.id
  structure_id: number | null;   // INTEGER FK → structures_sanitaires.id
  ville_libre: string | null;
  structure_libre: string | null;
  statut: string;
  expires_at: string;
  created_at: string;
}

// Schéma réel public.profils_donneurs
interface ProfilDonneur {
  user_id: string;
  groupe_sanguin: string;
  genre: string;           // public.genre_enum: "homme" | "femme"
  ville_id: number;        // INTEGER FK → villes.id
  disponible: boolean;
  dernier_don_date: string | null;
}

// ── Compatibilité ABO ─────────────────────────────────────────────────────────
// PÉRIMÈTRE STRICT — ne pas modifier

const COMPATIBILITE_ABO: Record<string, string[]> = {
  "O-":  ["O-"],
  "O+":  ["O-", "O+"],
  "A-":  ["O-", "A-"],
  "A+":  ["O-", "O+", "A-", "A+"],
  "B-":  ["O-", "B-"],
  "B+":  ["O-", "O+", "B-", "B+"],
  "AB-": ["O-", "A-", "B-", "AB-"],
  "AB+": ["O-", "O+", "A-", "A+", "B-", "B+", "AB-", "AB+"],
};

function estCompatible(groupeReceveur: string, groupeDonneur: string): boolean {
  const compatibles = COMPATIBILITE_ABO[groupeReceveur] ?? [];
  return compatibles.includes(groupeDonneur);
}

// ── Délai inter-don GENRE-AWARE ───────────────────────────────────────────────
// PÉRIMÈTRE STRICT — ne pas modifier (femme = 90j, homme/autre = 60j)

function estEligible(profil: ProfilDonneur): boolean {
  if (!profil.dernier_don_date) return true;

  const dernierDon = new Date(profil.dernier_don_date);
  const maintenant = new Date();
  const joursEcoules = Math.floor(
    (maintenant.getTime() - dernierDon.getTime()) / (1000 * 60 * 60 * 24),
  );

  const seuilJours = profil.genre === "femme" ? 90 : 60;
  return joursEcoules >= seuilJours;
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req);
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  // ── Validation WEBHOOK_SECRET — OBLIGATOIRE ───────────────────────────────
  const webhookSecret = Deno.env.get("WEBHOOK_SECRET");
  if (!webhookSecret || webhookSecret.trim().length === 0) {
    console.error("[matcher] WEBHOOK_SECRET manquant — configuration incomplète.");
    return jsonResponse({ error: "Configuration serveur incomplète." }, 500, corsHeaders);
  }

  const receivedSecret = req.headers.get("x-webhook-secret");
  if (receivedSecret !== webhookSecret) {
    console.warn("[matcher] Webhook secret invalide — requête rejetée.");
    return jsonResponse({ error: "Unauthorized." }, 401, corsHeaders);
  }

  // ── Parser le payload ─────────────────────────────────────────────────────
  let payload: WebhookPayload;
  try {
    payload = await req.json() as WebhookPayload;
  } catch {
    return jsonResponse({ error: "Payload JSON invalide." }, 400, corsHeaders);
  }

  // N'agir que sur les INSERTs dans demandes_sang (schéma public)
  if (payload.type !== "INSERT" || payload.table !== "demandes_sang") {
    return jsonResponse({ skipped: true }, 200, corsHeaders);
  }

  const demande = payload.record;

  if (demande.statut !== "active") {
    return jsonResponse({ skipped: "statut non active" }, 200, corsHeaders);
  }

  if (!demande.ville_id && !demande.ville_libre) {
    console.warn("[matcher] Demande sans localisation — ignorée.");
    return jsonResponse({ skipped: "pas de localisation" }, 200, corsHeaders);
  }

  // ── Client admin Supabase ─────────────────────────────────────────────────
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // ── Récupérer le libellé ville/structure pour les notifs ──────────────────
  let villeLabel = demande.ville_libre ?? "ville inconnue";
  let structureLabel = demande.structure_libre ?? "structure inconnue";

  if (demande.ville_id) {
    const { data: villeData } = await adminClient
      .from("villes")
      .select("nom")
      .eq("id", demande.ville_id)
      .maybeSingle();
    if (villeData?.nom) villeLabel = villeData.nom;
  }

  if (demande.structure_id) {
    const { data: structureData } = await adminClient
      .from("structures_sanitaires")
      .select("nom")
      .eq("id", demande.structure_id)
      .maybeSingle();
    if (structureData?.nom) structureLabel = structureData.nom;
  }

  // ── 1. Trouver les donneurs compatibles ───────────────────────────────────
  // PÉRIMÈTRE STRICT — logique de matching inchangée
  let profilQuery = adminClient
    .from("profils_donneurs")
    .select("user_id, groupe_sanguin, genre, ville_id, disponible, dernier_don_date")
    .eq("disponible", true)
    .neq("user_id", demande.auteur_id);

  if (demande.ville_id) {
    profilQuery = profilQuery.eq("ville_id", demande.ville_id);
  }

  const { data: profils, error: profilError } = await profilQuery;

  if (profilError) {
    console.error("[matcher] Erreur lecture profils:", profilError);
    return jsonResponse({ error: "Erreur DB profils." }, 500, corsHeaders);
  }

  if (!profils || profils.length === 0) {
    console.log("[matcher] Aucun donneur disponible pour", villeLabel);
    return jsonResponse({ matched: 0 }, 200, corsHeaders);
  }

  // Filtrer par compatibilité ABO et éligibilité (délai inter-don genre-aware)
  const donneursFiltres = (profils as ProfilDonneur[]).filter((p) =>
    estCompatible(demande.groupe_sanguin_recherche, p.groupe_sanguin) &&
    estEligible(p)
  );

  if (donneursFiltres.length === 0) {
    console.log("[matcher] Aucun donneur compatible pour", demande.groupe_sanguin_recherche);
    return jsonResponse({ matched: 0 }, 200, corsHeaders);
  }

  const donneurIds = donneursFiltres.map((p) => p.user_id);

  // ── 2. Récupérer les emails depuis auth.users (requête bulk) ──────────────
  // ── Correction P-02/R-11 (audit 2026-07-09) ──────────────────────────────
  // Ancienne version : N appels getUserById en parallèle par lots de 50.
  // Pour 100 donneurs = 100 appels Admin API → risque de rate-limit et latence.
  // Correction : une seule requête SQL directe sur auth.users via service_role.
  // adminClient.from() peut accéder à auth.users avec service_role_key.
  const emailsMap = new Map<string, string>();
  if (donneurIds.length > 0) {
    try {
      // Requête bulk : SELECT id, email FROM auth.users WHERE id IN (...)
      const { data: usersRows, error: usersError } = await adminClient
        .from("users")
        .select("id, email")
        .in("id", donneurIds)
        .schema("auth");

      if (usersError) {
        // Fallback vers N+1 si la requête bulk échoue (ex: permissions insuffisantes)
        console.warn("[matcher] Bulk email fetch failed, fallback to N+1:", usersError.message);
        const BATCH_USERS = 50;
        for (let i = 0; i < donneurIds.length; i += BATCH_USERS) {
          const batchIds = donneurIds.slice(i, i + BATCH_USERS);
          await Promise.all(
            batchIds.map(async (uid) => {
              const { data, error } = await adminClient.auth.admin.getUserById(uid);
              if (!error && data?.user?.email) {
                emailsMap.set(uid, data.user.email);
              }
            }),
          );
        }
      } else if (usersRows) {
        for (const u of usersRows as { id: string; email: string }[]) {
          if (u.email) emailsMap.set(u.id, u.email);
        }
        console.log(`[matcher] Bulk email fetch: ${emailsMap.size}/${donneurIds.length} emails récupérés`);
      }
    } catch (bulkErr) {
      console.warn("[matcher] Bulk email error:", bulkErr);
    }
  }

  // ── 3. Récupérer les tokens FCM via _shared/fcm.ts ────────────────────────
  const fcmMultiMap = new Map<string, string[]>();
  await Promise.all(
    donneurIds.map(async (uid) => {
      const tokens = await getFcmTokensForUser(adminClient, uid);
      if (tokens.length > 0) fcmMultiMap.set(uid, tokens);
    }),
  );

  // ── 4. Préparer les données FCM ───────────────────────────────────────────
  const fcmAuth = await getFcmAccessTokenFromEnv();
  if (!fcmAuth) {
    console.warn("[matcher] FCM désactivé pour ce batch.");
  }

  const templateData: Record<string, string> = {
    groupe_sanguin: demande.groupe_sanguin_recherche,
    ville: villeLabel,
    structure: structureLabel,
  };

  const emailSujet = `[SONGRE] Besoin urgent de ${demande.groupe_sanguin_recherche} à ${villeLabel}`;
  const emailHtml = renderTemplate("demande_compatible", templateData);

  const titreNotif = `Besoin de ${demande.groupe_sanguin_recherche} à ${villeLabel}`;
  const corpsNotif = `${structureLabel} cherche un donneur compatible. Répondez maintenant.`;
  const fcmData: Record<string, string> = {
    demande_id: demande.id,
    groupe_sanguin: demande.groupe_sanguin_recherche,
    ville: villeLabel,
    type: "demande_compatible",
  };

  // ── 5. Envoyer notifications + persister ─────────────────────────────────
  let notifCount = 0;
  const notifInserts: Array<{
    user_id: string;
    demande_id: string;
    type: string;
    lu: boolean;
  }> = [];

  const BATCH_SIZE = 10;
  for (let i = 0; i < donneursFiltres.length; i += BATCH_SIZE) {
    const batch = donneursFiltres.slice(i, i + BATCH_SIZE);

    await Promise.all(
      batch.map(async (profil) => {
        let notifieParQuelqueMoyen = false;

        // a. Notification FCM v1 (multi-device) via _shared/fcm.ts
        if (fcmAuth) {
          const tokens = fcmMultiMap.get(profil.user_id) ?? [];
          for (const token of tokens) {
            const ok = await envoyerFcmV1(
              token,
              titreNotif,
              corpsNotif,
              fcmData,
              fcmAuth.accessToken,
              fcmAuth.projectId,
            );
            if (ok) {
              notifieParQuelqueMoyen = true;
              notifCount++;
              break;
            }
          }
        }

        // b. Email rotatif via _shared/email.ts
        const email = emailsMap.get(profil.user_id);
        if (email && emailHtml) {
          const emailResult = await envoyerEmailRotatif(email, emailSujet, emailHtml);
          if (emailResult.success) {
            notifieParQuelqueMoyen = true;
            notifCount++;
          }
        }

        // c. Insérer dans notifications_envoyees si au moins un canal fonctionnel
        if (notifieParQuelqueMoyen) {
          notifInserts.push({
            user_id: profil.user_id,
            demande_id: demande.id,
            type: "demande_compatible",
            lu: false,
          });
        }
      }),
    );
  }

  // ── 6. Persister les notifications en DB ─────────────────────────────────
  if (notifInserts.length > 0) {
    const { error: insertError } = await adminClient
      .from("notifications_envoyees")
      .insert(notifInserts);

    if (insertError) {
      console.error("[matcher] Erreur insert notifications_envoyees:", insertError);
    } else {
      console.log(`[matcher] ${notifInserts.length} notifications persistées en DB.`);
    }
  }

  console.log(
    `[matcher] Demande ${demande.id} (${demande.groupe_sanguin_recherche} @ ${villeLabel}): ` +
    `${donneursFiltres.length} donneurs matchés, ${notifCount} canaux notifiés, ` +
    `${notifInserts.length} entrées DB créées.`,
  );

  return jsonResponse({
    success: true,
    matched: donneursFiltres.length,
    notified: notifCount,
    persisted: notifInserts.length,
  }, 200, corsHeaders);
});
