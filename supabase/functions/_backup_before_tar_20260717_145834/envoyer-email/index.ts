import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import {
  envoyerEmailRotatif,
  renderTemplate,
  type TemplateName,
} from "../_shared/email.ts";

function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  const internalSecret = Deno.env.get("INTERNAL_SECRET");
  const receivedInternalSecret = req.headers.get("x-internal-secret");
  const authHeader = req.headers.get("Authorization") ?? "";

  let isAuthorized = false;
  if (internalSecret && receivedInternalSecret === internalSecret) isAuthorized = true;
  if (!isAuthorized && authHeader.startsWith("Bearer ")) {
    const token = authHeader.replace("Bearer ", "").trim();
    if (token === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) isAuthorized = true;
  }

  if (!isAuthorized) return jsonResponse({ error: "Accès non autorisé." }, 403, corsHeaders);

  const body = await req.json();
  const { to, subject, html, template, data } = body;

  if (!to || !isValidEmail(to)) return jsonResponse({ error: "Email invalide." }, 400, corsHeaders);
  if (!subject) return jsonResponse({ error: "Sujet manquant." }, 400, corsHeaders);

  let htmlContent = null;
  if (template && template !== "custom") {
    htmlContent = renderTemplate(template as TemplateName, data ?? {});
  } else {
    htmlContent = html;
  }

  if (!htmlContent) return jsonResponse({ error: "Contenu manquant." }, 400, corsHeaders);

  const result = await envoyerEmailRotatif(to, subject, htmlContent);
  return jsonResponse({ success: result.success, provider: result.provider, to }, result.success ? 200 : 500, corsHeaders);
});
