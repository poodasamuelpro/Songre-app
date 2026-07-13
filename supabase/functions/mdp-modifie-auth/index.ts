import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { notifierUtilisateur } from "../_shared/notifier.ts";

interface AuthUpdatePayload {
  type: "UPDATE";
  table: string;
  schema: string;
  record: {
    id: string;
    email: string | null;
    updated_at: string;
  };
}

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? serviceRoleKey;

  const webhookSecret = Deno.env.get("WEBHOOK_SECRET") ?? "";
  const receivedSecret = req.headers.get("x-webhook-secret") ?? "";
  const authHeader = req.headers.get("Authorization") ?? "";

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  if (receivedSecret && webhookSecret && receivedSecret === webhookSecret) {
    let payload: AuthUpdatePayload;
    try {
      payload = await req.json() as AuthUpdatePayload;
    } catch {
      return jsonResponse({ error: "Payload JSON invalide." }, 400, corsHeaders);
    }

    if (payload.type !== "UPDATE" || payload.table !== "users") {
      return jsonResponse({ skipped: true }, 200, corsHeaders);
    }

    const updatedUser = payload.record;
    const dateHeure = new Date(updatedUser.updated_at).toLocaleString("fr-FR", {
      timeZone: "Africa/Ouagadougou",
    });

    const result = await notifierUtilisateur(
      adminClient,
      updatedUser.id,
      "mdp_modifie",
      { date_heure: dateHeure },
    );

    return jsonResponse({
      success: true,
      mode: "webhook",
      emailSent: result.emailSent,
    }, 200, corsHeaders);
  }

  if (authHeader.startsWith("Bearer ")) {
    const jwt = authHeader.substring(7);

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false },
    });

    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      return jsonResponse({ error: "JWT invalide ou expiré." }, 401, corsHeaders);
    }

    let body: { action?: string } = {};
    try {
      body = await req.json();
    } catch { /* empty */ }

    if (body.action !== "mdp_modifie") {
      return jsonResponse({ error: "Action 'mdp_modifie' requise." }, 400, corsHeaders);
    }

    const dateHeure = new Date().toLocaleString("fr-FR", {
      timeZone: "Africa/Ouagadougou",
    });

    const result = await notifierUtilisateur(
      adminClient,
      user.id,
      "mdp_modifie",
      { date_heure: dateHeure },
    );

    return jsonResponse({
      success: true,
      mode: "explicit",
      emailSent: result.emailSent,
      fcmSent: result.fcmSent,
    }, 200, corsHeaders);
  }

  return jsonResponse({ error: "Authentification requise." }, 401, corsHeaders);
});
