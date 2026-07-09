// =============================================================================
// Edge Function : contacter-support  (D8)
// Déploiement   : supabase functions deploy contacter-support
//
// Rôle : Reçoit un message de contact depuis l'app Flutter et l'envoie
//        à songre.contact@gmail.com via le système email rotatif.
//
// Auth : Bearer JWT utilisateur (obligatoire — identifie l'expéditeur)
//
// Anti-spam : un utilisateur ne peut envoyer qu'un message toutes les 10 minutes.
//   La vérification est faite en interrogeant public.contact_spam_log
//   (table légère créée par mission-d.sql).
//   Si la table n'existe pas encore, l'anti-spam est skippé avec un warning.
//
// Payload POST JSON :
//   {
//     "objet":   "Problème avec l'application",  // max 100 chars
//     "message": "Description détaillée..."       // max 2000 chars
//   }
//
// Variables d'environnement :
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY
//   SUPPORT_EMAIL  — ex: "songre.contact@gmail.com" (par défaut)
//   + Variables email (_shared/email.ts)
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { envoyerEmailRotatif, renderTemplate } from "../_shared/email.ts";

// ── Constantes ────────────────────────────────────────────────────────────────

const SUPPORT_EMAIL_DEFAULT = "songre.contact@gmail.com";
const ANTI_SPAM_MINUTES = 10;    // Délai minimum entre deux messages
const MAX_OBJET_LENGTH = 100;
const MAX_MESSAGE_LENGTH = 2000;

// ── Handler principal ─────────────────────────────────────────────────────────

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
    return jsonResponse({ error: "Authentification requise." }, 401, corsHeaders);
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
    return jsonResponse({ error: "Session invalide ou expirée." }, 401, corsHeaders);
  }

  // ── Parser le body ─────────────────────────────────────────────────────────
  let body: { objet?: string; message?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Body JSON invalide." }, 400, corsHeaders);
  }

  const { objet, message } = body;

  if (!objet || typeof objet !== "string" || objet.trim().length === 0) {
    return jsonResponse({ error: "Champ 'objet' manquant ou vide." }, 400, corsHeaders);
  }
  if (!message || typeof message !== "string" || message.trim().length === 0) {
    return jsonResponse({ error: "Champ 'message' manquant ou vide." }, 400, corsHeaders);
  }
  if (objet.trim().length > MAX_OBJET_LENGTH) {
    return jsonResponse({
      error: `L'objet ne peut pas dépasser ${MAX_OBJET_LENGTH} caractères.`,
    }, 400, corsHeaders);
  }
  if (message.trim().length > MAX_MESSAGE_LENGTH) {
    return jsonResponse({
      error: `Le message ne peut pas dépasser ${MAX_MESSAGE_LENGTH} caractères.`,
    }, 400, corsHeaders);
  }

  // ── Anti-spam : vérifier le délai depuis le dernier message ───────────────
  try {
    const limiteAntiSpam = new Date(
      Date.now() - ANTI_SPAM_MINUTES * 60 * 1000,
    ).toISOString();

    const { data: spamCheck } = await adminClient
      .from("contact_spam_log")
      .select("created_at")
      .eq("user_id", user.id)
      .gte("created_at", limiteAntiSpam)
      .limit(1);

    if (spamCheck && spamCheck.length > 0) {
      return jsonResponse({
        error: `Vous pouvez envoyer un message toutes les ${ANTI_SPAM_MINUTES} minutes. Veuillez réessayer ultérieurement.`,
        retry_after_minutes: ANTI_SPAM_MINUTES,
      }, 429, corsHeaders);
    }
  } catch (spamErr) {
    // La table n'existe peut-être pas encore — warning non bloquant
    console.warn("[contacter-support] Anti-spam check skipped:", spamErr);
  }

  // ── Récupérer l'email de l'utilisateur ────────────────────────────────────
  const userEmail = user.email ?? "email inconnu";

  // ── Construire et envoyer l'email au support ──────────────────────────────
  const supportEmail = Deno.env.get("SUPPORT_EMAIL") ?? SUPPORT_EMAIL_DEFAULT;
  const dateHeure = new Date().toLocaleString("fr-FR", {
    timeZone: "Africa/Ouagadougou",
  });

  const htmlContent = renderTemplate("contact_support", {
    email: userEmail,
    objet: objet.trim(),
    message: message.trim(),
    user_id: user.id,
    date_heure: dateHeure,
  });

  if (!htmlContent) {
    return jsonResponse({ error: "Erreur interne de template." }, 500, corsHeaders);
  }

  const sujetEmail = `[SONGRE Support] ${objet.trim().substring(0, 60)}`;

  const emailResult = await envoyerEmailRotatif(
    supportEmail,
    sujetEmail,
    htmlContent,
    { replyTo: userEmail }, // Réponse directe à l'utilisateur
  );

  if (!emailResult.success) {
    console.error("[contacter-support] Échec envoi email support.");
    return jsonResponse({
      error: "Impossible d'envoyer votre message. Réessayez plus tard.",
    }, 500, corsHeaders);
  }

  // ── Enregistrer dans contact_spam_log ─────────────────────────────────────
  try {
    await adminClient
      .from("contact_spam_log")
      .insert({ user_id: user.id });
  } catch (logErr) {
    console.warn("[contacter-support] Erreur log anti-spam:", logErr);
  }

  console.log(
    `[contacter-support] Message de ${user.id} (${userEmail}) envoyé → ${supportEmail}`,
  );

  return jsonResponse({
    success: true,
    message: "Votre message a bien été envoyé. Nous vous répondrons dans les plus brefs délais.",
  }, 200, corsHeaders);
});
