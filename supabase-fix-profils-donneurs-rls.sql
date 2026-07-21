-- =============================================================================
-- SONGRE — Fix critique : RLS manquante sur public.profils_donneurs
-- 
-- PROBLÈME CONFIRMÉ PAR AUDIT CODE :
--   supabase-schema-corrections.sql Section 8 créait une policy sur
--   sante.profils_donneurs (MAUVAIS schéma) — jamais appliquée à public.*.
--   supabase-addendum.sql confirme schéma public.* mais N'INCLUT PAS de RLS
--   pour public.profils_donneurs.
--   Résultat : tout POST /rest/v1/profils_donneurs retourne HTTP 403 si
--   RLS est activée (comportement par défaut Supabase) sans policy INSERT.
--
-- CAUSE PRIMAIRE DU BUG poodasamuelpro@gmail.com :
--   INSERT bloqué silencieusement par RLS absente.
--   sauvegarderProfil() ignore le bool false retourné → état local validé.
--   Reconnexion suivante : lireProfil() → liste vide → redirect /completer-profil.
--
-- INSTANCE  : https://ptomqwucvveuflfnyczo.supabase.co
-- SCHÉMA    : public.* (schéma réel — PAS sante.* ni identite.*)
-- DATE      : 2026-07-21
-- EXÉCUTION : Supabase Dashboard → SQL Editor → Run
-- IDEMPOTENT: Oui — utilise DO $$ IF NOT EXISTS $$ pour chaque policy
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- §0 — DIAGNOSTIC : état actuel de la table avant intervention
-- ─────────────────────────────────────────────────────────────────────────────
-- Ces SELECT ne modifient rien — utiles pour confirmer l'état avant exécution.

-- 0.1 Vérifier si RLS est activée sur public.profils_donneurs
SELECT
  relname          AS table_name,
  relrowsecurity   AS rls_enabled,
  relforcerowsecurity AS rls_forced
FROM pg_class
WHERE relname = 'profils_donneurs'
  AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

-- 0.2 Lister toutes les policies existantes sur public.profils_donneurs
SELECT
  policyname,
  roles,
  cmd,
  qual,
  with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename  = 'profils_donneurs'
ORDER BY cmd, policyname;

-- 0.3 Confirmer l'absence du profil pour l'utilisateur de test
-- SELECT * FROM public.profils_donneurs
-- WHERE user_id = '4d75c1a9-258d-4d79-a80d-61d3925a491f';
-- → Doit retourner 0 lignes avant le correctif côté Flutter

-- ─────────────────────────────────────────────────────────────────────────────
-- §1 — ACTIVER RLS (si pas encore activée)
-- ─────────────────────────────────────────────────────────────────────────────
-- Supabase active RLS par défaut sur les nouvelles tables, mais on s'assure
-- explicitement que c'est le cas pour public.profils_donneurs.

ALTER TABLE public.profils_donneurs ENABLE ROW LEVEL SECURITY;

-- ─────────────────────────────────────────────────────────────────────────────
-- §2 — POLICY SELECT : un utilisateur authentifié lit uniquement son propre profil
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'profils_donneurs'
      AND policyname = 'profil_select_proprietaire'
  ) THEN
    CREATE POLICY "profil_select_proprietaire"
      ON public.profils_donneurs
      FOR SELECT
      TO authenticated
      USING (auth.uid() = user_id);

    RAISE NOTICE '✅ Policy SELECT créée : profil_select_proprietaire';
  ELSE
    RAISE NOTICE 'ℹ️  Policy SELECT déjà présente : profil_select_proprietaire';
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- §3 — POLICY INSERT : un utilisateur authentifié crée uniquement son propre profil
-- ─────────────────────────────────────────────────────────────────────────────
-- C'est LA POLICY MANQUANTE qui causait le bug (HTTP 403 sur POST).
-- WITH CHECK (auth.uid() = user_id) garantit qu'un utilisateur ne peut
-- pas créer un profil avec l'UUID d'un autre utilisateur.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'profils_donneurs'
      AND policyname = 'profil_insert_proprietaire'
  ) THEN
    CREATE POLICY "profil_insert_proprietaire"
      ON public.profils_donneurs
      FOR INSERT
      TO authenticated
      WITH CHECK (auth.uid() = user_id);

    RAISE NOTICE '✅ Policy INSERT créée : profil_insert_proprietaire (LA POLICY MANQUANTE)';
  ELSE
    RAISE NOTICE 'ℹ️  Policy INSERT déjà présente : profil_insert_proprietaire';
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- §4 — POLICY UPDATE : un utilisateur authentifié modifie uniquement son propre profil
-- ─────────────────────────────────────────────────────────────────────────────
-- Requise pour PATCH /rest/v1/profils_donneurs?user_id=eq.$userId
-- (mettreAJourDisponibilite, sauvegarderProfil en mode upsert).

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'profils_donneurs'
      AND policyname = 'profil_update_proprietaire'
  ) THEN
    CREATE POLICY "profil_update_proprietaire"
      ON public.profils_donneurs
      FOR UPDATE
      TO authenticated
      USING     (auth.uid() = user_id)
      WITH CHECK (auth.uid() = user_id);

    RAISE NOTICE '✅ Policy UPDATE créée : profil_update_proprietaire';
  ELSE
    RAISE NOTICE 'ℹ️  Policy UPDATE déjà présente : profil_update_proprietaire';
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- §5 — POLICY SELECT MATCHING : les Edge Functions et le matching
--      doivent pouvoir lire les profils disponibles des donneurs
--      (pour matcher-et-notifier, retour-eligibilite-cron, etc.)
-- ─────────────────────────────────────────────────────────────────────────────
-- NOTE : Les Edge Functions utilisent la service_role key qui bypasse RLS.
-- Cette policy est donc uniquement pour les appels depuis Flutter avec JWT
-- utilisateur (cas des futures fonctionnalités de consultation de profil public).
-- Pour l'instant, l'app Flutter lit uniquement son propre profil → §2 suffit.
-- Décommenter uniquement si une fonctionnalité requiert la lecture des profils
-- d'autres utilisateurs depuis le client Flutter.
--
-- DO $$
-- BEGIN
--   IF NOT EXISTS (
--     SELECT 1 FROM pg_policies
--     WHERE schemaname = 'public'
--       AND tablename  = 'profils_donneurs'
--       AND policyname = 'profil_select_disponibles'
--   ) THEN
--     CREATE POLICY "profil_select_disponibles"
--       ON public.profils_donneurs
--       FOR SELECT
--       TO authenticated
--       USING (disponible = true);
--     RAISE NOTICE '✅ Policy SELECT disponibles créée (optionnelle)';
--   END IF;
-- END;
-- $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- §6 — VÉRIFICATION FINALE : confirmer les 3 policies en place
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  policyname,
  roles,
  cmd,
  qual        AS condition_using,
  with_check  AS condition_with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename  = 'profils_donneurs'
ORDER BY cmd, policyname;

-- Résultat attendu (3 lignes minimum) :
-- ┌─────────────────────────────┬────────────────────┬────────┬──────────────────────────┬──────────────────────────┐
-- │ policyname                  │ roles              │ cmd    │ condition_using          │ condition_with_check     │
-- ├─────────────────────────────┼────────────────────┼────────┼──────────────────────────┼──────────────────────────┤
-- │ profil_insert_proprietaire  │ {authenticated}    │ INSERT │ (null)                   │ (auth.uid() = user_id)   │
-- │ profil_select_proprietaire  │ {authenticated}    │ SELECT │ (auth.uid() = user_id)   │ (null)                   │
-- │ profil_update_proprietaire  │ {authenticated}    │ UPDATE │ (auth.uid() = user_id)   │ (auth.uid() = user_id)   │
-- └─────────────────────────────┴────────────────────┴────────┴──────────────────────────┴──────────────────────────┘

-- ─────────────────────────────────────────────────────────────────────────────
-- §7 — TEST DE VALIDATION (optionnel — à exécuter séparément)
-- ─────────────────────────────────────────────────────────────────────────────
-- Après exécution de ce script, tester via l'app Flutter :
-- 1. Créer un nouveau compte de test
-- 2. Compléter le formulaire de profil
-- 3. Vérifier en DB : SELECT * FROM public.profils_donneurs WHERE user_id = '<uuid>';
--    → Doit retourner 1 ligne
-- 4. Se déconnecter puis se reconnecter
-- 5. Vérifier que l'app navigue vers /home (pas /completer-profil)

-- ─────────────────────────────────────────────────────────────────────────────
-- §8 — MIGRATION DE L'UTILISATEUR EXISTANT (poodasamuelpro@gmail.com)
-- ─────────────────────────────────────────────────────────────────────────────
-- L'utilisateur 4d75c1a9-258d-4d79-a80d-61d3925a491f n'a pas de ligne dans
-- public.profils_donneurs. Deux options :
--
-- OPTION A (recommandée) : L'utilisateur soumet à nouveau le formulaire.
--   Avec le correctif RLS en place + correctif Flutter (sauvegarderProfil
--   retourne bool + SnackBar erreur), l'upsert fonctionnera correctement.
--   Le GoRouter redirigera vers /completer-profil car profil = null,
--   l'utilisateur remplit le formulaire → INSERT réussit → /home.
--
-- OPTION B (admin) : Insertion manuelle depuis le Dashboard Supabase.
--   Requiert les données du profil — à utiliser si l'utilisateur ne peut pas
--   se reconnecter ou si le formulaire est inaccessible.
--
-- VÉRIFICATION PRÉALABLE :
SELECT
  u.id         AS user_id,
  u.email,
  u.created_at AS inscription_at,
  p.user_id    AS profil_user_id
FROM auth.users u
LEFT JOIN public.profils_donneurs p ON p.user_id = u.id
WHERE u.id = '4d75c1a9-258d-4d79-a80d-61d3925a491f';
-- → user_id non null, profil_user_id NULL → confirme l'absence du profil

-- =============================================================================
-- FIN DU SCRIPT supabase-fix-profils-donneurs-rls.sql
-- Après exécution : appliquer également les corrections Flutter dans
-- app_state.dart, supabase_service.dart et login_screen.dart.
-- =============================================================================
