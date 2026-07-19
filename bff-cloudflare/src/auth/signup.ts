// bff-cloudflare/src/auth/signup.ts
// POST /bff/auth/signup — Inscription via BFF
//
// Flux :
//   1. Rate limiter (même limite que login — évite spam d'inscription)
//   2. Validation email + password
//   3. Appel Supabase /auth/v1/signup
//   4. Si session immédiate (email auto-confirmé) → KV + cookies
//   5. Si confirmation email requise → réponse sans cookie (normal)

import { Env, SessionData } from '../types.js';
import {
  jsonSecureResponse,
  preflightResponse,
} from '../security/headers.js';
import { generateCsrfToken } from '../security/csrf.js';
import {
  createSession,
  buildCsrfCookie,
} from '../session/store.js';

export async function handleSignup(
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

  // Parsing
  let body: { email?: unknown; password?: unknown };
  try {
    body = (await request.json()) as { email?: unknown; password?: unknown };
  } catch {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Corps JSON invalide' },
      400,
    );
  }

  const email =
    typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  const password = typeof body.password === 'string' ? body.password : '';

  if (!email || !password) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Email et mot de passe requis' },
      400,
    );
  }

  // Appel Supabase Auth signup
  let supaData: Record<string, unknown>;
  let supaStatus: number;

  try {
    const supaResp = await fetch(`${env.SUPABASE_URL}/auth/v1/signup`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: env.SUPABASE_ANON_KEY,
      },
      body: JSON.stringify({ email, password }),
    });
    supaStatus = supaResp.status;
    supaData = (await supaResp.json()) as Record<string, unknown>;
  } catch (err) {
    console.error('[BFF signup] Supabase fetch error:', (err as Error).message);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Service temporairement indisponible' },
      503,
    );
  }

  // Erreurs Supabase
  if (supaStatus !== 200) {
    const rawMsg = (
      (supaData.error_description as string) ??
      (supaData.msg as string) ??
      (supaData.error as string) ??
      ''
    ).toLowerCase();

    const msg = translateSignupError(rawMsg, supaStatus);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: msg },
      supaStatus >= 500 ? 502 : 400,
    );
  }

  // Cas 1 : confirmation email requise (session null)
  const session = supaData.session as Record<string, unknown> | null;
  if (!session) {
    return jsonSecureResponse(env.ALLOWED_ORIGIN, {
      ok: true,
      needsEmailConfirmation: true,
    });
  }

  // Cas 2 : session immédiate (email auto-confirmé)
  const accessToken = session.access_token as string | undefined;
  const refreshToken = session.refresh_token as string | undefined;
  const userObj = supaData.user as Record<string, unknown> | undefined;
  const userId = userObj?.id as string | undefined;

  if (!accessToken || !refreshToken || !userId) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Erreur interne lors de l\'inscription' },
      500,
    );
  }

  const ttlSeconds = parseInt(env.SESSION_TTL_SECONDS, 10) || 86400;

  const sessionData: SessionData = {
    userId,
    accessToken,
    refreshToken,
    authType: 'email',
    createdAt: Date.now(),
    expiresAt: Date.now() + ttlSeconds * 1000,
  };

  let signedSessionCookieValue: string;
  try {
    signedSessionCookieValue = await createSession(
      env.SESSIONS,
      env.SESSION_SECRET,
      sessionData,
      ttlSeconds,
    );
  } catch (err) {
    console.error('[BFF signup] KV createSession error:', (err as Error).message);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Erreur création de session' },
      500,
    );
  }

  const sessionId = signedSessionCookieValue.split('.')[0];
  const csrfToken = await generateCsrfToken(env.CSRF_SECRET, sessionId);

  const isProduction = env.ENVIRONMENT === 'production';
  const secureCookieFlag = isProduction ? '; Secure' : '';

  const sessionCookie =
    `bff_session=${signedSessionCookieValue}` +
    '; HttpOnly' +
    secureCookieFlag +
    '; SameSite=Strict' +
    `; Max-Age=${ttlSeconds}` +
    '; Path=/';

  const csrfCookie = buildCsrfCookie(csrfToken, ttlSeconds, isProduction);

  const resp = jsonSecureResponse(env.ALLOWED_ORIGIN, {
    ok: true,
    userId,
    authType: 'email',
    needsEmailConfirmation: false,
  });

  const finalResp = new Response(resp.body, resp);
  finalResp.headers.append('Set-Cookie', sessionCookie);
  finalResp.headers.append('Set-Cookie', csrfCookie);

  return finalResp;
}

function translateSignupError(rawMsg: string, status: number): string {
  if (
    rawMsg.includes('user already registered') ||
    rawMsg.includes('already_registered') ||
    rawMsg.includes('email already')
  ) {
    return 'Cette adresse email est déjà associée à un compte.';
  }
  if (rawMsg.includes('password') && rawMsg.includes('weak')) {
    return 'Mot de passe trop faible. Utilisez au moins 8 caractères avec lettres et chiffres.';
  }
  if (rawMsg.includes('invalid email') || status === 422) {
    return 'L\'adresse email saisie est invalide.';
  }
  if (rawMsg.includes('rate limit') || status === 429) {
    return 'Trop de tentatives. Patientez quelques minutes.';
  }
  if (status === 500 && rawMsg.includes('database error')) {
    return 'Inscription temporairement indisponible. Réessayez dans quelques minutes.';
  }
  if (rawMsg.length > 0) {
    return `Inscription impossible : ${rawMsg}`;
  }
  return `Erreur lors de l'inscription (${status}). Réessayez.`;
}
