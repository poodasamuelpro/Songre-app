-- =============================================================================
-- mission-e.sql — Script d'audit et correction de la base de données SONGRE
-- Basé sur l'audit de production du 2026-07-09 (rapport-audit-songre.md)
-- À exécuter dans : Supabase Dashboard → SQL Editor
-- =============================================================================
-- IMPORTANT : Ce script est idempotent (utilise IF NOT EXISTS, OR REPLACE, etc.)
-- Il peut être réexécuté sans danger.
-- =============================================================================

-- ── §1 — Vérification et correction : Enum type_notification_enum ──────────────
-- L'audit S-02 a confirmé que mission-d.sql a ajouté 7 valeurs. On vérifie ici.

DO $$
DECLARE
  enum_values TEXT[];
BEGIN
  SELECT ARRAY_AGG(enumlabel ORDER BY enumlabel)
  INTO enum_values
  FROM pg_enum e
  JOIN pg_type t ON e.enumtypid = t.oid
  WHERE t.typname = 'type_notification_enum';

  RAISE NOTICE 'type_notification_enum valeurs: %', enum_values;

  IF NOT ('bienvenue' = ANY(enum_values)) THEN
    ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'bienvenue';
    RAISE NOTICE 'Added: bienvenue';
  END IF;
  IF NOT ('mdp_modifie' = ANY(enum_values)) THEN
    ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'mdp_modifie';
    RAISE NOTICE 'Added: mdp_modifie';
  END IF;
  IF NOT ('reponse_recue' = ANY(enum_values)) THEN
    ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'reponse_recue';
    RAISE NOTICE 'Added: reponse_recue';
  END IF;
  IF NOT ('reponse_encouragement' = ANY(enum_values)) THEN
    ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'reponse_encouragement';
    RAISE NOTICE 'Added: reponse_encouragement';
  END IF;
  IF NOT ('don_confirme_demandeur' = ANY(enum_values)) THEN
    ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'don_confirme_demandeur';
    RAISE NOTICE 'Added: don_confirme_demandeur';
  END IF;
  IF NOT ('don_enregistre_manuel' = ANY(enum_values)) THEN
    ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'don_enregistre_manuel';
    RAISE NOTICE 'Added: don_enregistre_manuel';
  END IF;
  IF NOT ('suppression_demandee' = ANY(enum_values)) THEN
    ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'suppression_demandee';
    RAISE NOTICE 'Added: suppression_demandee';
  END IF;
END $$;

-- ── §2 — Vérification : table public.identites ────────────────────────────────
-- R-10/2.1.3 : La table identites est requise pour programmerSuppression().

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'identites'
  ) THEN
    RAISE WARNING 'TABLE MANQUANTE : public.identites — à créer manuellement !';
  ELSE
    RAISE NOTICE '✅ public.identites existe.';
  END IF;
END $$;

-- Si la table identites n'existe pas, créez-la avec :
-- (Décommenter si nécessaire)
/*
CREATE TABLE IF NOT EXISTS public.identites (
  user_id     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  compte_actif BOOLEAN NOT NULL DEFAULT true,
  suppression_programmee_le TIMESTAMP WITH TIME ZONE,
  created_at  TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at  TIMESTAMP WITH TIME ZONE DEFAULT now()
);

ALTER TABLE public.identites ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Utilisateur voit sa propre identite"
  ON public.identites FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Utilisateur modifie sa propre identite"
  ON public.identites FOR UPDATE
  USING (auth.uid() = user_id);
*/

-- ── §3 — Correction R-05 : DEFAULT expires_at → 72h (vs 7 jours) ─────────────
-- L'audit a relevé une incohérence entre kDureeValiditeDemande (7j en code)
-- et le cahier des charges (72h). Le code Flutter a été corrigé → 72h.
-- On aligne maintenant le DEFAULT SQL.

DO $$
BEGIN
  -- Vérifier la valeur actuelle du default
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'demandes_sang'
      AND column_name = 'expires_at'
  ) THEN
    RAISE NOTICE 'Mise à jour DEFAULT expires_at → 72h';
    ALTER TABLE public.demandes_sang
      ALTER COLUMN expires_at SET DEFAULT now() + INTERVAL '72 hours';
    RAISE NOTICE '✅ DEFAULT expires_at mis à jour : now() + 72h';
  ELSE
    RAISE WARNING 'Colonne expires_at introuvable dans demandes_sang';
  END IF;
END $$;

-- ── §4 — Vérification et création : trigger trg_maj_dernier_don ───────────────
-- R-04/3.4 : Le trigger qui met à jour profils_donneurs.dernier_don_date
-- après INSERT dans historique_dons.
-- NOTE : don-manuel EF fait déjà ce UPDATE explicitement.
-- Ce trigger est donc redondant mais SÉCURISÉ pour le flux valider-token
-- (qui insert dans historique_dons sans update explicite du profil).

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.triggers
    WHERE trigger_name = 'trg_maj_dernier_don'
      AND event_object_schema = 'public'
      AND event_object_table = 'historique_dons'
  ) THEN
    RAISE NOTICE 'Création du trigger trg_maj_dernier_don...';
  ELSE
    RAISE NOTICE '✅ trigger trg_maj_dernier_don existe déjà.';
  END IF;
END $$;

-- Créer la fonction trigger si elle n'existe pas
CREATE OR REPLACE FUNCTION public.fn_maj_dernier_don_date()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Met à jour dernier_don_date dans profils_donneurs après un nouveau don
  UPDATE public.profils_donneurs
  SET dernier_don_date = NEW.date_don,
      updated_at = now()
  WHERE user_id = NEW.donneur_id
    AND (dernier_don_date IS NULL OR NEW.date_don > dernier_don_date);

  RETURN NEW;
END;
$$;

-- Créer le trigger si absent
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.triggers
    WHERE trigger_name = 'trg_maj_dernier_don'
      AND event_object_schema = 'public'
      AND event_object_table = 'historique_dons'
  ) THEN
    CREATE TRIGGER trg_maj_dernier_don
      AFTER INSERT ON public.historique_dons
      FOR EACH ROW
      EXECUTE FUNCTION public.fn_maj_dernier_don_date();
    RAISE NOTICE '✅ Trigger trg_maj_dernier_don créé.';
  END IF;
END $$;

-- ── §5 — Anti-spam demandes : contrainte backend (R-06/2.5.5) ─────────────────
-- Ajoute une FUNCTION + TRIGGER qui empêche > 3 demandes actives par auteur.
-- (Le guard Flutter seul n'est pas suffisant si API appelée directement.)

CREATE OR REPLACE FUNCTION public.fn_verifier_limite_demandes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  nb_actives INTEGER;
BEGIN
  SELECT COUNT(*) INTO nb_actives
  FROM public.demandes_sang
  WHERE auteur_id = NEW.auteur_id
    AND statut = 'active'
    AND expires_at > now();

  IF nb_actives >= 3 THEN
    RAISE EXCEPTION 'Limite atteinte : vous ne pouvez pas avoir plus de 3 demandes actives simultanément.';
  END IF;

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.triggers
    WHERE trigger_name = 'trg_verifier_limite_demandes'
      AND event_object_schema = 'public'
      AND event_object_table = 'demandes_sang'
  ) THEN
    CREATE TRIGGER trg_verifier_limite_demandes
      BEFORE INSERT ON public.demandes_sang
      FOR EACH ROW
      EXECUTE FUNCTION public.fn_verifier_limite_demandes();
    RAISE NOTICE '✅ Trigger trg_verifier_limite_demandes créé (anti-spam 3 demandes).';
  ELSE
    RAISE NOTICE '✅ Trigger trg_verifier_limite_demandes existe déjà.';
  END IF;
END $$;

-- ── §6 — Index manquants (3.3) ────────────────────────────────────────────────

-- Index pour le matching (profils_donneurs)
CREATE INDEX IF NOT EXISTS idx_profils_matching
  ON public.profils_donneurs(ville_id, disponible, groupe_sanguin)
  WHERE disponible = true;

-- Index pour les demandes actives par ville
CREATE INDEX IF NOT EXISTS idx_demandes_actives_ville
  ON public.demandes_sang(ville_id, statut, expires_at)
  WHERE statut = 'active';

-- Index pour les notifications par user
CREATE INDEX IF NOT EXISTS idx_notifications_user_date
  ON public.notifications_envoyees(user_id, created_at DESC);

-- Index pour les tokens QR (lookup par token + validité)
CREATE INDEX IF NOT EXISTS idx_qr_tokens_valid
  ON public.dons_qr_tokens(token, expires_at)
  WHERE used_at IS NULL;

DO $$ BEGIN RAISE NOTICE '✅ Index créés/confirmés.'; END $$;

-- ── §7 — Vérification RLS sur les tables core ─────────────────────────────────

DO $$
DECLARE
  tables TEXT[] := ARRAY['profils_donneurs', 'demandes_sang', 'dons_qr_tokens',
                          'historique_dons', 'notifications_envoyees', 'reponses_donneurs'];
  t TEXT;
  has_rls BOOLEAN;
BEGIN
  FOREACH t IN ARRAY tables LOOP
    SELECT relrowsecurity INTO has_rls
    FROM pg_class
    WHERE relname = t AND relnamespace = 'public'::regnamespace;

    IF has_rls IS NULL THEN
      RAISE WARNING 'TABLE INTROUVABLE : public.%', t;
    ELSIF NOT has_rls THEN
      RAISE WARNING '⚠️ RLS DÉSACTIVÉ sur public.% — activer avec : ALTER TABLE public.% ENABLE ROW LEVEL SECURITY;', t, t;
    ELSE
      RAISE NOTICE '✅ RLS actif sur public.%', t;
    END IF;
  END LOOP;
END $$;

-- ── §8 — Vérification des enums PostgreSQL utilisés par Flutter ───────────────

DO $$
BEGIN
  -- groupe_sanguin
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'groupe_sanguin_enum' AND typnamespace = 'public'::regnamespace) THEN
    RAISE NOTICE '✅ enum groupe_sanguin_enum existe.';
  ELSE
    RAISE WARNING '⚠️ enum groupe_sanguin_enum introuvable — groupe_sanguin est peut-être TEXT.';
  END IF;

  -- Vérifier source_don
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'source_don_enum') THEN
    RAISE NOTICE '✅ enum source_don_enum existe.';
  ELSE
    RAISE NOTICE 'source_don est probablement TEXT — acceptable si colonne text avec check constraint.';
  END IF;
END $$;

-- ── §9 — Résumé des tables et colonnes critiques ──────────────────────────────

SELECT
  table_name,
  column_name,
  data_type,
  column_default,
  is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('profils_donneurs', 'demandes_sang', 'identites',
                     'historique_dons', 'dons_qr_tokens', 'notifications_envoyees')
ORDER BY table_name, ordinal_position;

-- ── §10 — Liste des triggers actifs ──────────────────────────────────────────

SELECT
  trigger_name,
  event_object_schema || '.' || event_object_table AS table_cible,
  event_manipulation AS evenement,
  action_timing AS timing
FROM information_schema.triggers
WHERE trigger_schema IN ('public', 'extensions')
  OR event_object_schema IN ('public', 'auth')
ORDER BY event_object_table, trigger_name;

-- ── §11 — Liste des cron jobs actifs ─────────────────────────────────────────

SELECT jobname, schedule, command, active
FROM cron.job
ORDER BY jobname;

-- =============================================================================
-- FIN DU SCRIPT mission-e.sql
-- À exécuter dans Supabase Dashboard → SQL Editor → Run
-- Vérifier les NOTICE, WARNING et résultats des SELECT en bas.
-- =============================================================================
