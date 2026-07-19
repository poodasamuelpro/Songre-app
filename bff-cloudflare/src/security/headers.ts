// =============================================================================
// security/headers.ts — En-têtes de sécurité HTTP pour le BFF SONGRE
//
// Appliqués systématiquement sur TOUTES les réponses du BFF.
// Ref : OWASP Secure Headers Project, RFC 6797 (HSTS), RFC 7034 (X-Frame)
// =============================================================================

import type { Env } from '../types.js';

/**
 * Construit les en-têtes CORS stricts pour l'origin autorisée.
 * - Jamais de wildcard (*) — uniquement l'origine déclarée dans ALLOWED_ORIGIN
 * - SameSite=None requis si BFF et app Web sont sur des sous-domaines différents
 *   (ex: bff.songre.bf vs songre.bf).
 *   → Documenter dans GUIDE_WEB.md le choix SameSite retenu selon la topologie.
 */
export function buildCorsHeaders(env: Env, requestOrigin: string | null): Record<string, string> {
  const allowedOrigin = env.ALLOWED_ORIGIN;

  // En dev local, autoriser aussi localhost
  const isDevOrigin =
    env.ENVIRONMENT === 'development' &&
    requestOrigin?.startsWith('http://localhost');

  const origin = requestOrigin === allowedOrigin || isDevOrigin
    ? (requestOrigin ?? allowedOrigin)
    : '';

  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers':
      'Content-Type, X-CSRF-Token, X-Requested-With',
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Max-Age': '86400',
  };
}

/**
 * En-têtes de sécurité HTTP à ajouter sur TOUTES les réponses BFF.
 * Protections couvertes :
 * - HSTS    : force HTTPS pour 1 an, incluant sous-domaines
 * - X-Frame : interdit l'embedding dans une iframe (clickjacking)
 * - XCTO    : empêche le sniffing de content-type (MIME confusion)
 * - Referrer: ne transmet pas d'URL de référence hors du site
 * - CSP     : restreint les sources de scripts, styles, images, fetch
 * - Permissions-Policy : désactive les APIs sensibles non utilisées
 */
export function buildSecurityHeaders(env: Env): Record<string, string> {
  const isProd = env.ENVIRONMENT === 'production';
  const allowedOrigin = env.ALLOWED_ORIGIN;

  // Domaine de l'app (ex: "songre.bf" extrait de "https://songre.bf")
  const appDomain = allowedOrigin.replace(/^https?:\/\//, '');
  // Domaine Supabase (à adapter si changement de projet)
  const supabaseDomain = '*.supabase.co';
  // Tuiles OSM pour la carte
  const osmDomain = '*.tile.openstreetmap.org';
  // Google Fonts
  const fontsDomain = 'fonts.googleapis.com fonts.gstatic.com';

  const csp = [
    `default-src 'self'`,
    `script-src 'self' 'wasm-unsafe-eval'`,            // Flutter Web compile en WASM/JS
    `style-src 'self' 'unsafe-inline' ${fontsDomain}`, // Flutter injecte du style inline
    `font-src 'self' data: ${fontsDomain}`,
    `img-src 'self' data: blob: ${osmDomain}`,          // Tuiles OSM + assets Flutter
    `connect-src 'self' https://${supabaseDomain} ${allowedOrigin}`,
    `frame-ancestors 'none'`,                           // Bloque l'embedding iframe
    `base-uri 'self'`,
    `form-action 'self'`,
    `object-src 'none'`,
    `upgrade-insecure-requests`,
  ].join('; ');

  return {
    // HSTS — 1 an, inclut sous-domaines, préload opt-in
    ...(isProd ? { 'Strict-Transport-Security': 'max-age=31536000; includeSubDomains' } : {}),
    // Anti-clickjacking
    'X-Frame-Options': 'DENY',
    // Anti-MIME sniffing
    'X-Content-Type-Options': 'nosniff',
    // Referrer minimal
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    // Content Security Policy
    'Content-Security-Policy': csp,
    // Désactiver les APIs sensibles non utilisées dans SONGRE
    'Permissions-Policy': [
      'camera=()',          // Scanner QR géré nativement sur mobile
      'microphone=()',
      'geolocation=(self)', // Géoloc utilisée dans l'app
      'payment=()',
      'usb=()',
    ].join(', '),
    // Cache — pas de cache des réponses d'auth
    'Cache-Control': 'no-store, no-cache, must-revalidate',
    'Pragma': 'no-cache',
    // Identifier le BFF sans exposer la technologie sous-jacente
    'Server': 'SONGRE-BFF/1.0',
  };
}

/**
 * Applique tous les en-têtes de sécurité sur une Response existante.
 * Retourne une nouvelle Response avec les en-têtes ajoutés.
 */
export function applySecurityHeaders(
  response: Response,
  env: Env,
  requestOrigin: string | null,
): Response {
  const headers = new Headers(response.headers);

  const corsHeaders = buildCorsHeaders(env, requestOrigin);
  const secHeaders = buildSecurityHeaders(env);

  for (const [key, value] of Object.entries({ ...corsHeaders, ...secHeaders })) {
    if (value) headers.set(key, value);
  }

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/** Réponse JSON avec tous les en-têtes de sécurité */
export function jsonSecureResponse(
  body: unknown,
  status: number,
  env: Env,
  requestOrigin: string | null,
): Response {
  const raw = new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
  return applySecurityHeaders(raw, env, requestOrigin);
}

/** Réponse OPTIONS (preflight CORS) */
export function preflightResponse(
  env: Env,
  requestOrigin: string | null,
): Response {
  const cors = buildCorsHeaders(env, requestOrigin);
  const headers = new Headers();
  for (const [k, v] of Object.entries(cors)) {
    if (v) headers.set(k, v);
  }
  headers.set('Content-Length', '0');
  return new Response(null, { status: 204, headers });
}
