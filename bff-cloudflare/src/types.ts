// =============================================================================
// types.ts — Types partagés pour le BFF SONGRE Cloudflare Workers
// =============================================================================

/**
 * Environnement Cloudflare Workers — bindings KV, secrets, variables.
 * Toutes les propriétés marquées `secret` sont injectées via
 * `wrangler secret put` et n'apparaissent jamais dans le code source.
 */
export interface Env {
  // ── KV Namespace ────────────────────────────────────────────────────────────
  /** Stockage des sessions : sessionId opaque → tokens Supabase */
  SESSIONS: KVNamespace;

  // ── Rate Limiter ─────────────────────────────────────────────────────────────
  AUTH_RATE_LIMITER: RateLimit;

  // ── Secrets (injectés via wrangler secret put) ────────────────────────────
  /** URL de votre projet Supabase, ex: https://xxx.supabase.co */
  SUPABASE_URL: string;
  /** Clé anon Supabase (JWT public par design) */
  SUPABASE_ANON_KEY: string;
  /** Clé de signature des session IDs (32 bytes hex aléatoire) */
  SESSION_SECRET: string;
  /** Clé de génération des tokens CSRF (32 bytes hex aléatoire) */
  CSRF_SECRET: string;

  // ── Variables publiques (wrangler.toml [vars]) ────────────────────────────
  /** Origine autorisée pour CORS, ex: https://songre.bf */
  ALLOWED_ORIGIN: string;
  /** TTL des sessions en secondes (chaîne, parsée en entier) */
  SESSION_TTL_SECONDS: string;
  /** "development" | "production" */
  ENVIRONMENT: string;
}

/** Données stockées dans KV pour une session */
export interface SessionData {
  userId: string;
  accessToken: string;
  refreshToken: string;
  authType: string;
  createdAt: number;   // timestamp ms
  expiresAt: number;   // timestamp ms
}

/** Résultat normalisé d'un appel Supabase Auth */
export interface SupabaseAuthResult {
  success: boolean;
  userId?: string;
  error?: string;
  needsEmailConfirmation?: boolean;
}

/** Réponse JSON standard du BFF */
export interface BffResponse<T = unknown> {
  success: boolean;
  data?: T;
  error?: string;
}
