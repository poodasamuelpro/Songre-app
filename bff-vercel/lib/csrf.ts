// bff-vercel/lib/csrf.ts
// Protection CSRF — Double-Submit HMAC
// Équivalent exact de bff-cloudflare/src/security/csrf.ts
// Adapté pour Node.js (crypto module) au lieu de Web Crypto API

import { createHmac, randomBytes, timingSafeEqual as nodeTimingSafeEqual } from 'crypto';

const CSRF_TOKEN_BYTES = 32;

/**
 * Génère un token CSRF Double-Submit HMAC.
 * Format : randomB64.hmacHex
 * Le HMAC est calculé sur randomB64 + ':' + sessionId.
 * Cela lie cryptographiquement le token à la session (prévient les fixations).
 */
export function generateCsrfToken(csrfSecret: string, sessionId: string): string {
  const random = randomBytes(CSRF_TOKEN_BYTES).toString('base64url');
  const hmac = createHmac('sha256', csrfSecret)
    .update(`${random}:${sessionId}`)
    .digest('hex');
  return `${random}.${hmac}`;
}

/**
 * Vérifie un token CSRF reçu dans l'en-tête X-CSRF-Token.
 * La vérification est timing-safe pour prévenir les attaques de timing.
 */
export function verifyCsrfToken(
  token: string,
  csrfSecret: string,
  sessionId: string,
): boolean {
  if (!token || !token.includes('.')) return false;

  const dotIdx = token.indexOf('.');
  const random = token.slice(0, dotIdx);
  const receivedHmac = token.slice(dotIdx + 1);

  if (!random || !receivedHmac) return false;

  const expectedHmac = createHmac('sha256', csrfSecret)
    .update(`${random}:${sessionId}`)
    .digest('hex');

  // Comparaison timing-safe (Node.js natif)
  try {
    const bufA = Buffer.from(receivedHmac, 'hex');
    const bufB = Buffer.from(expectedHmac, 'hex');
    if (bufA.length !== bufB.length) return false;
    return nodeTimingSafeEqual(bufA, bufB);
  } catch {
    return false;
  }
}

/**
 * Retourne true si la méthode HTTP nécessite une protection CSRF.
 * GET et HEAD sont safe methods (RFC 7231) et ne modifient pas l'état.
 */
export function requiresCsrfProtection(method: string): boolean {
  return !['GET', 'HEAD', 'OPTIONS'].includes(method.toUpperCase());
}

/**
 * Extrait le token CSRF depuis les headers de la requête Vercel.
 */
export function extractCsrfToken(headers: Record<string, string | string[] | undefined>): string {
  const raw = headers['x-csrf-token'];
  if (Array.isArray(raw)) return raw[0] ?? '';
  return raw ?? '';
}
