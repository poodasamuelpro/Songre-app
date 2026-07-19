// bff-cloudflare/src/auth/logout.ts
// POST /bff/auth/logout — Déconnexion BFF

import { Env } from '../types.js';
import { jsonSecureResponse, preflightResponse } from '../security/headers.js';
import { requiresCsrfProtection, verifyCsrfToken } from '../security/csrf.js';
import {
  getSession,
  deleteSession,
  buildLogoutCookie,
  extractCookie,
  validateSessionCookie,
} from '../session/store.js';

export async function handleLogout(request: Request, env: Env): Promise<Response> {
  if (request.method === 'OPTIONS') return preflightResponse(env.ALLOWED_ORIGIN);

  if (request.method !== 'POST') {
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Méthode non autorisée' }, 405);
  }

  const cookieHeader = request.headers.get('Cookie') ?? '';
  const signedSessionValue = extractCookie(cookieHeader, 'bff_session');

  if (!signedSessionValue) {
    return buildLogoutResponse(env);
  }

  // Vérification CSRF
  if (requiresCsrfProtection(request.method)) {
    const csrfHeader = request.headers.get('X-CSRF-Token') ?? '';
    const sessionId = (await validateSessionCookie(signedSessionValue, env.SESSION_SECRET)) ?? '';
    if (!sessionId || !await verifyCsrfToken(csrfHeader, env.CSRF_SECRET, sessionId)) {
      return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Token CSRF invalide' }, 403);
    }
  }

  // Récupération session
  const sessionResult = await getSession(env, signedSessionValue);

  if (sessionResult) {
    // Invalider la session Supabase (best-effort)
    try {
      await fetch(`${env.SUPABASE_URL}/auth/v1/logout`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: env.SUPABASE_ANON_KEY,
          Authorization: `Bearer ${sessionResult.data.accessToken}`,
        },
      });
    } catch (err) {
      console.error('[BFF logout] Supabase logout error (non-bloquant):', (err as Error).message);
    }
    await deleteSession(env, sessionResult.sessionId);
  }

  return buildLogoutResponse(env);
}

function buildLogoutResponse(env: Env): Response {
  const isProd = env.ENVIRONMENT === 'production';
  const resp = jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: true });
  const finalResp = new Response(resp.body, resp);
  finalResp.headers.append('Set-Cookie', buildLogoutCookie(isProd));
  finalResp.headers.append('Set-Cookie', `bff_csrf=; Max-Age=0; Path=/; SameSite=Strict`);
  return finalResp;
}
