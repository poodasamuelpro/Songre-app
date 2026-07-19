// bff-vercel/lib/types.ts
// Types partagés pour le BFF Vercel — équivalent exact de bff-cloudflare/src/types.ts
//
// Différences vs Cloudflare :
//   - Env est lu depuis process.env (Node.js) au lieu des bindings Workers
//   - KVNamespace est remplacé par Redis (Upstash) via @upstash/redis
//   - RateLimit est implémenté via Redis (INCR + EXPIRE)

export interface BffEnv {
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
  SESSION_SECRET: string;    // 32 bytes hex — injecté via Vercel Environment Variables (encrypted)
  CSRF_SECRET: string;       // 32 bytes hex — injecté via Vercel Environment Variables (encrypted)
  ALLOWED_ORIGIN: string;    // ex: https://songre.bf
  SESSION_TTL_SECONDS: string;
  ENVIRONMENT: string;       // 'production' | 'development'

  // Upstash Redis (équivalent Cloudflare KV)
  UPSTASH_REDIS_REST_URL: string;
  UPSTASH_REDIS_REST_TOKEN: string;
}

export interface SessionData {
  userId: string;
  accessToken: string;     // Token Supabase — jamais transmis au client
  refreshToken: string;    // Refresh token — jamais transmis au client
  authType: string;        // 'email'
  createdAt: number;       // timestamp ms
  expiresAt: number;       // timestamp ms
}

export interface AuthResult {
  ok: boolean;
  userId?: string;
  authType?: string;
  needsEmailConfirmation?: boolean;
  error?: string;
}

export function getEnv(): BffEnv {
  const required = [
    'SUPABASE_URL',
    'SUPABASE_ANON_KEY',
    'SESSION_SECRET',
    'CSRF_SECRET',
    'ALLOWED_ORIGIN',
    'UPSTASH_REDIS_REST_URL',
    'UPSTASH_REDIS_REST_TOKEN',
  ];

  for (const key of required) {
    if (!process.env[key]) {
      throw new Error(`Variable d'environnement manquante : ${key}`);
    }
  }

  return {
    SUPABASE_URL: process.env['SUPABASE_URL']!,
    SUPABASE_ANON_KEY: process.env['SUPABASE_ANON_KEY']!,
    SESSION_SECRET: process.env['SESSION_SECRET']!,
    CSRF_SECRET: process.env['CSRF_SECRET']!,
    ALLOWED_ORIGIN: process.env['ALLOWED_ORIGIN']!,
    SESSION_TTL_SECONDS: process.env['SESSION_TTL_SECONDS'] ?? '86400',
    ENVIRONMENT: process.env['ENVIRONMENT'] ?? 'production',
    UPSTASH_REDIS_REST_URL: process.env['UPSTASH_REDIS_REST_URL']!,
    UPSTASH_REDIS_REST_TOKEN: process.env['UPSTASH_REDIS_REST_TOKEN']!,
  };
}
