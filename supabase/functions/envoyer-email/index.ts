// =============================================================================
// Edge Function : envoyer-email
// Déploiement   : supabase functions deploy envoyer-email
//
// Rôle : Service d'envoi d'email générique avec système rotatif Brevo + Resend.
//        Utilisable depuis d'autres Edge Functions ou depuis un backend sécurisé.
//        Ne doit JAMAIS être appelé directement depuis le client Flutter.
//
// Authentification :
//   - Appel interne (depuis autre EF) : header X-Internal-Secret
//   - Appel admin externe : JWT Supabase Service Role (pour monitoring/debug)
//
// Système rotatif :
//   EMAIL_PROVIDER = "auto"   → Brevo key1 → Brevo key2 → Resend key1 → Resend key2
//   EMAIL_PROVIDER = "brevo"  → Brevo key1 → Brevo key2 (arrêt)
//   EMAIL_PROVIDER = "resend" → Resend key1 → Resend key2 (arrêt)
//   À chaque échec (rate limit, clé révoquée, erreur réseau), la clé suivante est tentée.
//
// Payload POST JSON :
//   {
//     "to":       "destinataire@example.com",        // OBLIGATOIRE
//     "subject":  "Objet de l'email",                // OBLIGATOIRE
//     "html":     "<p>Corps HTML</p>",               // OBLIGATOIRE
//     "template": "don_confirme" | "demande_compatible" | "retour_eligibilite",
//                                                    // OPTIONNEL — génère html automatiquement
//     "data":     { ... }                            // OPTIONNEL — données pour le template
//   }
//
// Variables d'environnement OBLIGATOIRES :
//   SUPABASE_URL                 — injectée automatiquement
//   SUPABASE_SERVICE_ROLE_KEY    — injectée automatiquement
//   INTERNAL_SECRET              — secret partagé pour appels internes entre EFs
//   ALLOWED_ORIGIN               — domaine de prod, ex: "https://songre.bf"
//
// Variables email (au moins une paire requise) :
//   EMAIL_FROM                   — ex: "SONGRE <noreply@songre.bf>"
//   EMAIL_PROVIDER               — "auto" | "brevo" | "resend" (défaut: "auto")
//   BREVO_API_KEY                — clé Brevo principale
//   BREVO_API_KEY_2              — clé Brevo de secours
//   RESEND_API_KEY               — clé Resend principale
//   RESEND_API_KEY_2             — clé Resend de secours
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// ── CORS restrictif ──────────────────────────────────────────────────────────

function getCorsHeaders(): Record<string, string> {
  const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN") ?? "https://songre.bf";
  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-internal-secret",
    "Access-Control-Max-Age": "86400",
  };
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...getCorsHeaders() },
  });
}

// ── Types ─────────────────────────────────────────────────────────────────────

interface EmailRequest {
  to: string;
  subject: string;
  html?: string;
  template?: "don_confirme" | "demande_compatible" | "retour_eligibilite" | "custom";
  data?: Record<string, string>;
}

interface EnvoiResult {
  success: boolean;
  provider?: string;
  tentatives: number;
  error?: string;
}

// ── Templates HTML ────────────────────────────────────────────────────────────

function baseTemplate(titre: string, contenu: string, couleur = "#C0392B"): string {
  return `<!DOCTYPE html>
<html lang="fr">
<head><meta charset="UTF-8"><title>${titre} — SONGRE</title></head>
<body style="font-family:Arial,sans-serif;background:#f9f9f9;margin:0;padding:20px;">
  <div style="max-width:560px;margin:0 auto;background:#fff;border-radius:12px;
              padding:32px;box-shadow:0 2px 8px rgba(0,0,0,0.08);">
    <div style="text-align:center;margin-bottom:24px;">
      <span style="font-size:40px;">&#x1F9B8;</span>
      <h2 style="color:${couleur};margin:8px 0 0;">${titre}</h2>
    </div>
    ${contenu}
    <hr style="border:none;border-top:1px solid #eee;margin:28px 0;">
    <p style="color:#999;font-size:12px;text-align:center;">
      Vous recevez cet email car vous êtes inscrit(e) sur SONGRE.
      Pour modifier vos préférences, accédez à votre profil dans l'application.
    </p>
  </div>
</body>
</html>`.trim();
}

function templateDemandeCompatible(data: Record<string, string>): string {
  const groupe = data["groupe_sanguin"] ?? "?";
  const ville = data["ville"] ?? "votre ville";
  const structure = data["structure"] ?? "la structure";
  return baseTemplate(
    "Besoin urgent de sang",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Une demande de don de type <strong>${groupe}</strong>
      vient d'être publiée à <strong>${ville}</strong>.
    </p>
    <div style="background:#fff5f5;border-left:4px solid #C0392B;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0;font-size:15px;color:#555;">
        &#128205; <strong>Structure :</strong> ${structure}
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Si votre groupe sanguin est compatible et que vous êtes disponible,
      ouvrez l'application SONGRE pour répondre à cette demande.
    </p>
    <div style="text-align:center;margin-top:28px;">
      <a href="https://songre.bf/app"
         style="background:#C0392B;color:white;text-decoration:none;
                padding:12px 28px;border-radius:8px;font-weight:bold;font-size:15px;">
        Ouvrir SONGRE
      </a>
    </div>`,
  );
}

function templateDonConfirme(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "Donneur";
  const dateStr = data["date"] ?? new Date().toLocaleDateString("fr-FR");
  return baseTemplate(
    "Don confirmé — Merci !",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Votre don du <strong>${dateStr}</strong> a été confirmé.
      Votre geste peut sauver jusqu'à 3 vies.
    </p>
    <div style="background:#f0fff4;border-left:4px solid #27AE60;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0;font-size:15px;color:#27AE60;font-weight:bold;">
        &#10003; Merci pour votre générosité !
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Pensez à bien vous hydrater et vous reposer dans les heures qui suivent.
      Votre historique de dons a été mis à jour dans SONGRE.
    </p>`,
    "#27AE60",
  );
}

function templateRetourEligibilite(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "Donneur";
  const jours = data["jours_restants"] ?? "quelques jours";
  return baseTemplate(
    "Bientôt de nouveau éligible",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Bonne nouvelle ! Il vous reste seulement <strong>${jours} jours</strong>
      avant de pouvoir donner à nouveau.
    </p>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Assurez-vous que votre disponibilité est activée dans votre profil
      pour être notifié(e) dès qu'un besoin compatible apparaît dans votre ville.
    </p>
    <div style="text-align:center;margin-top:28px;">
      <a href="https://songre.bf/app"
         style="background:#C0392B;color:white;text-decoration:none;
                padding:12px 28px;border-radius:8px;font-weight:bold;font-size:15px;">
        Mettre à jour mon profil
      </a>
    </div>`,
  );
}

function renderTemplate(
  template: string,
  data: Record<string, string> = {},
): string | null {
  switch (template) {
    case "demande_compatible":
      return templateDemandeCompatible(data);
    case "don_confirme":
      return templateDonConfirme(data);
    case "retour_eligibilite":
      return templateRetourEligibilite(data);
    default:
      return null;
  }
}

// ── Validation email basique ──────────────────────────────────────────────────

function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

// ── Fournisseurs email ────────────────────────────────────────────────────────

async function envoyerViaBrevo(
  apiKey: string,
  from: string,
  to: string,
  subject: string,
  html: string,
): Promise<boolean> {
  try {
    const fromMatch = from.match(/^(.+?)\s*<(.+?)>$/);
    const senderName = fromMatch ? fromMatch[1].trim() : "SONGRE";
    const senderEmail = fromMatch ? fromMatch[2].trim() : from;

    const resp = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "api-key": apiKey,
      },
      body: JSON.stringify({
        sender: { name: senderName, email: senderEmail },
        to: [{ email: to }],
        subject,
        htmlContent: html,
      }),
    });

    if (!resp.ok) {
      const body = await resp.text();
      console.warn("[envoyer-email] Brevo error:", resp.status, body.slice(0, 300));
      return false;
    }
    return true;
  } catch (err) {
    console.warn("[envoyer-email] Brevo fetch error:", err);
    return false;
  }
}

async function envoyerViaResend(
  apiKey: string,
  from: string,
  to: string,
  subject: string,
  html: string,
): Promise<boolean> {
  try {
    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({ from, to: [to], subject, html }),
    });

    if (!resp.ok) {
      const body = await resp.text();
      console.warn("[envoyer-email] Resend error:", resp.status, body.slice(0, 300));
      return false;
    }
    return true;
  } catch (err) {
    console.warn("[envoyer-email] Resend fetch error:", err);
    return false;
  }
}

// ── Orchestrateur rotatif ─────────────────────────────────────────────────────

async function envoyerAvecRotation(
  to: string,
  subject: string,
  html: string,
): Promise<EnvoiResult> {
  const emailFrom = Deno.env.get("EMAIL_FROM") ?? "SONGRE <noreply@songre.bf>";
  const providerPref = (Deno.env.get("EMAIL_PROVIDER") ?? "auto").toLowerCase();

  type Candidat = {
    label: string;
    fn: () => Promise<boolean>;
  };

  const candidats: Candidat[] = [];

  function addBrevo(key: string, label: string) {
    candidats.push({
      label,
      fn: () => envoyerViaBrevo(key, emailFrom, to, subject, html),
    });
  }

  function addResend(key: string, label: string) {
    candidats.push({
      label,
      fn: () => envoyerViaResend(key, emailFrom, to, subject, html),
    });
  }

  if (providerPref === "brevo") {
    const k1 = Deno.env.get("BREVO_API_KEY");
    const k2 = Deno.env.get("BREVO_API_KEY_2");
    if (k1) addBrevo(k1, "Brevo/key1");
    if (k2) addBrevo(k2, "Brevo/key2");
  } else if (providerPref === "resend") {
    const k1 = Deno.env.get("RESEND_API_KEY");
    const k2 = Deno.env.get("RESEND_API_KEY_2");
    if (k1) addResend(k1, "Resend/key1");
    if (k2) addResend(k2, "Resend/key2");
  } else {
    // "auto" : Brevo d'abord, Resend en fallback
    const bk1 = Deno.env.get("BREVO_API_KEY");
    const bk2 = Deno.env.get("BREVO_API_KEY_2");
    const rk1 = Deno.env.get("RESEND_API_KEY");
    const rk2 = Deno.env.get("RESEND_API_KEY_2");
    if (bk1) addBrevo(bk1, "Brevo/key1");
    if (bk2) addBrevo(bk2, "Brevo/key2");
    if (rk1) addResend(rk1, "Resend/key1");
    if (rk2) addResend(rk2, "Resend/key2");
  }

  if (candidats.length === 0) {
    return {
      success: false,
      tentatives: 0,
      error: "Aucune clé email configurée (BREVO_API_KEY / RESEND_API_KEY manquantes).",
    };
  }

  for (let i = 0; i < candidats.length; i++) {
    const c = candidats[i];
    console.log(`[envoyer-email] Tentative ${i + 1}/${candidats.length}: ${c.label} → ${to}`);
    const ok = await c.fn();
    if (ok) {
      console.log(`[envoyer-email] Succès via ${c.label}`);
      return { success: true, provider: c.label, tentatives: i + 1 };
    }
    console.warn(`[envoyer-email] ${c.label} échoué, passage au suivant...`);
  }

  return {
    success: false,
    tentatives: candidats.length,
    error: `Tous les ${candidats.length} fournisseur(s) ont échoué.`,
  };
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  // ── Preflight CORS ────────────────────────────────────────────────────────
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: getCorsHeaders() });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405);
  }

  // ── Authentification ──────────────────────────────────────────────────────
  // Deux modes acceptés :
  //   1. Header X-Internal-Secret (appels entre Edge Functions)
  //   2. Bearer JWT Service Role (monitoring/debug admin)

  const internalSecret = Deno.env.get("INTERNAL_SECRET");
  const receivedInternalSecret = req.headers.get("x-internal-secret");
  const authHeader = req.headers.get("Authorization") ?? "";

  let isAuthorized = false;

  // Mode 1 : secret interne
  if (internalSecret && internalSecret.trim().length > 0) {
    if (receivedInternalSecret === internalSecret) {
      isAuthorized = true;
    }
  }

  // Mode 2 : JWT Service Role (uniquement pour monitoring admin)
  // Note : dans ce cas, le caller doit envoyer Authorization: Bearer <service_role_key>
  // On vérifie simplement la présence d'un token non vide ici — en production,
  // vous pouvez ajouter une vérification plus stricte.
  if (!isAuthorized && authHeader.startsWith("Bearer ")) {
    const token = authHeader.replace("Bearer ", "").trim();
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (token === serviceRoleKey && serviceRoleKey.length > 10) {
      isAuthorized = true;
    }
  }

  if (!isAuthorized) {
    return jsonResponse({ error: "Accès non autorisé." }, 403);
  }

  // ── Parser le body ────────────────────────────────────────────────────────
  let body: EmailRequest;
  try {
    body = await req.json() as EmailRequest;
  } catch {
    return jsonResponse({ error: "Body JSON invalide." }, 400);
  }

  const { to, subject, html, template, data } = body;

  // ── Validation des champs obligatoires ────────────────────────────────────
  if (!to || typeof to !== "string" || !isValidEmail(to.trim())) {
    return jsonResponse({ error: "Champ 'to' manquant ou adresse email invalide." }, 400);
  }

  if (!subject || typeof subject !== "string" || subject.trim().length === 0) {
    return jsonResponse({ error: "Champ 'subject' manquant ou vide." }, 400);
  }

  // ── Résoudre le HTML : template ou html direct ────────────────────────────
  let htmlContent: string | null = null;

  if (template && template !== "custom") {
    htmlContent = renderTemplate(template, data ?? {});
    if (!htmlContent) {
      return jsonResponse({ error: `Template inconnu: ${template}` }, 400);
    }
  } else if (html) {
    htmlContent = html;
  } else {
    return jsonResponse({
      error: "Fournir soit 'html' (string) soit 'template' (nom du template).",
    }, 400);
  }

  // Limite de taille raisonnable pour éviter les abus
  if (htmlContent.length > 100_000) {
    return jsonResponse({ error: "Corps HTML trop volumineux (max 100 KB)." }, 413);
  }

  // ── Envoi avec système rotatif ────────────────────────────────────────────
  const result = await envoyerAvecRotation(to.trim(), subject.trim(), htmlContent);

  if (!result.success) {
    console.error("[envoyer-email] Échec total:", result.error);
    return jsonResponse({
      success: false,
      error: "Impossible d'envoyer l'email.",
      details: result,
    }, 500);
  }

  return jsonResponse({
    success: true,
    provider: result.provider,
    tentatives: result.tentatives,
    to: to.trim(),
  }, 200);
});
