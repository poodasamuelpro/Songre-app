// =============================================================================
// _shared/notifier.ts — Module partagé SONGRE : orchestrateur de notifications
//
// Fonction centrale : notifierUtilisateur(adminClient, userId, type, data)
//   1. Récupère l'email de l'utilisateur via auth.users (admin API)
//   2. Rend le template HTML via email.ts
//   3. Envoie l'email via email.ts (rotation Brevo/Resend)
//   4. Envoie la notification FCM v1 via fcm.ts (si token disponible)
//   5. Insère dans public.notifications_envoyees (sauf fire-and-forget)
//
// Options :
//   skipDbInsert   — true pour les cas fire-and-forget (ex: suppression compte)
//   demandeId      — UUID de la demande liée (optionnel, pour la clé FK)
//   fcmTitre       — Titre de la notification push (défaut : titre du type)
//   fcmCorps       — Corps de la notification push (défaut : message court)
//   fcmData        — Données supplémentaires pour la notification push
// =============================================================================

import {
  envoyerEmailRotatif,
  renderTemplate,
  type TemplateName,
} from "./email.ts";

import {
  envoyerFcmV1,
  getFcmAccessTokenFromEnv,
  getFcmTokensForUser,
} from "./fcm.ts";

// ── Types publics ─────────────────────────────────────────────────────────────

export interface NotifierOptions {
  demandeId?: string;
  fcmTitre?: string;
  fcmCorps?: string;
  fcmData?: Record<string, string>;
  skipDbInsert?: boolean;
  replyToEmail?: string;
}

export interface NotifierResult {
  userId: string;
  type: string;
  emailSent: boolean;
  fcmSent: boolean;
  dbInserted: boolean;
  errors: string[];
}

// ── Titres et corps FCM par défaut selon le type de notification ──────────────

function fcmDefaults(
  type: string,
  templateData: Record<string, string>,
): { titre: string; corps: string } {
  switch (type) {
    case "demande_compatible":
      return {
        titre: `Besoin de ${templateData["groupe_sanguin"] ?? "sang"} à ${templateData["ville"] ?? "votre ville"}`,
        corps: "Une demande compatible vient d'être publiée. Répondez maintenant.",
      };
    case "reponse_recue":
      return {
        titre: "Un donneur a répondu !",
        corps: "Ouvrez l'app pour consulter ses coordonnées et l'appeler.",
      };
    case "reponse_encouragement":
      return {
        titre: "Merci d'avoir répondu !",
        corps: "Contactez rapidement le demandeur — chaque minute compte.",
      };
    case "don_confirme":
      return {
        titre: "Don confirmé — Merci !",
        corps: "Votre don a été validé. Vous sauvez des vies !",
      };
    case "don_confirme_demandeur":
      return {
        titre: "Votre demande a été honorée !",
        corps: "Un donneur a confirmé son don. Votre demande est pourvue.",
      };
    case "don_enregistre_manuel":
      return {
        titre: "Don enregistré",
        corps: "Votre don déclaratif a bien été pris en compte. Merci !",
      };
    case "retour_eligibilite":
      return {
        titre: "Vous êtes de nouveau éligible !",
        corps: "Activez votre disponibilité dans votre profil SONGRE.",
      };
    case "suppression_demandee":
      return {
        titre: "Suppression de compte programmée",
        corps: "Vous pouvez annuler depuis votre profil avant l'échéance.",
      };
    case "bienvenue":
      return {
        titre: "Bienvenue sur SONGRE !",
        corps: "Complétez votre profil pour commencer à donner du sang.",
      };
    case "mdp_modifie":
      return {
        titre: "Mot de passe modifié",
        corps: "Ce n'était pas vous ? Contactez le support immédiatement.",
      };
    default:
      return {
        titre: "SONGRE — Notification",
        corps: "Ouvrez l'application pour plus d'informations.",
      };
  }
}

// ── Mapping type → sujet email ────────────────────────────────────────────────

function emailSujet(type: string, templateData: Record<string, string>): string {
  switch (type) {
    case "demande_compatible":
      return `[SONGRE] Besoin urgent de ${templateData["groupe_sanguin"] ?? "sang"} à ${templateData["ville"] ?? "votre ville"}`;
    case "reponse_recue":
      return "[SONGRE] Un donneur a répondu à votre demande !";
    case "reponse_encouragement":
      return "[SONGRE] Merci — contactez le demandeur rapidement";
    case "don_confirme":
      return "[SONGRE] Don confirmé — Merci pour votre générosité !";
    case "don_confirme_demandeur":
      return "[SONGRE] Votre demande de sang a été honorée !";
    case "don_enregistre_manuel":
      return "[SONGRE] Don déclaratif enregistré";
    case "retour_eligibilite":
      return "[SONGRE] Vous pouvez à nouveau donner votre sang !";
    case "suppression_demandee":
      return "[SONGRE] Demande de suppression de compte reçue";
    case "bienvenue":
      return "[SONGRE] Bienvenue — Complétez votre profil donneur";
    case "mdp_modifie":
      return "[SONGRE] Votre mot de passe a été modifié";
    case "contact_support":
      return `[SONGRE Support] ${templateData["objet"] ?? "Message"}`;
    default:
      return "[SONGRE] Notification";
  }
}

// ── Fonction principale ───────────────────────────────────────────────────────

// deno-lint-ignore no-explicit-any
export async function notifierUtilisateur(
  adminClient: any,
  userId: string,
  type: TemplateName,
  templateData: Record<string, string> = {},
  options: NotifierOptions = {},
): Promise<NotifierResult> {
  const result: NotifierResult = {
    userId,
    type,
    emailSent: false,
    fcmSent: false,
    dbInserted: false,
    errors: [],
  };

  // ── 1. Récupérer l'email depuis auth.users ────────────────────────────────
  let userEmail: string | null = null;
  try {
    const { data: userData, error: userError } =
      await adminClient.auth.admin.getUserById(userId);
    if (!userError && userData?.user?.email) {
      userEmail = userData.user.email;
    }
  } catch (err) {
    const msg = `Erreur récupération email user ${userId}: ${err}`;
    console.warn(`[notifier] ${msg}`);
    result.errors.push(msg);
  }

  // ── 2. Générer le HTML du template ────────────────────────────────────────
  const htmlContent = renderTemplate(type, templateData);

  // ── 3. Envoyer l'email ────────────────────────────────────────────────────
  if (userEmail && htmlContent) {
    const sujet = emailSujet(type, templateData);
    const emailResult = await envoyerEmailRotatif(userEmail, sujet, htmlContent, {
      replyTo: options.replyToEmail,
    });
    result.emailSent = emailResult.success;
    if (!emailResult.success) {
      result.errors.push(`Email non envoyé vers ${userEmail}`);
    }
  } else if (!userEmail) {
    result.errors.push(`Email introuvable pour user ${userId}`);
  }

  // ── 4. Envoyer la notification FCM ────────────────────────────────────────
  const fcmTokens = await getFcmTokensForUser(adminClient, userId);
  if (fcmTokens.length > 0) {
    const fcmAuth = await getFcmAccessTokenFromEnv();
    if (fcmAuth) {
      const { titre: defTitre, corps: defCorps } = fcmDefaults(type, templateData);
      const titre = options.fcmTitre ?? defTitre;
      const corps = options.fcmCorps ?? defCorps;
      const fcmData: Record<string, string> = {
        type,
        ...(options.demandeId ? { demande_id: options.demandeId } : {}),
        ...(options.fcmData ?? {}),
      };

      for (const token of fcmTokens) {
        const sent = await envoyerFcmV1(
          token,
          titre,
          corps,
          fcmData,
          fcmAuth.accessToken,
          fcmAuth.projectId,
        );
        if (sent) {
          result.fcmSent = true;
          break; // Succès sur au moins un appareil
        }
      }
    }
  }

  // ── 5. Insérer dans public.notifications_envoyees ─────────────────────────
  // skip si fire-and-forget (ex: suppression de compte → ligne sera supprimée)
  if (!options.skipDbInsert && (result.emailSent || result.fcmSent)) {
    try {
      const { error: insertError } = await adminClient
        .from("notifications_envoyees")
        .insert({
          user_id: userId,
          demande_id: options.demandeId ?? null,
          type, // Valeur de l'enum public.type_notification_enum
          lu: false,
        });

      if (insertError) {
        const msg = `Erreur insert notifications_envoyees: ${insertError.message}`;
        console.error(`[notifier] ${msg}`);
        result.errors.push(msg);
      } else {
        result.dbInserted = true;
      }
    } catch (err) {
      result.errors.push(`Exception insert notifications_envoyees: ${err}`);
    }
  }

  return result;
}

// ── Variante pour envoi direct sans persistence DB ───────────────────────────
// Utilisée pour suppression_confirmee (compte sera supprimé juste après)

export async function envoyerEmailDirect(
  destinataire: string,
  type: TemplateName,
  templateData: Record<string, string> = {},
  options?: { replyTo?: string },
): Promise<boolean> {
  const htmlContent = renderTemplate(type, templateData);
  if (!htmlContent) {
    console.error(`[notifier] Template inconnu: ${type}`);
    return false;
  }
  const sujet = emailSujet(type, templateData);
  const result = await envoyerEmailRotatif(destinataire, sujet, htmlContent, options);
  return result.success;
}
