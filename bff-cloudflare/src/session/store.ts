// =============================================================================
// session/store.ts — Gestion des sessions BFF via Cloudflare Workers KV
//
// Architecture :
//   - Le client (navigateur) reçoit un cookie HttpOnly contenant uniquement
//     un identifiant de session OPAQUE (UUID + signature HMAC). Ce cookie
//     ne contient JAMAIS le token Supabase réel.
//   - Le token Supabase réel est stocké côté serveur dans Cloudflare KV,
//     associé à l'identifiant de session.
//   - À chaque requête authentifiée, le BFF :
//       1. Lit l'id de session depuis le cookie
//       2. Vérifie sa signature HMAC (anti-falsification)
//       3. Récupère les tokens Supabase depuis KV
//       4. Ajoute le Bearer token à la requête vers Supabase
//
// Sécurité KV :
//   - TTL automatique (expirationTtl) → les sessions expirées sont
//     automatiquement supprimées par Cloudflare KV sans cron job
//   - Les données stockées sont sérialisées en JSON (pas chiffrées côté KV)
//     mais sécurisées par le contrôle d'accès Cloudflare Account
// =============================================================================

import type { Env, SessionData } from '../types.js';

const SESSION_ID_PREFIX = 'session:';
const SESSION_ID_BYTES = 32; // 32 octets = 256 bits d'entropie

/**
 * Génère un identifiant de session aléatoire et sa signature HMAC.
 * Format du cookie : `sessionId.hmacSignature` (séparés par un point)
 */
export async function createSessionId(sessionSecret: string): Promise<string> {
  const randomBytes = crypto.getRandomValues(new Uint8Array(SESSION_ID_BYTES));
  const sessionId = bufferToHex(randomBytes);

  const signature = await hmacSign(sessionSecret, sessionId);
  return `${sessionId}.${signature}`;
}

/**
 * Valide et extrait le sessionId depuis la valeur du cookie.
 * Retourne null si le cookie est absent ou si la signature est invalide.
 */
export async function validateSessionCookie(
  cookieValue: string | undefined,
  sessionSecret: string,
): Promise<string | null> {
  if (!cookieValue || typeof cookieValue !== 'string') return null;

  const dotIndex = cookieValue.lastIndexOf('.');
  if (dotIndex < 0) return null;

  const sessionId = cookieValue.substring(0, dotIndex);
  const signature = cookieValue.substring(dotIndex + 1);

  if (!sessionId || !signature) return null;

  const expectedSig = await hmacSign(sessionSecret, sessionId);

  // Comparaison en temps constant
  if (!timingSafeEqual(expectedSig, signature)) return null;

  return sessionId;
}

/**
 * Crée une nouvelle session dans KV.
 * @returns Le token de session opaque (sessionId + signature) à mettre dans le cookie
 */
export async function createSession(
  env: Env,
  data: Omit<SessionData, 'createdAt' | 'expiresAt'>,
): Promise<string> {
  const ttlSeconds = parseInt(env.SESSION_TTL_SECONDS, 10) || 3600;
  const now = Date.now();

  const sessionCookieValue = await createSessionId(env.SESSION_SECRET);
  const sessionId = sessionCookieValue.split('.')[0];

  const sessionData: SessionData = {
    ...data,
    createdAt: now,
    expiresAt: now + ttlSeconds * 1000,
  };

  // Stocker dans KV avec TTL automatique
  await env.SESSIONS.put(
    `${SESSION_ID_PREFIX}${sessionId}`,
    JSON.stringify(sessionData),
    { expirationTtl: ttlSeconds },
  );

  return sessionCookieValue;
}

/**
 * Récupère les données d'une session depuis KV.
 * Retourne null si la session n'existe pas ou a expiré.
 */
export async function getSession(
  env: Env,
  sessionCookieValue: string | undefined,
): Promise<{ sessionId: string; data: SessionData } | null> {
  const sessionId = await validateSessionCookie(sessionCookieValue, env.SESSION_SECRET);
  if (!sessionId) return null;

  const raw = await env.SESSIONS.get(`${SESSION_ID_PREFIX}${sessionId}`);
  if (!raw) return null;

  try {
    const data = JSON.parse(raw) as SessionData;
    // Vérification d'expiration côté applicatif (en plus du TTL KV)
    if (data.expiresAt < Date.now()) {
      await deleteSession(env, sessionId);
      return null;
    }
    return { sessionId, data };
  } catch {
    return null;
  }
}

/**
 * Met à jour les tokens d'une session existante (après refresh).
 */
export async function updateSessionTokens(
  env: Env,
  sessionId: string,
  accessToken: string,
  refreshToken: string,
): Promise<void> {
  const raw = await env.SESSIONS.get(`${SESSION_ID_PREFIX}${sessionId}`);
  if (!raw) return;

  const data = JSON.parse(raw) as SessionData;
  const ttlSeconds = parseInt(env.SESSION_TTL_SECONDS, 10) || 3600;

  const updated: SessionData = {
    ...data,
    accessToken,
    refreshToken,
    expiresAt: Date.now() + ttlSeconds * 1000,
  };

  await env.SESSIONS.put(
    `${SESSION_ID_PREFIX}${sessionId}`,
    JSON.stringify(updated),
    { expirationTtl: ttlSeconds },
  );
}

/**
 * Supprime une session de KV (déconnexion).
 */
export async function deleteSession(
  env: Env,
  sessionId: string,
): Promise<void> {
  await env.SESSIONS.delete(`${SESSION_ID_PREFIX}${sessionId}`);
}

/**
 * Construit la valeur du cookie de session HTTP avec les flags de sécurité.
 * SameSite=None + Secure requis si le BFF et le client sont sur des domaines
 * différents (ex: bff.songre.bf vs songre.bf).
 * Choisir SameSite=Strict si même domaine (plus sécurisé).
 */
export function buildSessionCookie(
  cookieValue: string,
  ttlSeconds: number,
  isProd: boolean,
): string {
  const parts = [
    `songre_session=${cookieValue}`,
    'HttpOnly',                          // Inaccessible depuis JavaScript
    ...(isProd ? ['Secure'] : []),       // HTTPS uniquement en prod
    'SameSite=Strict',                   // Protection CSRF renforcée
    `Max-Age=${ttlSeconds}`,             // Durée de vie alignée sur la session
    'Path=/',                            // Valable pour tout le domaine
  ];
  return parts.join('; ');
}

/** Cookie de déconnexion (expire immédiatement) */
export function buildLogoutCookie(isProd: boolean): string {
  return [
    'songre_session=',
    'HttpOnly',
    ...(isProd ? ['Secure'] : []),
    'SameSite=Strict',
    'Max-Age=0',
    'Path=/',
  ].join('; ');
}

/** Cookie CSRF (lisible par JS, non HttpOnly — intentionnel) */
export function buildCsrfCookie(
  csrfToken: string,
  ttlSeconds: number,
  isProd: boolean,
): string {
  // Note : PAS HttpOnly — l'app Flutter Web doit pouvoir lire ce cookie
  // pour l'insérer dans le header X-CSRF-Token
  return [
    `songre_csrf=${csrfToken}`,
    ...(isProd ? ['Secure'] : []),
    'SameSite=Strict',
    `Max-Age=${ttlSeconds}`,
    'Path=/',
  ].join('; ');
}

// ── Helpers crypto ─────────────────────────────────────────────────────────────

async function hmacSign(secret: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(data),
  );
  return bufferToHex(new Uint8Array(sig));
}

function bufferToHex(buffer: Uint8Array): string {
  return Array.from(buffer)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
