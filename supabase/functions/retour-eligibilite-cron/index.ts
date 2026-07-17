// =============================================================================
// Edge Function : retour-eligibilite-cron  (D3 — Cas 5)
// Déploiement   : supabase functions deploy retour-eligibilite-cron
//
// Déclenchement : pg_cron quotidien à 08h00 UTC
//   SELECT cron.schedule(
//     'songre-retour-eligibilite',
//     '0 8 * * *',
//     $$
//       SELECT net.http_post(
//         url := current_setting('app.supabase_url') || '/functions/v1/retour-eligibilite-cron',
//         headers := jsonb_build_object(
//           'Content-Type', 'application/json',
//           'Authorization', 'Bearer ' || current_setting('app.service_role_key')
//         ),
//         body := '{}'::jsonb
//       );
//     $$
//   );
//
// Logique :
//   - Cherche les donneurs dont dernier_don_date + délai (60j homme / 90j femme)
//     tombe dans les prochains 24h (J+0 ou J+1)
//   - Envoie une notification "retour_eligibilite" avec un message encourageant
//     à réactiver leur disponibilité
//
// Auth : Bearer Service Role (pg_cron l'injecte via current_setting)
//
// Variables d'environnement :
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — injectées automatiquement
//   + Variables email/FCM (_shared/)
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { notifierUtilisateur } from "../_shared/notifier.ts";

// ── Types ─────────────────────────────────────────────────────────────────────

interface ProfilRow {
  user_id: string;
  genre: string;
  dernier_don_date: string;
  disponible: boolean;
}

// ── Handler principal ─────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req, "POST, OPTIONS");
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  // ── Auth : Service Role Bearer (injecté par pg_cron) ──────────────────────
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

  // ── Calculer la fenêtre temporelle ────────────────────────────────────────
  // On cherche les donneurs dont la date d'éligibilité est aujourd'hui (J+0)
  // ou demain (J+1). Cela permet d'anticiper et d'encourager en avance.
  //
  // Date d'éligibilité = dernier_don_date + délai (60j ou 90j selon genre)
  // On récupère tous les donneurs avec dernier_don_date et on filtre en mémoire
  // pour éviter des requêtes SQL complexes.

  const maintenant = new Date();
  // Mis à jour le 2026-07-16 : délai passé de 60/90j à 90/120j (homme/femme).
  // Fenêtre de recherche élargie pour couvrir les deux genres avec marge :
  //   dateMin = maintenant - 121 jours (délai max 120j + 1j de marge)
  //   dateMax = maintenant - 89 jours  (délai min 90j - 1j de marge)
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
    console.log("[retour-eligibilite] Aucun donneur à notifier.");
    return jsonResponse({ success: true, notified: 0 }, 200, corsHeaders);
  }

  // ── Filtrer les donneurs qui deviennent éligibles dans J+0 ou J+1 ─────────

  interface DonneurEligible {
    user_id: string;
    joursRestants: number;
  }

  const donneursEligibles: DonneurEligible[] = [];

  for (const profil of profils as ProfilRow[]) {
    const dernierDon = new Date(profil.dernier_don_date);
    const delaiJours = profil.genre === "femme" ? 120 : 90;
    const dateEligibilite = new Date(dernierDon);
    dateEligibilite.setDate(dateEligibilite.getDate() + delaiJours);

    // Normaliser à minuit UTC pour comparer les dates
    const normMaintenant = new Date(maintenant.toISOString().substring(0, 10));
    const normEligibilite = new Date(dateEligibilite.toISOString().substring(0, 10));
    const diffMs = normEligibilite.getTime() - normMaintenant.getTime();
    const joursRestants = Math.ceil(diffMs / (1000 * 60 * 60 * 24));

    // Notifier si éligibilité dans 0 ou 1 jour(s)
    if (joursRestants >= 0 && joursRestants <= 1) {
      donneursEligibles.push({ user_id: profil.user_id, joursRestants });
    }
  }

  if (donneursEligibles.length === 0) {
    console.log("[retour-eligibilite] Aucun donneur atteignant l'éligibilité aujourd'hui.");
    return jsonResponse({ success: true, notified: 0 }, 200, corsHeaders);
  }

  // ── Envoyer les notifications ─────────────────────────────────────────────

  let notifiedCount = 0;
  const errors: string[] = [];

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
        if (result.errors.length > 0) {
          errors.push(...result.errors);
        }
      } catch (err) {
        errors.push(`User ${user_id}: ${err}`);
      }
    }),
  );

  console.log(
    `[retour-eligibilite] Cron terminé: ${donneursEligibles.length} candidats, ` +
    `${notifiedCount} notifiés, ${errors.length} erreur(s).`,
  );

  return jsonResponse({
    success: true,
    candidates: donneursEligibles.length,
    notified: notifiedCount,
    errors: errors.length > 0 ? errors.slice(0, 5) : undefined, // Limiter log
  }, 200, corsHeaders);
});
