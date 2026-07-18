-- =============================================================================
-- MODIFICATIONS_MANUELLES_CARTE.sql
-- Projet : SONGRE — Application de don de sang
-- Mission : E — Carte des structures sanitaires (bascule dynamique A/B)
-- Date    : 2026-07-19
--
-- INSTRUCTIONS :
--   Copier-coller ce fichier dans le SQL Editor du Dashboard Supabase.
--   URL : https://app.supabase.com → votre projet → SQL Editor → New query
--   Exécuter dans l'ordre des sections numérotées.
--
-- PRÉREQUIS :
--   - Les tables public.villes et public.structures_sanitaires existent déjà.
--   - L'extension PostGIS n'est PAS requise (coordonnées stockées en FLOAT8).
-- =============================================================================


-- =============================================================================
-- SECTION 1 : Ajout des coordonnées géographiques à la table public.villes
-- =============================================================================
-- Ces colonnes permettent de centrer la carte Option A sur la ville du profil
-- de l'utilisateur quand la permission géolocalisation n'est pas accordée.
-- Elles sont NULLABLES : une ville sans coordonnées est toujours valide.
-- La carte tombera alors sur les coordonnées par défaut (Ouagadougou).
-- =============================================================================

ALTER TABLE public.villes
  ADD COLUMN IF NOT EXISTS latitude  DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION;

COMMENT ON COLUMN public.villes.latitude  IS
  'Latitude géographique de la ville (WGS84). Null si non renseignée.';
COMMENT ON COLUMN public.villes.longitude IS
  'Longitude géographique de la ville (WGS84). Null si non renseignée.';


-- =============================================================================
-- SECTION 2 : Coordonnées de référence pour les villes du Burkina Faso
-- =============================================================================
-- Ces valeurs sont des coordonnées de référence pour le centre des villes.
-- Elles permettent d'avoir une carte fonctionnelle dès la mise en production,
-- avant que les structures individuelles soient géolocalisées.
--
-- Source : coordonnées approximatives du centre géographique de chaque ville.
-- Mise à jour : adapter selon la liste réelle dans votre base.
-- =============================================================================

-- Mettre à jour uniquement les villes dont le nom correspond exactement.
-- Les villes non listées ici conserveront latitude/longitude = NULL.

UPDATE public.villes SET latitude = 12.3647, longitude = -1.5337
  WHERE nom ILIKE '%ouagadougou%';

UPDATE public.villes SET latitude = 11.1777, longitude = -4.2979
  WHERE nom ILIKE '%bobo%dioulasso%';

UPDATE public.villes SET latitude = 11.8886, longitude = -1.5342
  WHERE nom ILIKE '%koudougou%';

UPDATE public.villes SET latitude = 14.3388, longitude = -0.3476
  WHERE nom ILIKE '%ouahigouya%';

UPDATE public.villes SET latitude = 11.8661, longitude = -4.2969
  WHERE nom ILIKE '%banfora%';

UPDATE public.villes SET latitude = 12.3590, longitude = -1.0590
  WHERE nom ILIKE '%koupéla%' OR nom ILIKE '%koupela%';

UPDATE public.villes SET latitude = 13.0702, longitude = -2.2969
  WHERE nom ILIKE '%dédougou%' OR nom ILIKE '%dedougou%';

UPDATE public.villes SET latitude = 14.0000, longitude = -0.0500
  WHERE nom ILIKE '%dori%';

UPDATE public.villes SET latitude = 11.1612, longitude = -1.4740
  WHERE nom ILIKE '%po%';

UPDATE public.villes SET latitude = 10.4044, longitude = -2.9219
  WHERE nom ILIKE '%diébougou%' OR nom ILIKE '%diebougou%';

UPDATE public.villes SET latitude = 11.7427, longitude = -2.8994
  WHERE nom ILIKE '%gaoua%';

UPDATE public.villes SET latitude = 12.8622, longitude = -2.3996
  WHERE nom ILIKE '%kaya%';

UPDATE public.villes SET latitude = 13.2875, longitude = -0.8461
  WHERE nom ILIKE '%kongoussi%';

UPDATE public.villes SET latitude = 12.7524, longitude = -0.7094
  WHERE nom ILIKE '%ziniaré%' OR nom ILIKE '%ziniare%';

UPDATE public.villes SET latitude = 12.8950, longitude = -1.7500
  WHERE nom ILIKE '%yako%';


-- =============================================================================
-- SECTION 3 : Ajout des coordonnées géographiques à public.structures_sanitaires
-- =============================================================================
-- Ces colonnes permettent de placer les marqueurs sur la carte Option A.
-- Une structure sans coordonnées n'apparaît simplement pas sur la carte
-- (elle n'est pas affichée, sans erreur).
-- =============================================================================

ALTER TABLE public.structures_sanitaires
  ADD COLUMN IF NOT EXISTS latitude  DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION;

COMMENT ON COLUMN public.structures_sanitaires.latitude  IS
  'Latitude géographique de la structure (WGS84). Null si non renseignée.';
COMMENT ON COLUMN public.structures_sanitaires.longitude IS
  'Longitude géographique de la structure (WGS84). Null si non renseignée.';


-- =============================================================================
-- SECTION 4 : Mise à jour des coordonnées des structures sanitaires
-- =============================================================================
-- À renseigner manuellement ou via Google Maps / OpenStreetMap.
-- Méthode rapide : dans Google Maps, faire un clic droit sur l'emplacement
-- de la structure → "Copier les coordonnées" → coller ici.
--
-- Exemple de mise à jour pour un CHR de Ouagadougou :
--   UPDATE public.structures_sanitaires
--     SET latitude = 12.3652, longitude = -1.5390
--     WHERE nom ILIKE '%CHR Yalgado%';
--
-- NOTE : Cette section est intentionnellement laissée vide.
-- Les coordonnées des structures doivent être saisies manuellement
-- par le porteur du projet, car elles nécessitent une vérification
-- terrain pour chaque établissement.
--
-- IMPACT SI NON RENSEIGNÉ : la carte Option A affiche un message
-- "Aucune structure géolocalisée disponible" — l'app reste fonctionnelle.
-- =============================================================================

-- Décommenter et adapter cet exemple pour chaque structure :
-- UPDATE public.structures_sanitaires
--   SET latitude = 12.3652, longitude = -1.5390
--   WHERE id = <id_de_la_structure>;

-- Alternative : mettre à jour par nom (vérifier l'unicité du nom avant) :
-- UPDATE public.structures_sanitaires
--   SET latitude = 12.3652, longitude = -1.5390
--   WHERE nom ILIKE '%Yalgado%';


-- =============================================================================
-- SECTION 5 : Création de la table public.app_config (configuration dynamique)
-- =============================================================================
-- Cette table permet de basculer entre Option A (carte intégrée) et Option B
-- (Maps externe) sans recompiler l'application, via le Dashboard Supabase.
--
-- Même principe que la table liens_externes déjà utilisée dans le projet.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.app_config (
  id          SERIAL       PRIMARY KEY,
  cle         TEXT         NOT NULL UNIQUE,
  valeur      TEXT         NOT NULL,
  description TEXT,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.app_config IS
  'Configuration dynamique de l''application lue au démarrage des écrans concernés.
   Modifier la valeur ici pour changer le comportement sans recompiler l''app.';

COMMENT ON COLUMN public.app_config.cle IS
  'Clé de configuration unique (ex: mode_carte).';
COMMENT ON COLUMN public.app_config.valeur IS
  'Valeur associée à la clé (ex: externe | integree).';


-- =============================================================================
-- SECTION 6 : Insertion de la configuration par défaut
-- =============================================================================
-- Valeur par défaut : 'externe' (Option B — ouvre l'app Maps native).
-- Pour activer Option A (carte intégrée flutter_map) :
--   → Changer la valeur en 'integree' dans le Dashboard Supabase.
--   → URL : Table Editor → app_config → modifier la ligne mode_carte
-- =============================================================================

INSERT INTO public.app_config (cle, valeur, description)
VALUES (
  'mode_carte',
  'externe',
  'Mode d''affichage de la carte des structures sanitaires.
   Valeurs possibles :
     externe  → ouvre l''app Maps native du téléphone (Google Maps, etc.)
     integree → affiche une carte flutter_map intégrée dans l''application'
)
ON CONFLICT (cle) DO NOTHING;  -- Ne pas écraser si déjà configurée


-- =============================================================================
-- SECTION 7 : Politique RLS pour app_config (lecture publique authentifiée)
-- =============================================================================
-- Les utilisateurs authentifiés peuvent lire la configuration.
-- Seul le service_role (admin) peut modifier.
-- =============================================================================

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

-- Lecture : tous les utilisateurs authentifiés
DROP POLICY IF EXISTS "app_config_lecture_auth" ON public.app_config;
CREATE POLICY "app_config_lecture_auth"
  ON public.app_config
  FOR SELECT
  TO authenticated
  USING (true);

-- Écriture : service_role uniquement (admin Supabase)
-- Aucune politique d'écriture pour authenticated → lecture seule depuis l'app


-- =============================================================================
-- SECTION 8 : Index utiles
-- =============================================================================

-- Index sur la clé de app_config (déjà unique mais on s'assure de l'index)
CREATE INDEX IF NOT EXISTS idx_app_config_cle ON public.app_config (cle);

-- Index partiels sur les structures géolocalisées (performance requêtes carte)
CREATE INDEX IF NOT EXISTS idx_structures_geoloc
  ON public.structures_sanitaires (ville_id)
  WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND active = true;

CREATE INDEX IF NOT EXISTS idx_villes_geoloc
  ON public.villes (id)
  WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND active = true;


-- =============================================================================
-- VÉRIFICATION FINALE
-- =============================================================================
-- Exécuter ces requêtes pour confirmer que les modifications ont été appliquées.
-- =============================================================================

-- Vérifier les colonnes de public.villes
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'villes'
  AND column_name IN ('latitude', 'longitude')
ORDER BY column_name;
-- Attendu : 2 lignes, data_type = 'double precision', is_nullable = 'YES'

-- Vérifier les colonnes de public.structures_sanitaires
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'structures_sanitaires'
  AND column_name IN ('latitude', 'longitude')
ORDER BY column_name;
-- Attendu : 2 lignes, data_type = 'double precision', is_nullable = 'YES'

-- Vérifier la table app_config et sa valeur par défaut
SELECT cle, valeur, description FROM public.app_config WHERE cle = 'mode_carte';
-- Attendu : 1 ligne avec valeur = 'externe'

-- Vérifier les villes avec coordonnées
SELECT nom, latitude, longitude
FROM public.villes
WHERE latitude IS NOT NULL
ORDER BY nom;
-- Attendu : les villes mises à jour à la section 2

-- =============================================================================
-- FIN DU SCRIPT
-- =============================================================================
