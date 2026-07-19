// bff-vercel/api/bff/auth/[action].ts
// Routes d'authentification BFF — Vercel Serverless Function
//
// Cette fonction unique gère les 5 routes d'authentification grâce au
// routing dynamique Vercel ([action] = login | signup | logout | recover | refresh).
//
// Parité fonctionnelle garantie avec bff-cloudflare/src/auth/*.ts :
//   POST /bff/auth/login    → handleLogin
//   POST /bff/auth/signup   → handleSignup
//   POST /bff/auth/logout   → handleLogout
//   POST /bff/auth/recover  → handleRecover
//   POST /bff/auth/refresh  → handleRefresh

import type { VercelRequest, VercelResponse } from '@vercel/node';
import { getEnv } from '../../../lib/types.js';
import {
  sendSecureJson,
  handlePreflight,
  isOriginAllowed,
} from '../../../lib/headers.js';
import {
  generateCsrfToken,
  verifyCsrfToken,
  requiresCsrfProtection,
  extractCsrfToken,
} from '../../../lib/csrf.js';
import {
  createSession,
  getSession,
  updateSessionTokens,
  deleteSession,
  buildSessionCookie,
  buildLogoutCookie,
  buildCsrfCookie,
  checkRateLimit,
  extractCookie,
} from '../../../lib/session.js';
import type { SessionData } from '../../../lib/types.js';

// ── Rate limiting config (équivalent wrangler.toml : 5 req / 60s) ─────────
const RATE_LIMIT = 5;
const RATE_WINDOW_SECONDS = 60;

export default async function handler(
  req: VercelRequest,
  res: VercelResponse,
): Promise<void> {
  // Preflight
  if (handlePreflight(req, res, process.env['ALLOWED_ORIGIN'] ?? '')) return;

  // Validation origin
  const env = getEnv();
  if (!isOriginAllowed(req, env.ALLOWED_ORIGIN)) {
    res.status(403).json({ ok: false, error: 'Forbidden' });
    return;
  }

  const action = req.query['action'] as string;

  switch (action) {
    case 'login':
      return handleLogin(req, res, env);
    case 'signup':
      return handleSignup(req, res, env);
    case 'logout':
      return handleLogout(req, res, env);
    case 'recover':
      return handleRecover(req, res, env);
    case 'refresh':
      return handleRefresh(req, res, env);
    default:
      sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Action inconnue' }, 404);
  }
}

// ────────────────────────────────────────────────────────────────────────────
// LOGIN
// ────────────────────────────────────────────────────────────────────────────
async function handleLogin(
  req: VercelRequest,
  res: VercelResponse,
  env: ReturnType<typeof getEnv>,
): Promise<void> {
  if (req.method !== 'POST') {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Méthode non autorisée' }, 405);
    return;
  }

  // Rate limiting par IP
  const clientIp = (req.headers['x-forwarded-for'] as string | undefined)?.split(',')[0]?.trim() ?? 'unknown';
  const { allowed, remaining } = await checkRateLimit(
    env.UPSTASH_REDIS_REST_URL,
    env.UPSTASH_REDIS_REST_TOKEN,
    `auth:${clientIp}`,
    RATE_LIMIT,
    RATE_WINDOW_SECONDS,
  );

  if (!allowed) {
    res.setHeader('Retry-After', String(RATE_WINDOW_SECONDS));
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, {
      ok: false,
      error: 'Trop de tentatives. Attendez 60 secondes.',
    }, 429);
    return;
  }

  const body = req.body as { email?: unknown; password?: unknown } | undefined;
  const email = typeof body?.email === 'string' ? body.email.trim().toLowerCase() : '';
  const password = typeof body?.password === 'string' ? body.password : '';

  if (!email || !password) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Email et mot de passe requis' }, 400);
    return;
  }

  // Appel Supabase
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
    console.error('[BFF-Vercel login] Supabase error:', (err as Error).message);
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Service temporairement indisponible' }, 503);
    return;
  }

  if (supaStatus !== 200) {
    const rawMsg = extractSupabaseError(supaData).toLowerCase();
    const msg = translateLoginError(rawMsg, supaStatus);
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: msg }, supaStatus === 429 ? 429 : 401);
    return;
  }

  const { userId, accessToken, refreshToken } = extractTokens(supaData);
  if (!userId || !accessToken || !refreshToken) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Erreur de connexion interne' }, 500);
    return;
  }

  const ttlSeconds = parseInt(env.SESSION_TTL_SECONDS, 10) || 86400;
  const sessionData: SessionData = {
    userId, accessToken, refreshToken, authType: 'email',
    createdAt: Date.now(),
    expiresAt: Date.now() + ttlSeconds * 1000,
  };

  let signedSessionValue: string;
  try {
    signedSessionValue = await createSession(
      env.UPSTASH_REDIS_REST_URL,
      env.UPSTASH_REDIS_REST_TOKEN,
      env.SESSION_SECRET,
      sessionData,
      ttlSeconds,
    );
  } catch (err) {
    console.error('[BFF-Vercel login] Redis error:', (err as Error).message);
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Erreur création de session' }, 500);
    return;
  }

  const sessionId = signedSessionValue.split('.')[0] ?? '';
  const csrfToken = generateCsrfToken(env.CSRF_SECRET, sessionId);
  const isProd = env.ENVIRONMENT === 'production';

  res.setHeader('Set-Cookie', [
    buildSessionCookie(signedSessionValue, ttlSeconds, isProd),
    buildCsrfCookie(csrfToken, ttlSeconds, isProd),
  ]);

  sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: true, userId, authType: 'email' });
}

// ────────────────────────────────────────────────────────────────────────────
// SIGNUP
// ────────────────────────────────────────────────────────────────────────────
async function handleSignup(
  req: VercelRequest,
  res: VercelResponse,
  env: ReturnType<typeof getEnv>,
): Promise<void> {
  if (req.method !== 'POST') {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Méthode non autorisée' }, 405);
    return;
  }

  // Rate limiting
  const clientIp = (req.headers['x-forwarded-for'] as string | undefined)?.split(',')[0]?.trim() ?? 'unknown';
  const { allowed } = await checkRateLimit(
    env.UPSTASH_REDIS_REST_URL,
    env.UPSTASH_REDIS_REST_TOKEN,
    `auth:${clientIp}`,
    RATE_LIMIT,
    RATE_WINDOW_SECONDS,
  );
  if (!allowed) {
    res.setHeader('Retry-After', String(RATE_WINDOW_SECONDS));
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Trop de tentatives. Attendez 60 secondes.' }, 429);
    return;
  }

  const body = req.body as { email?: unknown; password?: unknown } | undefined;
  const email = typeof body?.email === 'string' ? body.email.trim().toLowerCase() : '';
  const password = typeof body?.password === 'string' ? body.password : '';

  if (!email || !password) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Email et mot de passe requis' }, 400);
    return;
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
    console.error('[BFF-Vercel signup] Supabase error:', (err as Error).message);
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Service temporairement indisponible' }, 503);
    return;
  }

  if (supaStatus !== 200) {
    const rawMsg = extractSupabaseError(supaData).toLowerCase();
    const msg = translateSignupError(rawMsg, supaStatus);
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: msg }, supaStatus >= 500 ? 502 : 400);
    return;
  }

  // Confirmation email requise
  const session = supaData['session'] as Record<string, unknown> | null;
  if (!session) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: true, needsEmailConfirmation: true });
    return;
  }

  // Session immédiate
  const { userId, accessToken, refreshToken } = extractTokensFromSession(session, supaData);
  if (!userId || !accessToken || !refreshToken) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Erreur interne lors de l\'inscription' }, 500);
    return;
  }

  const ttlSeconds = parseInt(env.SESSION_TTL_SECONDS, 10) || 86400;
  const sessionData: SessionData = {
    userId, accessToken, refreshToken, authType: 'email',
    createdAt: Date.now(), expiresAt: Date.now() + ttlSeconds * 1000,
  };

  const signedSessionValue = await createSession(
    env.UPSTASH_REDIS_REST_URL, env.UPSTASH_REDIS_REST_TOKEN,
    env.SESSION_SECRET, sessionData, ttlSeconds,
  );

  const sessionId = signedSessionValue.split('.')[0] ?? '';
  const csrfToken = generateCsrfToken(env.CSRF_SECRET, sessionId);
  const isProd = env.ENVIRONMENT === 'production';

  res.setHeader('Set-Cookie', [
    buildSessionCookie(signedSessionValue, ttlSeconds, isProd),
    buildCsrfCookie(csrfToken, ttlSeconds, isProd),
  ]);

  sendSecureJson(req, res, env.ALLOWED_ORIGIN, {
    ok: true, userId, authType: 'email', needsEmailConfirmation: false,
  });
}

// ────────────────────────────────────────────────────────────────────────────
// LOGOUT
// ────────────────────────────────────────────────────────────────────────────
async function handleLogout(
  req: VercelRequest,
  res: VercelResponse,
  env: ReturnType<typeof getEnv>,
): Promise<void> {
  if (req.method !== 'POST') {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Méthode non autorisée' }, 405);
    return;
  }

  const cookieHeader = req.headers['cookie'];
  const signedSessionValue = extractCookie(
    Array.isArray(cookieHeader) ? cookieHeader.join('; ') : cookieHeader,
    'bff_session',
  );

  if (!signedSessionValue) {
    // Déjà déconnecté
    respondLogout(req, res, env);
    return;
  }

  // Vérification CSRF
  if (requiresCsrfProtection(req.method ?? 'POST')) {
    const csrfToken = extractCsrfToken(req.headers as Record<string, string | string[] | undefined>);
    const sessionId = signedSessionValue.split('.')[0] ?? '';
    if (!verifyCsrfToken(csrfToken, env.CSRF_SECRET, sessionId)) {
      sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Token CSRF invalide' }, 403);
      return;
    }
  }

  const sessionData = await getSession(
    env.UPSTASH_REDIS_REST_URL, env.UPSTASH_REDIS_REST_TOKEN,
    env.SESSION_SECRET, signedSessionValue,
  );

  if (sessionData) {
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
      console.error('[BFF-Vercel logout] Supabase error (non-bloquant):', (err as Error).message);
    }

    await deleteSession(
      env.UPSTASH_REDIS_REST_URL, env.UPSTASH_REDIS_REST_TOKEN,
      env.SESSION_SECRET, signedSessionValue,
    );
  }

  respondLogout(req, res, env);
}

function respondLogout(req: VercelRequest, res: VercelResponse, env: ReturnType<typeof getEnv>): void {
  const isProd = env.ENVIRONMENT === 'production';
  res.setHeader('Set-Cookie', [
    buildLogoutCookie(isProd),
    'bff_csrf=; Max-Age=0; Path=/; SameSite=Strict',
  ]);
  sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: true });
}

// ────────────────────────────────────────────────────────────────────────────
// RECOVER
// ────────────────────────────────────────────────────────────────────────────
async function handleRecover(
  req: VercelRequest,
  res: VercelResponse,
  env: ReturnType<typeof getEnv>,
): Promise<void> {
  if (req.method !== 'POST') {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Méthode non autorisée' }, 405);
    return;
  }

  const body = req.body as { email?: unknown } | undefined;
  const email = typeof body?.email === 'string' ? body.email.trim().toLowerCase() : '';

  if (!email) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Email requis' }, 400);
    return;
  }

  try {
    const supaResp = await fetch(`${env.SUPABASE_URL}/auth/v1/recover`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: env.SUPABASE_ANON_KEY },
      body: JSON.stringify({ email }),
    });

    if (supaResp.status === 429) {
      res.setHeader('Retry-After', '60');
      sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Trop de demandes. Patientez quelques minutes.' }, 429);
      return;
    }

    // Anti-énumération : toujours retourner OK
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: true });
  } catch (err) {
    console.error('[BFF-Vercel recover] error:', (err as Error).message);
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Service temporairement indisponible' }, 503);
  }
}

// ────────────────────────────────────────────────────────────────────────────
// REFRESH
// ────────────────────────────────────────────────────────────────────────────
async function handleRefresh(
  req: VercelRequest,
  res: VercelResponse,
  env: ReturnType<typeof getEnv>,
): Promise<void> {
  if (req.method !== 'POST') {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Méthode non autorisée' }, 405);
    return;
  }

  const cookieHeader = req.headers['cookie'];
  const signedSessionValue = extractCookie(
    Array.isArray(cookieHeader) ? cookieHeader.join('; ') : cookieHeader,
    'bff_session',
  );

  if (!signedSessionValue) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Session absente' }, 401);
    return;
  }

  // Vérification CSRF
  if (requiresCsrfProtection(req.method ?? 'POST')) {
    const csrfToken = extractCsrfToken(req.headers as Record<string, string | string[] | undefined>);
    const sessionId = signedSessionValue.split('.')[0] ?? '';
    if (!verifyCsrfToken(csrfToken, env.CSRF_SECRET, sessionId)) {
      sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Token CSRF invalide' }, 403);
      return;
    }
  }

  const sessionData = await getSession(
    env.UPSTASH_REDIS_REST_URL, env.UPSTASH_REDIS_REST_TOKEN,
    env.SESSION_SECRET, signedSessionValue,
  );

  if (!sessionData) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Session invalide ou expirée' }, 401);
    return;
  }

  let supaData: Record<string, unknown>;
  let supaStatus: number;

  try {
    const supaResp = await fetch(
      `${env.SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: env.SUPABASE_ANON_KEY },
        body: JSON.stringify({ refresh_token: sessionData.refreshToken }),
      },
    );
    supaStatus = supaResp.status;
    supaData = (await supaResp.json()) as Record<string, unknown>;
  } catch (err) {
    console.error('[BFF-Vercel refresh] Supabase error:', (err as Error).message);
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Service temporairement indisponible' }, 503);
    return;
  }

  if (supaStatus !== 200) {
    await deleteSession(
      env.UPSTASH_REDIS_REST_URL, env.UPSTASH_REDIS_REST_TOKEN,
      env.SESSION_SECRET, signedSessionValue,
    );
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Session expirée. Reconnectez-vous.' }, 401);
    return;
  }

  const newAccessToken = supaData['access_token'] as string | undefined;
  const newRefreshToken = supaData['refresh_token'] as string | undefined;

  if (!newAccessToken || !newRefreshToken) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Erreur interne lors du rafraîchissement' }, 500);
    return;
  }

  const ttlSeconds = parseInt(env.SESSION_TTL_SECONDS, 10) || 86400;
  await updateSessionTokens(
    env.UPSTASH_REDIS_REST_URL, env.UPSTASH_REDIS_REST_TOKEN,
    env.SESSION_SECRET, signedSessionValue,
    newAccessToken, newRefreshToken, ttlSeconds,
  );

  const sessionId = signedSessionValue.split('.')[0] ?? '';
  const newCsrfToken = generateCsrfToken(env.CSRF_SECRET, sessionId);
  const isProd = env.ENVIRONMENT === 'production';

  res.setHeader('Set-Cookie', [
    buildSessionCookie(signedSessionValue, ttlSeconds, isProd),
    buildCsrfCookie(newCsrfToken, ttlSeconds, isProd),
  ]);

  sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: true });
}

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────
function extractSupabaseError(data: Record<string, unknown>): string {
  return (
    (data['error_description'] as string) ??
    (data['msg'] as string) ??
    (data['error'] as string) ??
    ''
  );
}

function extractTokens(data: Record<string, unknown>): {
  userId: string | undefined;
  accessToken: string | undefined;
  refreshToken: string | undefined;
} {
  return {
    accessToken: data['access_token'] as string | undefined,
    refreshToken: data['refresh_token'] as string | undefined,
    userId: (data['user'] as Record<string, unknown> | undefined)?.['id'] as string | undefined,
  };
}

function extractTokensFromSession(
  session: Record<string, unknown>,
  data: Record<string, unknown>,
): { userId: string | undefined; accessToken: string | undefined; refreshToken: string | undefined } {
  return {
    accessToken: session['access_token'] as string | undefined,
    refreshToken: session['refresh_token'] as string | undefined,
    userId: (data['user'] as Record<string, unknown> | undefined)?.['id'] as string | undefined,
  };
}

function translateLoginError(rawMsg: string, status: number): string {
  if (rawMsg.includes('invalid login credentials') || rawMsg.includes('invalid_credentials')) return 'Email ou mot de passe incorrect.';
  if (rawMsg.includes('email not confirmed')) return 'Veuillez confirmer votre email avant de vous connecter.';
  if (rawMsg.includes('too many requests') || status === 429) return 'Trop de tentatives. Réessayez dans quelques minutes.';
  if (rawMsg.length > 0) return `Connexion impossible : ${rawMsg}`;
  return `Erreur de connexion (${status}). Réessayez.`;
}

function translateSignupError(rawMsg: string, status: number): string {
  if (rawMsg.includes('already_registered') || rawMsg.includes('email already')) return 'Cette adresse email est déjà associée à un compte.';
  if (rawMsg.includes('password') && rawMsg.includes('weak')) return 'Mot de passe trop faible.';
  if (rawMsg.includes('invalid email') || status === 422) return 'L\'adresse email est invalide.';
  if (rawMsg.includes('rate limit') || status === 429) return 'Trop de tentatives. Patientez quelques minutes.';
  if (rawMsg.length > 0) return `Inscription impossible : ${rawMsg}`;
  return `Erreur lors de l'inscription (${status}). Réessayez.`;
}
