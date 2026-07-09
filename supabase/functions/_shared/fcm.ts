// =============================================================================
// _shared/fcm.ts — Module partagé SONGRE : envoi push FCM HTTP v1 (OAuth2)
//
// Extrait de matcher-et-notifier/index.ts — code identique, centralisé ici.
// Protégé par périmètre strict : NE PAS modifier la logique OAuth2/FCM.
//
// Utilisé par : notifier.ts (→ toutes les EFs via notifierUtilisateur)
// =============================================================================

// ── Types publics ─────────────────────────────────────────────────────────────

export interface FcmResult {
  success: boolean;
  token?: string;
  error?: string;
}

// ── Obtenir un access_token OAuth2 depuis le service account JSON ─────────────
// Périmètre strict : logique copiée telle quelle de matcher-et-notifier v2.

export async function getOAuth2AccessToken(
  serviceAccountJson: string,
): Promise<string | null> {
  try {
    const sa = JSON.parse(serviceAccountJson);
    const privateKey = sa.private_key as string;
    const clientEmail = sa.client_email as string;

    const now = Math.floor(Date.now() / 1000);
    const expiry = now + 3600;

    const header = { alg: "RS256", typ: "JWT" };
    const claim = {
      iss: clientEmail,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: expiry,
    };

    const encode = (obj: unknown) =>
      btoa(JSON.stringify(obj))
        .replace(/\+/g, "-")
        .replace(/\//g, "_")
        .replace(/=+$/, "");

    const headerB64 = encode(header);
    const claimB64 = encode(claim);
    const signingInput = `${headerB64}.${claimB64}`;

    const pemBody = privateKey
      .replace("-----BEGIN PRIVATE KEY-----", "")
      .replace("-----END PRIVATE KEY-----", "")
      .replace(/\s/g, "");
    const keyData = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

    const cryptoKey = await crypto.subtle.importKey(
      "pkcs8",
      keyData.buffer,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );

    const signatureBuffer = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      cryptoKey,
      new TextEncoder().encode(signingInput),
    );

    const signatureB64 = btoa(
      String.fromCharCode(...new Uint8Array(signatureBuffer)),
    )
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");

    const jwt = `${signingInput}.${signatureB64}`;

    const tokenResp = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwt,
      }),
    });

    if (!tokenResp.ok) {
      const err = await tokenResp.text();
      console.error("[fcm] OAuth2 token error:", tokenResp.status, err);
      return null;
    }

    const tokenData = await tokenResp.json();
    return tokenData.access_token as string;
  } catch (err) {
    console.error("[fcm] getOAuth2AccessToken error:", err);
    return null;
  }
}

// ── Envoyer une notification FCM HTTP v1 ─────────────────────────────────────
// Périmètre strict : logique copiée telle quelle de matcher-et-notifier v2.

export async function envoyerFcmV1(
  fcmToken: string,
  titre: string,
  corps: string,
  data: Record<string, string>,
  accessToken: string,
  projectId: string,
): Promise<boolean> {
  try {
    const url =
      `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

    const message = {
      message: {
        token: fcmToken,
        notification: { title: titre, body: corps },
        data,
        android: { priority: "high" },
        apns: {
          payload: { aps: { sound: "default", badge: 1 } },
        },
      },
    };

    const resp = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify(message),
    });

    if (!resp.ok) {
      const errBody = await resp.text();
      console.error("[fcm] FCM v1 error:", resp.status, errBody);
      return false;
    }

    return true;
  } catch (err) {
    console.error("[fcm] FCM v1 fetch error:", err);
    return false;
  }
}

// ── Récupérer tous les tokens FCM d'un utilisateur depuis device_tokens ───────
// Retourne un tableau vide si aucun token ou si la requête échoue.
// doit recevoir un client Supabase admin (service_role).

// deno-lint-ignore no-explicit-any
export async function getFcmTokensForUser(
  adminClient: any,
  userId: string,
): Promise<string[]> {
  try {
    const { data, error } = await adminClient
      .from("device_tokens")
      .select("fcm_token")
      .eq("user_id", userId);

    if (error || !data) return [];
    return (data as { fcm_token: string }[]).map((d) => d.fcm_token);
  } catch {
    return [];
  }
}

// ── Obtenir un access_token FCM depuis les variables d'environnement ──────────
// Retourne null si les variables sont absentes.

export async function getFcmAccessTokenFromEnv(): Promise<{
  accessToken: string;
  projectId: string;
} | null> {
  const serviceAccountJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  const projectId = Deno.env.get("FCM_PROJECT_ID");

  if (!serviceAccountJson || !projectId) {
    console.warn("[fcm] FCM_SERVICE_ACCOUNT_JSON ou FCM_PROJECT_ID manquant.");
    return null;
  }

  const accessToken = await getOAuth2AccessToken(serviceAccountJson);
  if (!accessToken) {
    console.warn("[fcm] Impossible d'obtenir le token OAuth2 FCM.");
    return null;
  }

  return { accessToken, projectId };
}
