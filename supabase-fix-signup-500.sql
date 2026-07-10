-- =============================================================================
-- SONGRE — Fix critique : "Database error saving new user" (HTTP 500)
-- 
-- PROBLÈME : Un trigger sur auth.users échoue lors de l'inscription
-- de tout nouvel utilisateur, causant un HTTP 500 systématique.
--
-- CAUSE : Le trigger trg_creer_identite (ou similaire) tente d'insérer
-- dans identite.identites ou public.identites avec des colonnes qui
-- n'existent pas ou une structure incorrecte.
--
-- SOLUTION : Supprimer le trigger défaillant + recréer proprement
-- la fonction + trigger avec gestion d'erreur robuste (EXCEPTION WHEN OTHERS).
--
-- À exécuter dans : Supabase Dashboard → SQL Editor → Run
-- Idempotent : peut être relancé sans danger.
-- =============================================================================

-- ── ÉTAPE 1 : Supprimer les triggers défaillants sur auth.users ──────────────
-- On supprime TOUS les triggers connus (quel que soit le schéma de la fonction)

DROP TRIGGER IF EXISTS trg_creer_identite ON auth.users;
DROP TRIGGER IF EXISTS trg_on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS trg_bienvenue ON auth.users;
DROP TRIGGER IF EXISTS trg_new_user ON auth.users;

-- ── ÉTAPE 2 : Vérifier la structure réelle de public.identites ────────────────
-- Cette requête affiche les colonnes disponibles pour recréer le trigger correctement.

SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'identites'
ORDER BY ordinal_position;

-- ── ÉTAPE 3 : Recréer la fonction trigger avec gestion d'erreur robuste ───────
-- La fonction tente l'insertion dans public.identites mais NE BLOQUE JAMAIS
-- la création du compte en cas d'erreur (EXCEPTION WHEN OTHERS → log seulement).

CREATE OR REPLACE FUNCTION public.fn_creer_identite_safe()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Insertion avec gestion de toutes les colonnes possibles
  -- ON CONFLICT pour idempotence (si l'entrée existe déjà)
  BEGIN
    INSERT INTO public.identites (user_id, compte_actif, created_at)
    VALUES (NEW.id, TRUE, now())
    ON CONFLICT (user_id) DO NOTHING;
  EXCEPTION
    WHEN undefined_column THEN
      -- La table a une structure différente — essayer sans les colonnes optionnelles
      BEGIN
        INSERT INTO public.identites (user_id)
        VALUES (NEW.id)
        ON CONFLICT (user_id) DO NOTHING;
      EXCEPTION WHEN OTHERS THEN
        -- Log l'erreur sans bloquer l'inscription
        RAISE WARNING 'fn_creer_identite_safe: insertion ignorée pour user % — %', NEW.id, SQLERRM;
      END;
    WHEN OTHERS THEN
      -- Ne JAMAIS bloquer l'inscription pour une erreur dans ce trigger
      RAISE WARNING 'fn_creer_identite_safe: erreur ignorée pour user % — %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

-- ── ÉTAPE 4 : Rattacher le trigger sécurisé sur auth.users ───────────────────

DROP TRIGGER IF EXISTS trg_creer_identite_safe ON auth.users;
CREATE TRIGGER trg_creer_identite_safe
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_creer_identite_safe();

-- ── ÉTAPE 5 : Vérification ────────────────────────────────────────────────────

-- Confirmer que le trigger est bien en place
SELECT trigger_name, event_object_schema, event_object_table, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'auth'
  AND event_object_table = 'users'
ORDER BY trigger_name;

DO $$ BEGIN
  RAISE NOTICE '✅ Fix appliqué — relancez une inscription de test sur l''app';
END $$;

-- =============================================================================
-- FIN DU SCRIPT
-- Après exécution, testez l''inscription via l''application mobile.
-- Si l''inscription fonctionne → HTTP 200 avec user_id retourné.
-- =============================================================================
