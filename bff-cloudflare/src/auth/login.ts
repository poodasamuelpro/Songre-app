// bff-cloudflare/src/auth/login.ts
// POST /bff/auth/login — Authentification BFF sécurisée
//
// Flux :
//   1. Rate limiter (5 req / 60 s par IP)
//   2. Validation corps JSON (email + password)
//   3. Appel Supabase Auth (token?grant_type=password)
//   4. Stockage session dans KV (token JAMAIS transmis au client)
//   5. Cookie HttpOnly session + cookie CSRF (readable JS, non-HttpOnly)
//   6. Réponse JSON : { ok: true, userId, authType }
//
// Sécurité : les tokens JWT Supabase ne quittent JAMAIS le serveur.

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

export async function handleLogin(
  request: Request,
  env: Env,
): Promise<Response> {
  // ── OPTIONS preflight ─────────────────────────────────────────────
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

  // ── Rate limiting (Cloudflare Workers Rate Limiting API) ──────────
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

  // ── Parsing du corps ──────────────────────────────────────────────
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

  // ── Appel Supabase Auth ───────────────────────────────────────────
  let supaData: Record<string, unknown>;
  let supaStatus: number;

  try {
    const supaResp = await fetch(
      `${env.SUPABASE_URL}/auth/v1/token?grant_type=password`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: env.SUPABASE_ANON_KEY,
        },
        body: JSON.stringify({ email, password }),
      },
    );
    supaStatus = supaResp.status;
    supaData = (await supaResp.json()) as Record<string, unknown>;
  } catch (err) {
    console.error('[BFF login] Supabase fetch error:', (err as Error).message);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Service temporairement indisponible' },
      503,
    );
  }

  // ── Gestion erreurs Supabase ──────────────────────────────────────
  if (supaStatus !== 200) {
    const rawMsg = (
      (supaData.error_description as string) ??
      (supaData.msg as string) ??
      (supaData.error as string) ??
      ''
    ).toLowerCase();

    const msg = translateLoginError(rawMsg, supaStatus);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: msg },
      supaStatus === 429 ? 429 : 401,
    );
  }

  // ── Extraction tokens ─────────────────────────────────────────────
  const accessToken = supaData.access_token as string | undefined;
  const refreshToken = supaData.refresh_token as string | undefined;
  const userObj = supaData.user as Record<string, unknown> | undefined;
  const userId = userObj?.id as string | undefined;

  if (!accessToken || !refreshToken || !userId) {
    console.error('[BFF login] Réponse Supabase incomplète');
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Erreur de connexion interne' },
      500,
    );
  }

  // ── Création session KV ───────────────────────────────────────────
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
    console.error('[BFF login] KV createSession error:', (err as Error).message);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Erreur création de session' },
      500,
    );
  }

  // ── Génération token CSRF ─────────────────────────────────────────
  // Le sessionId est la partie avant le point (avant la signature HMAC)
  const sessionId = signedSessionCookieValue.split('.')[0];
  const csrfToken = await generateCsrfToken(env.CSRF_SECRET, sessionId);

  // ── Réponse avec cookies ──────────────────────────────────────────
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

  const responseBody = {
    ok: true,
    userId,
    authType: 'email',
  };

  const resp = jsonSecureResponse(env.ALLOWED_ORIGIN, responseBody, 200);

  // Ajout des cookies (Response est immuable — on reconstruit)
  const finalResp = new Response(resp.body, resp);
  finalResp.headers.append('Set-Cookie', sessionCookie);
  finalResp.headers.append('Set-Cookie', csrfCookie);

  return finalResp;
}

// ── Traduction erreurs Supabase → messages français ───────────────────
function translateLoginError(rawMsg: string, status: number): string {
  if (rawMsg.includes('invalid login credentials') || rawMsg.includes('invalid_credentials')) {
    return 'Email ou mot de passe incorrect.';
  }
  if (rawMsg.includes('email not confirmed')) {
    return 'Veuillez confirmer votre email avant de vous connecter.';
  }
  if (rawMsg.includes('too many requests') || status === 429) {
    return 'Trop de tentatives. Réessayez dans quelques minutes.';
  }
  if (rawMsg.includes('user not found')) {
    return 'Aucun compte associé à cet email.';
  }
  if (rawMsg.length > 0) {
    return `Connexion impossible : ${rawMsg}`;
  }
  return `Erreur de connexion (${status}). Réessayez.`;
}
