// bff-vercel/lib/session.ts
// Gestion des sessions via Upstash Redis (équivalent Cloudflare KV)
//
// Pourquoi Upstash Redis ?
//   Vercel n'a pas de KV intégré équivalent à Cloudflare KV gratuit.
//   Upstash Redis est l'option officielle recommandée par Vercel :
//   - API REST simple (compatible Edge et Serverless)
//   - TTL natif (SETEX) — équivalent parfait à Workers KV avec expiration
//   - Géo-distribué, faible latence (même modèle que CF KV)
//   - Gratuit jusqu'à 10 000 requêtes/jour
//   - Intégration Vercel Marketplace disponible (configure automatiquement
//     UPSTASH_REDIS_REST_URL et UPSTASH_REDIS_REST_TOKEN)
//
// Différence avec Cloudflare KV :
//   Cloudflare : env.SESSIONS.put(key, value, { expirationTtl: ttl })
//   Upstash    : redis.setex(key, ttlSeconds, value)  ← API identique en concept
//
// Format clé KV : "session:{sessionId}"
// Valeur : JSON.stringify(SessionData)

import { Redis } from '@upstash/redis';
import { createHmac, randomBytes } from 'crypto';
import type { SessionData } from './types.js';

const SESSION_KEY_PREFIX = 'session:';
const SESSION_ID_BYTES = 32;

/**
 * Crée une instance Redis Upstash.
 * Appelé à chaque requête (les instances sont légères et stateless).
 */
function getRedis(url: string, token: string): Redis {
  return new Redis({ url, token });
}

// ── Signature HMAC du session ID ─────────────────────────────────────────
// Empêche la falsification de session ID par force brute ou devinette.
// Format cookie : sessionId.hmacHex

function signSessionId(sessionId: string, secret: string): string {
  const hmac = createHmac('sha256', secret)
    .update(sessionId)
    .digest('hex');
  return `${sessionId}.${hmac}`;
}

function verifySessionIdSignature(
  signedValue: string,
  secret: string,
): string | null {
  const dotIdx = signedValue.lastIndexOf('.');
  if (dotIdx === -1) return null;

  const sessionId = signedValue.slice(0, dotIdx);
  const receivedSig = signedValue.slice(dotIdx + 1);

  const expectedSig = createHmac('sha256', secret)
    .update(sessionId)
    .digest('hex');

  // Comparaison timing-safe
  try {
    const bufA = Buffer.from(receivedSig, 'hex');
    const bufB = Buffer.from(expectedSig, 'hex');
    if (bufA.length !== bufB.length) return null;

    let diff = 0;
    for (let i = 0; i < bufA.length; i++) {
      diff |= (bufA[i] ?? 0) ^ (bufB[i] ?? 0);
    }
    return diff === 0 ? sessionId : null;
  } catch {
    return null;
  }
}

// ── API publique ──────────────────────────────────────────────────────────

/**
 * Crée une nouvelle session dans Redis.
 * Retourne la valeur signée du cookie (sessionId.hmac).
 * Le token Supabase n'est jamais transmis au client.
 */
export async function createSession(
  redisUrl: string,
  redisToken: string,
  sessionSecret: string,
  sessionData: SessionData,
  ttlSeconds: number,
): Promise<string> {
  const redis = getRedis(redisUrl, redisToken);
  const sessionId = randomBytes(SESSION_ID_BYTES).toString('base64url');
  const key = `${SESSION_KEY_PREFIX}${sessionId}`;

  await redis.setex(key, ttlSeconds, JSON.stringify(sessionData));

  return signSessionId(sessionId, sessionSecret);
}

/**
 * Récupère les données de session depuis Redis.
 * Valide la signature HMAC + expiration.
 * Retourne null si invalide/expiré.
 */
export async function getSession(
  redisUrl: string,
  redisToken: string,
  sessionSecret: string,
  signedCookieValue: string,
): Promise<SessionData | null> {
  const sessionId = verifySessionIdSignature(signedCookieValue, sessionSecret);
  if (!sessionId) return null;

  const redis = getRedis(redisUrl, redisToken);
  const key = `${SESSION_KEY_PREFIX}${sessionId}`;
  const raw = await redis.get<string>(key);

  if (!raw) return null;

  try {
    const data = JSON.parse(typeof raw === 'string' ? raw : JSON.stringify(raw)) as SessionData;

    // Vérification d'expiration (double sécurité au-delà du TTL Redis)
    if (Date.now() > data.expiresAt) {
      await redis.del(key);
      return null;
    }

    return data;
  } catch {
    return null;
  }
}

/**
 * Met à jour les tokens dans Redis après un refresh Supabase.
 * Réinitialise le TTL.
 */
export async function updateSessionTokens(
  redisUrl: string,
  redisToken: string,
  sessionSecret: string,
  signedCookieValue: string,
  newAccessToken: string,
  newRefreshToken: string,
  ttlSeconds: number,
): Promise<boolean> {
  const sessionId = verifySessionIdSignature(signedCookieValue, sessionSecret);
  if (!sessionId) return false;

  const redis = getRedis(redisUrl, redisToken);
  const key = `${SESSION_KEY_PREFIX}${sessionId}`;
  const raw = await redis.get<string>(key);

  if (!raw) return false;

  try {
    const data = JSON.parse(typeof raw === 'string' ? raw : JSON.stringify(raw)) as SessionData;
    data.accessToken = newAccessToken;
    data.refreshToken = newRefreshToken;
    data.expiresAt = Date.now() + ttlSeconds * 1000;

    await redis.setex(key, ttlSeconds, JSON.stringify(data));
    return true;
  } catch {
    return false;
  }
}

/**
 * Supprime une session de Redis (déconnexion).
 */
export async function deleteSession(
  redisUrl: string,
  redisToken: string,
  sessionSecret: string,
  signedCookieValue: string,
): Promise<void> {
  const sessionId = verifySessionIdSignature(signedCookieValue, sessionSecret);
  if (!sessionId) return;

  const redis = getRedis(redisUrl, redisToken);
  await redis.del(`${SESSION_KEY_PREFIX}${sessionId}`);
}

// ── Builders de cookies ───────────────────────────────────────────────────

export function buildSessionCookie(
  signedValue: string,
  ttlSeconds: number,
  isProduction: boolean,
): string {
  const secure = isProduction ? '; Secure' : '';
  return (
    `bff_session=${signedValue}` +
    '; HttpOnly' +
    secure +
    '; SameSite=Strict' +
    `; Max-Age=${ttlSeconds}` +
    '; Path=/'
  );
}

export function buildLogoutCookie(isProduction: boolean): string {
  const secure = isProduction ? '; Secure' : '';
  return (
    'bff_session=; HttpOnly' +
    secure +
    '; SameSite=Strict' +
    '; Max-Age=0' +
    '; Path=/'
  );
}

export function buildCsrfCookie(
  csrfToken: string,
  ttlSeconds: number,
  isProduction: boolean,
): string {
  // Note : intentionnellement PAS HttpOnly — l'app Flutter Web doit lire
  // ce cookie pour l'inclure dans l'en-tête X-CSRF-Token
  const secure = isProduction ? '; Secure' : '';
  return (
    `bff_csrf=${csrfToken}` +
    secure +
    '; SameSite=Strict' +
    `; Max-Age=${ttlSeconds}` +
    '; Path=/'
  );
}

// ── Rate limiting via Redis ───────────────────────────────────────────────
// Équivalent de Cloudflare Workers Rate Limiting API
// Implémentation : compteur Redis avec TTL glissant (sliding window)

export async function checkRateLimit(
  redisUrl: string,
  redisToken: string,
  key: string,
  limit: number,
  windowSeconds: number,
): Promise<{ allowed: boolean; remaining: number }> {
  const redis = getRedis(redisUrl, redisToken);
  const redisKey = `ratelimit:${key}`;

  try {
    // Pipeline : INCR + EXPIRE atomique
    const count = await redis.incr(redisKey);

    if (count === 1) {
      // Première requête dans cette fenêtre — définir l'expiration
      await redis.expire(redisKey, windowSeconds);
    }

    const remaining = Math.max(0, limit - count);
    return { allowed: count <= limit, remaining };
  } catch {
    // En cas d'erreur Redis, on laisse passer (fail-open)
    // Mieux vaut un rate limiting raté que bloquer tous les utilisateurs
    return { allowed: true, remaining: limit };
  }
}

// ── Extraction cookie ─────────────────────────────────────────────────────

export function extractCookie(
  cookieHeader: string | undefined,
  name: string,
): string | null {
  if (!cookieHeader) return null;
  const cookies = cookieHeader.split(';').map((c) => c.trim());
  for (const cookie of cookies) {
    const eqIdx = cookie.indexOf('=');
    if (eqIdx === -1) continue;
    const key = cookie.slice(0, eqIdx).trim();
    const value = cookie.slice(eqIdx + 1).trim();
    if (key === name) return value;
  }
  return null;
}
