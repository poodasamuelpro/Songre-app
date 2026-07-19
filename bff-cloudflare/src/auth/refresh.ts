// =============================================================================
// bff-cloudflare/src/auth/refresh.ts
// POST /bff/auth/refresh — Rafraîchissement silencieux du token JWT
//
// Flux :
//   1. Lire cookie bff_session (HttpOnly → transparent pour le client)
//   2. Vérifier CSRF (méthode POST → protégée)
//   3. Récupérer les tokens depuis KV via getSession(env, signedValue)
//   4. Appeler Supabase /auth/v1/token?grant_type=refresh_token
//   5. Mettre à jour les tokens dans KV via updateSessionTokens(env, id, acc, ref)
//   6. Renouveler le cookie session + nouveau cookie CSRF
//   7. Retourner { ok: true } — AUCUN token n'est transmis au navigateur
//
// Ce endpoint est appelé automatiquement par Flutter Web avant l'expiration
// du cookie (ex: toutes les 50 minutes pour un TTL de 3600s).
// =============================================================================

import { Env } from '../types.js';
import {
  jsonSecureResponse,
  preflightResponse,
} from '../security/headers.js';
import {
  requiresCsrfProtection,
  verifyCsrfToken,
  generateCsrfToken,
} from '../security/csrf.js';
import {
  getSession,
  updateSessionTokens,
  deleteSession,
  buildSessionCookie,
  buildCsrfCookie,
  extractCookie,
} from '../session/store.js';

export async function handleRefresh(
  request: Request,
  env: Env,
): Promise<Response> {
  // ── OPTIONS preflight ───────────────────────────────────────────────────────
  if (request.method === 'OPTIONS') {
    return preflightResponse(env.ALLOWED_ORIGIN);
  }

  if (request.method !== 'POST') {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Méthode non autorisée' },
      405,
    );
  }

  // ── Extraction cookie session ───────────────────────────────────────────────
  const cookieHeader = request.headers.get('Cookie') ?? '';
  const signedSessionValue = extractCookie(cookieHeader, 'bff_session');

  if (!signedSessionValue) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Session absente ou expirée' },
      401,
    );
  }

  // ── Vérification CSRF ───────────────────────────────────────────────────────
  // POST est protégé par CSRF — l'extractCookie donne le sessionId brut
  // pour valider le token CSRF sans accès KV préalable.
  if (requiresCsrfProtection(request.method)) {
    const csrfHeader = request.headers.get('X-CSRF-Token') ?? '';
    // Le sessionId est la partie avant le point dans le cookie signé
    const sessionId = signedSessionValue.split('.')[0];

    const csrfValid = await verifyCsrfToken(
      csrfHeader,
      env.CSRF_SECRET,
      sessionId,
    );

    if (!csrfValid) {
      return jsonSecureResponse(
        env.ALLOWED_ORIGIN,
        { ok: false, error: 'Token CSRF invalide' },
        403,
      );
    }
  }

  // ── Récupération session KV ─────────────────────────────────────────────────
  // getSession(env, signedValue) → { sessionId: string; data: SessionData } | null
  const sessionResult = await getSession(env, signedSessionValue);

  if (!sessionResult) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Session invalide ou expirée' },
      401,
    );
  }

  // Déstructuration pour accès lisible
  const { sessionId, data: sessionData } = sessionResult;

  // ── Appel Supabase refresh token ────────────────────────────────────────────
  let supaData: Record<string, unknown>;
  let supaStatus: number;

  try {
    const supaResp = await fetch(
      `${env.SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: env.SUPABASE_ANON_KEY,
        },
        // sessionData.refreshToken est bien accessible via data: SessionData
        body: JSON.stringify({ refresh_token: sessionData.refreshToken }),
      },
    );
    supaStatus = supaResp.status;
    supaData = (await supaResp.json()) as Record<string, unknown>;
  } catch (err) {
    console.error('[BFF refresh] Erreur Supabase fetch:', (err as Error).message);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Service temporairement indisponible' },
      503,
    );
  }

  // ── Refresh token invalide → invalidation session ────────────────────────────
  if (supaStatus !== 200) {
    // Supprimer la session côté serveur — le client doit se reconnecter
    try {
      await deleteSession(env, sessionId);
    } catch {
      // Non bloquant — la session expirera via TTL KV de toute façon
    }

    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Session expirée. Reconnectez-vous.' },
      401,
    );
  }

  // ── Extraction nouveaux tokens ──────────────────────────────────────────────
  const newAccessToken = supaData.access_token as string | undefined;
  const newRefreshToken = supaData.refresh_token as string | undefined;

  if (!newAccessToken || !newRefreshToken) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Erreur interne lors du rafraîchissement' },
      500,
    );
  }

  // ── Mise à jour des tokens dans KV ─────────────────────────────────────────
  // updateSessionTokens(env, sessionId, accessToken, refreshToken) — 4 arguments
  // Le TTL est relu depuis env.SESSION_TTL_SECONDS directement dans la fonction
  await updateSessionTokens(env, sessionId, newAccessToken, newRefreshToken);

  // ── Renouvellement cookies session + CSRF ───────────────────────────────────
  const isProduction = env.ENVIRONMENT === 'production';
  const ttlSeconds = parseInt(env.SESSION_TTL_SECONDS, 10) || 86400;

  // Le signedSessionValue reste le même (l'ID de session n'a pas changé)
  const renewedSessionCookie = buildSessionCookie(
    signedSessionValue,
    ttlSeconds,
    isProduction,
  );

  // Nouveau token CSRF basé sur le même sessionId
  const newCsrfToken = await generateCsrfToken(env.CSRF_SECRET, sessionId);
  const csrfCookie = buildCsrfCookie(newCsrfToken, ttlSeconds, isProduction);

  // ── Construction de la réponse ──────────────────────────────────────────────
  // Réponse minimale : { ok: true } — AUCUN token transmis
  const baseResp = jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: true });

  // Cloner la réponse pour pouvoir modifier les headers (Response est immutable)
  const finalResp = new Response(baseResp.body, {
    status: baseResp.status,
    headers: baseResp.headers,
  });
  finalResp.headers.append('Set-Cookie', renewedSessionCookie);
  finalResp.headers.append('Set-Cookie', csrfCookie);

  return finalResp;
}
