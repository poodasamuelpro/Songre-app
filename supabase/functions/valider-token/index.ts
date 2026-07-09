// =============================================================================
// Edge Function : valider-token  (v2 — synchronisé avec schéma public.*)
// Déploiement  : supabase functions deploy valider-token
//
// Flux :
//   POST /functions/v1/valider-token
//   Body : { token: string, demandeur_id: string }
//   Auth : Bearer <access_token> (JWT Supabase authentifié)
//
// Étapes :
//   1. Valider le JWT de l'appelant
//   2. Vérifier WEBHOOK_SECRET (obligatoire — erreur explicite si absent)
//   3. Récupérer le token dans public.dons_qr_tokens
//   4. Vérifier que demandeur_id == auteur de la demande liée
//   5. Marquer le token utilisé (used_at = now, used_by = demandeur_id)
//      → Le trigger trg_verifier_token (BEFORE UPDATE of used_at) valide
//        atomiquement : token non expiré ET used_at IS NULL.
//        Si le trigger lève une exception, l'UPDATE échoue → on renvoie l'erreur.
//   6. Insérer dans public.historique_dons (source = 'qr_valide')
//   7. Mettre à jour public.reponses_donneurs.statut → 'confirme'
//   8. Retourner { donneur_id, demande_id, validated_at }
//
// Variables d'environnement requises (Supabase Dashboard → Settings → Secrets) :
//   SUPABASE_URL              (injectée automatiquement par Supabase)
//   SUPABASE_SERVICE_ROLE_KEY (injectée automatiquement par Supabase)
//   SUPABASE_ANON_KEY         (injectée automatiquement par Supabase)
//   WEBHOOK_SECRET            Obligatoire — clé secrète pour l'appelant Flutter
//   ALLOWED_ORIGIN            Domaine de prod (ex: https://songre.bf) — optionnel,
//                             par défaut toutes les origines Supabase sont autorisées
//
// IMPORTANT : SUPABASE_SERVICE_ROLE_KEY ne doit JAMAIS apparaître dans le
//             code Flutter. Elle est injectée uniquement ici côté serveur.
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors } from "../_shared/cors.ts";
import { notifierUtilisateur } from "../_shared/notifier.ts";

// ── Helpers CORS — délégués à _shared/cors.ts ─────────────────────────────────
// (Les fonctions locales getCorsHeaders/jsonResponse ont été migrées vers _shared)

function jsonResponse(
  body: unknown,
  status = 200,
  corsHeaders?: Record<string, string>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...(corsHeaders ?? {}),
    },
  });
}

function errorResponse(
  message: string,
  status = 400,
  corsHeaders?: Record<string, string>,
): Response {
  return jsonResponse({ error: message }, status, corsHeaders);
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req);
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return errorResponse("Méthode non autorisée.", 405, corsHeaders);
  }

  // ── 0. WEBHOOK_SECRET — OBLIGATOIRE ──────────────────────────────────────
  // §6 audit : rendre la variable obligatoire, lever une erreur explicite si absente.
  const webhookSecret = Deno.env.get("WEBHOOK_SECRET");
  if (!webhookSecret || webhookSecret.trim().length === 0) {
    console.error("[valider-token] ERREUR CRITIQUE : WEBHOOK_SECRET non configuré.");
    return errorResponse(
      "Configuration serveur incomplète. Contactez l'administrateur.",
      500,
      corsHeaders,
    );
  }
  const receivedSecret = req.headers.get("x-webhook-secret");
  if (receivedSecret !== webhookSecret) {
    console.warn("[valider-token] Secret webhook invalide — requête rejetée.");
    return errorResponse("Authentification webhook invalide.", 401, corsHeaders);
  }

  // ── 1. Authentification JWT de l'appelant ─────────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return errorResponse("Token d'authentification manquant.", 401, corsHeaders);
  }
  const jwt = authHeader.substring(7);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? serviceRoleKey;

  // Client service_role pour les opérations DB (contourne RLS)
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // Vérifier le JWT de l'appelant
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false },
  });

  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return errorResponse("JWT invalide ou expiré.", 401, corsHeaders);
  }

  // ── 2. Parser le body ─────────────────────────────────────────────────────
  let body: { token?: string; demandeur_id?: string };
  try {
    body = await req.json();
  } catch {
    return errorResponse("Body JSON invalide.", 400, corsHeaders);
  }

  const { token, demandeur_id } = body;

  if (!token || typeof token !== "string" || token.trim().length === 0) {
    return errorResponse("Champ 'token' manquant ou vide.", 400, corsHeaders);
  }
  if (
    !demandeur_id ||
    typeof demandeur_id !== "string" ||
    demandeur_id.trim().length === 0
  ) {
    return errorResponse("Champ 'demandeur_id' manquant ou vide.", 400, corsHeaders);
  }

  // §6 audit : ID utilisateur vide → bloquer immédiatement
  if (demandeur_id !== user.id) {
    return errorResponse(
      "demandeur_id ne correspond pas à l'utilisateur authentifié.",
      403,
      corsHeaders,
    );
  }

  const tokenTrimmed = token.trim();

  // ── 3. Récupérer le token QR ──────────────────────────────────────────────
  // Schéma public.dons_qr_tokens — colonnes : token (PK), donneur_id,
  // demande_id, expires_at, used_at, used_by, created_at
  const { data: qrRows, error: qrError } = await adminClient
    .from("dons_qr_tokens")
    .select("token, donneur_id, demande_id, expires_at, used_at, used_by")
    .eq("token", tokenTrimmed)
    .limit(1);

  if (qrError) {
    console.error("[valider-token] DB error fetching token:", qrError);
    return errorResponse("Erreur interne lors de la récupération du token.", 500, corsHeaders);
  }

  if (!qrRows || qrRows.length === 0) {
    return errorResponse("Code QR introuvable ou invalide.", 404, corsHeaders);
  }

  const qr = qrRows[0] as {
    token: string;
    donneur_id: string;
    demande_id: string;
    expires_at: string;
    used_at: string | null;
    used_by: string | null;
  };

  // Vérifications préliminaires (en double avec le trigger, pour un message
  // d'erreur clair à l'utilisateur avant même de tenter l'UPDATE)
  if (qr.used_at !== null) {
    return errorResponse(
      "Ce code QR a déjà été utilisé. Il ne peut être validé qu'une seule fois.",
      400,
      corsHeaders,
    );
  }
  const now = new Date();
  if (now > new Date(qr.expires_at)) {
    const exp = new Date(qr.expires_at).toLocaleString("fr-FR", {
      timeZone: "UTC",
    });
    return errorResponse(`Code QR expiré depuis le ${exp}.`, 400, corsHeaders);
  }

  // ── 4. Vérifier que l'appelant est bien l'auteur de la demande ────────────
  const { data: demandeRows, error: demandeError } = await adminClient
    .from("demandes_sang")
    .select("id, auteur_id, statut")
    .eq("id", qr.demande_id)
    .limit(1);

  if (demandeError || !demandeRows || demandeRows.length === 0) {
    return errorResponse("Demande liée au token introuvable.", 404, corsHeaders);
  }

  const demande = demandeRows[0] as {
    id: string;
    auteur_id: string;
    statut: string;
  };

  if (demande.auteur_id !== demandeur_id) {
    return errorResponse(
      "Vous n'êtes pas l'auteur de cette demande.",
      403,
      corsHeaders,
    );
  }

  if (demande.statut !== "active") {
    return errorResponse(
      `La demande est dans l'état '${demande.statut}' et ne peut plus être honorée.`,
      400,
      corsHeaders,
    );
  }

  // ── 5. Marquer le token comme utilisé ────────────────────────────────────
  // Le trigger trg_verifier_token (BEFORE UPDATE OF used_at) valide
  // atomiquement que le token est valide (non expiré + non utilisé).
  // Si la validation échoue, le trigger lève une EXCEPTION → l'UPDATE retourne
  // une erreur → on propage le message à l'utilisateur.
  const { error: updateError } = await adminClient
    .from("dons_qr_tokens")
    .update({
      used_at: now.toISOString(),
      used_by: demandeur_id, // §2 audit : renseigner used_by
    })
    .eq("token", qr.token)
    .is("used_at", null); // Guard supplémentaire contre les race conditions

  if (updateError) {
    console.error("[valider-token] Failed to mark token used:", updateError);
    const triggerMessage = updateError.message ?? "";
    if (
      triggerMessage.includes("expiré") ||
      triggerMessage.includes("expired") ||
      triggerMessage.includes("utilisé") ||
      triggerMessage.includes("used")
    ) {
      return errorResponse(triggerMessage, 400, corsHeaders);
    }
    return errorResponse("Erreur lors de la validation du code.", 500, corsHeaders);
  }

  // ── 6. Insérer dans public.historique_dons ────────────────────────────────
  const dateAujourdhui = now.toISOString().substring(0, 10);
  const { error: donError } = await adminClient
    .from("historique_dons")
    .insert({
      donneur_id: qr.donneur_id,
      demande_id: qr.demande_id,
      date_don: dateAujourdhui,
      source: "qr_valide",
    });

  if (donError) {
    // Non bloquant : le token est déjà marqué utilisé
    console.error("[valider-token] Failed to insert historique_don:", donError);
  }

  // ── 7. Mettre à jour public.reponses_donneurs → 'confirme' ───────────────
  const { error: reponseError } = await adminClient
    .from("reponses_donneurs")
    .update({ statut: "confirme" })
    .eq("donneur_id", qr.donneur_id)
    .eq("demande_id", qr.demande_id);

  if (reponseError) {
    // Non bloquant
    console.error(
      "[valider-token] Failed to update reponse statut:",
      reponseError,
    );
  }

  // ── 8. Notifications D3-case3 ────────────────────────────────────────────
  // Donneur : "don_confirme" — merci pour votre don
  // Demandeur : "don_confirme_demandeur" — votre demande a été honorée
  // Ces notifications sont non bloquantes : une erreur n'interrompt pas la réponse.
  const dateStr = now.toLocaleDateString("fr-FR");

  const [notifDonneur, notifDemandeur] = await Promise.all([
    notifierUtilisateur(
      adminClient,
      qr.donneur_id,
      "don_confirme",
      { date: dateStr },
      { demandeId: qr.demande_id },
    ).catch((err) => {
      console.error("[valider-token] Erreur notif donneur:", err);
      return null;
    }),
    notifierUtilisateur(
      adminClient,
      demande.auteur_id,
      "don_confirme_demandeur",
      {},
      { demandeId: qr.demande_id },
    ).catch((err) => {
      console.error("[valider-token] Erreur notif demandeur:", err);
      return null;
    }),
  ]);

  console.log(
    `[valider-token] Notifs: donneur=${notifDonneur?.emailSent || notifDonneur?.fcmSent}, ` +
    `demandeur=${notifDemandeur?.emailSent || notifDemandeur?.fcmSent}`,
  );

  // ── 9. Réponse succès ─────────────────────────────────────────────────────
  return jsonResponse({
    success: true,
    donneur_id: qr.donneur_id,
    demande_id: qr.demande_id,
    validated_at: now.toISOString(),
  }, 200, corsHeaders);
});
