// =============================================================================
// Edge Function : matcher-et-notifier
// Déployement : supabase functions deploy matcher-et-notifier
//
// Déclenchement : Webhook base de données Supabase
//   Table   : sante.demandes_sang
//   Event   : INSERT
//   Payload : { type: "INSERT", table: "demandes_sang", record: { ... } }
//
// Flux :
//   1. Valider la signature webhook (secret WEBHOOK_SECRET)
//   2. Extraire la nouvelle demande (record)
//   3. Trouver les donneurs compatibles (groupe sanguin ABO + ville + disponible + délai)
//   4. Pour chaque donneur compatible :
//      a. Envoyer une notification FCM via Firebase Cloud Messaging
//      b. Envoyer un email via Resend (ou Brevo en fallback)
//      c. Insérer dans sante.notifications_envoyees
//
// Variables d'environnement requises (Supabase Dashboard → Settings → Edge Functions) :
//   SUPABASE_URL                 (injectée automatiquement)
//   SUPABASE_SERVICE_ROLE_KEY    (injectée automatiquement)
//   WEBHOOK_SECRET               Clé secrète pour valider l'origine du webhook
//   FCM_SERVER_KEY               Firebase Cloud Messaging server key (Legacy HTTP API)
//                                ou FCM_PROJECT_ID + FCM_SERVICE_ACCOUNT_JSON pour v1 API
//   RESEND_API_KEY               Clé API Resend (service email)
//   EMAIL_FROM                   Expéditeur : ex. "SONGRE <noreply@songre.bf>"
//
// Note FCM : utilise l'API Legacy (v1 nécessite un service account JWT).
//   Migrer vers v1 API quand disponible en production.
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Types ────────────────────────────────────────────────────────────────────

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: DemandeSangRecord;
  old_record: DemandeSangRecord | null;
}

interface DemandeSangRecord {
  id: string;
  auteur_id: string;
  groupe_sanguin_recherche: string;
  ville: string;
  structure_sanitaire: string;
  statut: string;
  expires_at: string;
  created_at: string;
}

interface ProfilDonneur {
  user_id: string;
  groupe_sanguin: string;
  ville: string;
  disponible: boolean;
  dernier_don_date: string | null;
}

interface Identite {
  user_id: string;
  email: string;
  fcm_token: string | null;
}

interface NotificationEnvoyee {
  donneur_id: string;
  demande_id: string;
  canal: "fcm" | "email";
  statut: "envoye" | "echec";
  message: string;
}

// ── Compatibilité ABO ─────────────────────────────────────────────────────────
// Miroir de sante.est_compatible_abo() et DemandeSang._groupesCompatibles()

const COMPATIBILITE_ABO: Record<string, string[]> = {
  "O-":  ["O-"],
  "O+":  ["O-", "O+"],
  "A-":  ["O-", "A-"],
  "A+":  ["O-", "O+", "A-", "A+"],
  "B-":  ["O-", "B-"],
  "B+":  ["O-", "O+", "B-", "B+"],
  "AB-": ["O-", "A-", "B-", "AB-"],
  "AB+": ["O-", "O+", "A-", "A+", "B-", "B+", "AB-", "AB+"],
};

function estCompatible(groupeReceveur: string, groupeDonneur: string): boolean {
  const compatibles = COMPATIBILITE_ABO[groupeReceveur] ?? [];
  return compatibles.includes(groupeDonneur);
}

// ── Délai inter-don ───────────────────────────────────────────────────────────

function estEligible(profil: ProfilDonneur): boolean {
  if (!profil.dernier_don_date) return true;
  const dernierDon = new Date(profil.dernier_don_date);
  const maintenant = new Date();
  const joursEcoules = Math.floor(
    (maintenant.getTime() - dernierDon.getTime()) / (1000 * 60 * 60 * 24),
  );
  // 60 jours par défaut (profil non différencié — le trigger vérifie par genre)
  return joursEcoules >= 60;
}

// ── Notification FCM (Legacy HTTP API) ────────────────────────────────────────

async function envoyerFcm(
  fcmToken: string,
  titre: string,
  corps: string,
  data: Record<string, string>,
): Promise<boolean> {
  const fcmServerKey = Deno.env.get("FCM_SERVER_KEY");
  if (!fcmServerKey) {
    console.warn("[matcher] FCM_SERVER_KEY non configurée — notification FCM ignorée.");
    return false;
  }

  try {
    const payload = {
      to: fcmToken,
      notification: {
        title: titre,
        body: corps,
        sound: "default",
      },
      data,
      priority: "high",
    };

    const resp = await fetch("https://fcm.googleapis.com/fcm/send", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `key=${fcmServerKey}`,
      },
      body: JSON.stringify(payload),
    });

    if (!resp.ok) {
      const errBody = await resp.text();
      console.error("[matcher] FCM error:", resp.status, errBody);
      return false;
    }

    const result = await resp.json();
    // FCM retourne success=1 même avec HTTP 200 si le token est invalide
    return result.success === 1;
  } catch (err) {
    console.error("[matcher] FCM fetch error:", err);
    return false;
  }
}

// ── Notification Email via Resend ─────────────────────────────────────────────

async function envoyerEmail(
  destinataire: string,
  sujet: string,
  htmlBody: string,
): Promise<boolean> {
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const emailFrom = Deno.env.get("EMAIL_FROM") ?? "SONGRE <noreply@songre.bf>";

  if (!resendKey) {
    console.warn("[matcher] RESEND_API_KEY non configurée — email ignoré.");
    return false;
  }

  try {
    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${resendKey}`,
      },
      body: JSON.stringify({
        from: emailFrom,
        to: [destinataire],
        subject: sujet,
        html: htmlBody,
      }),
    });

    if (!resp.ok) {
      const errBody = await resp.text();
      console.error("[matcher] Resend error:", resp.status, errBody);
      return false;
    }
    return true;
  } catch (err) {
    console.error("[matcher] Resend fetch error:", err);
    return false;
  }
}

// ── Template email ─────────────────────────────────────────────────────────────

function genererEmailHtml(
  groupeSanguin: string,
  ville: string,
  structure: string,
): string {
  return `
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>Demande de don de sang — SONGRE</title>
</head>
<body style="font-family: Arial, sans-serif; background: #f9f9f9; margin: 0; padding: 20px;">
  <div style="max-width: 560px; margin: 0 auto; background: #fff;
              border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.08);">
    <div style="text-align: center; margin-bottom: 24px;">
      <span style="font-size: 40px;">🩸</span>
      <h2 style="color: #C0392B; margin: 8px 0 0;">Besoin urgent de sang</h2>
    </div>
    <p style="color: #333; font-size: 16px; line-height: 1.6;">
      Une demande de don de type <strong>${groupeSanguin}</strong> vient d'être publiée
      à <strong>${ville}</strong>.
    </p>
    <div style="background: #fff5f5; border-left: 4px solid #C0392B;
                padding: 16px; border-radius: 6px; margin: 20px 0;">
      <p style="margin: 0; font-size: 15px; color: #555;">
        📍 <strong>Structure :</strong> ${structure}
      </p>
    </div>
    <p style="color: #555; font-size: 14px; line-height: 1.6;">
      Si votre groupe sanguin est compatible et que vous êtes disponible,
      ouvrez l'application SONGRE pour répondre à cette demande.
    </p>
    <div style="text-align: center; margin-top: 28px;">
      <a href="https://songre.bf/app"
         style="background: #C0392B; color: white; text-decoration: none;
                padding: 12px 28px; border-radius: 8px; font-weight: bold; font-size: 15px;">
        Ouvrir SONGRE
      </a>
    </div>
    <hr style="border: none; border-top: 1px solid #eee; margin: 28px 0;">
    <p style="color: #999; font-size: 12px; text-align: center;">
      Vous recevez cet email car vous êtes inscrit(e) comme donneur de sang sur SONGRE.
      Pour modifier vos préférences, accédez à votre profil dans l'application.
    </p>
  </div>
</body>
</html>
`.trim();
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-secret",
      },
    });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Méthode non autorisée." }), { status: 405 });
  }

  // ── Validation de la signature webhook ───────────────────────────────────
  const webhookSecret = Deno.env.get("WEBHOOK_SECRET");
  if (webhookSecret) {
    const receivedSecret = req.headers.get("x-webhook-secret");
    if (receivedSecret !== webhookSecret) {
      console.warn("[matcher] Webhook secret invalide — requête rejetée.");
      return new Response(JSON.stringify({ error: "Unauthorized." }), { status: 401 });
    }
  }

  // ── Parser le payload ─────────────────────────────────────────────────────
  let payload: WebhookPayload;
  try {
    payload = await req.json() as WebhookPayload;
  } catch {
    return new Response(JSON.stringify({ error: "Payload JSON invalide." }), { status: 400 });
  }

  // N'agir que sur les INSERTs dans demandes_sang
  if (payload.type !== "INSERT" || payload.table !== "demandes_sang") {
    return new Response(JSON.stringify({ skipped: true }), { status: 200 });
  }

  const demande = payload.record;

  if (demande.statut !== "active") {
    return new Response(JSON.stringify({ skipped: "statut non active" }), { status: 200 });
  }

  // ── Client admin Supabase ─────────────────────────────────────────────────
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // ── 1. Trouver les donneurs compatibles ───────────────────────────────────
  // Critères : bonne ville + disponible=true + groupe sanguin compatible + pas l'auteur
  const { data: profils, error: profilError } = await adminClient
    .from("profils_donneurs")
    .select("user_id, groupe_sanguin, ville, disponible, dernier_don_date")
    .eq("ville", demande.ville)
    .eq("disponible", true)
    .neq("user_id", demande.auteur_id); // Ne pas notifier le demandeur lui-même

  if (profilError) {
    console.error("[matcher] Erreur lecture profils:", profilError);
    return new Response(JSON.stringify({ error: "DB error." }), { status: 500 });
  }

  if (!profils || profils.length === 0) {
    console.log("[matcher] Aucun donneur disponible à", demande.ville);
    return new Response(JSON.stringify({ matched: 0 }), { status: 200 });
  }

  // Filtrer par compatibilité ABO et éligibilité (délai inter-don)
  const donneursFiltres = (profils as ProfilDonneur[]).filter((p) =>
    estCompatible(demande.groupe_sanguin_recherche, p.groupe_sanguin) &&
    estEligible(p)
  );

  if (donneursFiltres.length === 0) {
    console.log("[matcher] Aucun donneur compatible pour", demande.groupe_sanguin_recherche);
    return new Response(JSON.stringify({ matched: 0 }), { status: 200 });
  }

  const donneurIds = donneursFiltres.map((p) => p.user_id);

  // ── 2. Récupérer emails + tokens FCM des donneurs matchés ────────────────
  const { data: identites, error: idError } = await adminClient
    .from("identites")
    .select("user_id, email, fcm_token")
    .in("user_id", donneurIds);

  if (idError) {
    console.error("[matcher] Erreur lecture identites:", idError);
    return new Response(JSON.stringify({ error: "DB error identites." }), { status: 500 });
  }

  const identitesMap = new Map<string, Identite>();
  (identites as Identite[] ?? []).forEach((i) => identitesMap.set(i.user_id, i));

  // ── 3. Envoyer notifications + insérer dans notifications_envoyees ────────
  const logs: NotificationEnvoyee[] = [];
  let notifCount = 0;

  const titreNotif = `🩸 Besoin de ${demande.groupe_sanguin_recherche} à ${demande.ville}`;
  const corpsNotif = `${demande.structure_sanitaire} cherche un donneur. Répondez maintenant.`;
  const emailData: Record<string, string> = {
    demande_id: demande.id,
    groupe_sanguin: demande.groupe_sanguin_recherche,
    ville: demande.ville,
  };
  const emailHtml = genererEmailHtml(
    demande.groupe_sanguin_recherche,
    demande.ville,
    demande.structure_sanitaire,
  );
  const emailSujet = `[SONGRE] Besoin urgent de ${demande.groupe_sanguin_recherche} à ${demande.ville}`;

  // Traiter chaque donneur compatible (parallélisé par batch de 10)
  const BATCH_SIZE = 10;
  for (let i = 0; i < donneursFiltres.length; i += BATCH_SIZE) {
    const batch = donneursFiltres.slice(i, i + BATCH_SIZE);

    await Promise.all(
      batch.map(async (profil) => {
        const identite = identitesMap.get(profil.user_id);
        if (!identite) return;

        // a. Notification FCM si token disponible
        if (identite.fcm_token) {
          const fcmOk = await envoyerFcm(
            identite.fcm_token,
            titreNotif,
            corpsNotif,
            emailData,
          );
          logs.push({
            donneur_id: profil.user_id,
            demande_id: demande.id,
            canal: "fcm",
            statut: fcmOk ? "envoye" : "echec",
            message: fcmOk ? "FCM envoyé" : "FCM échoué",
          });
          if (fcmOk) notifCount++;
        }

        // b. Email via Resend
        if (identite.email) {
          const emailOk = await envoyerEmail(identite.email, emailSujet, emailHtml);
          logs.push({
            donneur_id: profil.user_id,
            demande_id: demande.id,
            canal: "email",
            statut: emailOk ? "envoye" : "echec",
            message: emailOk ? "Email envoyé" : "Email échoué",
          });
          if (emailOk) notifCount++;
        }
      }),
    );
  }

  // ── 4. Persister les logs dans notifications_envoyees ────────────────────
  if (logs.length > 0) {
    const { error: logError } = await adminClient
      .from("notifications_envoyees")
      .insert(
        logs.map((l) => ({
          donneur_id: l.donneur_id,
          demande_id: l.demande_id,
          canal: l.canal,
          statut: l.statut,
          message: l.message,
          envoye_le: new Date().toISOString(),
        })),
      );

    if (logError) {
      // Non bloquant — les notifications ont déjà été envoyées
      console.error("[matcher] Erreur insert notifications_envoyees:", logError);
    }
  }

  console.log(
    `[matcher] Demande ${demande.id}: ${donneursFiltres.length} donneurs matchés,`
    + ` ${notifCount} notifications envoyées.`,
  );

  return new Response(
    JSON.stringify({
      success: true,
      matched: donneursFiltres.length,
      notified: notifCount,
    }),
    {
      status: 200,
      headers: { "Content-Type": "application/json" },
    },
  );
});
