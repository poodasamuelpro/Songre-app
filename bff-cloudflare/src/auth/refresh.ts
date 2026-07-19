// bff-cloudflare/src/auth/refresh.ts
// POST /bff/auth/refresh — Rafraîchissement silencieux du token JWT
//
// Flux :
//   1. Lire cookie session (HttpOnly → transparent pour le client)
//   2. Récupérer les tokens depuis KV
//   3. Appeler Supabase /auth/v1/token?grant_type=refresh_token
//   4. Mettre à jour les tokens dans KV (nouveaux tokens, JAMAIS transmis)
//   5. Renouveler le cookie session (nouveau Max-Age)
//   6. Retourner { ok: true } sans aucun token
//
// Ce endpoint est appelé automatiquement par le client Flutter Web
// avant l'expiration du cookie (ex: toutes les 50 minutes).

import { Env, SessionData } from '../types.js';
import {
  jsonSecureResponse,
  preflightResponse,
} from '../security/headers.js';
import { requiresCsrfProtection, verifyCsrfToken } from '../security/csrf.js';
import {
  getSession,
  updateSessionTokens,
  buildCsrfCookie,
} from '../session/store.js';
import { generateCsrfToken } from '../security/csrf.js';

export async function handleRefresh(
  request: Request,
  env: Env,
): Promise<Response> {
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

  // ── Extraction cookie session ─────────────────────────────────────
  const cookieHeader = request.headers.get('Cookie') ?? '';
  const signedSessionValue = extractCookie(cookieHeader, 'bff_session');

  if (!signedSessionValue) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Session absente ou expirée' },
      401,
    );
  }

  // ── Vérification CSRF ─────────────────────────────────────────────
  if (requiresCsrfProtection(request.method)) {
    const csrfHeader = request.headers.get('X-CSRF-Token') ?? '';
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

  // ── Récupération session KV ───────────────────────────────────────
  const sessionData = await getSession(
    env.SESSIONS,
    env.SESSION_SECRET,
    signedSessionValue,
  );

  if (!sessionData) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Session invalide ou expirée' },
      401,
    );
  }

  // ── Appel Supabase refresh ────────────────────────────────────────
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
        body: JSON.stringify({ refresh_token: sessionData.refreshToken }),
      },
    );
    supaStatus = supaResp.status;
    supaData = (await supaResp.json()) as Record<string, unknown>;
  } catch (err) {
    console.error('[BFF refresh] Supabase fetch error:', (err as Error).message);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Service temporairement indisponible' },
      503,
    );
  }

  if (supaStatus !== 200) {
    // Refresh token invalide/expiré → session terminée
    const sessionId = signedSessionValue.split('.')[0];
    await deleteSessionSilently(env.SESSIONS, sessionId);

    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Session expirée. Reconnectez-vous.' },
      401,
    );
  }

  // ── Mise à jour des tokens dans KV ────────────────────────────────
  const newAccessToken = supaData.access_token as string | undefined;
  const newRefreshToken = supaData.refresh_token as string | undefined;

  if (!newAccessToken || !newRefreshToken) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Erreur interne lors du rafraîchissement' },
      500,
    );
  }

  const sessionId = signedSessionValue.split('.')[0];
  const ttlSeconds = parseInt(env.SESSION_TTL_SECONDS, 10) || 86400;

  await updateSessionTokens(
    env.SESSIONS,
    sessionId,
    newAccessToken,
    newRefreshToken,
    ttlSeconds,
  );

  // ── Renouveler le cookie session + CSRF ───────────────────────────
  const isProduction = env.ENVIRONMENT === 'production';
  const secureCookieFlag = isProduction ? '; Secure' : '';

  const renewedSessionCookie =
    `bff_session=${signedSessionValue}` +
    '; HttpOnly' +
    secureCookieFlag +
    '; SameSite=Strict' +
    `; Max-Age=${ttlSeconds}` +
    '; Path=/';

  const newCsrfToken = await generateCsrfToken(env.CSRF_SECRET, sessionId);
  const csrfCookie = buildCsrfCookie(newCsrfToken, ttlSeconds, isProduction);

  const resp = jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: true });
  const finalResp = new Response(resp.body, resp);
  finalResp.headers.append('Set-Cookie', renewedSessionCookie);
  finalResp.headers.append('Set-Cookie', csrfCookie);

  return finalResp;
}

async function deleteSessionSilently(
  kv: KVNamespace,
  sessionId: string,
): Promise<void> {
  try {
    await kv.delete(`session:${sessionId}`);
  } catch {
    // Non bloquant
  }
}

function extractCookie(cookieHeader: string, name: string): string | null {
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
