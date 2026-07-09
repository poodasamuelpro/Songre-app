-- =============================================================================
-- MISSION D — Script SQL consolidé
-- Projet : SONGRE — Application de don de sang au Burkina Faso
-- =============================================================================
-- Contenu :
--   §1  — Vérification de l'enum existant (diagnostic avant extension)
--   §2  — Extension de type_notification_enum (7 nouvelles valeurs)
--   §3  — Table public.contact_spam_log (anti-spam pour contacter-support)
--   §4  — Table public.liens_externes (boutons dynamiques)
--   §5  — Données initiales pour liens_externes
--   §6  — Trigger updated_at sur liens_externes
--   §7  — Index sur liens_externes
--   §8  — RLS sur liens_externes
--   §9  — pg_cron : enregistrement des jobs cron
--   §10 — Vérification finale
-- =============================================================================
-- IMPORTANT : Exécuter dans le SQL Editor du Dashboard Supabase.
-- Le rôle postgres (superuser) est requis pour les commandes pg_cron.
-- Les ALTER TYPE ADD VALUE IF NOT EXISTS sont idempotents.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- §1 — DIAGNOSTIC : valeurs actuelles de l'enum
-- ─────────────────────────────────────────────────────────────────────────────
-- Exécuter d'abord cette requête pour voir les valeurs existantes :
-- SELECT enum_range(NULL::public.type_notification_enum);
--
-- Résultat attendu avant Migration D (base Mission C) :
--   {demande_compatible, don_confirme, retour_eligibilite}
--
-- Si votre enum contient des valeurs sous un nom différent
-- (ex: 'nouveau_don' au lieu de 'don_confirme'), NE PAS exécuter §2
-- sans adapter les noms — signaler l'écart avant d'exécuter.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- §2 — EXTENSION DE TYPE_NOTIFICATION_ENUM
-- ─────────────────────────────────────────────────────────────────────────────
-- Valeurs déjà présentes (à conserver intactes) :
--   demande_compatible, don_confirme, retour_eligibilite
--
-- Nouvelles valeurs ajoutées par Mission D :
ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'reponse_recue';
ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'reponse_encouragement';
ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'don_confirme_demandeur';
ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'don_enregistre_manuel';
ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'suppression_demandee';
ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'bienvenue';
ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'mdp_modifie';

-- Note : 'suppression_confirmee' (Case 7) n'est PAS dans l'enum car cet email
-- est envoyé en fire-and-forget AVANT la suppression du compte et n'est jamais
-- inséré dans notifications_envoyees (la ligne user serait supprimée en cascade).

-- Vérification post-migration :
-- SELECT enum_range(NULL::public.type_notification_enum);
-- Résultat attendu :
--   {demande_compatible, don_confirme, retour_eligibilite, reponse_recue,
--    reponse_encouragement, don_confirme_demandeur, don_enregistre_manuel,
--    suppression_demandee, bienvenue, mdp_modifie}

-- ─────────────────────────────────────────────────────────────────────────────
-- §3 — TABLE public.contact_spam_log (anti-spam pour contacter-support)
-- ─────────────────────────────────────────────────────────────────────────────
-- Utilisée par l'Edge Function contacter-support pour limiter les envois
-- à 1 message par user toutes les 10 minutes.
CREATE TABLE IF NOT EXISTS public.contact_spam_log (
  id          bigserial PRIMARY KEY,
  user_id     uuid NOT NULL,               -- référence à auth.users.id
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Index pour les recherches anti-spam (user_id + horodatage récent)
CREATE INDEX IF NOT EXISTS idx_contact_spam_log_user_recent
  ON public.contact_spam_log (user_id, created_at DESC);

-- RLS : aucun accès direct aux utilisateurs — uniquement via service_role (EF)
ALTER TABLE public.contact_spam_log ENABLE ROW LEVEL SECURITY;

-- Pas de policy SELECT/INSERT/DELETE pour les users : tout passe par EF
-- (la EF utilise la service_role key qui bypass RLS)

-- TTL / nettoyage automatique (optionnel) :
-- Pour éviter la croissance infinie de la table, configurer une purge périodique
-- dans le cron ou via pg_cron :
-- DELETE FROM public.contact_spam_log WHERE created_at < now() - interval '24 hours';
-- (Ajouté dans §9 ci-dessous comme job cron)

-- ─────────────────────────────────────────────────────────────────────────────
-- §4 — TABLE public.liens_externes (boutons dynamiques)
-- ─────────────────────────────────────────────────────────────────────────────
-- Permet à l'admin de gérer dynamiquement les boutons de l'écran Paramètres
-- (Politique de confidentialité, CGU, Site web, etc.) sans mise à jour de l'app.
CREATE TABLE IF NOT EXISTS public.liens_externes (
  id               serial PRIMARY KEY,
  cle              text NOT NULL UNIQUE,      -- identifiant stable, ex: 'politique_confidentialite'
  libelle          text NOT NULL,             -- texte affiché sur le bouton
  url              text NOT NULL,             -- URL complète (https obligatoire)
  icone            text NULL,                 -- nom d'icône optionnel (ex: 'shield', 'file-text')
  ordre_affichage  integer NOT NULL DEFAULT 0,
  actif            boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_url_https CHECK (url LIKE 'https://%')
);

COMMENT ON TABLE public.liens_externes IS
  'Boutons dynamiques pour l''écran Paramètres — gérés par l''admin via Dashboard Supabase.';
COMMENT ON COLUMN public.liens_externes.cle IS
  'Identifiant stable utilisé par le Flutter pour identifier des liens spécifiques si besoin.';
COMMENT ON COLUMN public.liens_externes.icone IS
  'Nom d''icône MaterialIcons ou personnalisé (optionnel). Ex: privacy_tip_outlined, gavel, language.';

-- ─────────────────────────────────────────────────────────────────────────────
-- §5 — DONNÉES INITIALES pour liens_externes
-- ─────────────────────────────────────────────────────────────────────────────
-- Insérer les liens de base. INSERT ... ON CONFLICT DO NOTHING = idempotent.
INSERT INTO public.liens_externes (cle, libelle, url, icone, ordre_affichage) VALUES
  (
    'politique_confidentialite',
    'Politique de confidentialité',
    'https://songre.bf/politique-confidentialite',
    'privacy_tip_outlined',
    10
  ),
  (
    'cgu',
    'Conditions générales d''utilisation',
    'https://songre.bf/cgu',
    'gavel',
    20
  ),
  (
    'site_web',
    'Site web SONGRE',
    'https://songre.bf',
    'language',
    30
  ),
  (
    'faq',
    'Questions fréquentes',
    'https://songre.bf/faq',
    'help_outline',
    40
  ),
  (
    'a_propos',
    'À propos de SONGRE',
    'https://songre.bf/a-propos',
    'info_outline',
    50
  )
ON CONFLICT (cle) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- §6 — TRIGGER updated_at sur liens_externes
-- ─────────────────────────────────────────────────────────────────────────────
-- Fonction générique pour mettre à jour updated_at (réutilisable)
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- Trigger sur liens_externes
DROP TRIGGER IF EXISTS trg_liens_externes_updated_at ON public.liens_externes;
CREATE TRIGGER trg_liens_externes_updated_at
  BEFORE UPDATE ON public.liens_externes
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- §7 — INDEX sur liens_externes
-- ─────────────────────────────────────────────────────────────────────────────
-- Index partiel sur les liens actifs triés par ordre_affichage
-- (utilisé par la requête Flutter : SELECT WHERE actif = true ORDER BY ordre_affichage)
CREATE INDEX IF NOT EXISTS idx_liens_externes_actifs
  ON public.liens_externes (ordre_affichage)
  WHERE actif = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- §8 — RLS sur liens_externes
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.liens_externes ENABLE ROW LEVEL SECURITY;

-- Lecture publique des liens actifs (utilisateurs connectés ET anonymes)
DROP POLICY IF EXISTS "lecture_publique_liens_actifs" ON public.liens_externes;
CREATE POLICY "lecture_publique_liens_actifs"
  ON public.liens_externes
  FOR SELECT
  USING (actif = true);

-- AUCUNE policy d'écriture pour les utilisateurs normaux.
-- Modifications uniquement via le Dashboard Supabase (rôle service_role/postgres).
-- Pour autoriser l'admin via RLS, ajouter une policy FOR ALL USING (auth.role() = 'service_role')
-- ou utiliser directement la connexion postgres dans le Dashboard.

-- ─────────────────────────────────────────────────────────────────────────────
-- §9 — pg_cron : ENREGISTREMENT DES JOBS CRON
-- ─────────────────────────────────────────────────────────────────────────────
-- PRÉREQUIS : L'extension pg_cron doit être activée dans le projet Supabase.
-- Aller dans : Dashboard > Database > Extensions > pg_cron > Enable
--
-- IMPORTANT : Remplacer <PROJECT_REF> par la référence de votre projet Supabase
-- (ex: ptomqwucvveuflfnyczo) dans les URL des Edge Functions ci-dessous.
--
-- Remplacer <SERVICE_ROLE_KEY> par votre service_role key.

-- Job 1 — retour-eligibilite-cron : tous les jours à 08h00 UTC
-- Trouve les donneurs dont la date d'éligibilité tombe à J ou J+1
-- et envoie une notification d'encouragement à réactiver leur disponibilité.
SELECT cron.schedule(
  'retour-eligibilite-cron',           -- nom du job (unique)
  '0 8 * * *',                          -- cron expression : 08h00 UTC quotidien
  $$
  SELECT net.http_post(
    url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/retour-eligibilite-cron',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <SERVICE_ROLE_KEY>'
    ),
    body    := '{}'::jsonb
  ) AS request_id;
  $$
);

-- Job 2 — executer-suppressions-programmees : tous les jours à 02h00 UTC
-- Traite les comptes dont suppression_programmee_le <= now() :
-- envoie l'email de confirmation, puis supprime le compte.
SELECT cron.schedule(
  'executer-suppressions-programmees',
  '0 2 * * *',                          -- 02h00 UTC quotidien
  $$
  SELECT net.http_post(
    url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/executer-suppressions-programmees',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <SERVICE_ROLE_KEY>'
    ),
    body    := '{}'::jsonb
  ) AS request_id;
  $$
);

-- Job 3 — purge contact_spam_log : tous les jours à 03h00 UTC
-- Supprime les entrées de spam_log de plus de 24h pour éviter la croissance infinie.
SELECT cron.schedule(
  'purge-contact-spam-log',
  '0 3 * * *',                          -- 03h00 UTC quotidien
  $$
  DELETE FROM public.contact_spam_log
  WHERE created_at < now() - interval '24 hours';
  $$
);

-- VÉRIFICATION des jobs enregistrés :
-- SELECT jobid, jobname, schedule, command FROM cron.job ORDER BY jobid;

-- Pour SUPPRIMER un job (si besoin de reconfiguration) :
-- SELECT cron.unschedule('retour-eligibilite-cron');
-- SELECT cron.unschedule('executer-suppressions-programmees');
-- SELECT cron.unschedule('purge-contact-spam-log');

-- ─────────────────────────────────────────────────────────────────────────────
-- §9b — CONFIGURATION DES WEBHOOKS DB
-- ─────────────────────────────────────────────────────────────────────────────
-- Les webhooks suivants doivent être configurés via :
-- Dashboard Supabase > Database > Webhooks > Create a new hook
--
-- WEBHOOK 1 — reponse-donneur (Case 2)
--   Table     : public.reponses_donneurs
--   Event     : INSERT
--   URL       : https://<PROJECT_REF>.supabase.co/functions/v1/reponse-donneur
--   HTTP Headers :
--     webhook-secret: <WEBHOOK_SECRET>
--   (Générer un secret fort et l'ajouter aussi dans les secrets EF)
--
-- WEBHOOK 2 — bienvenue-auth (Case 8)
--   ⚠️ Option A (recommandée si disponible) :
--     Supabase Auth Hooks > Send Email Hook : pointer sur bienvenue-auth EF
--     Cette approche est plus fiable car déclenchée par l'authentification.
--   ⚠️ Option B (fallback) :
--     Table     : auth.users (NB: non disponible dans tous les plans Supabase)
--     Event     : INSERT
--     URL       : https://<PROJECT_REF>.supabase.co/functions/v1/bienvenue-auth
--   Si aucune option ne fonctionne : appeler la EF directement depuis Flutter
--   après un signUp() réussi (moins fiable, mais fonctionnel).
--
-- WEBHOOK 3 — mdp-modifie-auth (Case 9)
--   Option A (Auth Hook) : Supabase Auth > Send Custom Email > hook sur EF
--   Option B (DB Webhook sur auth.users UPDATE) — même limitation que Option B ci-dessus
--   Option C (préférée) : appel explicite depuis Flutter après password change réussi
--   → La EF mdp-modifie-auth gère les 3 modes (webhook + appel Flutter).

-- ─────────────────────────────────────────────────────────────────────────────
-- §10 — VÉRIFICATION FINALE
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Vérifier les valeurs de l'enum après migration :
-- SELECT enum_range(NULL::public.type_notification_enum);

-- 2. Vérifier que contact_spam_log existe :
-- SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public' AND table_name = 'contact_spam_log';

-- 3. Vérifier que liens_externes existe avec les données initiales :
-- SELECT id, cle, libelle, url, actif, ordre_affichage
--   FROM public.liens_externes ORDER BY ordre_affichage;

-- 4. Vérifier les jobs pg_cron enregistrés :
-- SELECT jobid, jobname, schedule FROM cron.job ORDER BY jobid;

-- 5. Vérifier les policies RLS :
-- SELECT schemaname, tablename, policyname, cmd, qual
--   FROM pg_policies
--   WHERE schemaname = 'public'
--     AND tablename IN ('liens_externes', 'contact_spam_log')
--   ORDER BY tablename, policyname;

-- =============================================================================
-- FIN DU SCRIPT mission-d.sql
-- =============================================================================
