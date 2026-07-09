-- =============================================================================
-- SONGRE — supabase-addendum.sql
-- Correctifs additionnels pour la base de données de production
-- Instance : https://ptomqwucvveuflfnyczo.supabase.co
--
-- Ce fichier COMPLÈTE (sans remplacer) supabase-schema-corrections.sql.
-- Il cible exclusivement le schéma PUBLIC et ne touche pas aux schémas
-- sante.* ou identite.* (qui n'existent pas dans cette instance).
--
-- CONTENU :
--   1. Cron job : purge des tokens QR expirés ou utilisés
--   2. Vue corrigée : demandes_sang_avec_contact (schéma public, FK entières)
--   3. Index manquants pour notifications_envoyees
--   4. Extension pg_cron : vérification de présence
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 0. Vérification que pg_cron est activé
-- ─────────────────────────────────────────────────────────────────────────────
-- PRÉREQUIS : activez pg_cron dans Supabase Dashboard
--   → Database → Extensions → pg_cron → Enable
-- Sans cela, les commandes cron.schedule() ci-dessous échoueront.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'
  ) THEN
    RAISE NOTICE 'pg_cron non installé — activez-le dans Supabase Dashboard > Database > Extensions';
  ELSE
    RAISE NOTICE 'pg_cron présent — configuration des cron jobs...';
  END IF;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Cron job : purge des tokens QR obsolètes
-- ─────────────────────────────────────────────────────────────────────────────
-- Supprime les entrées de public.dons_qr_tokens qui répondent aux DEUX conditions :
--   - (expires_at < now() OU used_at IS NOT NULL)  → token invalide (expiré ou utilisé)
--   - created_at < now() - interval '30 days'      → ancien d'au moins 30 jours
--
-- La double condition évite de supprimer des tokens récemment utilisés
-- qui pourraient encore être référencés dans des logs ou des rapports.
--
-- Fréquence : quotidienne à 03h00 UTC (03h00 UTC = 04h00 WAT, Burkina Faso)
--
-- Note : si pg_cron n'est pas disponible, exécutez cette purge manuellement
-- ou via une Edge Function Supabase déclenchée par un cron externe.

SELECT cron.unschedule('songre-purger-tokens-qr')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'songre-purger-tokens-qr'
);

SELECT cron.schedule(
  'songre-purger-tokens-qr',
  '0 3 * * *',   -- Quotidien à 03h00 UTC
  $$
    DELETE FROM public.dons_qr_tokens
    WHERE
      (expires_at < now() OR used_at IS NOT NULL)
      AND created_at < now() - interval '30 days';
  $$
);

-- Vérification
SELECT jobid, jobname, schedule, command
FROM cron.job
WHERE jobname = 'songre-purger-tokens-qr';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Cron jobs existants — rappel (déjà configurés, NE PAS recréer)
-- ─────────────────────────────────────────────────────────────────────────────
-- Ces jobs sont déjà en place et ne doivent PAS être recréés :
--
-- songre-expirer-demandes (déjà actif) :
--   '5 * * * *'
--   UPDATE public.demandes_sang SET statut = 'expiree'
--   WHERE statut = 'active' AND expires_at < now();
--
-- songre-supprimer-comptes (déjà actif) :
--   '0 2 * * *'
--   DELETE FROM auth.users WHERE id IN (
--     SELECT user_id FROM public.identites
--     WHERE suppression_programmee_le IS NOT NULL
--     AND suppression_programmee_le <= now()
--   );
--
-- NE PAS exécuter ces commandes — elles sont déjà configurées.


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Vue corrigée : demandes_sang_avec_contact (schéma public)
-- ─────────────────────────────────────────────────────────────────────────────
-- La vue affiche les demandes avec les informations de contact DÉCHIFFRÉES
-- uniquement pour les donneurs ayant répondu (reponses_donneurs).
-- Les champs contact_chiffre et contact_secondaire_chiffre restent NULL
-- si le donneur n'a pas encore répondu → anonymat garanti.
--
-- Corrections par rapport à l'ancienne version :
--   - Schéma public.* partout (plus de sante.* ou identite.*)
--   - Jointures sur ville_id (int) et structure_id (int) — plus de champs texte
--   - Noms de colonnes alignés sur le schéma réel audité
--   - security_invoker = TRUE pour respecter les droits RLS de l'appelant
--
-- Note : le déchiffrement AES-256 des contacts est effectué CÔTÉ APPLICATION
-- (Flutter / Edge Function) car les clés de chiffrement ne sont pas stockées
-- en base. La vue expose donc les valeurs chiffrées conditionnellement.

DROP VIEW IF EXISTS public.demandes_sang_avec_contact;

CREATE OR REPLACE VIEW public.demandes_sang_avec_contact
WITH (security_invoker = TRUE)
AS
SELECT
  -- Champs de la demande
  d.id,
  d.auteur_id,
  d.groupe_sanguin_recherche,
  d.statut,
  d.expires_at,
  d.created_at,

  -- Localisation (FK entières + libellés depuis les tables de référence)
  d.ville_id,
  v.nom                            AS ville_nom,
  d.structure_id,
  ss.nom                           AS structure_nom,
  d.ville_libre,
  d.structure_libre,
  d.quartier,

  -- Contact chiffré : visible UNIQUEMENT si le donneur courant a répondu
  -- L'opérateur appelant (RLS security_invoker) doit avoir une ligne dans
  -- public.reponses_donneurs pour cette demande.
  CASE
    WHEN EXISTS (
      SELECT 1
      FROM public.reponses_donneurs r
      WHERE r.demande_id = d.id
        AND r.donneur_id = auth.uid()
    )
    THEN d.contact_chiffre
    ELSE NULL
  END                              AS contact_chiffre,

  CASE
    WHEN EXISTS (
      SELECT 1
      FROM public.reponses_donneurs r
      WHERE r.demande_id = d.id
        AND r.donneur_id = auth.uid()
    )
    THEN d.contact_secondaire_chiffre
    ELSE NULL
  END                              AS contact_secondaire_chiffre,

  -- Métadonnées
  d.updated_at

FROM public.demandes_sang d
LEFT JOIN public.villes            v  ON v.id  = d.ville_id
LEFT JOIN public.structures_sanitaires ss ON ss.id = d.structure_id;

-- Commentaire de documentation
COMMENT ON VIEW public.demandes_sang_avec_contact IS
  'Vue demandes_sang avec contacts chiffrés visibles uniquement par les donneurs '
  'ayant une réponse associée dans reponses_donneurs. '
  'Jointures sur ville_id (int FK) et structure_id (int FK). '
  'security_invoker = TRUE — les droits RLS de l''appelant s''appliquent.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Index supplémentaires (optimisation des requêtes critiques)
-- ─────────────────────────────────────────────────────────────────────────────

-- Index partiel sur dons_qr_tokens : accélère la purge des tokens actifs
-- (tokens non encore utilisés et non expirés)
CREATE INDEX IF NOT EXISTS idx_tokens_actifs
  ON public.dons_qr_tokens (expires_at, created_at)
  WHERE used_at IS NULL;

-- Index sur notifications_envoyees (user_id + lu) : accélère le comptage
-- des notifications non lues (badge dans l'app)
CREATE INDEX IF NOT EXISTS idx_notif_user_non_lues
  ON public.notifications_envoyees (user_id, lu)
  WHERE lu = false;

-- Commentaires
COMMENT ON INDEX public.idx_tokens_actifs IS
  'Accélère la purge quotidienne des tokens QR expirés ou utilisés.';
COMMENT ON INDEX public.idx_notif_user_non_lues IS
  'Accélère le comptage du badge de notifications non lues dans l''application.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. RLS : politique d'accès à la vue (rappel de configuration)
-- ─────────────────────────────────────────────────────────────────────────────
-- Les vues avec security_invoker héritent des politiques RLS des tables
-- sous-jacentes. Les politiques suivantes doivent être en place sur
-- public.demandes_sang pour que la vue fonctionne correctement :
--
-- Lecture publique des demandes actives (tous les utilisateurs authentifiés) :
--   CREATE POLICY "demandes_actives_lisibles"
--   ON public.demandes_sang FOR SELECT
--   TO authenticated
--   USING (statut = 'active');
--
-- Création limitée à l'auteur authentifié :
--   CREATE POLICY "demandes_creation_auteur"
--   ON public.demandes_sang FOR INSERT
--   TO authenticated
--   WITH CHECK (auteur_id = auth.uid());
--
-- NE PAS exécuter si ces politiques sont déjà en place — vérifier d'abord :
--   SELECT * FROM pg_policies WHERE tablename = 'demandes_sang';


-- ─────────────────────────────────────────────────────────────────────────────
-- Fin du fichier supabase-addendum.sql
-- Version : 1.0 — Mission C — Production Sprint
-- =============================================================================
