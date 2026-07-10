// =============================================================================
// _shared/cors.ts — Module partagé SONGRE : gestion CORS multi-domaine
//
// Tous les domaines SONGRE autorisés :
//   - https://songre.bf        (production principale)
//   - https://songre.com       (domaine alternatif)
//   - https://songre.vercel.app (preview Vercel)
//
// Usage :
//   import { getCorsHeaders, jsonResponse, handleCors } from "../_shared/cors.ts";
//
//   serve(async (req) => {
//     const corsHeaders = getCorsHeaders(req);
//     const preflight = handleCors(req, corsHeaders);
//     if (preflight) return preflight;
//     // ... handler
//   });
// =============================================================================

const ALLOWED_ORIGINS = [
  "https://songre.bf",
  "https://songre.com",
  "https://songre.vercel.app",
];

export function getCorsHeaders(
  req: Request,
  allowedMethods = "POST, OPTIONS",
  extraHeaders?: string,
): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";

  // ── Correction S-06 (audit 2026-07-09) ────────────────────────────────────
  // Ancienne version : retournait ALLOWED_ORIGINS[0] pour toute origine inconnue,
  // ce qui produisait un header CORS syntaxiquement valide mais sémantiquement
  // trompeur. Correction : null-string pour les origines non autorisées,
  // ce qui fait rejeter la requête par le navigateur (comportement CORS attendu).
  // Note : les EFs Supabase côté mobile n'envoient pas d'Origin → elles passent.
  const allowOrigin = ALLOWED_ORIGINS.includes(origin) ? origin : "";

  const baseHeaders =
    "authorization, x-client-info, apikey, content-type, " +
    "x-webhook-secret, x-internal-secret";

  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Methods": allowedMethods,
    "Access-Control-Allow-Headers": extraHeaders
      ? `${baseHeaders}, ${extraHeaders}`
      : baseHeaders,
    "Access-Control-Max-Age": "86400",
  };
}

// ── Preflight CORS ────────────────────────────────────────────────────────────

export function handleCors(
  req: Request,
  corsHeaders: Record<string, string>,
): Response | null {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  return null;
}

// ── Réponse JSON standardisée avec CORS ──────────────────────────────────────

export function jsonResponse(
  body: unknown,
  status: number,
  corsHeaders: Record<string, string>,
  extraHeaders?: Record<string, string>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders,
      ...(extraHeaders ?? {}),
    },
  });
}
