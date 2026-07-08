// =============================================================================
// Edge Function : valider-token
// Déployement : supabase functions deploy valider-token
//
// Flux :
//   POST /functions/v1/valider-token
//   Body : { token: string, demandeur_id: string }
//   Auth : Bearer <access_token> (JWT Supabase authentifié)
//
// Étapes :
//   1. Valider le JWT de l'appelant (via SUPABASE_URL + SUPABASE_ANON_KEY)
//   2. Récupérer le token dans sante.dons_qr_tokens
//   3. Vérifier : token existe, non expiré (expires_at > now), non utilisé (used_at IS NULL)
//   4. Vérifier que demandeur_id == auteur de la demande liée
//   5. Marquer le token comme utilisé (used_at = now)
//   6. Insérer dans sante.historique_dons (source = 'qr_valide')
//   7. Retourner { donneur_id, demande_id }
//
// Variables d'environnement requises :
//   SUPABASE_URL          (injectée automatiquement par Supabase)
//   SUPABASE_SERVICE_ROLE_KEY  (injectée automatiquement par Supabase)
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Types ────────────────────────────────────────────────────────────────────

interface RequestBody {
  token: string;
  demandeur_id: string;
}

interface QrToken {
  id: string;
  donneur_id: string;
  demande_id: string;
  expires_at: string;
  used_at: string | null;
  created_at: string;
}

interface DemandeSang {
  id: string;
  auteur_id: string;
  statut: string;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      // CORS — adapter selon l'origine de l'app
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    },
  });
}

function errorResponse(message: string, status = 400): Response {
  return jsonResponse({ error: message }, status);
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  // Preflight CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    });
  }

  if (req.method !== "POST") {
    return errorResponse("Méthode non autorisée.", 405);
  }

  // ── 1. Authentification appelant ──────────────────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return errorResponse("Token d'authentification manquant.", 401);
  }
  const jwt = authHeader.substring(7);

  // Client avec JWT de l'appelant (pour vérifier l'identité)
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Client service_role pour les opérations DB (contourne RLS)
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // Vérifier le JWT de l'appelant
  const userClient = createClient(
    supabaseUrl,
    Deno.env.get("SUPABASE_ANON_KEY") ?? serviceRoleKey,
    {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false },
    },
  );

  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return errorResponse("JWT invalide ou expiré.", 401);
  }

  // ── 2. Parser le body ─────────────────────────────────────────────────────
  let body: RequestBody;
  try {
    body = await req.json() as RequestBody;
  } catch {
    return errorResponse("Body JSON invalide.");
  }

  const { token, demandeur_id } = body;

  if (!token || typeof token !== "string" || token.trim().length === 0) {
    return errorResponse("Champ 'token' manquant ou vide.");
  }
  if (!demandeur_id || typeof demandeur_id !== "string" || demandeur_id.trim().length === 0) {
    return errorResponse("Champ 'demandeur_id' manquant ou vide.");
  }

  const tokenTrimmed = token.trim();

  // ── 3. Récupérer le token QR ──────────────────────────────────────────────
  const { data: qrRows, error: qrError } = await adminClient
    .from("dons_qr_tokens")
    .select("id, donneur_id, demande_id, expires_at, used_at, created_at")
    .eq("token", tokenTrimmed)
    .limit(1);

  if (qrError) {
    console.error("[valider-token] DB error fetching token:", qrError);
    return errorResponse("Erreur interne lors de la récupération du token.", 500);
  }

  if (!qrRows || qrRows.length === 0) {
    return errorResponse("Code QR introuvable ou invalide.", 404);
  }

  const qr = qrRows[0] as QrToken;

  // ── 4. Vérifications métier ───────────────────────────────────────────────

  // [a] Token déjà utilisé (usage unique)
  if (qr.used_at !== null) {
    return errorResponse("Ce code QR a déjà été utilisé. Il ne peut être validé qu'une seule fois.");
  }

  // [b] Token expiré
  const now = new Date();
  const expiresAt = new Date(qr.expires_at);
  if (now > expiresAt) {
    return errorResponse(
      `Code QR expiré depuis le ${expiresAt.toLocaleString("fr-FR", { timeZone: "UTC" })}.`,
    );
  }

  // ── 5. Vérifier que l'appelant est bien l'auteur de la demande ────────────
  const { data: demandeRows, error: demandeError } = await adminClient
    .from("demandes_sang")
    .select("id, auteur_id, statut")
    .eq("id", qr.demande_id)
    .limit(1);

  if (demandeError || !demandeRows || demandeRows.length === 0) {
    return errorResponse("Demande liée au token introuvable.", 404);
  }

  const demande = demandeRows[0] as DemandeSang;

  if (demande.auteur_id !== demandeur_id) {
    // Sécurité : le demandeur_id fourni ne correspond pas à l'auteur réel
    return errorResponse("Vous n'êtes pas l'auteur de cette demande.", 403);
  }

  if (demande.statut !== "active") {
    return errorResponse(`La demande est dans l'état '${demande.statut}' et ne peut plus être honorée.`);
  }

  // ── 6. Marquer le token comme utilisé (atomique) ──────────────────────────
  const { error: updateError } = await adminClient
    .from("dons_qr_tokens")
    .update({ used_at: now.toISOString() })
    .eq("id", qr.id)
    .is("used_at", null); // Guard against race condition

  if (updateError) {
    console.error("[valider-token] Failed to mark token used:", updateError);
    return errorResponse("Erreur lors de la validation du code.", 500);
  }

  // ── 7. Insérer dans historique_dons ──────────────────────────────────────
  const dateAujourdhui = now.toISOString().substring(0, 10); // "YYYY-MM-DD"
  const { error: donError } = await adminClient
    .from("historique_dons")
    .insert({
      donneur_id: qr.donneur_id,
      demande_id: qr.demande_id,
      date_don: dateAujourdhui,
      source: "qr_valide",
    });

  if (donError) {
    // Non bloquant : le token est déjà marqué utilisé. Logger sans interrompre.
    console.error("[valider-token] Failed to insert historique_don:", donError);
  }

  // ── 8. Mettre à jour le statut de la réponse donneur → 'confirme' ─────────
  const { error: reponseError } = await adminClient
    .from("reponses_donneurs")
    .update({ statut: "confirme" })
    .eq("donneur_id", qr.donneur_id)
    .eq("demande_id", qr.demande_id);

  if (reponseError) {
    // Non bloquant
    console.error("[valider-token] Failed to update reponse statut:", reponseError);
  }

  // ── 9. Réponse succès ─────────────────────────────────────────────────────
  return jsonResponse({
    success: true,
    donneur_id: qr.donneur_id,
    demande_id: qr.demande_id,
    validated_at: now.toISOString(),
  });
});
