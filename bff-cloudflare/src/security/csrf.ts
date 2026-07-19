// =============================================================================
// security/csrf.ts — Protection CSRF pour le BFF SONGRE
//
// Stratégie : Double-Submit Cookie Pattern (renforcé avec signature HMAC)
//
// Fonctionnement :
//   1. Le serveur génère un token CSRF aléatoire signé (HMAC-SHA256)
//   2. Il l'envoie dans deux endroits :
//      a) Cookie `csrf_token` : SameSite=Strict, Secure (mais lisible JS côté client !)
//         → Ce cookie est délibérément lisible par JS pour que l'app puisse le relire
//      b) Response body (lors du login) : l'app doit le stocker en mémoire
//   3. À chaque requête modifiante (POST/PATCH/DELETE), l'app envoie le token
//      dans le header `X-CSRF-Token`
//   4. Le serveur vérifie que le header X-CSRF-Token correspond à la signature
//      du cookie csrf_token ET est cryptographiquement valide
//
// Pourquoi pas SameSite seul ?
//   SameSite=Strict/Lax protège contre le CSRF classique mais pas contre :
//   - Les requêtes same-site depuis des sous-domaines compromis
//   - Certains navigateurs anciens qui ignorent SameSite
//   Le double-submit + HMAC ajoute une couche cryptographique indépendante.
//
// Note : Pour les sessions HttpOnly, le token CSRF est lié à la session via
//        le sessionId pour éviter les attaques de fixation de session CSRF.
// =============================================================================

const CSRF_ALGORITHM = { name: 'HMAC', hash: 'SHA-256' };
const CSRF_TOKEN_LENGTH = 32; // bytes

/**
 * Génère un token CSRF aléatoire signé avec HMAC-SHA256.
 * Le token a la forme : `randomBytes.hmacSignature` (base64url séparé par un point)
 */
export async function generateCsrfToken(
  csrfSecret: string,
  sessionId: string,
): Promise<string> {
  const randomBytes = crypto.getRandomValues(new Uint8Array(CSRF_TOKEN_LENGTH));
  const randomB64 = bufferToBase64Url(randomBytes);

  // Signer : HMAC(secret, sessionId + "." + randomBytes)
  const keyMaterial = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(csrfSecret),
    CSRF_ALGORITHM,
    false,
    ['sign'],
  );

  const dataToSign = new TextEncoder().encode(`${sessionId}.${randomB64}`);
  const signature = await crypto.subtle.sign('HMAC', keyMaterial, dataToSign);
  const signatureB64 = bufferToBase64Url(new Uint8Array(signature));

  return `${randomB64}.${signatureB64}`;
}

/**
 * Vérifie qu'un token CSRF reçu dans le header X-CSRF-Token est valide.
 * - Token doit être présent et non vide
 * - Signature HMAC doit correspondre au secret et au sessionId
 * - Protection contre timing attacks via comparaison en temps constant
 */
export async function verifyCsrfToken(
  token: string | null,
  csrfSecret: string,
  sessionId: string,
): Promise<boolean> {
  if (!token || typeof token !== 'string') return false;

  const parts = token.split('.');
  // Le token signé est composé de exactement 2 segments (randomB64.signatureB64)
  if (parts.length !== 2) return false;

  const [randomB64, receivedSig] = parts;
  if (!randomB64 || !receivedSig) return false;

  try {
    const keyMaterial = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(csrfSecret),
      CSRF_ALGORITHM,
      false,
      ['sign'],
    );

    const dataToSign = new TextEncoder().encode(`${sessionId}.${randomB64}`);
    const expectedSig = await crypto.subtle.sign('HMAC', keyMaterial, dataToSign);
    const expectedSigB64 = bufferToBase64Url(new Uint8Array(expectedSig));

    // Comparaison en temps constant pour éviter les timing attacks
    return timingSafeEqual(expectedSigB64, receivedSig);
  } catch {
    return false;
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function bufferToBase64Url(buffer: Uint8Array): string {
  return btoa(String.fromCharCode(...buffer))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

/**
 * Comparaison de chaînes en temps constant (prévention timing attack).
 * Parcourt toujours les deux chaînes entièrement même si elles diffèrent.
 */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) {
    // Toujours itérer pour éviter le timing différentiel sur la longueur
    // En pratique, si la longueur diffère, c'est un token invalide
    let diff = 0;
    const minLen = Math.min(a.length, b.length);
    for (let i = 0; i < minLen; i++) {
      diff |= a.charCodeAt(i) ^ (b.charCodeAt(i) ?? 0);
    }
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/**
 * Méthodes HTTP qui modifient des données → protection CSRF obligatoire.
 * GET et OPTIONS sont exempts (read-only).
 */
export function requiresCsrfProtection(method: string): boolean {
  return ['POST', 'PUT', 'PATCH', 'DELETE'].includes(method.toUpperCase());
}
