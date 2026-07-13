import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { envoyerEmailRotatif, renderTemplate } from "../_shared/email.ts";

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return jsonResponse({ error: "Unauthorized." }, 401, corsHeaders);

  const jwt = authHeader.substring(7);
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const adminClient = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const userClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });

  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return jsonResponse({ error: "JWT invalide." }, 401, corsHeaders);

  const { objet, message } = await req.json();
  if (!objet || !message) return jsonResponse({ error: "Champs manquants." }, 400, corsHeaders);

  const supportEmail = Deno.env.get("SUPPORT_EMAIL") || "songre.contact@gmail.com";
  const htmlContent = renderTemplate("contact_support", {
    email: user.email || "Inconnu",
    objet,
    message,
    user_id: user.id,
    date_heure: new Date().toLocaleString("fr-FR"),
  });

  if (!htmlContent) return jsonResponse({ error: "Template error." }, 500, corsHeaders);

  const res = await envoyerEmailRotatif(supportEmail, `[SONGRE Support] ${objet}`, htmlContent, { replyTo: user.email });
  
  if (res.success) {
    try { await adminClient.from("contact_spam_log").insert({ user_id: user.id }); } catch { /* ignore */ }
  }

  return jsonResponse({ success: res.success }, res.success ? 200 : 500, corsHeaders);
});
