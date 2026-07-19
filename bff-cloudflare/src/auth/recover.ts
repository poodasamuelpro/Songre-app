// bff-cloudflare/src/auth/recover.ts
// POST /bff/auth/recover — Envoi email de réinitialisation de mot de passe
//
// Note de sécurité : Supabase retourne 200 même si l'email n'existe pas
// (protection anti-énumération). Ce comportement est conservé tel quel.
// Ne pas logger l'email en clair.

import { Env } from '../types.js';
import {
  jsonSecureResponse,
  preflightResponse,
} from '../security/headers.js';

export async function handleRecover(
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

  // Parsing
  let body: { email?: unknown };
  try {
    body = (await request.json()) as { email?: unknown };
  } catch {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Corps JSON invalide' },
      400,
    );
  }

  const email =
    typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';

  if (!email) {
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Email requis' },
      400,
    );
  }

  // ── Appel Supabase /auth/v1/recover ───────────────────────────────
  try {
    const supaResp = await fetch(`${env.SUPABASE_URL}/auth/v1/recover`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: env.SUPABASE_ANON_KEY,
      },
      body: JSON.stringify({ email }),
    });

    // Supabase renvoie 200 même si email inexistant (anti-enumeration).
    // On retourne toujours 200 côté BFF également.
    if (supaResp.status === 200) {
      return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: true });
    }

    const data = (await supaResp.json()) as Record<string, unknown>;
    const rawMsg = (
      (data.error_description as string) ??
      (data.msg as string) ??
      ''
    ).toLowerCase();

    if (rawMsg.includes('rate limit') || supaResp.status === 429) {
      return jsonSecureResponse(
        env.ALLOWED_ORIGIN,
        { ok: false, error: 'Trop de demandes. Patientez quelques minutes.' },
        429,
        { 'Retry-After': '60' },
      );
    }

    // Pour tout autre erreur, on retourne quand même true (anti-enum)
    console.error('[BFF recover] Supabase status:', supaResp.status, rawMsg.slice(0, 80));
    return jsonSecureResponse(env.ALLOWED_ORIGIN, { ok: true });
  } catch (err) {
    console.error('[BFF recover] fetch error:', (err as Error).message);
    return jsonSecureResponse(
      env.ALLOWED_ORIGIN,
      { ok: false, error: 'Service temporairement indisponible' },
      503,
    );
  }
}
