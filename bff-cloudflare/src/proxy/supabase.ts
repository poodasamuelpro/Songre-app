// =============================================================================
// bff-cloudflare/src/proxy/supabase.ts
// Proxy authentifié vers Supabase — requêtes données et Edge Functions
//
// Routes couvertes :
//   ANY /bff/api/*        → proxy vers Supabase /rest/v1/* (PostgREST)
//   ANY /bff/functions/*  → proxy vers Supabase /functions/v1/* (Edge Funcs)
//
// Flux de sécurité :
//   1. Lire cookie bff_session (HttpOnly — opaque pour le navigateur)
//   2. Valider la signature HMAC du cookie et récupérer la session depuis KV
//   3. Vérifier CSRF pour les méthodes mutantes (POST/PATCH/PUT/DELETE)
//   4. Transmettre la requête à Supabase avec Bearer token (jamais exposé)
//   5. Retransmettre uniquement la réponse de données (pas les cookies Supabase)
//
// Garantie : le token Supabase ne transite JAMAIS dans le navigateur —
// il est injecté exclusivement côté serveur (Cloudflare Workers).
// =============================================================================

import { Env } from '../types.js';
import {
  jsonSecureResponse,
  preflightResponse,
  applySecurityHeaders,
} from '../security/headers.js';
import { requiresCsrfProtection, verifyCsrfToken } from '../security/csrf.js';
import { getSession, extractCookie } from '../session/store.js';

// Headers entrants à ne PAS transmettre vers Supabase
// (informations infrastructure CF, cookie HttpOnly, host origin)
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
  'x-csrf-token', // Header BFF — ne doit pas atteindre Supabase
]);

// Headers Supabase à ne PAS retransmettre vers le client
// (évite de révéler des informations d'infrastructure ou de surcharger HSTS)
const STRIP_RESPONSE_HEADERS = new Set([
  'set-cookie',               // Jamais de cookie Supabase vers le browser
  'strict-transport-security', // Le BFF le réinjecte lui-même
]);

export async function handleProxy(
  request: Request,
  env: Env,
  pathSuffix: string,       // Segment après /bff/api/ ou /bff/functions/
  targetBase: 'api' | 'functions',
): Promise<Response> {
  // ── OPTIONS preflight ─────────────────────────────────────────────────────
  if (request.method === 'OPTIONS') {
    return preflightResponse(env.ALLOWED_ORIGIN);
  }

  // ── Extraction cookie session ─────────────────────────────────────────────
  const cookieHeader = request.headers.get('Cookie') ?? '';
  const signedSessionValue = extractCookie(cookieHeader, 'bff_session');

  if (!signedSessionValue) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Non authentifié' },
      401,
    );
  }

  // ── Récupération session KV ───────────────────────────────────────────────
  // getSession(env, signedValue) → { sessionId: string; data: SessionData } | null
  const sessionResult = await getSession(env, signedSessionValue);

  if (!sessionResult) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Session invalide ou expirée. Reconnectez-vous.' },
      401,
    );
  }

  // Déstructuration explicite pour accès typé et lisible
  const { sessionId, data: sessionData } = sessionResult;

  // ── Vérification CSRF pour méthodes mutantes ──────────────────────────────
  if (requiresCsrfProtection(request.method)) {
    const csrfHeader = request.headers.get('X-CSRF-Token') ?? '';

    const csrfValid = await verifyCsrfToken(
      csrfHeader,
      env.CSRF_SECRET,
      sessionId, // sessionId extrait de la session validée (pas du cookie brut)
    );

    if (!csrfValid) {
      return jsonSecureResponse(
        env.ALLOWED_ORIGIN,
        { ok: false, error: 'Token CSRF invalide' },
        403,
      );
    }
  }

  // ── Construction URL Supabase cible ───────────────────────────────────────
  const targetPath =
    targetBase === 'api'
      ? `/rest/v1/${pathSuffix}`
      : `/functions/v1/${pathSuffix}`;

  const requestUrl = new URL(request.url);
  const targetUrl = `${env.SUPABASE_URL}${targetPath}${requestUrl.search}`;

  // ── Construction des headers pour Supabase ────────────────────────────────
  const upstreamHeaders = new Headers();

  // Copier les headers du client en filtrant les headers sensibles/CF
  for (const [key, value] of request.headers.entries()) {
    if (!STRIP_REQUEST_HEADERS.has(key.toLowerCase())) {
      upstreamHeaders.set(key, value);
    }
  }

  // Injecter l'authentification Supabase (jamais exposée au navigateur)
  upstreamHeaders.set('apikey', env.SUPABASE_ANON_KEY);
  // sessionData.accessToken est accessible via { data: SessionData }
  upstreamHeaders.set(
    'Authorization',
    `Bearer ${sessionData.accessToken}`,
  );

  // Content-Type par défaut pour les requêtes JSON mutantes
  if (
    ['POST', 'PUT', 'PATCH'].includes(request.method) &&
    !upstreamHeaders.has('Content-Type')
  ) {
    upstreamHeaders.set('Content-Type', 'application/json');
  }

  // Préférences PostgREST — retourner la représentation complète après écriture
  if (!upstreamHeaders.has('Accept')) {
    upstreamHeaders.set('Accept', 'application/json');
  }
  if (targetBase === 'api' && !upstreamHeaders.has('Prefer')) {
    upstreamHeaders.set('Prefer', 'return=representation');
  }

  // ── Corps de la requête ───────────────────────────────────────────────────
  // GET et HEAD n'ont pas de corps.
  // Pour les autres méthodes, on transmet le body en stream.
  // Le cast explicite vers BodyInit | null évite l'erreur de type CF Workers
  // (ReadableStream<Uint8Array> | null n'est pas directement BodyInit).
  const hasBody = !['GET', 'HEAD'].includes(request.method);
  const requestBody: BodyInit | null = hasBody
    ? (request.body as BodyInit | null)
    : null;

  // ── Appel Supabase ────────────────────────────────────────────────────────
  let supaResp: Response;
  try {
    supaResp = await fetch(targetUrl, {
      method: request.method,
      headers: upstreamHeaders,
      body: requestBody,
      // duplex requis pour le streaming body en Workers fetch
      // (cast nécessaire car non typé dans @cloudflare/workers-types)
      ...(hasBody && request.body ? { duplex: 'half' } : {}),
    } as RequestInit);
  } catch (err) {
    console.error('[BFF proxy] Erreur fetch Supabase:', (err as Error).message);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Service Supabase temporairement indisponible' },
      503,
    );
  }

  // ── Construction de la réponse vers le client ─────────────────────────────
  const responseHeaders = new Headers();

  // Copier les headers Supabase en filtrant ceux à ne pas retransmettre
  for (const [key, value] of supaResp.headers.entries()) {
    if (!STRIP_RESPONSE_HEADERS.has(key.toLowerCase())) {
      responseHeaders.set(key, value);
    }
  }

  // Appliquer les headers de sécurité BFF par-dessus les headers Supabase
  const clientResponse = applySecurityHeaders(
    new Response(supaResp.body, {
      status: supaResp.status,
      statusText: supaResp.statusText,
      headers: responseHeaders,
    }),
    env.ALLOWED_ORIGIN,
    request.headers.get('Origin'),
    env.ENVIRONMENT === 'production',
  );

  return clientResponse;
}
