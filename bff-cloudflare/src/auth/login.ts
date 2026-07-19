// bff-cloudflare/src/auth/login.ts
// POST /bff/auth/login — Authentification BFF sécurisée
//
// Flux :
//   1. Rate limiter (5 req / 60 s par IP)
//   2. Validation corps JSON (email + password)
//   3. Appel Supabase Auth (token?grant_type=password)
//   4. Création session KV — token JAMAIS transmis au navigateur
//   5. Cookie HttpOnly session + cookie CSRF (lisible JS, non HttpOnly)
//   6. Réponse JSON : { ok: true, userId, authType }

import { Env } from '../types.js';
import { jsonSecureResponse, preflightResponse } from '../security/headers.js';
import { generateCsrfToken } from '../security/csrf.js';
import {
  createSession,
  buildSessionCookie,
  buildCsrfCookie,
  extractCookie,
} from '../session/store.js';

export async function handleLogin(request: Request, env: Env): Promise<Response> {
  if (request.method === 'OPTIONS') return preflightResponse(env.ALLOWED_ORIGIN);

  if (request.method !== 'POST') {
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Méthode non autorisée' }, 405);
  }

  // ── Rate limiting ─────────────────────────────────────────────────
  const { success: rateLimitOk } = await env.AUTH_RATE_LIMITER.limit({
    key: request.headers.get('CF-Connecting-IP') ?? 'unknown',
  });
  if (!rateLimitOk) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Trop de tentatives. Attendez 60 secondes.' },
      429,
      { 'Retry-After': '60' },
    );
  }

  // ── Parsing ───────────────────────────────────────────────────────
  let body: { email?: unknown; password?: unknown };
  try {
    body = (await request.json()) as { email?: unknown; password?: unknown };
  } catch {
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Corps JSON invalide' }, 400);
  }

  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  const password = typeof body.password === 'string' ? body.password : '';

  if (!email || !password) {
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Email et mot de passe requis' }, 400);
  }

  // ── Appel Supabase Auth ───────────────────────────────────────────
  let supaData: Record<string, unknown>;
  let supaStatus: number;
  try {
    const supaResp = await fetch(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: env.SUPABASE_ANON_KEY },
      body: JSON.stringify({ email, password }),
    });
    supaStatus = supaResp.status;
    supaData = (await supaResp.json()) as Record<string, unknown>;
  } catch (err) {
    console.error('[BFF login] Supabase fetch error:', (err as Error).message);
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Service temporairement indisponible' }, 503);
  }

  if (supaStatus !== 200) {
    const rawMsg = extractSupabaseError(supaData).toLowerCase();
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: translateLoginError(rawMsg, supaStatus) },
      supaStatus === 429 ? 429 : 401,
    );
  }

  // ── Extraction tokens ─────────────────────────────────────────────
  const accessToken = supaData.access_token as string | undefined;
  const refreshToken = supaData.refresh_token as string | undefined;
  const userId = (supaData.user as Record<string, unknown> | undefined)?.id as string | undefined;

  if (!accessToken || !refreshToken || !userId) {
    console.error('[BFF login] Réponse Supabase incomplète');
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Erreur de connexion interne' }, 500);
  }

  // ── Création session KV ───────────────────────────────────────────
  let signedSessionCookieValue: string;
  try {
    signedSessionCookieValue = await createSession(env, {
      userId,
      accessToken,
      refreshToken,
      authType: 'email',
    });
  } catch (err) {
    console.error('[BFF login] KV createSession error:', (err as Error).message);
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Erreur création de session' }, 500);
  }

  // ── Génération token CSRF ─────────────────────────────────────────
  const sessionId = signedSessionCookieValue.split('.')[0] ?? '';
  const csrfToken = await generateCsrfToken(env.CSRF_SECRET, sessionId);

  const ttlSeconds = parseInt(env.SESSION_TTL_SECONDS, 10) || 86400;
  const isProd = env.ENVIRONMENT === 'production';

  const resp = jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: true, userId, authType: 'email' });
  const finalResp = new Response(resp.body, resp);
  finalResp.headers.append('Set-Cookie', buildSessionCookie(signedSessionCookieValue, ttlSeconds, isProd));
  finalResp.headers.append('Set-Cookie', buildCsrfCookie(csrfToken, ttlSeconds, isProd));
  return finalResp;
}

function extractSupabaseError(data: Record<string, unknown>): string {
  return (
    (data.error_description as string) ??
    (data.msg as string) ??
    (data.error as string) ??
    ''
  );
}

function translateLoginError(rawMsg: string, status: number): string {
  if (rawMsg.includes('invalid login credentials') || rawMsg.includes('invalid_credentials'))
    return 'Email ou mot de passe incorrect.';
  if (rawMsg.includes('email not confirmed'))
    return 'Veuillez confirmer votre email avant de vous connecter.';
  if (rawMsg.includes('too many requests') || status === 429)
    return 'Trop de tentatives. Réessayez dans quelques minutes.';
  if (rawMsg.length > 0) return `Connexion impossible : ${rawMsg}`;
  return `Erreur de connexion (${status}). Réessayez.`;
}

// Importé mais réexporté pour éviter un import inutile dans logout.ts/proxy.ts
export { extractCookie };
