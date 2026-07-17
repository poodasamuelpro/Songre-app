import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { notifierUtilisateur } from "../_shared/notifier.ts";

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) return jsonResponse({ error: "Token manquant." }, 401, corsHeaders);
  
  const jwt = authHeader.substring(7);
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? serviceRoleKey;

  const adminClient = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });

  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return jsonResponse({ error: "JWT invalide." }, 401, corsHeaders);

  const body = await req.json();
  const { date_don } = body;
  if (!date_don || !/^\d{4}-\d{2}-\d{2}$/.test(date_don)) return jsonResponse({ error: "Date invalide." }, 400, corsHeaders);

  await adminClient.from("profils_donneurs").update({ dernier_don_date: date_don }).eq("user_id", user.id);
  await adminClient.from("historique_dons").insert({ donneur_id: user.id, date_don, source: "declaratif" });

  const dateStr = new Date(date_don).toLocaleDateString("fr-FR");
  const notif = await notifierUtilisateur(adminClient, user.id, "don_enregistre_manuel", { date: dateStr }).catch(() => null);

  return jsonResponse({ success: true, date_don, notification: { emailSent: notif?.emailSent, fcmSent: notif?.fcmSent } }, 200, corsHeaders);
});
