// bff-vercel/lib/headers.ts
// Gestion des headers de sécurité HTTP — équivalent de bff-cloudflare/src/security/headers.ts
//
// Adapté pour Vercel : utilise VercelRequest/VercelResponse de @vercel/node
// au lieu de Request/Response Web standard.

import type { VercelRequest, VercelResponse } from '@vercel/node';

// ── CSP stricte ───────────────────────────────────────────────────────────
// Ajustée selon les domaines réellement utilisés par SONGRE :
//   - Supabase : données et auth
//   - OpenStreetMap / tile.openstreetmap.org : tuiles cartographiques
//   - Google Fonts : typographies
const CONTENT_SECURITY_POLICY = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "font-src 'self' https://fonts.gstatic.com",
  "img-src 'self' data: https://*.tile.openstreetmap.org",
  "connect-src 'self' https://*.supabase.co https://*.supabase.io",
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "object-src 'none'",
  "upgrade-insecure-requests",
].join('; ');

/**
 * Applique tous les headers de sécurité sur une VercelResponse.
 * Doit être appelé AVANT res.json() / res.send() sur Vercel.
 */
export function applySecurityHeaders(
  res: VercelResponse,
  allowedOrigin: string,
  origin?: string,
): void {
  // CORS strict — jamais de wildcard
  if (origin && origin === allowedOrigin) {
    res.setHeader('Access-Control-Allow-Origin', allowedOrigin);
    res.setHeader('Access-Control-Allow-Credentials', 'true');
    res.setHeader('Vary', 'Origin');
  }

  // Sécurité standard
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.setHeader('Content-Security-Policy', CONTENT_SECURITY_POLICY);

  // HSTS — HTTPS uniquement
  res.setHeader(
    'Strict-Transport-Security',
    'max-age=31536000; includeSubDomains; preload',
  );

  // Supprime le header Vercel par défaut
  res.removeHeader('X-Powered-By');
}

/**
 * Gère les requêtes OPTIONS (preflight CORS).
 */
export function handlePreflight(
  req: VercelRequest,
  res: VercelResponse,
  allowedOrigin: string,
): boolean {
  if (req.method !== 'OPTIONS') return false;

  const origin = req.headers['origin'] as string | undefined;

  if (origin === allowedOrigin) {
    res.setHeader('Access-Control-Allow-Origin', allowedOrigin);
    res.setHeader('Access-Control-Allow-Credentials', 'true');
    res.setHeader(
      'Access-Control-Allow-Methods',
      'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    );
    res.setHeader(
      'Access-Control-Allow-Headers',
      'Content-Type, X-CSRF-Token, Authorization',
    );
    res.setHeader('Access-Control-Max-Age', '86400');
    res.setHeader('Vary', 'Origin');
  }

  res.status(204).end();
  return true;
}

/**
 * Vérifie que l'origine de la requête correspond à l'origine autorisée.
 * Retourne true si autorisée, false sinon.
 */
export function isOriginAllowed(
  req: VercelRequest,
  allowedOrigin: string,
): boolean {
  const origin = req.headers['origin'] as string | undefined;
  // Requêtes sans Origin (ex: serveur-serveur, curl) → autoriser
  if (!origin) return true;
  return origin === allowedOrigin;
}

/**
 * Envoie une réponse JSON avec les headers de sécurité complets.
 */
export function sendSecureJson(
  req: VercelRequest,
  res: VercelResponse,
  allowedOrigin: string,
  data: unknown,
  statusCode = 200,
  extraHeaders?: Record<string, string>,
): void {
  const origin = req.headers['origin'] as string | undefined;
  applySecurityHeaders(res, allowedOrigin, origin);

  if (extraHeaders) {
    for (const [key, value] of Object.entries(extraHeaders)) {
      res.setHeader(key, value);
    }
  }

  res.status(statusCode).json(data);
}
