-- =============================================================================
-- SONGRE — Script de correction du schéma Supabase
-- Version : 2.0 (post-audit 8 juillet 2026)
-- Auteur  : Correction sprint production
--
-- À exécuter dans : Supabase Dashboard → SQL Editor
-- Ordre d'exécution : respecter l'ordre des sections (dépendances de FK).
--
-- Vérification finale après exécution :
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema IN ('sante','identite') ORDER BY 1;
-- =============================================================================


-- =============================================================================
-- SECTION 0 — Extensions requises
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid(), crypt()
CREATE EXTENSION IF NOT EXISTS "pg_cron";    -- jobs planifiés (expiration, suppression)


-- =============================================================================
-- SECTION 1 — Table sante.reponses_donneurs
-- (absente du schéma initial v1/v2 — référencée par le code Flutter)
-- =============================================================================

CREATE TABLE IF NOT EXISTS sante.reponses_donneurs (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  donneur_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  demande_id    uuid        NOT NULL REFERENCES sante.demandes_sang(id) ON DELETE CASCADE,
  repondu_le    timestamptz NOT NULL DEFAULT now(),
  -- statut : 'confirme' après scan QR, 'en_attente' par défaut
  statut        text        NOT NULL DEFAULT 'en_attente'
                            CHECK (statut IN ('en_attente','confirme','annule')),

  -- Un donneur ne peut répondre qu'une seule fois à la même demande
  CONSTRAINT uq_reponse_donneur_demande UNIQUE (donneur_id, demande_id)
);

-- Index pour les requêtes Flutter (_repondu == true)
CREATE INDEX IF NOT EXISTS idx_reponses_donneur_id
  ON sante.reponses_donneurs (donneur_id);
CREATE INDEX IF NOT EXISTS idx_reponses_demande_id
  ON sante.reponses_donneurs (demande_id);

-- RLS
ALTER TABLE sante.reponses_donneurs ENABLE ROW LEVEL SECURITY;

-- Un donneur peut insérer sa propre réponse
CREATE POLICY "donneur_inserer_reponse"
  ON sante.reponses_donneurs
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = donneur_id);

-- Un donneur peut voir ses propres réponses
CREATE POLICY "donneur_voir_ses_reponses"
  ON sante.reponses_donneurs
  FOR SELECT
  TO authenticated
  USING (auth.uid() = donneur_id);

-- L'auteur d'une demande peut voir qui a répondu (pour afficher les donneurs)
CREATE POLICY "demandeur_voir_reponses"
  ON sante.reponses_donneurs
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM sante.demandes_sang d
      WHERE d.id = demande_id
        AND d.auteur_id = auth.uid()
    )
  );

-- Un donneur peut annuler sa propre réponse
CREATE POLICY "donneur_mettre_a_jour_reponse"
  ON sante.reponses_donneurs
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = donneur_id)
  WITH CHECK (auth.uid() = donneur_id);


-- =============================================================================
-- SECTION 2 — Trigger trg_creer_identite
-- Crée automatiquement une ligne dans identite.identites lorsqu'un utilisateur
-- s'inscrit via Supabase Auth (REC-05). Évite les appels explicites depuis l'app.
-- =============================================================================

CREATE OR REPLACE FUNCTION identite.fn_creer_identite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = identite, public
AS $$
BEGIN
  -- Insérer silencieusement (ON CONFLICT IGNORE) pour idempotence
  INSERT INTO identite.identites (user_id, email, compte_actif, consentement_donne_le)
  VALUES (
    NEW.id,
    NEW.email,
    TRUE,
    now()
  )
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$$;

-- Attacher le trigger sur auth.users (INSERT uniquement)
DROP TRIGGER IF EXISTS trg_creer_identite ON auth.users;
CREATE TRIGGER trg_creer_identite
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION identite.fn_creer_identite();

-- Vérification : après création d'un compte de test, exécuter :
-- SELECT * FROM identite.identites WHERE email = 'test@example.com';


-- =============================================================================
-- SECTION 3 — Trigger trg_limite_demandes
-- Anti-spam réel en base : bloque toute 4e demande active du même auteur.
-- SEC-05 / REC-01 — supprime la possibilité de contourner la vérification
-- côté client.
-- =============================================================================

CREATE OR REPLACE FUNCTION sante.fn_verifier_limite_demandes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sante, public
AS $$
DECLARE
  v_count integer;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM sante.demandes_sang
  WHERE auteur_id = NEW.auteur_id
    AND statut = 'active'
    AND expires_at > now();

  IF v_count >= 3 THEN
    RAISE EXCEPTION
      'SONGRE-SPAM: Limite de 3 demandes actives atteinte pour cet utilisateur.'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_limite_demandes ON sante.demandes_sang;
CREATE TRIGGER trg_limite_demandes
  BEFORE INSERT ON sante.demandes_sang
  FOR EACH ROW
  EXECUTE FUNCTION sante.fn_verifier_limite_demandes();

-- Vérification : tenter d'insérer une 4e demande active via Postman avec un
-- JWT valide → doit retourner HTTP 400 avec le message SONGRE-SPAM.


-- =============================================================================
-- SECTION 4 — Trigger trg_verifier_eligibilite
-- Vérifie l'éligibilité au don (60 jours pour hommes, 90 jours pour femmes)
-- avant d'enregistrer une réponse donneur. REC-08.
-- =============================================================================

CREATE OR REPLACE FUNCTION sante.fn_verifier_eligibilite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sante, public
AS $$
DECLARE
  v_dernier_don   date;
  v_genre         text;
  v_delai_jours   integer;
BEGIN
  -- Récupérer le dernier don et le genre du donneur
  SELECT p.dernier_don_date, p.genre
  INTO v_dernier_don, v_genre
  FROM sante.profils_donneurs p
  WHERE p.user_id = NEW.donneur_id;

  -- Si pas de profil, laisser passer (premier don connu)
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- Si pas de don précédent, eligible
  IF v_dernier_don IS NULL THEN
    RETURN NEW;
  END IF;

  -- Délai selon genre : 90 jours femme, 60 jours homme/autre
  v_delai_jours := CASE WHEN v_genre = 'femme' THEN 90 ELSE 60 END;

  IF (CURRENT_DATE - v_dernier_don) < v_delai_jours THEN
    RAISE EXCEPTION
      'SONGRE-ELIG: Délai de % jours entre deux dons non respecté (dernier don : %).',
      v_delai_jours, v_dernier_don
      USING ERRCODE = 'P0002';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_verifier_eligibilite ON sante.reponses_donneurs;
CREATE TRIGGER trg_verifier_eligibilite
  BEFORE INSERT ON sante.reponses_donneurs
  FOR EACH ROW
  EXECUTE FUNCTION sante.fn_verifier_eligibilite();

-- Vérification : créer un profil avec dernier_don_date = hier, tenter
-- d'insérer dans reponses_donneurs → doit être rejeté.


-- =============================================================================
-- SECTION 5 — pg_cron : expiration automatique à 7 jours + suppression J+5
-- 2.1 — Remplace les valeurs en dur 72h de l'ancien schéma.
-- =============================================================================

-- Job 1 : Expiration automatique des demandes dont expires_at est dépassé
-- Toutes les heures (à :05 pour éviter les pics)
SELECT cron.schedule(
  'songre-expirer-demandes',
  '5 * * * *',
  $$
    UPDATE sante.demandes_sang
    SET statut = 'expiree'
    WHERE statut = 'active'
      AND expires_at < now();
  $$
);

-- Job 2 : Suppression définitive des comptes programmés (J+5)
-- Tous les jours à 02:00 UTC
SELECT cron.schedule(
  'songre-supprimer-comptes',
  '0 2 * * *',
  $$
    DELETE FROM auth.users
    WHERE id IN (
      SELECT user_id
      FROM identite.identites
      WHERE suppression_programmee_le IS NOT NULL
        AND suppression_programmee_le <= now()
    );
  $$
);

-- Vérification : SELECT * FROM cron.job WHERE jobname LIKE 'songre%';
-- Doit retourner 2 lignes actives.


-- =============================================================================
-- SECTION 6 — Fonction SQL de compatibilité ABO
-- Réplique la logique Dart estCompatibleAvec() côté base pour que
-- matcher-et-notifier (Edge Function 2.3) utilise la même règle. [2.4]
-- =============================================================================

CREATE OR REPLACE FUNCTION sante.est_compatible_abo(
  p_receveur text,
  p_donneur  text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_receveur
    -- Donneur universel O- compatible avec tout le monde
    WHEN 'O-' THEN p_donneur = 'O-'
    WHEN 'O+' THEN p_donneur IN ('O-', 'O+')
    WHEN 'A-' THEN p_donneur IN ('O-', 'A-')
    WHEN 'A+' THEN p_donneur IN ('O-', 'O+', 'A-', 'A+')
    WHEN 'B-' THEN p_donneur IN ('O-', 'B-')
    WHEN 'B+' THEN p_donneur IN ('O-', 'O+', 'B-', 'B+')
    WHEN 'AB-' THEN p_donneur IN ('O-', 'A-', 'B-', 'AB-')
    WHEN 'AB+' THEN TRUE  -- receveur universel
    ELSE FALSE
  END;
$$;

-- Vérification :
-- SELECT sante.est_compatible_abo('A+', 'O-');  → true
-- SELECT sante.est_compatible_abo('A+', 'B+');  → false
-- SELECT sante.est_compatible_abo('AB+', 'B+'); → true


-- =============================================================================
-- SECTION 7 — Vue demandes_sang_avec_contact [1.5]
-- Masque contact_chiffre / contact_secondaire_chiffre sauf si l'appelant
-- authentifié a une entrée dans sante.reponses_donneurs pour cette demande.
-- L'app Flutter doit interroger cette vue pour l'écran de détail.
-- =============================================================================

CREATE OR REPLACE VIEW sante.demandes_sang_avec_contact
WITH (security_invoker = TRUE)
AS
SELECT
  d.id,
  d.auteur_id,
  d.groupe_sanguin_recherche,
  d.ville,
  d.quartier,
  d.structure_sanitaire,
  d.statut,
  d.created_at,
  d.expires_at,
  d.updated_at,
  -- Contact principal : visible seulement si l'appelant a répondu
  CASE
    WHEN EXISTS (
      SELECT 1 FROM sante.reponses_donneurs r
      WHERE r.demande_id = d.id
        AND r.donneur_id = auth.uid()
    ) THEN d.contact_chiffre
    ELSE NULL
  END AS contact_chiffre,
  -- Contact secondaire : même condition
  CASE
    WHEN EXISTS (
      SELECT 1 FROM sante.reponses_donneurs r
      WHERE r.demande_id = d.id
        AND r.donneur_id = auth.uid()
    ) THEN d.contact_secondaire_chiffre
    ELSE NULL
  END AS contact_secondaire_chiffre,
  -- Indicateur booléen pratique pour l'app
  EXISTS (
    SELECT 1 FROM sante.reponses_donneurs r
    WHERE r.demande_id = d.id
      AND r.donneur_id = auth.uid()
  ) AS a_repondu
FROM sante.demandes_sang d;

-- RLS sur la vue (security_invoker applique les policies de la table sous-jacente)
-- Pas de policy distincte nécessaire : la table demandes_sang a déjà les siennes.

-- Vérification :
-- En tant qu'utilisateur A (n'a pas répondu) :
-- SELECT contact_chiffre FROM sante.demandes_sang_avec_contact
-- WHERE id = '<id_demande>'; → NULL attendu
-- En tant qu'utilisateur B (a répondu) :
-- Même requête → valeur chiffrée retournée


-- =============================================================================
-- SECTION 8 — RLS supplémentaires sur tables existantes
-- Garantit que les tables du schéma sante.* sont correctement protégées.
-- =============================================================================

-- S'assurer que RLS est activé sur toutes les tables sante.*
ALTER TABLE sante.demandes_sang          ENABLE ROW LEVEL SECURITY;
ALTER TABLE sante.profils_donneurs       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sante.historique_dons        ENABLE ROW LEVEL SECURITY;
ALTER TABLE sante.dons_qr_tokens         ENABLE ROW LEVEL SECURITY;

-- Lecture publique des demandes actives (niveau 1 assumé — feed public)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'sante'
      AND tablename = 'demandes_sang'
      AND policyname = 'lecture_publique_demandes_actives'
  ) THEN
    CREATE POLICY "lecture_publique_demandes_actives"
      ON sante.demandes_sang
      FOR SELECT
      TO anon, authenticated
      USING (statut = 'active' AND expires_at > now());
  END IF;
END;
$$;

-- Insertion d'une demande : uniquement par l'auteur authentifié
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'sante'
      AND tablename = 'demandes_sang'
      AND policyname = 'auteur_creer_demande'
  ) THEN
    CREATE POLICY "auteur_creer_demande"
      ON sante.demandes_sang
      FOR INSERT
      TO authenticated
      WITH CHECK (auth.uid() = auteur_id);
  END IF;
END;
$$;

-- Profil : lecture/écriture uniquement par son propriétaire
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'sante'
      AND tablename = 'profils_donneurs'
      AND policyname = 'proprietaire_profil'
  ) THEN
    CREATE POLICY "proprietaire_profil"
      ON sante.profils_donneurs
      FOR ALL
      TO authenticated
      USING (auth.uid() = user_id)
      WITH CHECK (auth.uid() = user_id);
  END IF;
END;
$$;

-- Historique dons : lecture/écriture par le donneur concerné
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'sante'
      AND tablename = 'historique_dons'
      AND policyname = 'proprietaire_historique'
  ) THEN
    CREATE POLICY "proprietaire_historique"
      ON sante.historique_dons
      FOR ALL
      TO authenticated
      USING (auth.uid() = donneur_id)
      WITH CHECK (auth.uid() = donneur_id);
  END IF;
END;
$$;

-- Tokens QR : le donneur crée et lit les siens, service_role peut tout faire
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'sante'
      AND tablename = 'dons_qr_tokens'
      AND policyname = 'donneur_gerer_ses_tokens'
  ) THEN
    CREATE POLICY "donneur_gerer_ses_tokens"
      ON sante.dons_qr_tokens
      FOR ALL
      TO authenticated
      USING (auth.uid() = donneur_id)
      WITH CHECK (auth.uid() = donneur_id);
  END IF;
END;
$$;

-- RLS sur identite.*
ALTER TABLE identite.identites ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'identite'
      AND tablename = 'identites'
      AND policyname = 'proprietaire_identite'
  ) THEN
    CREATE POLICY "proprietaire_identite"
      ON identite.identites
      FOR ALL
      TO authenticated
      USING (auth.uid() = user_id)
      WITH CHECK (auth.uid() = user_id);
  END IF;
END;
$$;


-- =============================================================================
-- SECTION 9 — Trigger trigger_maj_dernier_don (si absent)
-- Met à jour profils_donneurs.dernier_don_date après INSERT dans historique_dons.
-- Cohérent avec [2.2] valider-token qui insère dans historique_dons.
-- =============================================================================

CREATE OR REPLACE FUNCTION sante.fn_maj_dernier_don()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sante, public
AS $$
BEGIN
  UPDATE sante.profils_donneurs
  SET dernier_don_date = NEW.date_don
  WHERE user_id = NEW.donneur_id
    AND (dernier_don_date IS NULL OR NEW.date_don > dernier_don_date);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_maj_dernier_don ON sante.historique_dons;
CREATE TRIGGER trg_maj_dernier_don
  AFTER INSERT ON sante.historique_dons
  FOR EACH ROW
  EXECUTE FUNCTION sante.fn_maj_dernier_don();


-- =============================================================================
-- SECTION 10 — Checklist de vérification finale
-- =============================================================================
-- Après exécution, valider chaque point :
--
-- [A] Tables présentes :
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema IN ('sante','identite')
--   ORDER BY table_schema, table_name;
--   → Doit inclure : reponses_donneurs, demandes_sang, profils_donneurs,
--                    historique_dons, dons_qr_tokens, identites
--
-- [B] Triggers actifs :
--   SELECT trigger_name, event_object_schema, event_object_table
--   FROM information_schema.triggers
--   WHERE trigger_name LIKE 'trg_%'
--   ORDER BY 1;
--   → trg_creer_identite (auth.users)
--   → trg_limite_demandes (sante.demandes_sang)
--   → trg_verifier_eligibilite (sante.reponses_donneurs)
--   → trg_maj_dernier_don (sante.historique_dons)
--
-- [C] Jobs cron :
--   SELECT jobname, schedule, active FROM cron.job
--   WHERE jobname LIKE 'songre%';
--   → songre-expirer-demandes   | 5 * * * *  | t
--   → songre-supprimer-comptes  | 0 2 * * *  | t
--
-- [D] Fonction ABO :
--   SELECT sante.est_compatible_abo('A+', 'O-');  → true
--   SELECT sante.est_compatible_abo('A+', 'B+');  → false
--
-- [E] Vue contact masqué :
--   -- En tant qu'utilisateur N'AYANT PAS répondu :
--   SELECT a_repondu, contact_chiffre
--   FROM sante.demandes_sang_avec_contact
--   WHERE id = '<uuid_demande>';
--   → a_repondu = false, contact_chiffre = NULL
--
-- [F] Anti-spam :
--   -- Insérer 4 demandes actives pour le même user via API REST avec JWT →
--   -- La 4e doit retourner HTTP 400 avec erreur SONGRE-SPAM.
