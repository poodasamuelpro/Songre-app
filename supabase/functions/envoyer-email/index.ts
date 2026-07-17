// =============================================================================
// Edge Function : envoyer-email  (v2 — _shared/cors.ts + _shared/email.ts)
// Déploiement   : supabase functions deploy envoyer-email
//
// Rôle : Service d'envoi d'email générique.
//        Ne doit JAMAIS être appelé directement depuis le client Flutter.
//
// Authentification :
//   - Appel interne (depuis autre EF) : header X-Internal-Secret
//   - Appel admin externe : JWT Supabase Service Role
//
// Payload POST JSON :
//   {
//     "to":       "destinataire@example.com",
//     "subject":  "Objet de l'email",
//     "html":     "<p>Corps HTML</p>",             // ou "template" ci-dessous
//     "template": "don_confirme" | "demande_compatible" | ...
//     "data":     { ... }                          // données pour le template
//   }
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import {
  envoyerEmailRotatif,
  renderTemplate,
  type TemplateName,
} from "../_shared/email.ts";

// ── Types ─────────────────────────────────────────────────────────────────────

interface EmailRequest {
  to: string;
  subject: string;
  html?: string;
  template?: TemplateName | "custom";
  data?: Record<string, string>;
}

// ── Validation email basique ──────────────────────────────────────────────────

function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  // ── Authentification ──────────────────────────────────────────────────────
  const internalSecret = Deno.env.get("INTERNAL_SECRET");
  const receivedInternalSecret = req.headers.get("x-internal-secret");
  const authHeader = req.headers.get("Authorization") ?? "";

  let isAuthorized = false;

  if (internalSecret && internalSecret.trim().length > 0) {
    if (receivedInternalSecret === internalSecret) {
      isAuthorized = true;
    }
  }

  if (!isAuthorized && authHeader.startsWith("Bearer ")) {
    const token = authHeader.replace("Bearer ", "").trim();
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (token === serviceRoleKey && serviceRoleKey.length > 10) {
      isAuthorized = true;
    }
  }

  if (!isAuthorized) {
    return jsonResponse({ error: "Accès non autorisé." }, 403, corsHeaders);
  }

  // ── Parser le body ────────────────────────────────────────────────────────
  let body: EmailRequest;
  try {
    body = await req.json() as EmailRequest;
  } catch {
    return jsonResponse({ error: "Body JSON invalide." }, 400, corsHeaders);
  }

  const { to, subject, html, template, data } = body;

  if (!to || typeof to !== "string" || !isValidEmail(to.trim())) {
    return jsonResponse({ error: "Champ 'to' manquant ou adresse email invalide." }, 400, corsHeaders);
  }

  if (!subject || typeof subject !== "string" || subject.trim().length === 0) {
    return jsonResponse({ error: "Champ 'subject' manquant ou vide." }, 400, corsHeaders);
  }

  // ── Résoudre le HTML ──────────────────────────────────────────────────────
  let htmlContent: string | null = null;

  if (template && template !== "custom") {
    htmlContent = renderTemplate(template as TemplateName, data ?? {});
    if (!htmlContent) {
      return jsonResponse({ error: `Template inconnu: ${template}` }, 400, corsHeaders);
    }
  } else if (html) {
    htmlContent = html;
  } else {
    return jsonResponse({
      error: "Fournir soit 'html' (string) soit 'template' (nom du template).",
    }, 400, corsHeaders);
  }

  if (htmlContent.length > 100_000) {
    return jsonResponse({ error: "Corps HTML trop volumineux (max 100 KB)." }, 413, corsHeaders);
  }

  // ── Envoi avec système rotatif (_shared/email.ts) ─────────────────────────
  const result = await envoyerEmailRotatif(to.trim(), subject.trim(), htmlContent);

  if (!result.success) {
    console.error("[envoyer-email] Échec total.");
    return jsonResponse({
      success: false,
      error: "Impossible d'envoyer l'email.",
    }, 500, corsHeaders);
  }

  return jsonResponse({
    success: true,
    provider: result.provider,
    to: to.trim(),
  }, 200, corsHeaders);
});
