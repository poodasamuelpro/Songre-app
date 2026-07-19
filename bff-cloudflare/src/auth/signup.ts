// bff-cloudflare/src/auth/signup.ts
// POST /bff/auth/signup — Inscription via BFF

import { Env } from '../types.js';
import { jsonSecureResponse, preflightResponse } from '../security/headers.js';
import { generateCsrfToken } from '../security/csrf.js';
import {
  createSession,
  buildSessionCookie,
  buildCsrfCookie,
  extractCookie,
} from '../session/store.js';

export async function handleSignup(request: Request, env: Env): Promise<Response> {
  if (request.method === 'OPTIONS') return preflightResponse(env.ALLOWED_ORIGIN);

  if (request.method !== 'POST') {
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Méthode non autorisée' }, 405);
  }

  // Rate limiting
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

  let supaData: Record<string, unknown>;
  let supaStatus: number;
  try {
    const supaResp = await fetch(`${env.SUPABASE_URL}/auth/v1/signup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: env.SUPABASE_ANON_KEY },
      body: JSON.stringify({ email, password }),
    });
    supaStatus = supaResp.status;
    supaData = (await supaResp.json()) as Record<string, unknown>;
  } catch (err) {
    console.error('[BFF signup] Supabase fetch error:', (err as Error).message);
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Service temporairement indisponible' }, 503);
  }

  if (supaStatus !== 200) {
    const rawMsg = ((supaData.error_description as string) ?? (supaData.msg as string) ?? '').toLowerCase();
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: translateSignupError(rawMsg, supaStatus) },
      supaStatus >= 500 ? 502 : 400,
    );
  }

  // Cas : confirmation email requise
  const session = supaData.session as Record<string, unknown> | null;
  if (!session) {
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: true, needsEmailConfirmation: true });
  }

  // Cas : session immédiate
  const accessToken = session.access_token as string | undefined;
  const refreshToken = session.refresh_token as string | undefined;
  const userId = (supaData.user as Record<string, unknown> | undefined)?.id as string | undefined;

  if (!accessToken || !refreshToken || !userId) {
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: false, error: 'Erreur interne lors de l\'inscription' }, 500);
  }

  const signedSessionCookieValue = await createSession(env, {
    userId, accessToken, refreshToken, authType: 'email',
  });

  const sessionId = signedSessionCookieValue.split('.')[0] ?? '';
  const csrfToken = await generateCsrfToken(env.CSRF_SECRET, sessionId);
  const ttlSeconds = parseInt(env.SESSION_TTL_SECONDS, 10) || 86400;
  const isProd = env.ENVIRONMENT === 'production';

  const resp = jsonSecureResponse(env.ALLOWED_ORIGIN, {
    ok: true, userId, authType: 'email', needsEmailConfirmation: false,
  });
  const finalResp = new Response(resp.body, resp);
  finalResp.headers.append('Set-Cookie', buildSessionCookie(signedSessionCookieValue, ttlSeconds, isProd));
  finalResp.headers.append('Set-Cookie', buildCsrfCookie(csrfToken, ttlSeconds, isProd));
  return finalResp;
}

function translateSignupError(rawMsg: string, status: number): string {
  if (rawMsg.includes('already_registered') || rawMsg.includes('email already'))
    return 'Cette adresse email est déjà associée à un compte.';
  if (rawMsg.includes('password') && rawMsg.includes('weak'))
    return 'Mot de passe trop faible. Utilisez au moins 8 caractères.';
  if (rawMsg.includes('invalid email') || status === 422)
    return 'L\'adresse email est invalide.';
  if (rawMsg.includes('rate limit') || status === 429)
    return 'Trop de tentatives. Patientez quelques minutes.';
  if (status === 500 && rawMsg.includes('database error'))
    return 'Inscription temporairement indisponible. Réessayez dans quelques minutes.';
  if (rawMsg.length > 0) return `Inscription impossible : ${rawMsg}`;
  return `Erreur lors de l'inscription (${status}). Réessayez.`;
}

export { extractCookie };
