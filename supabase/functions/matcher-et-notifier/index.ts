import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders, handleCors, jsonResponse } from "../_shared/cors.ts";
import { envoyerEmailRotatif, renderTemplate } from "../_shared/email.ts";
import {
  envoyerFcmV1,
  getFcmAccessTokenFromEnv,
  getFcmTokensForUser,
} from "../_shared/fcm.ts";

interface DemandeSangRecord {
  id: string;
  auteur_id: string;
  groupe_sanguin_recherche: string;
  ville_id: number | null;
  structure_id: number | null;
  ville_libre: string | null;
  structure_libre: string | null;
  statut: string;
}

interface ProfilDonneur {
  user_id: string;
  groupe_sanguin: string;
  genre: string;
  ville_id: number;
  disponible: boolean;
  dernier_don_date: string | null;
}

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
  return (COMPATIBILITE_ABO[groupeReceveur] ?? []).includes(groupeDonneur);
}

function estEligible(profil: ProfilDonneur): boolean {
  if (!profil.dernier_don_date) return true;
  const dernierDon = new Date(profil.dernier_don_date);
  const maintenant = new Date();
  const joursEcoules = Math.floor((maintenant.getTime() - dernierDon.getTime()) / (1000 * 60 * 60 * 24));
  return joursEcoules >= (profil.genre === "femme" ? 90 : 60);
}

serve(async (req: Request) => {
  const corsHeaders = getCorsHeaders(req);
  const preflight = handleCors(req, corsHeaders);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "Méthode non autorisée." }, 405, corsHeaders);
  }

  const webhookSecret = Deno.env.get("WEBHOOK_SECRET");
  if (!webhookSecret || webhookSecret.trim().length === 0) {
    return jsonResponse({ error: "Configuration serveur incomplète." }, 500, corsHeaders);
  }

  const receivedSecret = req.headers.get("x-webhook-secret");
  if (receivedSecret !== webhookSecret) {
    return jsonResponse({ error: "Unauthorized." }, 401, corsHeaders);
  }

  let payload;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "Payload JSON invalide." }, 400, corsHeaders);
  }

  if (payload.type !== "INSERT" || payload.table !== "demandes_sang") {
    return jsonResponse({ skipped: true }, 200, corsHeaders);
  }

  const demande = payload.record as DemandeSangRecord;
  if (demande.statut !== "active") return jsonResponse({ skipped: "statut non active" }, 200, corsHeaders);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  let villeLabel = demande.ville_libre ?? "ville inconnue";
  let structureLabel = demande.structure_libre ?? "structure inconnue";

  if (demande.ville_id) {
    const { data } = await adminClient.from("villes").select("nom").eq("id", demande.ville_id).maybeSingle();
    if (data?.nom) villeLabel = data.nom;
  }
  if (demande.structure_id) {
    const { data } = await adminClient.from("structures_sanitaires").select("nom").eq("id", demande.structure_id).maybeSingle();
    if (data?.nom) structureLabel = data.nom;
  }

  let profilQuery = adminClient
    .from("profils_donneurs")
    .select("user_id, groupe_sanguin, genre, ville_id, disponible, dernier_don_date")
    .eq("disponible", true)
    .neq("user_id", demande.auteur_id);

  if (demande.ville_id) profilQuery = profilQuery.eq("ville_id", demande.ville_id);

  const { data: profils } = await profilQuery;
  if (!profils || profils.length === 0) return jsonResponse({ matched: 0 }, 200, corsHeaders);

  const donneursFiltres = (profils as ProfilDonneur[]).filter((p) =>
    estCompatible(demande.groupe_sanguin_recherche, p.groupe_sanguin) && estEligible(p)
  );

  if (donneursFiltres.length === 0) return jsonResponse({ matched: 0 }, 200, corsHeaders);

  const fcmAuth = await getFcmAccessTokenFromEnv();
  const templateData = { groupe_sanguin: demande.groupe_sanguin_recherche, ville: villeLabel, structure: structureLabel };
  const emailSujet = `[SONGRE] Besoin urgent de ${demande.groupe_sanguin_recherche} à ${villeLabel}`;
  const emailHtml = renderTemplate("demande_compatible", templateData);

  const notifInserts = [];
  for (const profil of donneursFiltres) {
    let notified = false;
    if (fcmAuth) {
      const tokens = await getFcmTokensForUser(adminClient, profil.user_id);
      for (const token of tokens) {
        const ok = await envoyerFcmV1(token, `Besoin de ${demande.groupe_sanguin_recherche}`, `${structureLabel} cherche un donneur.`, { demande_id: demande.id, type: "demande_compatible" }, fcmAuth.accessToken, fcmAuth.projectId);
        if (ok) { notified = true; break; }
      }
    }
    const { data: userData } = await adminClient.auth.admin.getUserById(profil.user_id);
    if (userData?.user?.email && emailHtml) {
      const res = await envoyerEmailRotatif(userData.user.email, emailSujet, emailHtml);
      if (res.success) notified = true;
    }
    if (notified) {
      notifInserts.push({ user_id: profil.user_id, demande_id: demande.id, type: "demande_compatible", lu: false });
    }
  }

  if (notifInserts.length > 0) await adminClient.from("notifications_envoyees").insert(notifInserts);

  return jsonResponse({ success: true, matched: donneursFiltres.length, notified: notifInserts.length }, 200, corsHeaders);
});
