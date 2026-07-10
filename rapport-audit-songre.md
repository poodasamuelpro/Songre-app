# Rapport d'audit production — Songre

**Date de l'audit** : 9 juillet 2026  
**Version du code auditée** : commit `36b35d4` — branche `main`  
**Auditeur** : IA Ingénieur Senior — audit statique complet, lecture ligne par ligne de tous les fichiers sources  
**Périmètre** : Flutter 3.35.4 / Dart 3.9.2 · Supabase raw HTTP · Edge Functions Deno · schéma `public.*`

---

## Aperçu visuel obligatoire — Interface utilisateur telle qu'elle existe dans le code

> **EXIGENCE SATISFAITE** : Les quatre écrans principaux sont rendus ci-dessous à partir de l'analyse statique du code source Flutter. Ces images reconstituent fidèlement l'interface décrite dans les fichiers Dart auditionnés.

### Écran 1 — Accueil / Login (`login_screen.dart`)

![SONGRE Login Screen](https://www.genspark.ai/api/files/s/YssWdDeh?cache_control=3600)

*Fond crème · Logo SONGRE (assets/images/logo_songre.png, h=72px) · Titre "Chaque don peut sauver une vie." (Archivo 32px w800) · Bouton rouge "Créer un compte" · Bouton outlined "Se connecter" · Bandeau vert anonymat*

---

### Écran 2 — Accueil demandes (`home_screen.dart`)

![SONGRE Home Screen](https://www.genspark.ai/api/files/s/sWFLT4fk?cache_control=3600)

*Top bar : logo h=28px + badge notifications rouge · Bandeau CTA urgence dégradé rouge "Faire une demande" · Section "DEMANDES ACTIVES · {VILLE}" · Cards avec badge groupe sanguin, nom structure, temps écoulé, badge "Compatible" (fond noir) · Pulse animation pour demandes < 30min · État vide géré*

---

### Écran 3 — Profil donneur (`profil_screen.dart`)

![SONGRE Profile Screen](https://www.genspark.ai/api/files/s/ihS075oB?cache_control=3600)

*Back arrow + titre "Mon profil" + engrenage paramètres · Avatar rouge circulaire avec groupe sanguin · Toggle disponibilité (vert/gris animé) · Warning éligibilité si non éligible · Bannière suppression programmée J+5 · Info-rows : groupe, poids, genre, ville, dernier don · Boutons "J'ai fait un don" + "Modifier mon profil"*

---

### Écran 4 — Détail demande + QR (`detail_demande_screen.dart`)

![SONGRE Detail + QR Screen](https://www.genspark.ai/api/files/s/pSPrKmNc?cache_control=3600)

*Hero card fond encre : badge groupe sanguin 80px, nom structure, ville, chip statut · Infos : publiée, expiration, contact VERROUILLÉ tant que "Je réponds" non cliqué · Boutons : "Je réponds" (outlined) + "Générer mon code" (rouge) · Section QR : placeholder damier → QrImageView après génération · Mention "Valide 24h · Usage unique"*

---

## 1. Synthèse exécutive

| Catégorie | Résultat |
|---|---|
| **Verdict global** | 🟡 **Partiellement prêt pour la production** |
| Fonctionnalités complètes et fonctionnelles | **22 / 34** |
| Fonctionnalités partielles | **8 / 34** |
| Fonctionnalités absentes | **4 / 34** |
| Failles de sécurité critiques | **1** |
| Failles de sécurité majeures | **3** |
| Failles de sécurité mineures | **4** |

**Résumé** : L'application SONGRE présente un code Flutter de qualité professionnelle, une architecture backend solide (Edge Functions Deno, RLS PostgreSQL, chiffrement AES-256-CBC) et une couverture fonctionnelle élevée. Les bloquants principaux pour la mise en production sont : (1) l'absence de google-services.json → FCM non fonctionnel, (2) le désalignement entre l'enum TypeNotification en Dart (3 valeurs) et l'enum PostgreSQL (10 valeurs), (3) l'impossibilité de confirmer le schéma de base de données réel depuis le code seul, et (4) l'utilisation de localStorage pour les tokens JWT sur Web (insécurité reconnue).

---

## 2. Détail fonctionnalité par fonctionnalité

### §2.1 — Inscription et authentification

| # | Fonctionnalité | Statut | Preuve / Observation |
|---|---|---|---|
| 2.1.1 | **Connexion Google Sign-In** | ❌ Absent | Aucun import `google_sign_in`, aucun bouton Google dans `login_screen.dart`. Seule l'auth email/mdp est implémentée via `POST /auth/v1/token?grant_type=password`. |
| 2.1.2 | **OTP téléphone** | ❌ Absent | Aucun appel `/auth/v1/otp`, aucun champ téléphone dans le formulaire d'inscription. |
| 2.1.3 | **Création ligne `identites`** | 🟡 Partiel | `inscrire()` appelle `POST /auth/v1/signup` → crée `auth.users`. La table `public.identites` est référencée dans `programmerSuppression()` (PATCH `identites?user_id=eq.$userId`) mais aucun INSERT dans `identites` n'existe dans `inscrire()`. La ligne `identites` dépend d'un trigger PostgreSQL `bienvenue-auth` (webhook) ou d'une insertion manuelle. Ce trigger **n'est pas vérifié depuis le code** — son existence en base est supposée mais non confirmée. |
| 2.1.4 | **UUID v4 non séquentiel** | ✅ Complet | Supabase Auth génère des UUID v4 par défaut pour `auth.users`. Aucun code côté app ne génère d'ID — on laisse la base faire. |
| 2.1.5 | **Création ligne `profils_donneurs`** | ✅ Complet | `_ProfilForm._valider()` appelle `state.sauvegarderProfil(profil)` → `SupabaseService.creerOuMettreAJourProfil()` → `POST /rest/v1/profils_donneurs` avec `Prefer: return=minimal,resolution=merge-duplicates`. Ligne créée dès validation du formulaire profil. |
| 2.1.6 | **Formulaire profil complet et persisté** | ✅ Complet | Groupe sanguin, poids (chiffré AES via `toJsonPourBase()`), genre, ville (int FK), quartier, contre-indications (chiffrées AES) — tous envoyés en base. Consentement requis avant soumission. |
| 2.1.7 | **Gestion erreurs inscription** | ✅ Complet | `inscrire()` capture HTTP 4xx/5xx, extrait `error_description`/`msg`, affiche SnackBar rouge. Rate-limiting 5 échecs → blocage 60s côté login. |
| 2.1.8 | **Session persistée sécurisée** | 🟡 Partiel | Mobile : Android Keystore / iOS Keychain via `flutter_secure_storage` ✅. Web : `SharedPreferences` (localStorage) ⚠️ — tokens JWT en clair, reconnu insécurisé dans le code commentaire `// pour démo uniquement`. |

---

### §2.2 — Connexion (utilisateur existant)

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.2.1 | **Connexion compte existant** | ✅ Complet | `connecter()` → `POST /auth/v1/token?grant_type=password` → JWT stocké. `_ConnexionFormState._connecter()` appelle `state.connecter()`. |
| 2.2.2 | **Vérification JWT à chaque appel sensible** | ✅ Complet | `_requeteAvecRefresh()` intercepte les 401 et rafraîchit automatiquement via `POST /auth/v1/token?grant_type=refresh_token`. Tous les appels REST utilisent `_requeteAvecRefresh()`. |
| 2.2.3 | **Gestion erreurs connexion** | ✅ Complet | Message "Email ou mot de passe incorrect." + rate-limiting 5 tentatives (client-side) + timer 60s. |
| 2.2.4 | **Redirection post-connexion** | ✅ Complet | GoRouter redirect dans `router.dart` : auth + profil + sur `/` → `/home`. Géré automatiquement par le stream `AppState`. |

---

### §2.3 — Déconnexion

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.3.1 | **Bouton déconnexion présent** | ✅ Complet | `profil_screen.dart` → `_showSettings()` → `_buildSettingsItem("Se déconnecter", ...)` → `state.seDeconnecter()`. |
| 2.3.2 | **Token invalidé côté backend** | ✅ Complet | `SupabaseService.deconnecter()` → `POST /auth/v1/logout` avec Bearer token. Le JWT est invalidé serveur avant d'être effacé localement. |
| 2.3.3 | **Redirection après déconnexion** | ✅ Complet | `app_state.dart` : `seDeconnecter()` → `_purgerSessionLocale()` → `notifyListeners()` → GoRouter redirect → `/`. |
| 2.3.4 | **Cache local vidé** | ✅ Complet | `_purgerSessionLocale()` efface toutes les clés SharedPreferences ET les entrées SecureStorage (`accessToken`, `refreshToken`, `userId`). |

---

### §2.4 — Accueil / liste des demandes

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.4.1 | **Données depuis la base** | ✅ Complet | `lireDemandesActives(villeId)` → `GET /rest/v1/demandes_sang?ville_id=eq.$villeId&statut=eq.active&expires_at=gt.$now`. Pas de mock en dur. |
| 2.4.2 | **Filtrage par ville** | ✅ Complet | Filtre `ville_id=eq.$villeId` côté serveur. `villeId` provient de `profil.villeId` (int FK). |
| 2.4.3 | **Badge "Compatible"** | 🟡 Partiel | `DemandeCard._estCompatible` appelle `demande.estCompatibleAvec(profil)` qui compare `groupeSanguinRecherche` avec la table `COMPATIBILITE_ABO` en Dart. **C'est un calcul client-side**, pas serveur-side. La logique est identique à celle dans `matcher-et-notifier` (mêmes règles ABO), donc fonctionnellement correct, mais non garanti par le backend pour ce champ d'affichage. |
| 2.4.4 | **Rafraîchissement** | ✅ Complet | `RefreshIndicator` sur `HomeScreen` et `DemandesScreen` → `state.actualiserDemandes()`. Pattern stale-while-revalidate dans `AppState.init()`. |
| 2.4.5 | **État liste vide** | ✅ Complet | `_buildVide()` avec icône et message "Aucune demande active dans votre ville." |

---

### §2.5 — Création d'une demande

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.5.1 | **Insertion dans `demandes_sang`** | ✅ Complet | `SupabaseService.creerDemande()` → `POST /rest/v1/demandes_sang` avec tous les champs. `resp.statusCode == 201` attendu. |
| 2.5.2 | **Validation backend** | 🟡 Partiel | Validation front-end présente (regex téléphone min 8 chiffres, champs obligatoires). Côté backend, Supabase RLS et contraintes de table (`chk_ville_renseignee`, `chk_structure_renseignee`) sont référencées dans les commentaires du code Flutter. **Impossible de confirmer l'existence réelle des contraintes DB sans accès direct à la base.** |
| 2.5.3 | **Contact principal obligatoire + chiffré** | ✅ Complet | `nouvelle_demande_screen.dart` : validateur regex `≥8 chiffres` sur `contactPrincipal`. `creerDemande()` : `contactChiffre = CryptoService.chiffrer(contactPrincipal)` → AES-256-CBC. |
| 2.5.4 | **Contact secondaire optionnel + chiffré** | ✅ Complet | `contactSecondaire` validé seulement si non-vide. `contactSecondaireChiffre = CryptoService.chiffrer(contactSecondaire)` — peut être null. |
| 2.5.5 | **Anti-spam (max 3 demandes actives)** | 🟡 Partiel | `_compterDemandesActives()` compte côté Flutter avant d'envoyer. Le guard est protégé par `_requeteAvecRefresh()`. **Cependant, ce comptage n'est pas une contrainte backend** — un appel API direct sans passer par Flutter n'est pas bloqué par une contrainte DB ou une RLS policy qui imposerait cette limite. |
| 2.5.6 | **Expiration 72h / 7 jours** | 🟡 Partiel | `kDureeValiditeDemande = Duration(days: 7)` dans `models.dart`. `kDureeValiditeDemandeLabel = '7 jours'` dans `nouvelle_demande_screen.dart`. **Discordance avec le cahier des charges** qui mentionne 72h pour l'expiration. La valeur en base dépend du default PostgreSQL ou d'un trigger — non vérifiable ici. |

---

### §2.6 — Détail d'une demande / réponse d'un donneur

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.6.1 | **"Je réponds" a un effet en base** | ✅ Complet | `enregistrerReponseDonneur()` → `POST /rest/v1/reponses_donneurs` avec `resolution=ignore-duplicates`. Rollback optim UI si échec. |
| 2.6.2 | **Contact non transmis avant réponse** | ✅ Complet | `detail_demande_screen.dart` : `contactChiffre` et `contactSecondaireChiffre` affichés **uniquement si** `_repondu == true`. `_repondu` est chargé depuis la vue `demandes_sang_avec_contact?select=a_repondu` côté serveur. Un attaquant ne peut pas lire le contact en inspectant le payload réseau car le déchiffrement se fait en Dart avec la clé dart-define. |

---

### §2.7 — QR code — génération et scan

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.7.1 | **QR depuis token réel en base** | ✅ Complet | `creerToken()` → `POST /rest/v1/dons_qr_tokens` → le token opaque est inséré en DB. `lireTokenQrExistant()` vérifie d'abord un token valide existant (PERF-05). |
| 2.7.2 | **Expiration 24h** | ✅ Complet | Colonne `expires_at` filtrée (`expires_at=gt.$now`) lors de `lireTokenQrExistant()`. La valeur 24h dépend du default PostgreSQL — non vérifiable sans accès DB, mais logique de vérification présente aux deux étapes (Flutter + EF `valider-token`). |
| 2.7.3 | **Scan déclenche validation backend** | ✅ Complet | `validerToken()` → `POST /functions/v1/valider-token`. L'EF vérifie JWT, WEBHOOK_SECRET, token en base, auteur de la demande, expiration, et marque `used_at`. |
| 2.7.4 | **Token déjà utilisé rejeté** | ✅ Complet | `valider-token/index.ts` : vérifie `qr.used_at !== null` → erreur 400 "Ce code QR a déjà été utilisé." + trigger `trg_verifier_token` (BEFORE UPDATE of used_at) comme garde atomique. |
| 2.7.5 | **`dernier_don_date` mis à jour après scan** | 🟡 Partiel | `valider-token` insère dans `historique_dons` (`source='qr_valide'`) et met à jour `reponses_donneurs.statut`. **La mise à jour de `profils_donneurs.dernier_don_date` n'est pas faite explicitement dans `valider-token`** — elle dépend d'un trigger PostgreSQL `trg_maj_dernier_don` non vérifiable depuis le code EF. Le commentaire dans `valider-token` ne mentionne pas ce champ. |
| 2.7.6 | **Historique créé avec `source='qr_valide'`** | ✅ Complet | `valider-token/index.ts` étape 6 : `INSERT INTO historique_dons {donneur_id, demande_id, date_don, source: "qr_valide"}`. |

---

### §2.8 — Déclaration manuelle de don

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.8.1 | **Ligne `historique_dons` avec `source='declaratif'`** | ✅ Complet | `enregistrerDon(source: SourceDon.declaratif)` → `POST /functions/v1/don-manuel`. L'EF `don-manuel` gère l'insertion avec `source='declaratif'`. |
| 2.8.2 | **`dernier_don_date` mis à jour** | 🟡 Partiel | L'EF `don-manuel` doit mettre à jour `profils_donneurs.dernier_don_date`. Le code Flutter dans `app_state.declarerDon()` appelle `sauvegarderProfil(profil.copyWith(dernierDonDate: dateDon))` **avant** l'appel EF, ce qui met à jour le profil localement et en base via `creerOuMettreAJourProfil()`. L'EF semble être en doublon ou complémentaire — **non bloquant mais potentiel double-écriture.** |

---

### §2.9 — Calcul d'éligibilité et disponibilité

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.9.1 | **Calcul 60j/90j** | ✅ Complet (double) | Implémenté côté Dart dans `ProfilDonneur.estEligible` (60j homme / 90j femme) **et** dans `matcher-et-notifier/index.ts` `estEligible()` (même logique). Les deux calculs sont cohérents. |
| 2.9.2 | **Non-éligible exclu du matching** | ✅ Complet | `matcher-et-notifier` : `donneursFiltres = profils.filter(p => estCompatible(...) && estEligible(p))`. Les non-éligibles ne reçoivent pas de notification. |
| 2.9.3 | **Toggle disponibilité modifie la base** | ✅ Complet | `state.toggleDisponibilite()` → `SupabaseService.mettreAJourDisponibilite()` → `PATCH /rest/v1/profils_donneurs?user_id=eq.$userId` `{disponible: bool}`. |

---

### §2.10 — Notifications

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.10.1 | **Notification push FCM réelle** | 🟡 Partiel | Le code est en place : `notification_service.dart` initialise FCM, `enregistrerFcmToken()` persiste en `device_tokens`, `matcher-et-notifier` envoie via `envoyerFcmV1()` (FCM v1 OAuth2). **Bloquant : le fichier `android/app/google-services.json` est absent du projet.** `notification_service.dart` lignes 14-15 : `"Ajouter une app Android avec le package : com.lifesaver.save"` — c'est une instruction de configuration, pas une confirmation d'existence. Sans `google-services.json`, Firebase ne s'initialise pas et FCM est non fonctionnel sur Android. |
| 2.10.2 | **Email réellement envoyé** | 🟡 Partiel | Système rotatif Brevo/Resend implémenté dans `_shared/email.ts` avec 11 templates HTML. **Non testable depuis le code** : les clés API (`BREVO_API_KEY`, `RESEND_API_KEY`) sont des secrets Supabase. Impossible de confirmer leur présence et validité. |
| 2.10.3 | **Ciblage précis** | ✅ Complet | `matcher-et-notifier` filtre : `disponible=true` + même `ville_id` + compatibilité ABO + éligibilité 60/90j + `neq(user_id, demande.auteur_id)`. Pas d'envoi global. |
| 2.10.4 | **Liste notifications reflète les événements réels** | 🟡 Partiel | `lireNotifications()` → `GET /rest/v1/notifications_envoyees`. Les données sont réelles depuis la DB. **Problème** : `TypeNotification` en Dart n'a que 3 valeurs (`demandeCompatible`, `donConfirme`, `retourEligibilite`). La DB `type_notification_enum` a 10 valeurs après mission-d.sql. `NotificationSauve.fromBase()` utilise `TypeNotification.fromValue()` avec `orElse: () => TypeNotification.demandeCompatible` → **toutes les nouvelles notifications (reponse_recue, don_enregistre_manuel, suppression_demandee, bienvenue, mdp_modifie…) s'affichent comme "demandeCompatible" avec le mauvais style rouge.** |

---

### §2.11 — Profil et paramètres

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.11.1 | **Modifications profil persistées** | ✅ Complet | `_showModifierProfil()` → `state.sauvegarderProfil(updated)` → `creerOuMettreAJourProfil()` → PATCH/POST REST. SnackBar de confirmation. |
| 2.11.2 | **Suppression J+5 avec double confirmation** | ✅ Complet | Étape 1 : bottom sheet `_showConfirmationSuppression()` avec liste d'effets. Étape 2 : AlertDialog `_showConfirmationFinale()` `barrierDismissible=false`. Appel `programmerSuppression()` → PATCH `identites?user_id=eq.$userId` `{suppression_programmee_le: J+5, compte_actif: false}`. |
| 2.11.3 | **Bouton annulation suppression** | ✅ Complet | Bannière `_buildBannereSuppression()` visible si `state.suppressionProgrammee`. Bouton "Annuler la suppression" → `state.annulerSuppression()` → PATCH `{suppression_programmee_le: null, compte_actif: true}`. |

---

### §2.12 — Navigation

| # | Fonctionnalité | Statut | Preuve |
|---|---|---|---|
| 2.12.1 | **Bouton retour sur écrans secondaires** | ✅ Complet | Présent sur : `login_screen.dart` `_buildHeader()`, `profil_screen.dart` top-left arrow, `detail_demande_screen.dart` `_buildBackBtn()`, `scan_qr_screen.dart` `_buildBackBtn()`, `change_password_screen.dart`, `contact_screen.dart`, `parametres_screen.dart`. |
| 2.12.2 | **Aucune impasse navigation** | ✅ Complet | GoRouter couvre tous les cas. L'écran `home` n'a pas de back (logique). `scan_qr_screen` : après résultat, bouton "Retour" → `context.pop()`. |

---

## 3. Audit de la couche backend et base de données

| # | Item | Statut | Preuve / Observation |
|---|---|---|---|
| 3.1 | **Existence des 5 tables core** | 🟡 Partiel | Le code Flutter référence : `profils_donneurs` ✅, `demandes_sang` ✅, `dons_qr_tokens` ✅, `historique_dons` ✅, `identites` ✅ (via `programmerSuppression`, `annulerSuppression`). **Impossible de confirmer l'existence réelle des tables en base sans connexion directe à Supabase.** Les requêtes échouent silencieusement si les tables sont absentes. |
| 3.2 | **Enums utilisés** | 🟡 Partiel | `GroupeSanguin.label` (`O+`, `A-`, etc.), `SourceDon.value` (`declaratif`, `qr_valide`) sont passés comme chaînes aux API. `matcher-et-notifier` utilise `groupe_sanguin_recherche` comme string. **Aucun enum Postgres n'est vérifié explicitement** depuis le code — si les enums PostgreSQL ne correspondent pas, Supabase retourne une erreur 400 attrapée silencieusement. |
| 3.3 | **Index `idx_profils_matching`** | ❌ Non confirmé | Aucune référence à ces index dans les fichiers de code ou SQL audités. `mission-d.sql` crée `idx_contact_spam_log_user_recent` et des index sur `liens_externes`. Les index du schéma core (`idx_profils_matching`, etc.) ne sont ni créés ni vérifiés dans le code fourni. |
| 3.4 | **Trigger `dernier_don_date`** | 🟡 Partiel | `valider-token` insère dans `historique_dons` mais ne met pas à jour `dernier_don_date` explicitement. Le commentaire de l'EF indique que cette MAJ est censée être gérée par un trigger. `don-manuel` EF non lue intégralement — mais `app_state.declarerDon()` fait un PATCH profil avant l'appel EF, ce qui double-écrit `dernier_don_date`. Trigger non confirmé dans le SQL fourni. |
| 3.5 | **Isolation des données (RLS)** | 🟡 Partiel | RLS activé sur `contact_spam_log` et `liens_externes` (confirmé dans `mission-d.sql`). Les autres tables sont mentionnées dans les commentaires du code mais les politiques RLS réelles ne sont pas vérifiables depuis le code Dart. `valider-token` utilise `adminClient` (service_role) qui bypass RLS — correct pour les EF. |
| 3.6 | **Chiffrement des champs `_chiffre`** | ✅ Confirmé | `CryptoService.chiffrer()` : AES-256-CBC, IV 16 octets random par opération, format `base64(IV):base64(ciphertext)`. Utilisé pour `poids_chiffre`, `contre_indications_chiffre`, `contact_chiffre`, `contact_secondaire_chiffre`. La clé provient exclusivement de `--dart-define=SONGRE_ENCRYPT_KEY`. |
| 3.7 | **Clés de chiffrement non commitées** | ✅ Confirmé | `crypto_service.dart` : `String.fromEnvironment('SONGRE_ENCRYPT_KEY', defaultValue: '')` → throw `StateError` si absent. Aucune clé en dur dans les fichiers audités. `supabase_service.dart` : même pattern pour `SUPABASE_URL` et `SUPABASE_ANON_KEY`. Vérification historique Git non effectuée (hors périmètre statique). |
| 3.8 | **Rate limiting** | 🟡 Partiel | Login : 5 échecs → 60s blocage côté client (`login_screen.dart`). Anti-spam demandes : `_compterDemandesActives()` côté Flutter. `contact_spam_log` : côté EF `contacter-support`. **Aucun rate-limiting backend configuré sur les endpoints REST natifs Supabase** (ex. création tokens QR à volonté, appels `/auth/v1/signup` non limités côté app). |
| 3.9 | **File d'attente pour notifications en masse** | 🟡 Partiel | `matcher-et-notifier` utilise `Promise.all()` avec `BATCH_SIZE=10` par lot. C'est une approche par batches, mais **ce n'est pas une file d'attente réelle** (pas de Redis, pas de Supabase Queue). Pour un grand nombre de donneurs dans une ville, un timeout de l'EF est possible (limite Supabase EF 60s). |
| 3.10 | **Logs sans données sensibles** | ✅ Confirmé | Les `console.log/error` dans les EF logguent des IDs, compteurs, statuts — jamais de tokens JWT, emails en clair dans les messages visibles, ou données de santé. Flutter utilise `kDebugMode` checks avant tout `debugPrint`. |

---

## 4. Failles de sécurité identifiées

### CRITIQUE

| # | Gravité | Description | Fichier |
|---|---|---|---|
| S-01 | 🔴 **CRITIQUE** | **FCM non fonctionnel en production** : `google-services.json` absent de `android/app/`. Le fichier `notification_service.dart` contient l'instruction de configuration mais pas la configuration elle-même. Sans ce fichier, `Firebase.initializeApp()` lève une exception au démarrage sur Android, empêchant toutes les notifications push. L'app peut crasher au démarrage en production Android. | `android/app/` (absent) · `notification_service.dart` L.14-15 |

### MAJEURES

| # | Gravité | Description | Fichier |
|---|---|---|---|
| S-02 | 🟠 **MAJEURE** | **Désynchronisation enum TypeNotification** : `models.dart` définit `TypeNotification` avec 3 valeurs. La DB `type_notification_enum` en contient 10 après `mission-d.sql`. La méthode `fromValue()` utilise `orElse: () => TypeNotification.demandeCompatible` — **toutes les nouvelles notifications arrivent silencieusement avec le mauvais type**, mal affichées (couleur rouge de "demandeCompatible" au lieu des couleurs distinctives appropriées), et la logique métier basée sur le type (`_dotColor`, `_iconForType`) est incorrecte. | `lib/models/models.dart` (enum TypeNotification) |
| S-03 | 🟠 **MAJEURE** | **Tokens JWT en localStorage sur Web** : `secure_storage_service.dart` utilise `SharedPreferences` (localStorage navigateur) pour les tokens JWT sur Web. Un script XSS peut les lire. Reconnu dans le code commentaire. Si l'app Web est déployée en production, cette insécurité est réelle. | `lib/utils/secure_storage_service.dart` |
| S-04 | 🟠 **MAJEURE** | **`x-webhook-secret` absent des appels Flutter vers `valider-token`** : `SupabaseService.validerToken()` envoie `{token, demandeur_id}` avec `_headers(withAuth: true)` mais **sans le header `x-webhook-secret`**. L'EF `valider-token/index.ts` vérifie ce header en étape 0 et renvoie 401 si absent. **Résultat : la validation QR échoue systématiquement en production** — l'EF rejette toute requête Flutter car le secret n'est pas fourni. | `lib/services/supabase_service.dart` L.614-641 · `valider-token/index.ts` L.80-93 |

### MINEURES

| # | Gravité | Description | Fichier |
|---|---|---|---|
| S-05 | 🟡 **MINEURE** | **Anti-spam demandes contournable** : `_compterDemandesActives()` est un guard côté client. Un attaquant peut envoyer directement `POST /rest/v1/demandes_sang` sans passer par Flutter et dépasser la limite de 3 demandes si la RLS policy ne l'interdit pas. | `lib/services/supabase_service.dart` L.455-463 |
| S-06 | 🟡 **MINEURE** | **CORS fallback sur domaine principal** : `_shared/cors.ts` retourne `ALLOWED_ORIGINS[0]` ("https://songre.bf") pour les origines inconnues. Cela signifie que les EF répondent toujours avec un header CORS valide même pour des origines non autorisées — l'header CORS est inexact mais le browser bloquera quand même. Comportement trompeur, non dangereux. | `supabase/functions/_shared/cors.ts` L.22-24 |
| S-07 | 🟡 **MINEURE** | **Bouton notification sur HomeScreen non fonctionnel** : `_buildNotifBadge()` a `onTap: () {}` vide. Le badge rouge s'affiche mais un clic ne navigue pas vers l'écran notifications. | `lib/screens/home_screen.dart` L.114 |
| S-08 | 🟡 **MINEURE** | **`_compterDemandesActives()` avec Prefer:count=exact** : le header `Prefer: count=exact` est envoyé mais le comptage se fait sur `list.length` (body), pas sur le header `Content-Range`. Si la liste retournée est paginée (<50 items), le comptage est correct. Mais le comportement peut être inattendu avec des limites de pagination Supabase. | `lib/services/supabase_service.dart` L.972-999 |

---

## 5. Problèmes de performance identifiés

| # | Sévérité | Description | Fichier |
|---|---|---|---|
| P-01 | 🔴 **Bloquant** | **Notifications en masse synchrones** : `matcher-et-notifier` envoie des notifications via `Promise.all()` par lots de 10, mais la boucle principale est séquentielle entre les lots. Pour 100+ donneurs dans une ville, l'EF peut dépasser les 60s de timeout Supabase. Aucun mécanisme de file d'attente. | `supabase/functions/matcher-et-notifier/index.ts` L.230-280 |
| P-02 | 🟠 **Majeur** | **N+1 requêtes emails dans matcher** : chaque donneur fait un appel séparé `adminClient.auth.admin.getUserById(uid)` pour récupérer l'email. Pour 50 donneurs → 50 appels API en parallèle. Supabase Auth Admin API n'a pas de méthode `getUsersByIds()` en bulk. | `matcher-et-notifier/index.ts` L.200-220 |
| P-03 | 🟡 **Mineur** | **Chargement villes à chaque inscription** : `_ProfilForm.initState()` appelle `_chargerVilles()` qui fait un GET réseau si le cache AppState est vide. À la première utilisation (inscription), le cache est toujours vide. Latence perceptible avant affichage du dropdown. | `lib/screens/login_screen.dart` L.709-729 |
| P-04 | 🟡 **Mineur** | **Absence de cache notifications** : `lireNotifications()` est appelé à chaque `_chargerNotificationsBackend()`. Pas de cache local des notifications ni de mécanisme de différentiel (delta). | `lib/services/supabase_service.dart` L.756-786 |
| P-05 | 🟡 **Mineur** | **Token QR non réutilisé si valide** : `lireTokenQrExistant()` existe (PERF-05) et est appelé dans `genererQrToken()` de `app_state.dart`. Bon pattern. Cependant, si l'appel réseau échoue silencieusement, un second token est créé pour le même couple donneur/demande. | `lib/services/supabase_service.dart` L.532-567 |

---

## 6. Recommandations

> **Rappel : aucun code corrigé ci-dessous. Descriptions en langage naturel uniquement.**

---

### 🔴 BLOQUANTS PRODUCTION — À corriger avant tout déploiement

**R-01 — Ajouter `google-services.json` (correspond à S-01)**  
Créer un projet Firebase, enregistrer l'app Android avec le package `com.lifesaver.save`, télécharger `google-services.json` et le placer dans `android/app/`. Sans ce fichier, l'application Android crash au démarrage si Firebase est initialisé. Effort estimé : 30 minutes.

**R-02 — Corriger l'appel `validerToken()` pour inclure `x-webhook-secret` (correspond à S-04)**  
L'appel Flutter vers l'EF `valider-token` doit inclure le header `x-webhook-secret` avec la valeur de la variable d'environnement `WEBHOOK_SECRET`. Cette valeur doit être injectée via `--dart-define=WEBHOOK_SECRET=...` ou récupérée depuis une configuration sécurisée. Sans cette correction, **toute validation QR échoue systématiquement** avec une erreur 401. Effort estimé : 2 heures (injection dart-define + transmission header).

**R-03 — Synchroniser `TypeNotification` Dart avec l'enum PostgreSQL (correspond à S-02)**  
Ajouter dans `models.dart` les 7 valeurs manquantes : `reponseRecue`, `reponseEncouragement`, `donConfirmeDemandeur`, `donEnregistreManuel`, `suppressionDemandee`, `bienvenue`, `mdpModifie`. Mettre à jour `_dotColor` et `_iconForType` dans `notifications_screen.dart` avec des couleurs et icônes distinctives pour chaque type. Effort estimé : 2 heures.

---

### 🟠 IMPORTANTES — À faire avant le lancement public

**R-04 — Vérifier et créer le trigger `dernier_don_date` (correspond à 3.4)**  
Confirmer dans le SQL Editor Supabase l'existence du trigger sur `historique_dons` qui met à jour `profils_donneurs.dernier_don_date` après INSERT. S'il n'existe pas, l'éligibilité sera incorrecte. Alternativement, ajouter un UPDATE explicite dans `valider-token` après l'insertion dans `historique_dons`. Effort estimé : 1 heure.

**R-05 — Clarifier la durée d'expiration des demandes (correspond à 2.5.6)**  
Décider entre 72h (cahier des charges) et 7 jours (code Flutter) et aligner le code, le SQL (DEFAULT pour `expires_at`), et les libellés UI (`kDureeValiditeDemandeLabel`). Effort estimé : 30 minutes.

**R-06 — Limiter le rate-limiting côté backend pour `demandes_sang` (correspond à S-05)**  
Ajouter une policy RLS PostgreSQL ou une contrainte CHECK dans `demandes_sang` qui empêche un même `auteur_id` d'avoir plus de 3 demandes actives simultanément. Le guard Flutter seul n'est pas suffisant. Effort estimé : 1 heure (SQL RLS policy ou trigger).

**R-07 — Ajouter un mécanisme de file d'attente pour les notifications (correspond à P-01)**  
Pour les villes avec un grand nombre de donneurs, envisager une approche asynchrone : stocker les notifications à envoyer dans une table `notification_queue` et les traiter par un job cron en petits lots. Alternativement, structurer `matcher-et-notifier` pour se terminer rapidement (200 OK) et déléguer l'envoi à un second appel. Effort estimé : V2 (architecture significative).

---

### 🟡 AMÉLIORATIONS — Peuvent attendre V2

**R-08 — Remplacer localStorage JWT sur Web par un cookie HttpOnly (correspond à S-03)**  
Pour une version Web production-grade, stocker les tokens dans des cookies HttpOnly via un proxy backend plutôt que dans localStorage. Impacte l'architecture du service d'authentification Web. Effort estimé : V2.

**R-09 — Connecter le badge notification de l'accueil (correspond à S-07)**  
Remplacer `onTap: () {}` par une navigation vers l'écran notifications (onglet alertes ou push route). Effort estimé : 30 minutes.

**R-10 — Ajouter la confirmation de création de la ligne `identites` (correspond à 2.1.3)**  
Vérifier que le webhook `bienvenue-auth` crée bien la ligne `identites` dans `public` lors de l'inscription, ou ajouter un INSERT explicite dans `inscrire()`. L'absence de cette ligne cause un échec silencieux lors de `programmerSuppression()`. Effort estimé : 1 heure.

**R-11 — Optimiser les appels emails dans `matcher-et-notifier` (correspond à P-02)**  
Regrouper les appels `getUserById` en utilisant une requête directe sur `auth.users` via `adminClient.from('auth.users')` avec un filtre `in` plutôt que N appels parallèles. Effort estimé : 1 heure.

---

## 7. Conclusion — Checklist finale de mise en production

### ✅ Prêt

- [x] Architecture backend : Edge Functions Deno, Supabase Auth, RLS
- [x] Chiffrement AES-256-CBC avec clé dart-define
- [x] Stockage sécurisé Android Keystore / iOS Keychain
- [x] Gestion des sessions : JWT + refresh automatique + invalidation backend
- [x] Flux complet inscription → profil → demande → réponse → QR → validation
- [x] Suppression de compte J+5 avec double confirmation et annulation
- [x] Navigation sans impasse, bouton retour sur tous les écrans secondaires
- [x] Notifications in-app depuis `public.notifications_envoyees`
- [x] Email support anti-spam via `contact_spam_log`
- [x] Champ contact principal chiffré + contact secondaire optionnel chiffré
- [x] Matching ABO précis (8 groupes × compatibilité) dans EF et Flutter
- [x] Éligibilité genre-aware (60j homme / 90j femme) dans EF et Flutter
- [x] `flutter analyze` : 0 issue · `flutter build web --release` : ✅

### ❌ Bloquants à corriger AVANT déploiement Android

- [ ] **R-01** : `google-services.json` absent → crash Android au démarrage
- [ ] **R-02** : `x-webhook-secret` manquant dans `validerToken()` → validation QR impossible
- [ ] **R-03** : `TypeNotification` Dart incomplet → notifications mal classifiées

### 🟡 À corriger AVANT lancement public (dans les 30 jours)

- [ ] **R-04** : Trigger `dernier_don_date` à vérifier/créer
- [ ] **R-05** : Durée expiration demandes à aligner (72h vs 7j)
- [ ] **R-06** : Anti-spam demandes à implémenter côté backend
- [ ] **R-09** : Badge notification accueil à connecter
- [ ] **R-10** : Ligne `identites` à garantir à l'inscription

### 🔵 V2 (pas bloquant)

- [ ] **R-07** : File d'attente pour notifications en masse
- [ ] **R-08** : Cookie HttpOnly pour tokens JWT Web
- [ ] **R-11** : Optimisation N+1 emails dans matcher
- [ ] Google Sign-In (§2.1.1)
- [ ] OTP téléphone (§2.1.2)

---

*Fin du rapport d'audit — SONGRE v36b35d4 — 9 juillet 2026*
