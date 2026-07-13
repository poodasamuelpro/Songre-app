-- =============================================================================
-- Script SQL : migration_expires_at_7jours.sql
-- Application : SONGRE — Don de sang, Burkina Faso
-- Date        : 2026-07-13
-- Auteur      : Généré par agent de développement SONGRE
-- =============================================================================
--
-- OBJECTIF :
--   Passer la durée de validité des demandes de sang de 3 jours (72 heures)
--   à 7 jours (168 heures) en modifiant la valeur DEFAULT de la colonne
--   expires_at dans la table public.demandes_sang.
--
-- PÉRIMÈTRE :
--   ✅ Nouvelles demandes créées APRÈS l'exécution de ce script
--   ❌ Demandes existantes en base NON affectées (le DEFAULT ne s'applique
--      qu'aux nouvelles insertions, conformément au comportement PostgreSQL)
--
-- EXÉCUTION :
--   Coller ce script dans l'éditeur SQL du Dashboard Supabase :
--   Dashboard → SQL Editor → New Query → Coller → Run
--   Ou via CLI : psql <connection_string> -f migration_expires_at_7jours.sql
--
-- PRÉREQUIS :
--   - Table public.demandes_sang existante avec colonne expires_at TIMESTAMPTZ
--   - Droits ALTER TABLE sur public.demandes_sang (role postgres ou owner)
--
-- VÉRIFICATION POST-EXÉCUTION :
--   Exécuter le bloc de vérification en bas de ce fichier pour confirmer
--   que le DEFAULT a bien été modifié.
--
-- ROLLBACK (retour à 72 heures si nécessaire) :
--   ALTER TABLE public.demandes_sang
--     ALTER COLUMN expires_at SET DEFAULT now() + interval '72 hours';
-- =============================================================================

-- ── Étape 1 : Modifier le DEFAULT de expires_at ───────────────────────────────

ALTER TABLE public.demandes_sang
  ALTER COLUMN expires_at SET DEFAULT now() + interval '7 days';

-- ── Étape 2 : Vérification immédiate ──────────────────────────────────────────
-- Cette requête doit retourner une ligne avec column_default contenant '7 days'.

SELECT
  column_name,
  column_default,
  data_type
FROM information_schema.columns
WHERE
  table_schema = 'public'
  AND table_name  = 'demandes_sang'
  AND column_name = 'expires_at';

-- ── Résultat attendu après exécution ─────────────────────────────────────────
-- column_name | column_default                                     | data_type
-- expires_at  | (now() + '7 days'::interval)                      | timestamp with time zone
--
-- Si column_default contient encore '72 hours' ou '3 days', le script
-- n'a pas été exécuté correctement — relancer la requête ALTER ci-dessus.
-- =============================================================================
--
-- NOTE FLUTTER (côté application) :
--   En parallèle de ce script SQL, la constante Dart dans lib/models/models.dart
--   doit être mise à jour pour cohérence d'affichage dans l'UI :
--     Avant : const Duration kDureeValiditeDemande = Duration(hours: 72);
--     Après : const Duration kDureeValiditeDemande = Duration(hours: 168);
--   Cette valeur n'est utilisée que pour l'affichage (ex: "Expire dans 7 jours").
--   Elle n'est PAS envoyée en base lors de la création d'une demande.
--   Les deux modifications (SQL + Dart) sont indépendantes et peuvent être
--   appliquées dans n'importe quel ordre.
-- =============================================================================
