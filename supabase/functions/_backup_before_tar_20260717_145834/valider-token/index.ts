import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors } from "../_shared/cors.ts";
import { notifierUtilisateur } from "../_shared/notifier.ts";

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

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req);
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return errorResponse("Méthode non autorisée.", 405, corsHeaders);
  }

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

  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return errorResponse("Token d'authentification manquant.", 401, corsHeaders);
  }
  const jwt = authHeader.substring(7);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? serviceRoleKey;

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false },
  });

  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return errorResponse("JWT invalide ou expiré.", 401, corsHeaders);
  }

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
  if (!demandeur_id || typeof demandeur_id !== "string" || demandeur_id.trim().length === 0) {
    return errorResponse("Champ 'demandeur_id' manquant ou vide.", 400, corsHeaders);
  }

  if (demandeur_id !== user.id) {
    return errorResponse(
      "demandeur_id ne correspond pas à l'utilisateur authentifié.",
      403,
      corsHeaders,
    );
  }

  const tokenTrimmed = token.trim();

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

  const qr = qrRows[0];

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

  const { data: demandeRows, error: demandeError } = await adminClient
    .from("demandes_sang")
    .select("id, auteur_id, statut")
    .eq("id", qr.demande_id)
    .limit(1);

  if (demandeError || !demandeRows || demandeRows.length === 0) {
    return errorResponse("Demande liée au token introuvable.", 404, corsHeaders);
  }

  const demande = demandeRows[0];

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

  const { error: updateError } = await adminClient
    .from("dons_qr_tokens")
    .update({
      used_at: now.toISOString(),
      used_by: demandeur_id,
    })
    .eq("token", qr.token)
    .is("used_at", null);

  if (updateError) {
    console.error("[valider-token] Failed to mark token used:", updateError);
    return errorResponse("Erreur lors de la validation du code.", 500, corsHeaders);
  }

  const dateAujourdhui = now.toISOString().substring(0, 10);
  await adminClient
    .from("historique_dons")
    .insert({
      donneur_id: qr.donneur_id,
      demande_id: qr.demande_id,
      date_don: dateAujourdhui,
      source: "qr_valide",
    });

  await adminClient
    .from("reponses_donneurs")
    .update({ statut: "confirme" })
    .eq("donneur_id", qr.donneur_id)
    .eq("demande_id", qr.demande_id);

  const dateStr = now.toLocaleDateString("fr-FR");

  await Promise.all([
    notifierUtilisateur(
      adminClient,
      qr.donneur_id,
      "don_confirme",
      { date: dateStr },
      { demandeId: qr.demande_id },
    ).catch(() => null),
    notifierUtilisateur(
      adminClient,
      demande.auteur_id,
      "don_confirme_demandeur",
      {},
      { demandeId: qr.demande_id },
    ).catch(() => null),
  ]);

  return jsonResponse({
    success: true,
    donneur_id: qr.donneur_id,
    demande_id: qr.demande_id,
    validated_at: now.toISOString(),
  }, 200, corsHeaders);
});
