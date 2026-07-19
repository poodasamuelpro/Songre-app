// bff-cloudflare/src/proxy/supabase.ts
// Proxy authentifié vers Supabase — toutes les requêtes données
//
// Routes couvertes :
//   ANY /bff/api/*        → proxy vers /rest/v1/* (PostgREST API)
//   ANY /bff/functions/*  → proxy vers /functions/v1/* (Edge Functions)
//
// Flux :
//   1. Lire cookie session (HttpOnly)
//   2. Récupérer access_token depuis KV
//   3. Vérifier CSRF pour les méthodes mutantes (POST/PATCH/PUT/DELETE)
//   4. Transmettre la requête à Supabase avec le token Bearer
//   5. Retransmettre la réponse Supabase au client SANS exposer le token
//
// Ce proxy garantit que le token Supabase ne transite JAMAIS via le
// navigateur — seule la réponse de données (JSON) est transmise.

import { Env } from '../types.js';
import {
  jsonSecureResponse,
  preflightResponse,
  applySecurityHeaders,
} from '../security/headers.js';
import { requiresCsrfProtection, verifyCsrfToken } from '../security/csrf.js';
import { getSession } from '../session/store.js';

// Headers à NE PAS transmettre vers Supabase (sécurité, réduction surface)
const STRIP_REQUEST_HEADERS = new Set([
  'cookie',
  'host',
  'origin',
  'cf-connecting-ip',
  'cf-ipcountry',
  'cf-ray',
  'cf-visitor',
  'x-forwarded-for',
  'x-forwarded-proto',
]);

// Headers Supabase à NE PAS retransmettre vers le client
const STRIP_RESPONSE_HEADERS = new Set([
  'set-cookie',
  'strict-transport-security', // ajouté par le BFF lui-même
]);

export async function handleProxy(
  request: Request,
  env: Env,
  pathSuffix: string, // ce qui vient après /bff/api/ ou /bff/functions/
  targetBase: 'api' | 'functions',
): Promise<Response> {
  // ── OPTIONS preflight ─────────────────────────────────────────────
  if (request.method === 'OPTIONS') {
    return preflightResponse(env.ALLOWED_ORIGIN);
  }

  // ── Extraction + validation cookie session ────────────────────────
  const cookieHeader = request.headers.get('Cookie') ?? '';
  const signedSessionValue = extractCookie(cookieHeader, 'bff_session');

  if (!signedSessionValue) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Non authentifié' },
      401,
    );
  }

  // ── Récupération session (tokens) depuis KV ───────────────────────
  const sessionData = await getSession(
    env.SESSIONS,
    env.SESSION_SECRET,
    signedSessionValue,
  );

  if (!sessionData) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Session invalide ou expirée. Reconnectez-vous.' },
      401,
    );
  }

  // ── Vérification CSRF pour méthodes mutantes ──────────────────────
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

  // ── Construction URL Supabase cible ───────────────────────────────
  const targetPath =
    targetBase === 'api'
      ? `/rest/v1/${pathSuffix}`
      : `/functions/v1/${pathSuffix}`;

  const requestUrl = new URL(request.url);
  const targetUrl = `${env.SUPABASE_URL}${targetPath}${requestUrl.search}`;

  // ── Construction des headers pour Supabase ────────────────────────
  const upstreamHeaders = new Headers();

  // Copier les headers du client en filtrant les headers sensibles/CF
  for (const [key, value] of request.headers.entries()) {
    if (!STRIP_REQUEST_HEADERS.has(key.toLowerCase())) {
      upstreamHeaders.set(key, value);
    }
  }

  // Injecter les headers d'authentification Supabase
  upstreamHeaders.set('apikey', env.SUPABASE_ANON_KEY);
  upstreamHeaders.set(
    'Authorization',
    `Bearer ${sessionData.accessToken}`,
  );

  // Assurer Content-Type pour les requêtes JSON
  if (
    ['POST', 'PUT', 'PATCH'].includes(request.method) &&
    !upstreamHeaders.has('Content-Type')
  ) {
    upstreamHeaders.set('Content-Type', 'application/json');
  }

  // Préférence Supabase pour les réponses JSON (PostgREST)
  if (!upstreamHeaders.has('Accept')) {
    upstreamHeaders.set('Accept', 'application/json');
  }
  if (!upstreamHeaders.has('Prefer')) {
    upstreamHeaders.set('Prefer', 'return=representation');
  }

  // ── Appel Supabase ────────────────────────────────────────────────
  let supaResp: Response;
  try {
    supaResp = await fetch(targetUrl, {
      method: request.method,
      headers: upstreamHeaders,
      body:
        ['GET', 'HEAD'].includes(request.method)
          ? undefined
          : request.body,
    });
  } catch (err) {
    console.error('[BFF proxy] fetch error:', (err as Error).message);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Service Supabase temporairement indisponible' },
      503,
    );
  }

  // ── Construction de la réponse vers le client ─────────────────────
  const responseHeaders = new Headers();

  // Copier les headers Supabase en filtrant ceux à ne pas retransmettre
  for (const [key, value] of supaResp.headers.entries()) {
    if (!STRIP_RESPONSE_HEADERS.has(key.toLowerCase())) {
      responseHeaders.set(key, value);
    }
  }

  // Appliquer les headers de sécurité BFF
  const clientResponse = applySecurityHeaders(
    new Response(supaResp.body, {
      status: supaResp.status,
      statusText: supaResp.statusText,
      headers: responseHeaders,
    }),
    env.ALLOWED_ORIGIN,
  );

  return clientResponse;
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
