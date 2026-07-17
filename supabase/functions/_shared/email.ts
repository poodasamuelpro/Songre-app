// =============================================================================
// _shared/email.ts — Module partagé SONGRE : envoi d'email avec rotation Brevo/Resend
//
// Utilisé par : matcher-et-notifier, envoyer-email, reponse-donneur,
//               valider-token, don-manuel, retour-eligibilite-cron,
//               executer-suppressions-programmees, bienvenue-auth,
//               mdp-modifie-auth, contacter-support
//
// Aucun import Supabase — ce module est purement HTTP.
// =============================================================================

// ── Types publics ─────────────────────────────────────────────────────────────

export interface EmailResult {
  success: boolean;
  provider?: string;
  key?: string;
  tentatives?: number;
}

export type TemplateName =
  | "demande_compatible"
  | "don_confirme"
  | "don_confirme_demandeur"
  | "reponse_recue"
  | "reponse_encouragement"
  | "retour_eligibilite"
  | "don_enregistre_manuel"
  | "suppression_demandee"
  | "suppression_confirmee"
  | "bienvenue"
  | "mdp_modifie"
  | "contact_support";

// ── Logo SONGRE (base64 inline pour compatibilité email) ──────────────────────
// URL publique CDN — remplacer par un lien permanent si possible
// ─── Logo SONGRE ───────────────────────────────────────────────────────────
// Héberger logo_songre.png sur un CDN public (Supabase Storage, Cloudflare R2,
// etc.) et mettre l'URL ici. La constante suivante est utilisée dans tous les
// templates HTML email.
// ⚠️  D7 NOTE : URL à mettre à jour une fois le logo uploadé sur Supabase Storage.
//     Exemple : https://<PROJECT_REF>.supabase.co/storage/v1/object/public/assets/logo_songre.png
const LOGO_URL = "https://ptomqwucvveuflfnyczo.supabase.co/storage/v1/object/public/assets/logo-songre.jpeg";

// ── Base HTML template ────────────────────────────────────────────────────────

function baseTemplate(
  titre: string,
  contenu: string,
  couleur = "#C0392B",
): string {
  return `<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${titre} — SONGRE</title>
</head>
<body style="font-family:Arial,sans-serif;background:#f9f9f9;margin:0;padding:20px;">
  <div style="max-width:560px;margin:0 auto;background:#fff;border-radius:12px;
              padding:32px;box-shadow:0 2px 8px rgba(0,0,0,0.08);">
    <div style="text-align:center;margin-bottom:24px;">
      <img src="${LOGO_URL}" alt="SONGRE" width="120"
           style="max-width:120px;height:auto;"
           onerror="this.style.display='none'" />
      <h2 style="color:${couleur};margin:12px 0 0;font-size:20px;">${titre}</h2>
    </div>
    ${contenu}
    <hr style="border:none;border-top:1px solid #eee;margin:28px 0;">
    <p style="color:#999;font-size:12px;text-align:center;line-height:1.6;">
      Vous recevez cet email car vous êtes inscrit(e) sur SONGRE —
      Plateforme de don de sang au Burkina Faso.<br>
      Pour gérer vos préférences, accédez à votre profil dans l'application.
    </p>
    <p style="color:#ccc;font-size:11px;text-align:center;">
      © SONGRE · <a href="https://songre.bf" style="color:#C0392B;">songre.bf</a>
    </p>
  </div>
</body>
</html>`.trim();
}

// ── Templates individuels ─────────────────────────────────────────────────────

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
        📍 <strong>Structure :</strong> ${structure}
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
        ✔ Merci pour votre générosité !
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Pensez à bien vous hydrater et vous reposer dans les heures qui suivent.
      Votre historique de dons a été mis à jour dans SONGRE.
    </p>`,
    "#27AE60",
  );
}

function templateDonConfirmeDemandeur(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "Demandeur";
  const groupe = data["groupe_sanguin"] ?? "";
  return baseTemplate(
    "Votre demande a été honorée !",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Un donneur a confirmé son don${groupe ? ` de type <strong>${groupe}</strong>` : ""}
      pour votre demande. Le don a été validé avec succès via l'application.
    </p>
    <div style="background:#f0fff4;border-left:4px solid #27AE60;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0;font-size:15px;color:#27AE60;font-weight:bold;">
        ✔ Don confirmé — votre demande est honorée.
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Merci d'utiliser SONGRE pour connecter les demandeurs et donneurs
      au Burkina Faso. Ensemble, nous sauvons des vies.
    </p>`,
    "#27AE60",
  );
}

function templateReponseRecue(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "Demandeur";
  const nbReponses = data["nb_reponses"] ?? "1";
  return baseTemplate(
    "Un donneur a répondu à votre demande !",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Bonne nouvelle — vous avez reçu <strong>${nbReponses} réponse(s)</strong>
      à votre demande de don de sang.
    </p>
    <div style="background:#fff5f5;border-left:4px solid #C0392B;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0;font-size:15px;color:#C0392B;font-weight:bold;">
        ⏰ Contactez le donneur rapidement — le temps est précieux.
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Ouvrez l'application SONGRE pour consulter les coordonnées du donneur
      et organiser le don dans les meilleurs délais.
    </p>
    <div style="text-align:center;margin-top:28px;">
      <a href="https://songre.bf/app"
         style="background:#C0392B;color:white;text-decoration:none;
                padding:12px 28px;border-radius:8px;font-weight:bold;font-size:15px;">
        Voir les réponses
      </a>
    </div>`,
  );
}

function templateReponseEncouragement(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "Donneur";
  return baseTemplate(
    "Merci d'avoir répondu — contactez vite !",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Vous avez répondu à une demande de don de sang. Votre geste peut
      <strong>sauver une vie</strong>.
    </p>
    <div style="background:#fff5f5;border-left:4px solid #C0392B;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0;font-size:15px;color:#C0392B;font-weight:bold;">
        ⚡ Prenez contact avec le demandeur le plus vite possible.
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Donner son sang, c'est donner une chance à quelqu'un de vivre.
      Le demandeur vous attend — chaque minute compte.
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

function templateRetourEligibilite(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "Donneur";
  const jours = data["jours_restants"] ?? "quelques jours";
  const demain = jours === "0" || jours === "1";
  return baseTemplate(
    demain ? "Vous êtes de nouveau éligible !" : "Bientôt de nouveau éligible",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      ${
        demain
          ? "Bonne nouvelle ! Vous êtes <strong>de nouveau éligible</strong> pour donner votre sang."
          : `Il vous reste seulement <strong>${jours} jour(s)</strong> avant de pouvoir donner à nouveau.`
      }
    </p>
    <div style="background:#fff5f5;border-left:4px solid #C0392B;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0;font-size:15px;color:#C0392B;">
        ❤️ <strong>Donner son sang, c'est sauver jusqu'à 3 vies.</strong><br>
        Pensez à activer votre disponibilité dans votre profil pour être
        contacté(e) lors des prochaines demandes compatibles.
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Des patients ont besoin de vous. Mettez à jour votre disponibilité
      dans l'application SONGRE dès maintenant.
    </p>
    <div style="text-align:center;margin-top:28px;">
      <a href="https://songre.bf/app"
         style="background:#C0392B;color:white;text-decoration:none;
                padding:12px 28px;border-radius:8px;font-weight:bold;font-size:15px;">
        Activer ma disponibilité
      </a>
    </div>`,
  );
}

function templateDonEnregistreManuel(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "Donneur";
  const dateStr = data["date"] ?? new Date().toLocaleDateString("fr-FR");
  return baseTemplate(
    "Don déclaratif enregistré",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Votre don déclaratif du <strong>${dateStr}</strong> a bien été enregistré
      dans votre historique SONGRE.
    </p>
    <div style="background:#f0fff4;border-left:4px solid #27AE60;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0;font-size:15px;color:#27AE60;font-weight:bold;">
        ✔ Merci pour votre générosité, vous sauvez des vies !
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Votre délai d'éligibilité a été mis à jour automatiquement.
      Pensez à bien vous hydrater et vous reposer.
    </p>`,
    "#27AE60",
  );
}

function templateSuppressionDemandee(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "Utilisateur";
  const dateStr = data["date_suppression"] ?? "dans 5 jours";
  return baseTemplate(
    "Demande de suppression de compte reçue",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Nous avons bien reçu votre demande de suppression de compte.
      La suppression définitive est programmée pour le
      <strong>${dateStr}</strong>.
    </p>
    <div style="background:#fff3cd;border-left:4px solid #F59E0B;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0 0 8px;font-size:15px;color:#B45309;font-weight:bold;">
        ⚠️ Comment annuler cette demande ?
      </p>
      <p style="margin:0;font-size:14px;color:#92400E;">
        Ouvrez l'application SONGRE → Profil → annulez depuis la bannière
        qui s'affiche en haut de votre profil. Vous avez jusqu'au
        <strong>${dateStr}</strong> pour changer d'avis.
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Pendant ce délai, votre compte est masqué des demandes de sang.
      Toutes vos données seront supprimées de façon irréversible à l'échéance.
    </p>`,
    "#F59E0B",
  );
}

function templateSuppressionConfirmee(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "Utilisateur";
  return baseTemplate(
    "Compte supprimé définitivement",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Votre compte SONGRE a été supprimé définitivement, comme demandé.
      Toutes vos données ont été effacées de nos serveurs.
    </p>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Merci d'avoir fait partie de la communauté SONGRE. Si vous changez
      d'avis, vous pourrez toujours créer un nouveau compte à tout moment.
    </p>`,
    "#6B7280",
  );
}

function templateBienvenue(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "nouvel utilisateur";
  return baseTemplate(
    "Bienvenue sur SONGRE !",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Bienvenue sur <strong>SONGRE</strong>, la plateforme de don de sang
      au Burkina Faso. Votre inscription a bien été prise en compte.
    </p>
    <div style="background:#f0fff4;border-left:4px solid #27AE60;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0;font-size:15px;color:#27AE60;">
        ❤️ <strong>Votre don de sang peut sauver jusqu'à 3 vies.</strong><br>
        Complétez votre profil donneur pour commencer à aider les patients
        qui ont besoin de vous.
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Pour commencer :<br>
      1. Complétez votre profil (groupe sanguin, poids, ville)<br>
      2. Activez votre disponibilité<br>
      3. Répondez aux demandes compatibles dans votre ville
    </p>
    <div style="text-align:center;margin-top:28px;">
      <a href="https://songre.bf/app"
         style="background:#C0392B;color:white;text-decoration:none;
                padding:12px 28px;border-radius:8px;font-weight:bold;font-size:15px;">
        Compléter mon profil
      </a>
    </div>`,
    "#27AE60",
  );
}

function templateMdpModifie(data: Record<string, string>): string {
  const prenom = data["prenom"] ?? "Utilisateur";
  const dateHeure = data["date_heure"] ?? new Date().toLocaleString("fr-FR");
  return baseTemplate(
    "Votre mot de passe a été modifié",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Le mot de passe de votre compte SONGRE a été modifié avec succès
      le <strong>${dateHeure}</strong>.
    </p>
    <div style="background:#fff3cd;border-left:4px solid #F59E0B;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0;font-size:15px;color:#B45309;font-weight:bold;">
        🔒 Ce n'était pas vous ?
      </p>
      <p style="margin:0 0 0 0;font-size:14px;color:#92400E;margin-top:8px;">
        Si vous n'avez pas effectué cette modification, contactez-nous
        immédiatement à
        <a href="mailto:songre.contact@gmail.com" style="color:#C0392B;">
          songre.contact@gmail.com
        </a>
        et changez votre mot de passe depuis l'application.
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Si c'est bien vous, ignorez ce message — votre compte est sécurisé.
    </p>`,
    "#F59E0B",
  );
}

function templateContactSupport(data: Record<string, string>): string {
  const email = data["email"] ?? "";
  const objet = data["objet"] ?? "Sans objet";
  const message = data["message"] ?? "";
  const userId = data["user_id"] ?? "Anonyme";
  const dateHeure = data["date_heure"] ?? new Date().toLocaleString("fr-FR");
  return baseTemplate(
    `[SONGRE Support] ${objet}`,
    `<p style="color:#333;font-size:16px;">
      Nouveau message depuis l'application SONGRE.
    </p>
    <table style="width:100%;border-collapse:collapse;font-size:14px;margin:16px 0;">
      <tr>
        <td style="padding:8px;font-weight:bold;color:#555;width:120px;">De :</td>
        <td style="padding:8px;color:#333;">${email}</td>
      </tr>
      <tr style="background:#f9f9f9;">
        <td style="padding:8px;font-weight:bold;color:#555;">User ID :</td>
        <td style="padding:8px;color:#333;">${userId}</td>
      </tr>
      <tr>
        <td style="padding:8px;font-weight:bold;color:#555;">Objet :</td>
        <td style="padding:8px;color:#333;">${objet}</td>
      </tr>
      <tr style="background:#f9f9f9;">
        <td style="padding:8px;font-weight:bold;color:#555;">Date :</td>
        <td style="padding:8px;color:#333;">${dateHeure}</td>
      </tr>
    </table>
    <div style="background:#f9f9f9;border:1px solid #eee;border-radius:8px;
                padding:16px;margin:16px 0;">
      <p style="margin:0;font-size:15px;color:#333;white-space:pre-wrap;">${message}</p>
    </div>
    <p style="color:#999;font-size:13px;">
      Répondre directement à : <a href="mailto:${email}" style="color:#C0392B;">${email}</a>
    </p>`,
  );
}

// ── Renderer principal ────────────────────────────────────────────────────────

export function renderTemplate(
  template: TemplateName,
  data: Record<string, string> = {},
): string | null {
  switch (template) {
    case "demande_compatible":
      return templateDemandeCompatible(data);
    case "don_confirme":
      return templateDonConfirme(data);
    case "don_confirme_demandeur":
      return templateDonConfirmeDemandeur(data);
    case "reponse_recue":
      return templateReponseRecue(data);
    case "reponse_encouragement":
      return templateReponseEncouragement(data);
    case "retour_eligibilite":
      return templateRetourEligibilite(data);
    case "don_enregistre_manuel":
      return templateDonEnregistreManuel(data);
    case "suppression_demandee":
      return templateSuppressionDemandee(data);
    case "suppression_confirmee":
      return templateSuppressionConfirmee(data);
    case "bienvenue":
      return templateBienvenue(data);
    case "mdp_modifie":
      return templateMdpModifie(data);
    case "contact_support":
      return templateContactSupport(data);
    default:
      return null;
  }
}

// ── Fournisseurs email ────────────────────────────────────────────────────────

async function envoyerViaBrevo(
  apiKey: string,
  from: string,
  to: string,
  subject: string,
  html: string,
  replyTo?: string,
): Promise<boolean> {
  try {
    const fromMatch = from.match(/^(.+?)\s*<(.+?)>$/);
    const senderName = fromMatch ? fromMatch[1].trim() : "SONGRE";
    const senderEmail = fromMatch ? fromMatch[2].trim() : from;

    const body: Record<string, unknown> = {
      sender: { name: senderName, email: senderEmail },
      to: [{ email: to }],
      subject,
      htmlContent: html,
    };
    if (replyTo) body["replyTo"] = { email: replyTo };

    const resp = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "api-key": apiKey,
      },
      body: JSON.stringify(body),
    });

    if (!resp.ok) {
      const errBody = await resp.text();
      console.warn("[email] Brevo error:", resp.status, errBody.slice(0, 300));
      return false;
    }
    return true;
  } catch (err) {
    console.warn("[email] Brevo fetch error:", err);
    return false;
  }
}

async function envoyerViaResend(
  apiKey: string,
  from: string,
  to: string,
  subject: string,
  html: string,
  replyTo?: string,
): Promise<boolean> {
  try {
    const body: Record<string, unknown> = {
      from,
      to: [to],
      subject,
      html,
    };
    if (replyTo) body["reply_to"] = replyTo;

    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(body),
    });

    if (!resp.ok) {
      const errBody = await resp.text();
      console.warn("[email] Resend error:", resp.status, errBody.slice(0, 300));
      return false;
    }
    return true;
  } catch (err) {
    console.warn("[email] Resend fetch error:", err);
    return false;
  }
}

// ── Orchestrateur rotatif (export principal) ──────────────────────────────────

export async function envoyerEmailRotatif(
  destinataire: string,
  sujet: string,
  htmlBody: string,
  options?: { replyTo?: string },
): Promise<EmailResult> {
  const emailFrom = Deno.env.get("EMAIL_FROM") ?? "SONGRE <noreply@songre.bf>";
  const provider = (Deno.env.get("EMAIL_PROVIDER") ?? "auto").toLowerCase();

  type Tentative = { provider: "brevo" | "resend"; key: string; label: string };
  const tentatives: Tentative[] = [];

  if (provider === "brevo") {
    const k1 = Deno.env.get("BREVO_API_KEY");
    const k2 = Deno.env.get("BREVO_API_KEY_2");
    if (k1) tentatives.push({ provider: "brevo", key: k1, label: "Brevo/key1" });
    if (k2) tentatives.push({ provider: "brevo", key: k2, label: "Brevo/key2" });
  } else if (provider === "resend") {
    const k1 = Deno.env.get("RESEND_API_KEY");
    const k2 = Deno.env.get("RESEND_API_KEY_2");
    if (k1) tentatives.push({ provider: "resend", key: k1, label: "Resend/key1" });
    if (k2) tentatives.push({ provider: "resend", key: k2, label: "Resend/key2" });
  } else {
    // "auto" : Brevo en priorité, Resend en fallback
    const bk1 = Deno.env.get("BREVO_API_KEY");
    const bk2 = Deno.env.get("BREVO_API_KEY_2");
    const rk1 = Deno.env.get("RESEND_API_KEY");
    const rk2 = Deno.env.get("RESEND_API_KEY_2");
    if (bk1) tentatives.push({ provider: "brevo", key: bk1, label: "Brevo/key1" });
    if (bk2) tentatives.push({ provider: "brevo", key: bk2, label: "Brevo/key2" });
    if (rk1) tentatives.push({ provider: "resend", key: rk1, label: "Resend/key1" });
    if (rk2) tentatives.push({ provider: "resend", key: rk2, label: "Resend/key2" });
  }

  if (tentatives.length === 0) {
    console.warn("[email] Aucune clé email configurée — email ignoré.");
    return { success: false };
  }

  for (const t of tentatives) {
    let ok = false;
    if (t.provider === "brevo") {
      ok = await envoyerViaBrevo(
        t.key, emailFrom, destinataire, sujet, htmlBody, options?.replyTo,
      );
    } else {
      ok = await envoyerViaResend(
        t.key, emailFrom, destinataire, sujet, htmlBody, options?.replyTo,
      );
    }

    if (ok) {
      console.log(`[email] Envoyé via ${t.label} → ${destinataire}`);
      return { success: true, provider: t.provider, key: t.label };
    }
    console.warn(`[email] ${t.label} échoué, tentative suivante...`);
  }

  return { success: false };
}
