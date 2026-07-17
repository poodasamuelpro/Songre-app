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

  // Vérifier si l'origin est dans la liste autorisée
  const allowOrigin = ALLOWED_ORIGINS.includes(origin)
    ? origin
    : ALLOWED_ORIGINS[0]; // Fallback sur le domaine principal

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
