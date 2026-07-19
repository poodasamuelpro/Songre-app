// bff-cloudflare/src/auth/logout.ts
// POST /bff/auth/logout — Déconnexion BFF
//
// Flux :
//   1. Lire + valider le cookie de session
//   2. Récupérer le token Supabase depuis KV
//   3. Invalider la session Supabase côté serveur
//   4. Supprimer la session du KV
//   5. Effacer les cookies (Max-Age=0)
//
// Note : même si le cookie est absent/invalide, on renvoie 200 pour
// éviter de divulguer des informations sur l'état de session.

import { Env } from '../types.js';
import {
  jsonSecureResponse,
  preflightResponse,
} from '../security/headers.js';
import { requiresCsrfProtection, verifyCsrfToken } from '../security/csrf.js';
import {
  getSession,
  deleteSession,
  buildLogoutCookie,
} from '../session/store.js';

export async function handleLogout(
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

  // ── Extraction du cookie session ──────────────────────────────────
  const cookieHeader = request.headers.get('Cookie') ?? '';
  const signedSessionValue = extractCookie(cookieHeader, 'bff_session');

  if (!signedSessionValue) {
    // Pas de session — déjà déconnecté
    return buildLogoutResponse(env.ALLOWED_ORIGIN, env.ENVIRONMENT === 'production');
  }

  // ── Vérification CSRF (POST → obligatoire) ────────────────────────
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

  if (sessionData) {
    // Invalider la session Supabase côté serveur (best-effort)
    try {
      await fetch(`${env.SUPABASE_URL}/auth/v1/logout`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: env.SUPABASE_ANON_KEY,
          Authorization: `Bearer ${sessionData.accessToken}`,
        },
      });
    } catch (err) {
      // Non bloquant — la session sera supprimée du KV de toute façon
      console.error('[BFF logout] Supabase logout error:', (err as Error).message);
    }

    // Supprimer du KV
    const sessionId = signedSessionValue.split('.')[0];
    await deleteSession(env.SESSIONS, sessionId);
  }

  return buildLogoutResponse(env.ALLOWED_ORIGIN, env.ENVIRONMENT === 'production');
}

function buildLogoutResponse(allowedOrigin: string, isProduction: boolean): Response {
  const logoutCookie = buildLogoutCookie(isProduction);
  const csrfClearCookie =
    'bff_csrf=; HttpOnly=false' +
    '; Max-Age=0' +
    '; Path=/' +
    '; SameSite=Strict';

  const resp = jsonSecureResponse(allowedOrigin, { ok: true }, 200);
  const finalResp = new Response(resp.body, resp);
  finalResp.headers.append('Set-Cookie', logoutCookie);
  finalResp.headers.append('Set-Cookie', csrfClearCookie);

  return finalResp;
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
