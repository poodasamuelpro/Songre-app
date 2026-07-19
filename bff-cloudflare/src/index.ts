// bff-cloudflare/src/index.ts
// Point d'entrée principal — Routeur Cloudflare Workers
//
// Architecture de routage :
//   POST /bff/auth/login    → handleLogin
//   POST /bff/auth/signup   → handleSignup
//   POST /bff/auth/logout   → handleLogout
//   POST /bff/auth/recover  → handleRecover
//   POST /bff/auth/refresh  → handleRefresh
//   ANY  /bff/api/*         → handleProxy (→ Supabase REST /rest/v1/*)
//   ANY  /bff/functions/*   → handleProxy (→ Supabase Functions /functions/v1/*)
//   GET  /bff/health        → health check
//   *                       → 404

import { Env } from './types.js';
import { handleLogin }   from './auth/login.js';
import { handleSignup }  from './auth/signup.js';
import { handleLogout }  from './auth/logout.js';
import { handleRecover } from './auth/recover.js';
import { handleRefresh } from './auth/refresh.js';
import { handleProxy }   from './proxy/supabase.js';
import {
  jsonSecureResponse,
  preflightResponse,
  applySecurityHeaders,
} from './security/headers.js';

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    // ── CORS preflight global ─────────────────────────────────────────
    if (request.method === 'OPTIONS') {
      // Vérifier que l'origine est autorisée
      const origin = request.headers.get('Origin') ?? '';
      if (origin !== env.ALLOWED_ORIGIN) {
        return new Response('Forbidden', { status: 403 });
      }
      return preflightResponse(env.ALLOWED_ORIGIN);
    }

    // ── Vérification origin (toutes les requêtes non-OPTIONS) ─────────
    // Note : en SameSite=Strict, les requêtes cross-origin avec cookies
    // ne passent pas, mais on valide quand même l'origin header.
    const origin = request.headers.get('Origin');
    if (origin && origin !== env.ALLOWED_ORIGIN) {
      return new Response('Forbidden', { status: 403 });
    }

    // ── Health check ──────────────────────────────────────────────────
    if (path === '/bff/health' && request.method === 'GET') {
      return applySecurityHeaders(
        new Response(
          JSON.stringify({ ok: true, service: 'SONGRE BFF', version: '1.0.0' }),
          {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          },
        ),
        env.ALLOWED_ORIGIN,
      );
    }

    // ── Auth routes ───────────────────────────────────────────────────
    if (path === '/bff/auth/login') {
      return handleLogin(request, env);
    }

    if (path === '/bff/auth/signup') {
      return handleSignup(request, env);
    }

    if (path === '/bff/auth/logout') {
      return handleLogout(request, env);
    }

    if (path === '/bff/auth/recover') {
      return handleRecover(request, env);
    }

    if (path === '/bff/auth/refresh') {
      return handleRefresh(request, env);
    }

    // ── Proxy routes ──────────────────────────────────────────────────
    // /bff/api/* → Supabase REST /rest/v1/*
    const apiMatch = path.match(/^\/bff\/api\/(.*)$/);
    if (apiMatch) {
      return handleProxy(request, env, apiMatch[1], 'api');
    }

    // /bff/functions/* → Supabase Edge Functions /functions/v1/*
    const functionsMatch = path.match(/^\/bff\/functions\/(.*)$/);
    if (functionsMatch) {
      return handleProxy(request, env, functionsMatch[1], 'functions');
    }

    // ── 404 ───────────────────────────────────────────────────────────
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Route inconnue' },
      404,
    );
  },
} satisfies ExportedHandler<Env>;
