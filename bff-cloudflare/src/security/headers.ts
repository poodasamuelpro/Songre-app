// =============================================================================
// security/headers.ts — En-têtes de sécurité HTTP pour le BFF SONGRE
//
// Appliqués systématiquement sur TOUTES les réponses du BFF.
// Ref : OWASP Secure Headers Project, RFC 6797 (HSTS), RFC 7034 (X-Frame)
// =============================================================================

// ── Content Security Policy ──────────────────────────────────────────────────
// Politique stricte adaptée à Flutter Web + Supabase + OSM + Google Fonts.
// 'wasm-unsafe-eval' : requis pour Flutter Web (compilation WASM en runtime).
// 'unsafe-inline' dans style-src : Flutter injecte du style CSS inline.
const CSP_DIRECTIVES = [
  "default-src 'self'",
  "script-src 'self' 'wasm-unsafe-eval'",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "font-src 'self' data: https://fonts.gstatic.com",
  "img-src 'self' data: blob: https://*.tile.openstreetmap.org",
  "connect-src 'self' https://*.supabase.co https://*.supabase.io",
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "object-src 'none'",
  "upgrade-insecure-requests",
].join('; ');

const PERMISSIONS_POLICY = [
  'camera=()',
  'microphone=()',
  'geolocation=(self)',
  'payment=()',
  'usb=()',
].join(', ');

// ── API publique ──────────────────────────────────────────────────────────────

/**
 * Construit les en-têtes CORS stricts.
 * L'origin autorisée est comparée à `allowedOrigin`.
 * En mode développement (requestOrigin commence par http://localhost), on autorise aussi.
 * JAMAIS de wildcard — credentials: true est incompatible avec *.
 */
function buildCorsHeaders(
  allowedOrigin: string,
  requestOrigin: string | null,
  isDev: boolean,
): Record<string, string> {
  const isDevOrigin = isDev && (requestOrigin?.startsWith('http://localhost') ?? false);
  const resolvedOrigin =
    requestOrigin === allowedOrigin || isDevOrigin
      ? (requestOrigin ?? allowedOrigin)
      : '';

  if (!resolvedOrigin) return {};

  return {
    'Access-Control-Allow-Origin': resolvedOrigin,
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-CSRF-Token, X-Requested-With',
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  };
}

function buildSecurityHeaders(isProduction: boolean): Record<string, string> {
  return {
    ...(isProduction
      ? { 'Strict-Transport-Security': 'max-age=31536000; includeSubDomains' }
      : {}),
    'X-Frame-Options': 'DENY',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    'Content-Security-Policy': CSP_DIRECTIVES,
    'Permissions-Policy': PERMISSIONS_POLICY,
    'Cache-Control': 'no-store, no-cache, must-revalidate',
    'Pragma': 'no-cache',
  };
}

/**
 * Applique tous les en-têtes de sécurité sur une Response existante.
 * Prend l'allowedOrigin comme string directement (plus simple pour les appelants).
 */
export function applySecurityHeaders(
  response: Response,
  allowedOrigin: string,
  requestOrigin: string | null = null,
  isProduction = true,
): Response {
  const headers = new Headers(response.headers);

  const corsH = buildCorsHeaders(allowedOrigin, requestOrigin, !isProduction);
  const secH = buildSecurityHeaders(isProduction);

  for (const [key, value] of Object.entries({ ...corsH, ...secH })) {
    if (value) headers.set(key, value);
  }

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/**
 * Crée une réponse JSON avec tous les en-têtes de sécurité.
 *
 * Signature : jsonSecureResponse(allowedOrigin, body, status?, extraHeaders?)
 * Compatible avec les appels dans tous les handlers auth et index.ts.
 */
export function jsonSecureResponse(
  allowedOrigin: string,
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  const raw = new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      ...extraHeaders,
    },
  });
  // En BFF, on ne dispose pas de l'origin de la requête à ce point ;
  // les handlers qui ont accès à request passent leur propre origin via applySecurityHeaders.
  // Ici on applique les en-têtes de sécurité sans CORS (ajouté par le caller si besoin).
  const secH = buildSecurityHeaders(true);
  const headers = new Headers(raw.headers);
  for (const [key, value] of Object.entries(secH)) {
    headers.set(key, value);
  }
  // CORS: par défaut, autoriser allowedOrigin (la plupart des réponses viennent de cette origin)
  const corsH = buildCorsHeaders(allowedOrigin, allowedOrigin, false);
  for (const [key, value] of Object.entries(corsH)) {
    headers.set(key, value);
  }
  return new Response(raw.body, { status, headers });
}

/**
 * Réponse OPTIONS (preflight CORS) — 204 No Content.
 */
export function preflightResponse(allowedOrigin: string): Response {
  const corsH = buildCorsHeaders(allowedOrigin, allowedOrigin, false);
  const headers = new Headers();
  for (const [k, v] of Object.entries(corsH)) {
    if (v) headers.set(k, v);
  }
  headers.set('Content-Length', '0');
  return new Response(null, { status: 204, headers });
}
