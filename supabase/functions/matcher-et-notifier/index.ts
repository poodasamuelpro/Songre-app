// =============================================================================
// Edge Function : matcher-et-notifier  (v2 — schéma public, FCM HTTP v1, email rotatif)
// Déploiement   : supabase functions deploy matcher-et-notifier
//
// Déclenchement : Webhook base de données Supabase
//   Table   : public.demandes_sang
//   Événement : INSERT
//   Payload : { type: "INSERT", table: "demandes_sang", schema: "public", record: {...} }
//
// Flux :
//   1. Valider signature webhook (WEBHOOK_SECRET — OBLIGATOIRE)
//   2. Extraire la nouvelle demande
//   3. Trouver donneurs compatibles (ABO + ville_id + disponible + délai genre-aware)
//   4. Pour chaque donneur :
//      a. Récupérer email depuis auth.users (admin listUsers)
//      b. Récupérer fcm_token depuis public.device_tokens
//      c. Envoyer notification FCM v1 (OAuth2 service account)
//      d. Envoyer email via système rotatif Brevo → Resend
//      e. Insérer dans public.notifications_envoyees ({user_id, demande_id, type, lu})
//
// Variables d'environnement OBLIGATOIRES :
//   SUPABASE_URL                 — injectée automatiquement
//   SUPABASE_SERVICE_ROLE_KEY    — injectée automatiquement
//   WEBHOOK_SECRET               — secret webhook (OBLIGATOIRE — erreur 500 si absent)
//   ALLOWED_ORIGIN               — domaine de prod, ex: "https://songre.bf"
//
// Variables FCM HTTP v1 (OAuth2) :
//   FCM_SERVICE_ACCOUNT_JSON     — JSON complet du service account Firebase (string)
//   FCM_PROJECT_ID               — project_id Firebase, ex: "songre-app"
//
// Variables email rotatif :
//   EMAIL_PROVIDER               — "brevo" | "resend" | "auto" (défaut: "auto")
//   EMAIL_FROM                   — ex: "SONGRE <noreply@songre.bf>"
//   BREVO_API_KEY                — clé API Brevo (anciennement Sendinblue)
//   BREVO_API_KEY_2              — clé API Brevo secondaire (rotation)
//   RESEND_API_KEY               — clé API Resend
//   RESEND_API_KEY_2             — clé API Resend secondaire (rotation)
//
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

// public.device_tokens
interface DeviceToken {
  user_id: string;
  fcm_token: string;
  plateforme: string | null;
}

// ── CORS restrictif ──────────────────────────────────────────────────────────

function getCorsHeaders(): Record<string, string> {
  const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN") ?? "https://songre.bf";
  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-webhook-secret",
    "Access-Control-Max-Age": "86400",
  };
}

function jsonResponse(
  body: unknown,
  status: number,
  extraHeaders?: Record<string, string>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...getCorsHeaders(),
      ...(extraHeaders ?? {}),
    },
  });
}

// ── Compatibilité ABO ─────────────────────────────────────────────────────────
// Miroir de public.est_compatible_abo() et DemandeSang._groupesCompatibles()

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
// Miroir de public.verifier_eligibilite_donneur() :
//   - Femme : 90 jours minimum entre deux dons
//   - Homme et autres genres : 60 jours minimum
//
// IMPORTANT : le trigger trg_verifier_eligibilite valide à nouveau côté DB.
// Ce filtre côté EF évite d'envoyer des notifications inutiles à des donneurs
// inéligibles — il ne se substitue pas à la contrainte DB.

function estEligible(profil: ProfilDonneur): boolean {
  if (!profil.dernier_don_date) return true;

  const dernierDon = new Date(profil.dernier_don_date);
  const maintenant = new Date();
  const joursEcoules = Math.floor(
    (maintenant.getTime() - dernierDon.getTime()) / (1000 * 60 * 60 * 24),
  );

  // Genre-aware : femme = 90 jours, homme/autre = 60 jours
  const seuilJours = profil.genre === "femme" ? 90 : 60;
  return joursEcoules >= seuilJours;
}

// ── FCM HTTP v1 (OAuth2 service account) ─────────────────────────────────────
//
// L'API Legacy (https://fcm.googleapis.com/fcm/send) est dépréciée depuis juin 2023.
// FCM v1 utilise OAuth2 avec un service account JSON.
//
// Flux :
//   1. Parser FCM_SERVICE_ACCOUNT_JSON
//   2. Créer un JWT signé avec la clé privée du service account
//   3. Échanger le JWT contre un access_token OAuth2 (https://oauth2.googleapis.com/token)
//   4. POST sur https://fcm.googleapis.com/v1/projects/{projectId}/messages:send
//

async function getOAuth2AccessToken(serviceAccountJson: string): Promise<string | null> {
  try {
    const sa = JSON.parse(serviceAccountJson);
    const privateKey = sa.private_key as string;
    const clientEmail = sa.client_email as string;

    const now = Math.floor(Date.now() / 1000);
    const expiry = now + 3600;

    // Header JWT
    const header = { alg: "RS256", typ: "JWT" };
    // Claim JWT
    const claim = {
      iss: clientEmail,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: expiry,
    };

    const encode = (obj: unknown) =>
      btoa(JSON.stringify(obj))
        .replace(/\+/g, "-")
        .replace(/\//g, "_")
        .replace(/=+$/, "");

    const headerB64 = encode(header);
    const claimB64 = encode(claim);
    const signingInput = `${headerB64}.${claimB64}`;

    // Importer la clé privée RSA
    const pemBody = privateKey
      .replace("-----BEGIN PRIVATE KEY-----", "")
      .replace("-----END PRIVATE KEY-----", "")
      .replace(/\s/g, "");
    const keyData = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

    const cryptoKey = await crypto.subtle.importKey(
      "pkcs8",
      keyData.buffer,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );

    const signatureBuffer = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      cryptoKey,
      new TextEncoder().encode(signingInput),
    );

    const signatureB64 = btoa(
      String.fromCharCode(...new Uint8Array(signatureBuffer)),
    )
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");

    const jwt = `${signingInput}.${signatureB64}`;

    // Échanger le JWT contre un access_token
    const tokenResp = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwt,
      }),
    });

    if (!tokenResp.ok) {
      const err = await tokenResp.text();
      console.error("[matcher] OAuth2 token error:", tokenResp.status, err);
      return null;
    }

    const tokenData = await tokenResp.json();
    return tokenData.access_token as string;
  } catch (err) {
    console.error("[matcher] getOAuth2AccessToken error:", err);
    return null;
  }
}

async function envoyerFcmV1(
  fcmToken: string,
  titre: string,
  corps: string,
  data: Record<string, string>,
  accessToken: string,
  projectId: string,
): Promise<boolean> {
  try {
    const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

    const message = {
      message: {
        token: fcmToken,
        notification: { title: titre, body: corps },
        data,
        android: { priority: "high" },
        apns: {
          payload: { aps: { sound: "default", badge: 1 } },
        },
      },
    };

    const resp = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify(message),
    });

    if (!resp.ok) {
      const errBody = await resp.text();
      console.error("[matcher] FCM v1 error:", resp.status, errBody);
      return false;
    }

    return true;
  } catch (err) {
    console.error("[matcher] FCM v1 fetch error:", err);
    return false;
  }
}

// ── Email rotatif Brevo + Resend ─────────────────────────────────────────────
//
// Ordre de tentative selon EMAIL_PROVIDER :
//   "brevo"  → Brevo key1 → Brevo key2 → abandon
//   "resend" → Resend key1 → Resend key2 → abandon
//   "auto"   → Brevo key1 → Brevo key2 → Resend key1 → Resend key2
//              (si Brevo absent, démarre directement sur Resend)
//
// Chaque clé est essayée indépendamment — si l'une échoue (rate limit,
// clé révoquée, erreur réseau), on passe automatiquement à la suivante.
//

interface EmailResult {
  success: boolean;
  provider?: string;
  key?: string;
}

async function envoyerViaBrevo(
  apiKey: string,
  from: string,
  destinataire: string,
  sujet: string,
  htmlBody: string,
): Promise<boolean> {
  try {
    // Extraire "Nom <email>" ou utiliser tel quel
    const fromMatch = from.match(/^(.+?)\s*<(.+?)>$/);
    const senderName = fromMatch ? fromMatch[1].trim() : "SONGRE";
    const senderEmail = fromMatch ? fromMatch[2].trim() : from;

    const resp = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "api-key": apiKey,
      },
      body: JSON.stringify({
        sender: { name: senderName, email: senderEmail },
        to: [{ email: destinataire }],
        subject: sujet,
        htmlContent: htmlBody,
      }),
    });

    if (!resp.ok) {
      const errBody = await resp.text();
      console.warn("[matcher] Brevo error:", resp.status, errBody.slice(0, 200));
      return false;
    }
    return true;
  } catch (err) {
    console.warn("[matcher] Brevo fetch error:", err);
    return false;
  }
}

async function envoyerViaResend(
  apiKey: string,
  from: string,
  destinataire: string,
  sujet: string,
  htmlBody: string,
): Promise<boolean> {
  try {
    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        from,
        to: [destinataire],
        subject: sujet,
        html: htmlBody,
      }),
    });

    if (!resp.ok) {
      const errBody = await resp.text();
      console.warn("[matcher] Resend error:", resp.status, errBody.slice(0, 200));
      return false;
    }
    return true;
  } catch (err) {
    console.warn("[matcher] Resend fetch error:", err);
    return false;
  }
}

async function envoyerEmailRotatif(
  destinataire: string,
  sujet: string,
  htmlBody: string,
): Promise<EmailResult> {
  const emailFrom = Deno.env.get("EMAIL_FROM") ?? "SONGRE <noreply@songre.bf>";
  const provider = (Deno.env.get("EMAIL_PROVIDER") ?? "auto").toLowerCase();

  // Collecter les paires [fournisseur, clé] selon la stratégie
  type Tentative = { provider: "brevo" | "resend"; key: string; label: string };
  const tentatives: Tentative[] = [];

  if (provider === "brevo") {
    const k1 = Deno.env.get("BREVO_API_KEY");
    const k2 = Deno.env.get("BREVO_API_KEY_2");
    if (k1) tentatives.push({ provider: "brevo", key: k1, label: "Brevo/key1" });
    if (k2) tentatives.push({ provider: "brevo", key: k2, label: "Brevo/key2" });
  } else if (provider === "resend") {
    const k1 = Deno.env.get("RESEND_API_KEY");
    const k2 = Deno.env.get("RESEND_API_KEY_2");
    if (k1) tentatives.push({ provider: "resend", key: k1, label: "Resend/key1" });
    if (k2) tentatives.push({ provider: "resend", key: k2, label: "Resend/key2" });
  } else {
    // "auto" : Brevo en priorité, Resend en fallback
    const bk1 = Deno.env.get("BREVO_API_KEY");
    const bk2 = Deno.env.get("BREVO_API_KEY_2");
    const rk1 = Deno.env.get("RESEND_API_KEY");
    const rk2 = Deno.env.get("RESEND_API_KEY_2");
    if (bk1) tentatives.push({ provider: "brevo", key: bk1, label: "Brevo/key1" });
    if (bk2) tentatives.push({ provider: "brevo", key: bk2, label: "Brevo/key2" });
    if (rk1) tentatives.push({ provider: "resend", key: rk1, label: "Resend/key1" });
    if (rk2) tentatives.push({ provider: "resend", key: rk2, label: "Resend/key2" });
  }

  if (tentatives.length === 0) {
    console.warn("[matcher] Aucune clé email configurée — email ignoré.");
    return { success: false };
  }

  for (const t of tentatives) {
    let ok = false;
    if (t.provider === "brevo") {
      ok = await envoyerViaBrevo(t.key, emailFrom, destinataire, sujet, htmlBody);
    } else {
      ok = await envoyerViaResend(t.key, emailFrom, destinataire, sujet, htmlBody);
    }

    if (ok) {
      console.log(`[matcher] Email envoyé via ${t.label} → ${destinataire}`);
      return { success: true, provider: t.provider, key: t.label };
    }
    console.warn(`[matcher] ${t.label} échoué, tentative suivante...`);
  }

  return { success: false };
}

// ── Template email HTML ───────────────────────────────────────────────────────

function genererEmailHtml(
  groupeSanguin: string,
  villeLabel: string,
  structureLabel: string,
): string {
  return `
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>Demande de don de sang — SONGRE</title>
</head>
<body style="font-family: Arial, sans-serif; background: #f9f9f9; margin: 0; padding: 20px;">
  <div style="max-width: 560px; margin: 0 auto; background: #fff;
              border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.08);">
    <div style="text-align: center; margin-bottom: 24px;">
      <span style="font-size: 40px;">&#x1F9B8;</span>
      <h2 style="color: #C0392B; margin: 8px 0 0;">Besoin urgent de sang</h2>
    </div>
    <p style="color: #333; font-size: 16px; line-height: 1.6;">
      Une demande de don de type <strong>${groupeSanguin}</strong>
      vient d'être publiée à <strong>${villeLabel}</strong>.
    </p>
    <div style="background: #fff5f5; border-left: 4px solid #C0392B;
                padding: 16px; border-radius: 6px; margin: 20px 0;">
      <p style="margin: 0; font-size: 15px; color: #555;">
        &#128205; <strong>Structure :</strong> ${structureLabel}
      </p>
    </div>
    <p style="color: #555; font-size: 14px; line-height: 1.6;">
      Si votre groupe sanguin est compatible et que vous êtes disponible,
      ouvrez l'application SONGRE pour répondre à cette demande.
    </p>
    <div style="text-align: center; margin-top: 28px;">
      <a href="https://songre.bf/app"
         style="background: #C0392B; color: white; text-decoration: none;
                padding: 12px 28px; border-radius: 8px; font-weight: bold; font-size: 15px;">
        Ouvrir SONGRE
      </a>
    </div>
    <hr style="border: none; border-top: 1px solid #eee; margin: 28px 0;">
    <p style="color: #999; font-size: 12px; text-align: center;">
      Vous recevez cet email car vous êtes inscrit(e) comme donneur de sang sur SONGRE.
      Pour modifier vos préférences, accédez à votre profil dans l'application.
    </p>
  </div>
</body>
</html>`.trim();
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  // ── Preflight CORS ────────────────────────────────────────────────────────
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: getCorsHeaders() });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405);
  }

  // ── Validation WEBHOOK_SECRET — OBLIGATOIRE ───────────────────────────────
  const webhookSecret = Deno.env.get("WEBHOOK_SECRET");
  if (!webhookSecret || webhookSecret.trim().length === 0) {
    console.error("[matcher] WEBHOOK_SECRET manquant — configuration incomplète.");
    return jsonResponse({ error: "Configuration serveur incomplète." }, 500);
  }

  const receivedSecret = req.headers.get("x-webhook-secret");
  if (receivedSecret !== webhookSecret) {
    console.warn("[matcher] Webhook secret invalide — requête rejetée.");
    return jsonResponse({ error: "Unauthorized." }, 401);
  }

  // ── Parser le payload ─────────────────────────────────────────────────────
  let payload: WebhookPayload;
  try {
    payload = await req.json() as WebhookPayload;
  } catch {
    return jsonResponse({ error: "Payload JSON invalide." }, 400);
  }

  // N'agir que sur les INSERTs dans demandes_sang (schéma public)
  if (payload.type !== "INSERT" || payload.table !== "demandes_sang") {
    return jsonResponse({ skipped: true }, 200);
  }

  const demande = payload.record;

  if (demande.statut !== "active") {
    return jsonResponse({ skipped: "statut non active" }, 200);
  }

  // demande sans ville_id ET sans ville_libre : cas invalide (viole la contrainte DB)
  if (!demande.ville_id && !demande.ville_libre) {
    console.warn("[matcher] Demande sans localisation — ignorée.");
    return jsonResponse({ skipped: "pas de localisation" }, 200);
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
  // Filtre primaire : même ville_id + disponible=true + pas l'auteur
  // Le filtre ABO + délai est appliqué en mémoire ensuite.
  //
  // NOTE : si la demande utilise ville_libre (structure hors liste), on ne peut
  // pas matcher par ville_id → on élargit à tous les donneurs disponibles
  // compatibles ABO dans tout le pays (notification nationale).
  //
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
    return jsonResponse({ error: "Erreur DB profils." }, 500);
  }

  if (!profils || profils.length === 0) {
    console.log("[matcher] Aucun donneur disponible pour", villeLabel);
    return jsonResponse({ matched: 0 }, 200);
  }

  // Filtrer par compatibilité ABO et éligibilité (délai inter-don genre-aware)
  const donneursFiltres = (profils as ProfilDonneur[]).filter((p) =>
    estCompatible(demande.groupe_sanguin_recherche, p.groupe_sanguin) &&
    estEligible(p)
  );

  if (donneursFiltres.length === 0) {
    console.log("[matcher] Aucun donneur compatible pour", demande.groupe_sanguin_recherche);
    return jsonResponse({ matched: 0 }, 200);
  }

  const donneurIds = donneursFiltres.map((p) => p.user_id);

  // ── 2. Récupérer les emails depuis auth.users (admin API) ─────────────────
  // La table public.identites ne contient PAS d'email (colonne inexistante).
  // Les emails sont dans auth.users — accessibles uniquement via Admin API.
  const emailsMap = new Map<string, string>();

  // Récupérer par batch de 50 (limite listUsers)
  const BATCH_USERS = 50;
  for (let i = 0; i < donneurIds.length; i += BATCH_USERS) {
    const batchIds = donneurIds.slice(i, i + BATCH_USERS);
    // Utiliser l'API admin REST directement (adminClient.auth.admin.listUsers
    // ne supporte pas de filtre par IDs, on utilise getUserById en parallèle)
    const emailPromises = batchIds.map(async (uid) => {
      const { data, error } = await adminClient.auth.admin.getUserById(uid);
      if (!error && data?.user?.email) {
        emailsMap.set(uid, data.user.email);
      }
    });
    await Promise.all(emailPromises);
  }

  // ── 3. Récupérer les tokens FCM depuis public.device_tokens ──────────────
  // La table public.identites ne contient PAS de fcm_token.
  // Les tokens FCM sont dans public.device_tokens.
  const fcmMap = new Map<string, string>();

  const { data: deviceTokens, error: dtError } = await adminClient
    .from("device_tokens")
    .select("user_id, fcm_token")
    .in("user_id", donneurIds);

  if (dtError) {
    console.warn("[matcher] Erreur lecture device_tokens:", dtError);
    // Non bloquant — on continue sans FCM
  } else {
    (deviceTokens as DeviceToken[] ?? []).forEach((dt) => {
      // En cas de plusieurs tokens par user (multi-device), on garde le dernier
      // Note : la table a une contrainte UNIQUE(fcm_token), pas UNIQUE(user_id)
      // → possible de notifier plusieurs appareils en itérant
      fcmMap.set(dt.user_id, dt.fcm_token);
    });
  }

  // Gérer plusieurs tokens FCM par utilisateur (multi-device)
  const fcmMultiMap = new Map<string, string[]>();
  (deviceTokens as DeviceToken[] ?? []).forEach((dt) => {
    const existing = fcmMultiMap.get(dt.user_id) ?? [];
    existing.push(dt.fcm_token);
    fcmMultiMap.set(dt.user_id, existing);
  });

  // ── 4. Préparer les données FCM ───────────────────────────────────────────
  const fcmServiceAccountJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  const fcmProjectId = Deno.env.get("FCM_PROJECT_ID");

  let fcmAccessToken: string | null = null;
  if (fcmServiceAccountJson && fcmProjectId) {
    fcmAccessToken = await getOAuth2AccessToken(fcmServiceAccountJson);
    if (!fcmAccessToken) {
      console.warn("[matcher] Impossible d'obtenir le token OAuth2 FCM — FCM désactivé.");
    }
  } else {
    console.warn("[matcher] FCM_SERVICE_ACCOUNT_JSON ou FCM_PROJECT_ID manquant — FCM ignoré.");
  }

  const titreNotif = `Besoin de ${demande.groupe_sanguin_recherche} a ${villeLabel}`;
  const corpsNotif = `${structureLabel} cherche un donneur compatible. Repondez maintenant.`;
  const fcmData: Record<string, string> = {
    demande_id: demande.id,
    groupe_sanguin: demande.groupe_sanguin_recherche,
    ville: villeLabel,
    type: "demande_compatible",
  };

  const emailSujet = `[SONGRE] Besoin urgent de ${demande.groupe_sanguin_recherche} a ${villeLabel}`;
  const emailHtml = genererEmailHtml(
    demande.groupe_sanguin_recherche,
    villeLabel,
    structureLabel,
  );

  // ── 5. Envoyer notifications + persister dans notifications_envoyees ──────
  let notifCount = 0;
  // Accumulation des inserts notifications_envoyees (schéma réel)
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

        // a. Notification FCM v1 (multi-device)
        if (fcmAccessToken && fcmProjectId) {
          const tokens = fcmMultiMap.get(profil.user_id) ?? [];
          for (const token of tokens) {
            const ok = await envoyerFcmV1(
              token,
              titreNotif,
              corpsNotif,
              fcmData,
              fcmAccessToken,
              fcmProjectId,
            );
            if (ok) {
              notifieParQuelqueMoyen = true;
              notifCount++;
              break; // Succès sur au moins un appareil — on arrête
            }
          }
        }

        // b. Email rotatif Brevo → Resend
        const email = emailsMap.get(profil.user_id);
        if (email) {
          const emailResult = await envoyerEmailRotatif(email, emailSujet, emailHtml);
          if (emailResult.success) {
            notifieParQuelqueMoyen = true;
            notifCount++;
          }
        }

        // c. Insérer dans notifications_envoyees UNIQUEMENT si au moins un canal a fonctionné
        // Schéma réel : {user_id, demande_id, type (enum), lu (boolean)}
        if (notifieParQuelqueMoyen) {
          notifInserts.push({
            user_id: profil.user_id,
            demande_id: demande.id,
            type: "demande_compatible", // valeur de l'enum public.type_notification_enum
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
      // Non bloquant — les notifications ont déjà été envoyées
      console.error("[matcher] Erreur insert notifications_envoyees:", insertError);
    } else {
      console.log(`[matcher] ${notifInserts.length} notifications persistées en DB.`);
    }
  }

  console.log(
    `[matcher] Demande ${demande.id} (${demande.groupe_sanguin_recherche} @ ${villeLabel}): `
    + `${donneursFiltres.length} donneurs matchés, ${notifCount} canaux notifiés, `
    + `${notifInserts.length} entrées DB créées.`,
  );

  return jsonResponse({
    success: true,
    matched: donneursFiltres.length,
    notified: notifCount,
    persisted: notifInserts.length,
  }, 200);
});
