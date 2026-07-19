// bff-vercel/api/bff/proxy.ts
// Proxy authentifié vers Supabase — Vercel Serverless Function
//
// Routes :
//   ANY /bff/api/*        → /rest/v1/* (PostgREST)
//   ANY /bff/functions/*  → /functions/v1/* (Edge Functions)
//
// Via vercel.json rewrites :
//   /bff/api/:path*        → /api/bff/proxy?_target=api&_path=:path*
//   /bff/functions/:path*  → /api/bff/proxy?_target=functions&_path=:path*

import type { VercelRequest, VercelResponse } from '@vercel/node';
import { getEnv } from '../../lib/types.js';
import {
  sendSecureJson,
  handlePreflight,
  isOriginAllowed,
  applySecurityHeaders,
} from '../../lib/headers.js';
import {
  verifyCsrfToken,
  requiresCsrfProtection,
  extractCsrfToken,
} from '../../lib/csrf.js';
import { getSession, extractCookie } from '../../lib/session.js';

// Headers à ne pas transmettre vers Supabase
const STRIP_REQUEST_HEADERS = new Set([
  'cookie',
  'host',
  'origin',
  'x-forwarded-for',
  'x-forwarded-host',
  'x-forwarded-proto',
  'x-vercel-id',
  'x-vercel-forwarded-for',
]);

// Headers Supabase à ne pas retransmettre vers le client
const STRIP_RESPONSE_HEADERS = new Set([
  'set-cookie',
  'strict-transport-security',
  'x-powered-by',
]);

export default async function handler(
  req: VercelRequest,
  res: VercelResponse,
): Promise<void> {
  // Preflight
  if (handlePreflight(req, res, process.env['ALLOWED_ORIGIN'] ?? '')) return;

  const env = getEnv();

  // Validation origin
  if (!isOriginAllowed(req, env.ALLOWED_ORIGIN)) {
    res.status(403).json({ ok: false, error: 'Forbidden' });
    return;
  }

  // Paramètres du rewrite
  const target = req.query['_target'] as string | undefined;
  const pathSuffix = req.query['_path'] as string | undefined;

  if (!target || !pathSuffix || !['api', 'functions'].includes(target)) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Paramètres proxy invalides' }, 400);
    return;
  }

  // ── Authentification via cookie session ───────────────────────────
  const cookieHeader = req.headers['cookie'];
  const signedSessionValue = extractCookie(
    Array.isArray(cookieHeader) ? cookieHeader.join('; ') : cookieHeader,
    'bff_session',
  );

  if (!signedSessionValue) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Non authentifié' }, 401);
    return;
  }

  const sessionData = await getSession(
    env.UPSTASH_REDIS_REST_URL,
    env.UPSTASH_REDIS_REST_TOKEN,
    env.SESSION_SECRET,
    signedSessionValue,
  );

  if (!sessionData) {
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Session invalide ou expirée. Reconnectez-vous.' }, 401);
    return;
  }

  // ── Vérification CSRF ─────────────────────────────────────────────
  if (requiresCsrfProtection(req.method ?? 'GET')) {
    const csrfToken = extractCsrfToken(req.headers as Record<string, string | string[] | undefined>);
    const sessionId = signedSessionValue.split('.')[0] ?? '';

    if (!verifyCsrfToken(csrfToken, env.CSRF_SECRET, sessionId)) {
      sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Token CSRF invalide' }, 403);
      return;
    }
  }

  // ── Construction URL Supabase ─────────────────────────────────────
  const targetPath =
    target === 'api' ? `/rest/v1/${pathSuffix}` : `/functions/v1/${pathSuffix}`;

  // Conserver la query string originale (ex: ?select=*, ?grant_type=...)
  // mais supprimer nos paramètres internes _target et _path
  const originalQuery = new URLSearchParams(
    req.query as Record<string, string>,
  );
  originalQuery.delete('_target');
  originalQuery.delete('_path');
  const queryString = originalQuery.toString();

  const targetUrl = `${env.SUPABASE_URL}${targetPath}${queryString ? `?${queryString}` : ''}`;

  // ── Construction headers upstream ────────────────────────────────
  const upstreamHeaders: Record<string, string> = {
    apikey: env.SUPABASE_ANON_KEY,
    Authorization: `Bearer ${sessionData.accessToken}`,
    Accept: 'application/json',
    Prefer: 'return=representation',
  };

  // Copier Content-Type si présent (pour POST/PUT/PATCH)
  const contentType = req.headers['content-type'];
  if (contentType) {
    upstreamHeaders['Content-Type'] = Array.isArray(contentType)
      ? contentType[0] ?? 'application/json'
      : contentType;
  } else if (['POST', 'PUT', 'PATCH'].includes(req.method ?? '')) {
    upstreamHeaders['Content-Type'] = 'application/json';
  }

  // Range header (pour pagination PostgREST)
  const range = req.headers['range'];
  if (range) {
    upstreamHeaders['Range'] = Array.isArray(range) ? range[0] ?? '' : range;
  }

  // ── Appel Supabase ────────────────────────────────────────────────
  let supaResp: Response;
  try {
    const bodyContent = ['GET', 'HEAD'].includes(req.method ?? '')
      ? undefined
      : JSON.stringify(req.body);

    supaResp = await fetch(targetUrl, {
      method: req.method ?? 'GET',
      headers: upstreamHeaders,
      body: bodyContent ?? null,
    });
  } catch (err) {
    console.error('[BFF-Vercel proxy] Supabase fetch error:', (err as Error).message);
    sendSecureJson(req, res, env.ALLOWED_ORIGIN, { ok: false, error: 'Service Supabase temporairement indisponible' }, 503);
    return;
  }

  // ── Transmission réponse vers client ──────────────────────────────
  const origin = req.headers['origin'] as string | undefined;
  applySecurityHeaders(res, env.ALLOWED_ORIGIN, origin);

  // Transmettre les headers Supabase (filtrés)
  for (const [key, value] of supaResp.headers.entries()) {
    if (!STRIP_RESPONSE_HEADERS.has(key.toLowerCase())) {
      res.setHeader(key, value);
    }
  }

  // Content-Range pour la pagination
  const contentRange = supaResp.headers.get('Content-Range');
  if (contentRange) res.setHeader('Content-Range', contentRange);

  const responseBody = await supaResp.text();
  res.status(supaResp.status).send(responseBody);
}
