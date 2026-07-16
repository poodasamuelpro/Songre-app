import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { notifierUtilisateur } from "../_shared/notifier.ts";

interface ProfilRow {
  user_id: string;
  genre: string;
  dernier_don_date: string;
  disponible: boolean;
}

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace("Bearer ", "").trim();

  if (token !== serviceRoleKey) {
    console.warn("[retour-eligibilite] Accès non autorisé.");
    return jsonResponse({ error: "Accès non autorisé." }, 403, corsHeaders);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  const maintenant = new Date();
  // Fenêtre SQL couvrant les nouveaux délais 90j (homme) et 120j (femme).
  // dateMin = maintenant - 121 jours → inclut les femmes devenant éligibles
  //           dans les 2 prochains jours (délai 120j ± 1j de marge)
  // dateMax = maintenant - 89 jours  → inclut les hommes devenus éligibles
  //           hier ou aujourd'hui     (délai 90j ± 1j de marge)
  const dateMin90 = new Date(maintenant);
  dateMin90.setDate(dateMin90.getDate() - 121);

  const dateMax90 = new Date(maintenant);
  dateMax90.setDate(dateMax90.getDate() - 89);

  const { data: profils, error: profilError } = await adminClient
    .from("profils_donneurs")
    .select("user_id, genre, dernier_don_date, disponible")
    .not("dernier_don_date", "is", null)
    .gte("dernier_don_date", dateMin90.toISOString().substring(0, 10))
    .lte("dernier_don_date", dateMax90.toISOString().substring(0, 10));

  if (profilError) {
    console.error("[retour-eligibilite] Erreur lecture profils:", profilError);
    return jsonResponse({ error: "Erreur DB." }, 500, corsHeaders);
  }

  if (!profils || profils.length === 0) {
    return jsonResponse({ success: true, notified: 0 }, 200, corsHeaders);
  }

  const donneursEligibles = [];

  for (const profil of profils as ProfilRow[]) {
    const dernierDon = new Date(profil.dernier_don_date);
    const delaiJours = profil.genre === "femme" ? 120 : 90;
    const dateEligibilite = new Date(dernierDon);
    dateEligibilite.setDate(dateEligibilite.getDate() + delaiJours);

    const normMaintenant = new Date(maintenant.toISOString().substring(0, 10));
    const normEligibilite = new Date(dateEligibilite.toISOString().substring(0, 10));
    const diffMs = normEligibilite.getTime() - normMaintenant.getTime();
    const joursRestants = Math.ceil(diffMs / (1000 * 60 * 60 * 24));

    if (joursRestants >= 0 && joursRestants <= 1) {
      donneursEligibles.push({ user_id: profil.user_id, joursRestants });
    }
  }

  let notifiedCount = 0;
  await Promise.all(
    donneursEligibles.map(async ({ user_id, joursRestants }) => {
      try {
        const result = await notifierUtilisateur(
          adminClient,
          user_id,
          "retour_eligibilite",
          { jours_restants: String(joursRestants) },
          {},
        );
        if (result.emailSent || result.fcmSent) {
          notifiedCount++;
        }
      } catch (err) {
        console.error(`User ${user_id}: ${err}`);
      }
    }),
  );

  return jsonResponse({
    success: true,
    candidates: donneursEligibles.length,
    notified: notifiedCount,
  }, 200, corsHeaders);
});
