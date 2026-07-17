// =============================================================================
// Edge Function : executer-suppressions-programmees  (D3 — Cas 7)
// Déploiement   : supabase functions deploy executer-suppressions-programmees
//
// Déclenchement : pg_cron quotidien à 02h00 UTC
//   SELECT cron.schedule(
//     'songre-executer-suppressions',
//     '0 2 * * *',
//     $$
//       SELECT net.http_post(
//         url := current_setting('app.supabase_url') || '/functions/v1/executer-suppressions-programmees',
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
//   1. Lister les comptes avec suppression_programmee_le <= now()
//   2. Pour chaque compte : récupérer l'email AVANT suppression
//   3. Envoyer l'email de confirmation (fire-and-forget, skipDbInsert=true)
//   4. Supprimer le compte via auth.admin.deleteUser()
//
// IMPORTANT : L'email est envoyé AVANT la suppression. La ligne
// notifications_envoyees n'est PAS créée (skipDbInsert=true) car elle
// serait supprimée en cascade juste après la suppression du compte.
//
// Auth : Bearer Service Role (injecté par pg_cron)
// =============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { envoyerEmailDirect } from "../_shared/notifier.ts";

// ── Types ─────────────────────────────────────────────────────────────────────

interface IdentiteRow {
  user_id: string;
  suppression_programmee_le: string;
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
    console.warn("[suppressions] Accès non autorisé.");
    return jsonResponse({ error: "Accès non autorisé." }, 403, corsHeaders);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // ── 1. Trouver les comptes à supprimer ────────────────────────────────────
  const maintenant = new Date().toISOString();

  const { data: identites, error: identitesError } = await adminClient
    .from("identites")
    .select("user_id, suppression_programmee_le")
    .not("suppression_programmee_le", "is", null)
    .lte("suppression_programmee_le", maintenant);

  if (identitesError) {
    console.error("[suppressions] Erreur lecture identites:", identitesError);
    return jsonResponse({ error: "Erreur DB." }, 500, corsHeaders);
  }

  if (!identites || identites.length === 0) {
    console.log("[suppressions] Aucun compte à supprimer aujourd'hui.");
    return jsonResponse({ success: true, deleted: 0 }, 200, corsHeaders);
  }

  console.log(`[suppressions] ${identites.length} compte(s) à supprimer.`);

  // ── 2 & 3 & 4. Pour chaque compte : email → suppression ──────────────────

  let deletedCount = 0;
  const errors: string[] = [];

  for (const identite of identites as IdentiteRow[]) {
    const userId = identite.user_id;

    // Récupérer l'email AVANT suppression
    let userEmail: string | null = null;
    try {
      const { data: userData, error: userError } =
        await adminClient.auth.admin.getUserById(userId);
      if (!userError && userData?.user?.email) {
        userEmail = userData.user.email;
      }
    } catch (err) {
      console.warn(`[suppressions] Impossible de récupérer email pour ${userId}:`, err);
    }

    // Envoyer l'email de confirmation (fire-and-forget, avant suppression)
    if (userEmail) {
      try {
        await envoyerEmailDirect(
          userEmail,
          "suppression_confirmee", // Template dédié — jamais persisté (fire-and-forget)
          {
            prenom: userEmail.split("@")[0] ?? "Utilisateur",
          },
        );
        console.log(`[suppressions] Email de confirmation envoyé à ${userEmail}`);
      } catch (err) {
        console.warn(`[suppressions] Erreur email confirmation pour ${userId}:`, err);
      }
    }

    // Supprimer le compte via auth.admin.deleteUser()
    // Cette opération supprime auth.users + déclenche la cascade RLS
    try {
      const { error: deleteError } =
        await adminClient.auth.admin.deleteUser(userId);

      if (deleteError) {
        const msg = `Erreur suppression ${userId}: ${deleteError.message}`;
        console.error(`[suppressions] ${msg}`);
        errors.push(msg);
      } else {
        console.log(`[suppressions] Compte ${userId} supprimé.`);
        deletedCount++;
      }
    } catch (err) {
      const msg = `Exception suppression ${userId}: ${err}`;
      console.error(`[suppressions] ${msg}`);
      errors.push(msg);
    }
  }

  console.log(
    `[suppressions] Cron terminé: ${deletedCount}/${identites.length} supprimés, ` +
    `${errors.length} erreur(s).`,
  );

  return jsonResponse({
    success: true,
    total: identites.length,
    deleted: deletedCount,
    errors: errors.length > 0 ? errors.slice(0, 5) : undefined,
  }, 200, corsHeaders);
});
