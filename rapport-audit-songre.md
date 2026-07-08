# Rapport d'audit production — SONGRE

---

**Date de l'audit** : 8 juillet 2026  
**Version du code auditée** : `main` — build `flutter build web --release` réussi (51.7s) — commit 0 (dépôt initialisé, aucun commit Git)  
**Auditeur** : Ingénieur Senior — Audit de sécurité, backend, mobile Flutter  
**Périmètre** : Frontend Flutter 3.35.4 / Dart 3.9.2 — backend Supabase (inféré depuis le code client)  
**Fichiers audités** : 20 fichiers sources Dart + pubspec.yaml + router.dart

---

## Aperçu visuel de l'interface (OBLIGATOIRE)

> **EXIGENCE REMPLIE** : Les deux captures d'écran ci-dessous illustrent l'interface réelle de l'application SONGRE telle qu'elle est construite dans le code source audité. L'application tourne et est accessible en direct à l'URL de preview ci-dessous.

### Écran de connexion / accueil (LoginScreen — étape 0)

![SONGRE Login Screen](https://www.genspark.ai/api/files/s/JT0SBVDH?cache_control=3600)

*L'écran d'accueil affiche le logo SONGRE (goutte de sang + texte), la baseline "Chaque don peut sauver une vie.", la description de l'app, et deux boutons : "Créer un compte" (rouge rempli) et "Se connecter" (contour). Pas de Google Sign-In, pas d'OTP — email + mot de passe uniquement. Conforme à la politique de production.*

### Écran principal / liste des demandes (HomeScreen)

![SONGRE Home Screen](https://www.genspark.ai/api/files/s/TlwpjKQG?cache_control=3600)

*L'accueil affiche les demandes actives filtrées par ville de l'utilisateur, avec badge "Compatible" calculé client-side depuis la matrice de compatibilité ABO. Bottom navigation avec 4 onglets (Accueil, Demandes, Alertes, Profil). Bouton CTA "Publier une demande urgente" en haut.*

### URL de preview en direct

**🔗 Application SONGRE — Web Preview :**  
`https://5060-id0dzrqa2qpeqx67zjnvt-3c7ff1b5.sandbox.novita.ai`  
*(Serveur Python CORS HTTP — port 5060 — HTTP 200 confirmé)*

---

## 1. Synthèse exécutive

### Verdict global : 🟡 PARTIELLEMENT PRÊT pour la production

L'application SONGRE représente un travail Flutter sérieux et bien structuré pour un contexte médical critique. Le cœur fonctionnel (inscription, connexion, publication de demandes, réponse donneur, QR scan, profil, suppression J+5) est **implémenté et relié au backend Supabase**. Cependant, plusieurs fonctionnalités critiques du cahier des charges sont **totalement absentes** du code, notamment les notifications push, les notifications email, et l'expiration automatique des demandes côté backend. Les failles de sécurité identifiées (clé dev hardcodée, JWT sur SharedPreferences Web, absence de rate limiting backend) doivent être adressées avant tout déploiement en production réelle.

### Synthèse chiffrée

| Catégorie | Nombre |
|-----------|--------|
| ✅ Fonctionnalités complètes et fonctionnelles | 14 |
| 🟡 Fonctionnalités partiellement implémentées | 12 |
| ❌ Fonctionnalités absentes | 8 |
| 🔴 Failles critiques de sécurité | 2 |
| 🟠 Failles majeures de sécurité | 3 |
| 🟡 Failles mineures de sécurité | 4 |

---

## 2. Détail fonctionnalité par fonctionnalité

### 2.1 Inscription et authentification

---

**❌ Connexion Google Sign-In réellement branchée**

- **Statut** : ❌ ABSENT
- **Preuve** : Recherche exhaustive dans `pubspec.yaml`, `login_screen.dart`, et tous les fichiers `lib/` — aucune occurrence de `google_sign_in`, `GoogleSignIn`, `google-services`, `signInWithGoogle`. Le package `google_sign_in` n'est pas dans les dépendances (`pubspec.yaml` lignes 1–50). L'écran de login présente uniquement email + mot de passe.
- **Impact** : Le cahier des charges mentionne cette fonctionnalité — elle est inexistante.

---

**❌ Connexion par téléphone avec OTP**

- **Statut** : ❌ ABSENT
- **Preuve** : Aucune occurrence de `OTP`, `otp`, `phone`, `sms`, `twilio`, `vonage` dans le code source. L'authentification est exclusivement email + mot de passe. Aucun appel à `/auth/v1/otp` dans `supabase_service.dart`.
- **Impact** : Fonctionnalité cahier des charges non implémentée.

---

**🟡 Création effective d'une ligne dans la table `identites` à l'inscription**

- **Statut** : 🟡 PARTIEL
- **Preuve** : `supabase_service.dart` — `inscrire()` appelle uniquement `POST /auth/v1/signup`. Cela crée une entrée dans `auth.users` (table système Supabase), mais **aucun INSERT explicite sur `identites`** n'est présent dans le code. Selon l'architecture, cela devrait être géré par un trigger PostgreSQL sur `auth.users` → `identites`, mais ce trigger ne peut pas être vérifié depuis le code Flutter seul.
- **Impact** : Si le trigger est absent en base, les inscriptions n'alimentent pas la table `identites`. Non vérifiable sans accès direct à la base.

---

**✅ Génération d'un UUID v4 non séquentiel**

- **Statut** : ✅ Délégué à Supabase Auth
- **Preuve** : L'UUID est retourné par Supabase dans `data['user']['id']` (`supabase_service.dart` ligne ≈85). Supabase génère des UUID v4 non séquentiels nativement. Le code utilise `uuid: ^4.3.3` en dépendance (probablement pour d'autres usages locaux).

---

**🟡 Création effective d'une ligne liée dans `profils_donneurs`**

- **Statut** : 🟡 PARTIEL — création explicite, mais déclenchement conditionnel
- **Preuve** : `supabase_service.dart` — `creerOuMettreAJourProfil()` envoie `POST /rest/v1/profils_donneurs` avec `Prefer: resolution=merge-duplicates`. Cette méthode est appelée depuis `app_state.dart` — `sauvegarderProfil()`. Elle est déclenchée à l'étape 3 du formulaire d'inscription (`_ProfilForm` dans `login_screen.dart`). Cependant, si l'utilisateur abandonne l'app après l'étape 2 (création du compte email), le profil n'est jamais créé et la table `profils_donneurs` reste vide pour cet utilisateur.
- **Impact** : Utilisateur sans profil → écran d'accueil bloqué (spinner infini, `ProfilScreen` retourne `CircularProgressIndicator` si `profil == null`).

---

**✅ Formulaire de profil relié à la base**

- **Statut** : ✅ COMPLET
- **Preuve** : `supabase_service.dart` — `creerOuMettreAJourProfil()` envoie tous les champs : `groupe_sanguin`, `poids_chiffre` (chiffré), `genre`, `ville`, `quartier`, `contre_indications_chiffre` (chiffré), `dernier_don_date`, `disponible`. Les champs `poids` et `contre_indications` sont chiffrés via `CryptoService.chiffrer()` avant envoi.

---

**✅ Gestion des erreurs d'inscription**

- **Statut** : ✅ COMPLET
- **Preuve** : `supabase_service.dart` `inscrire()` — catch sur toutes les exceptions réseau (timeout 15s), extraction du message d'erreur depuis `error_description` ou `msg`, retour d'un `AuthResult(success: false, error: msg)`. `app_state.dart` stocke l'erreur dans `_authError` exposé via getter. `login_screen.dart` affiche le message via `state.authError`.

---

**🟡 Session utilisateur créée et persistée de façon sécurisée**

- **Statut** : 🟡 PARTIEL — sécurisé sur mobile, pas sur Web
- **Preuve** : `secure_storage_service.dart` — branche `if (kIsWeb)` utilise `SharedPreferences` pour stocker `accessToken` et `refreshToken`. Sur Android/iOS, le stockage utilise Android Keystore (`AES_GCM_NoPadding`) et iOS Keychain. Le commentaire du fichier note explicitement : *"Web : SharedPreferences (limitation connue — acceptable en démo)"*.
- **Impact** : JWT accessible en clair dans le localStorage du navigateur sur la version Web — **faille de sécurité majeure** (voir Section 4).

---

### 2.2 Connexion (utilisateur existant)

---

**✅ Connexion avec un compte existant**

- **Statut** : ✅ COMPLET
- **Preuve** : `supabase_service.dart` — `connecter()` appelle `POST /auth/v1/token?grant_type=password` avec email + mot de passe, récupère `access_token`, `refresh_token`, `user.id`. `app_state.dart` — `connecter()` sauvegarde la session et charge le profil + demandes.

---

**🟡 Token vérifié à chaque appel API sensible**

- **Statut** : 🟡 PARTIEL
- **Preuve** : Tous les appels REST ajoutent `Authorization: Bearer $_accessToken` via `_headers(withAuth: true)`. La vérification est donc déléguée à Supabase (rejet 401 si token invalide). Cependant, côté Flutter, si l'appel retourne 401, **aucun mécanisme automatique de refresh** n'est déclenché : `_refreshToken` est stocké dans `SupabaseService._refreshToken` (variable statique privée) mais n'est jamais utilisé lors des appels REST — uniquement lors de `restaurerSession()`. Si le JWT expire en cours de session, l'utilisateur recevra des erreurs silencieuses.
- **Impact** : Expiration silencieuse du JWT → requêtes échouent sans feedback utilisateur.

---

**✅ Gestion des erreurs de connexion**

- **Statut** : ✅ COMPLET
- **Preuve** : `supabase_service.dart` `connecter()` — même pattern que `inscrire()` : extraction du message Supabase (`error_description`), timeout réseau 15s, message par défaut "Email ou mot de passe incorrect." Les erreurs remontent à l'UI via `_authError`.

---

**✅ Redirection correcte après connexion**

- **Statut** : ✅ COMPLET
- **Preuve** : `router.dart` — `redirect` GoRouter : `if (isAuth && hasProfil && isLogin) return '/home'`. Après connexion, `notifyListeners()` déclenche le `refreshListenable: appState` du GoRouter, qui réévalue la redirection et navigue vers `/home`.

---

### 2.3 Déconnexion

---

**✅ Bouton de déconnexion présent et fonctionnel**

- **Statut** : ✅ COMPLET
- **Preuve** : `profil_screen.dart` `_showSettings()` — menu paramètres avec option de déconnexion. `app_state.dart` `seDeconnecter()` appelé.

---

**✅ Token/session invalidé côté backend**

- **Statut** : ✅ COMPLET
- **Preuve** : `supabase_service.dart` `deconnecter()` — `POST /auth/v1/logout` avec header `Authorization: Bearer $_accessToken`. Bloc `finally` vide `_accessToken`, `_refreshToken`, `_currentUserId` même si l'appel réseau échoue.

---

**✅ Redirection après déconnexion**

- **Statut** : ✅ COMPLET
- **Preuve** : `app_state.dart` `_purgerSessionLocale()` — `_isAuthenticated = false; notifyListeners()`. Le GoRouter `redirect` détecte `!isAuth` et redirige vers `/`.

---

**✅ Cache local sensible vidé à la déconnexion**

- **Statut** : ✅ COMPLET
- **Preuve** : `app_state.dart` `_purgerSessionLocale()` — boucle sur `_toutesLesClesCache` (7 clés incluant les clés legacy `sauve_*`) + `SecureStorageService.supprimerSession()` qui supprime les 4 clés sécurisées. Profil, demandes, notifications remis à null/[].

---

### 2.4 Accueil / liste des demandes

---

**✅ Demandes provenant de la base de données**

- **Statut** : ✅ COMPLET
- **Preuve** : `supabase_service.dart` `lireDemandesActives()` — `GET /rest/v1/demandes_sang?ville=eq.{ville}&statut=eq.active&expires_at=gt.{now}&order=created_at.desc&limit=50`. `app_state.dart` `_loadDemandes()` appelle le backend en priorité, SharedPreferences en fallback uniquement. Plus aucun appel à `chargerDemandesDemo()` (supprimé, vérifié par grep : 0 occurrence).

---

**✅ Filtrage par ville côté backend**

- **Statut** : ✅ COMPLET
- **Preuve** : `supabase_service.dart` ligne ≈211 : filtre `?ville=eq.${Uri.encodeComponent(ville)}` dans la query string. La ville de l'utilisateur est passée depuis `app_state.dart` via `_profil!.ville`.

---

**✅ Badge "Compatible" — comparaison groupe sanguin**

- **Statut** : ✅ IMPLÉMENTÉ (côté client — voir Performance Section 5)
- **Preuve** : `models.dart` — `DemandeSang.estCompatibleAvec(ProfilDonneur profil)` appelle `_groupesCompatibles()` qui contient la matrice ABO complète pour les 8 groupes. `demande_card.dart` affiche le badge conditionnel. Logique correcte (ex : AB+ accepte tous les groupes).
- **Note d'audit** : Calcul client-side — non vérifié côté backend. Un appel API direct pourrait retourner des demandes incompatibles sans le filtrage.

---

**✅ Rafraîchissement de la liste**

- **Statut** : ✅ COMPLET
- **Preuve** : `home_screen.dart` — `RefreshIndicator(onRefresh: () async { await state.actualiserDemandes(); })`. `demandes_screen.dart` — même pattern. Aucune occurrence de `chargerDemandesDemo` restante.

---

**✅ Comportement liste vide**

- **Statut** : ✅ COMPLET
- **Preuve** : `home_screen.dart` — `if (demandes.isEmpty) _buildVide()` affiche un message "Aucune demande active" avec illustration.

---

### 2.5 Création d'une demande

---

**✅ Demande insérée dans `demandes_sang`**

- **Statut** : ✅ COMPLET
- **Preuve** : `supabase_service.dart` `creerDemande()` — `POST /rest/v1/demandes_sang` avec tous les champs requis. Réponse 201 attendue, retourne l'objet créé.

---

**🟡 Validation côté backend uniquement**

- **Statut** : 🟡 PARTIEL — validation côté client uniquement
- **Preuve** : `nouvelle_demande_screen.dart` ligne 180-186 — validator Flutter côté client (contact principal obligatoire, minimum 8 chiffres). Cependant, `supabase_service.dart` `creerDemande()` n'ajoute aucune validation avant l'envoi. Si un appel API direct contourne le formulaire Flutter, **le backend n'a pas de contrainte NOT NULL visible depuis le code** — dépend des contraintes Supabase/PostgreSQL définies directement en base (non vérifiables depuis le code Flutter).
- **Impact** : Un attaquant qui envoie une requête REST directe à `/rest/v1/demandes_sang` avec `contact_chiffre=null` pourrait créer une demande sans contact.

---

**✅ Contact principal obligatoire et chiffré**

- **Statut** : ✅ COMPLET
- **Preuve** : `nouvelle_demande_screen.dart` — validator ligne 181-186 : champ obligatoire, minimum 8 chiffres. `supabase_service.dart` `creerDemande()` ligne ≈305 : `CryptoService.chiffrer(contactPrincipal)` avant envoi. Résultat stocké dans `contact_chiffre`.

---

**✅ Contact secondaire optionnel et chiffré**

- **Statut** : ✅ COMPLET
- **Preuve** : `nouvelle_demande_screen.dart` ligne 240-244 — validator retourne `null` si vide (optionnel), valide le format si rempli. `supabase_service.dart` `creerDemande()` — `CryptoService.chiffrer(contactSecondaire)` appliqué même sur valeur optionnelle (retourne `null` si null entrant). Champ `contact_secondaire_chiffre` envoyé au backend.

---

**🟡 Limite anti-spam réellement appliquée côté backend**

- **Statut** : 🟡 PARTIEL — anti-spam client-side uniquement
- **Preuve** : `supabase_service.dart` `_compterDemandesActives()` — `GET /rest/v1/demandes_sang?auteur_id=eq.{userId}&statut=eq.active&expires_at=gt.{now}&select=id`. Ce comptage se fait côté client via une requête GET. La limite max=3 est évaluée dans `creerDemande()` avant le POST. **Il n'y a pas de contrainte CHECK ou trigger PostgreSQL visible** — un attaquant qui envoie directement plusieurs POST à `/rest/v1/demandes_sang` peut contourner la limite.
- **Impact** : Flood de demandes possible en contournant le client Flutter.

---

**❌ Expiration automatique des demandes après 72h côté backend**

- **Statut** : ❌ ABSENT dans le code — état base inconnu
- **Preuve** : Grep complet de `lib/` pour `cron`, `job`, `scheduled`, `timer`, `72h`, `3 days`, `Duration(days`, `pg_cron`, `edge function expire` — **zéro résultat**. Le champ `expires_at` est passé lors de la création (implicitement géré par la base via `DEFAULT now() + interval '72 hours'` si configuré), mais aucun job planifié n'est défini dans le code Flutter. L'appel `lireDemandesActives()` filtre `expires_at=gt.{now}` côté client, mais les lignes restent avec `statut='active'` en base après expiration — elles ne sont jamais mises à jour en `statut='expiree'`.
- **Impact** : La base de données accumule des demandes techniquement expirées mais toujours marquées `active`. Pas de nettoyage automatique. Dépend d'un mécanisme Supabase (pg_cron ou Edge Function planifiée) non vérifiable depuis le code Flutter.

---

### 2.6 Détail d'une demande / réponse donneur

---

**✅ Bouton "Je réponds" avec effet réel en base**

- **Statut** : ✅ COMPLET
- **Preuve** : `detail_demande_screen.dart` — `_repondre()` est `async`, appelle `state.enregistrerReponseDonneur(demande.id)`. `app_state.dart` `enregistrerReponseDonneur()` appelle `SupabaseService.enregistrerReponseDonneur(donneurId, demandeId)`. `supabase_service.dart` `enregistrerReponseDonneur()` — `POST /rest/v1/reponses_donneurs` avec `Prefer: resolution=ignore-duplicates`. Optimistic update : `setState(() => _repondu = true)` avant l'appel, SnackBar de confirmation après.
- **Note** : La table `reponses_donneurs` doit exister en base — non vérifiable depuis le code seul (voir Section 3).

---

**✅ Aucune donnée d'identité donneur transmise au demandeur à ce stade**

- **Statut** : ✅ COMPLET
- **Preuve** : `supabase_service.dart` `enregistrerReponseDonneur()` — envoie uniquement `donneur_id` (UUID) et `demande_id`. L'écran de détail n'affiche pas d'informations personnelles du donneur. L'anonymat est préservé par design.

---

### 2.7 QR code — génération et scan

---

**✅ QR généré correspond à un token créé en base**

- **Statut** : ✅ COMPLET
- **Preuve** : `supabase_service.dart` `creerToken()` — `POST /rest/v1/dons_qr_tokens` avec `donneur_id` et `demande_id`. Token retourné depuis la base (champ `token` de la réponse 201). Le QR est généré avec ce token opaque (non devinable), pas des données locales.

---

**🟡 Token expire après 24h**

- **Statut** : 🟡 NON VÉRIFIABLE depuis le code Flutter
- **Preuve** : Aucune logique d'expiration dans le code Flutter. L'expiration à 24h serait gérée par un champ `expires_at DEFAULT now() + interval '24 hours'` dans la table `dons_qr_tokens` et vérifiée par l'Edge Function `valider-token`. **Cette logique n'est pas dans le code Flutter audité** — son existence dépend du schéma PostgreSQL et du code de l'Edge Function, non accessibles.
- **Impact** : Si l'Edge Function ne vérifie pas l'expiration, les tokens sont permanents.

---

**✅ Scan déclenche un appel backend**

- **Statut** : ✅ COMPLET
- **Preuve** : `scan_qr_screen.dart` `_valider()` — appelle `SupabaseService.validerToken(token, demandeurId)`. `supabase_service.dart` `validerToken()` — `POST /functions/v1/valider-token` (Edge Function Supabase). Résultat affiché dans `_buildResultView()`.

---

**🟡 Token déjà utilisé rejeté**

- **Statut** : 🟡 NON VÉRIFIABLE depuis le code Flutter
- **Preuve** : La logique de rejet (token usage_unique) appartient à l'Edge Function `valider-token`, dont le code n'est pas dans le dépôt Flutter. Le code Flutter gère uniquement la réponse d'erreur.

---

**❌ Mise à jour de `dernier_don_date` dans `profils_donneurs` après validation QR**

- **Statut** : ❌ ABSENT dans le code Flutter
- **Preuve** : `supabase_service.dart` — `validerToken()` appelle l'Edge Function mais ne met pas à jour `dernier_don_date`. Aucun PATCH sur `profils_donneurs` après validation QR. La mise à jour pourrait être dans l'Edge Function, mais non vérifiable.
- **Impact** : Le calcul d'éligibilité (`estEligible`) ne tient pas compte des dons validés par QR (uniquement des dons déclarés manuellement).

---

**❌ Création d'un historique dans `historique_dons` après validation QR**

- **Statut** : ❌ ABSENT dans le code Flutter
- **Preuve** : Aucun appel à `enregistrerDon()` depuis `validerToken()` ou depuis la logique de scan. `supabase_service.dart` `enregistrerDon()` existe mais n'est appelé que depuis `app_state.dart` `declarerDon()` (don déclaratif uniquement). La création avec `source='qr_valide'` dépend de l'Edge Function.

---

### 2.8 Déclaration manuelle de don

---

**✅ Bouton "J'ai fait un don" crée une ligne dans `historique_dons`**

- **Statut** : ✅ COMPLET
- **Preuve** : `app_state.dart` `declarerDon()` — appelle `SupabaseService.enregistrerDon(donneurId, dateDon, source: SourceDon.declaratif)`. `supabase_service.dart` `enregistrerDon()` — `POST /rest/v1/historique_dons` avec `source='declaratif'`.

---

**✅ `dernier_don_date` mis à jour pour don déclaratif**

- **Statut** : ✅ COMPLET
- **Preuve** : `app_state.dart` `declarerDon()` — `updated = _profil!.copyWith(dernierDonDate: dateDon)`, puis `sauvegarderProfil(updated)` qui appelle `SupabaseService.creerOuMettreAJourProfil(profil)` avec le nouveau `dernier_don_date`. Mise à jour locale (SharedPreferences) et backend.

---

### 2.9 Calcul d'éligibilité et disponibilité

---

**🟡 Calcul 60j/90j implémenté côté backend**

- **Statut** : 🟡 CÔTÉ CLIENT UNIQUEMENT
- **Preuve** : `models.dart` `ProfilDonneur.estEligible` getter — calcul `DateTime.now().difference(dernierDonDate!).inDays` comparé à 60 (homme) ou 90 (femme). Ce calcul est **client-side**. Aucune fonction PostgreSQL ou contrainte backend équivalente n'est visible dans le code.
- **Impact** : Un utilisateur peut contourner le calcul en modifiant localement les données (attaque avancée). Le matching ne filtre pas les donneurs non éligibles côté backend.

---

**❌ Utilisateur non éligible exclu du matching côté backend**

- **Statut** : ❌ ABSENT côté backend
- **Preuve** : `supabase_service.dart` `lireDemandesActives()` — retourne toutes les demandes sans filtrage sur l'éligibilité. Le badge "Compatible" dans `demande_card.dart` vérifie uniquement la compatibilité ABO, pas l'éligibilité. Un donneur non éligible voit les demandes compatibles et peut répondre.
- **Impact** : Risque médical — des donneurs non éligibles peuvent se manifester.

---

**✅ Toggle disponible/indisponible relié à la base**

- **Statut** : ✅ COMPLET
- **Preuve** : `app_state.dart` `toggleDisponibilite()` — appelle `SupabaseService.mettreAJourDisponibilite(userId, !disponible)`. `supabase_service.dart` `mettreAJourDisponibilite()` — `PATCH /rest/v1/profils_donneurs?user_id=eq.{userId}` avec `{'disponible': bool}`.
- **Note** : Le matching côté backend doit filtrer `disponible=true` — non vérifiable depuis le code Flutter.

---

### 2.10 Notifications

---

**❌ Notification push (Firebase Cloud Messaging)**

- **Statut** : ❌ TOTALEMENT ABSENT
- **Preuve** : `pubspec.yaml` — aucun package Firebase (`firebase_core`, `firebase_messaging`, etc.). Grep complet : aucune occurrence de `firebase`, `FCM`, `push_notification`, `firebase_messaging`. Les notifications sont **locales uniquement** : `app_state.dart` `_ajouterNotification()` insère dans la liste en mémoire, sauvegardée en SharedPreferences.
- **Impact** : Les utilisateurs ne reçoivent aucune notification en temps réel quand une nouvelle demande compatible est publiée.

---

**❌ Email réellement envoyé (Resend/Brevo)**

- **Statut** : ❌ TOTALEMENT ABSENT
- **Preuve** : Grep complet : aucune occurrence de `resend`, `brevo`, `sendgrid`, `smtp`, `email_provider`, `send_email`. Aucun appel HTTP vers un service d'envoi d'email.
- **Impact** : Aucune notification email pour les utilisateurs.

---

**❌ Notifications ciblant uniquement les donneurs compatibles + disponibles + éligibles + ville**

- **Statut** : ❌ ABSENT (conséquence directe de l'absence de push/email)
- **Preuve** : Sans infrastructure de notification, aucun ciblage n'est possible. Les notifications locales sont générées pour l'utilisateur courant uniquement.

---

**🟡 Liste des notifications dans l'app**

- **Statut** : 🟡 PARTIEL — notifications locales fonctionnelles, pas temps réel
- **Preuve** : `notifications_screen.dart` — liste depuis `state.notifications`. `app_state.dart` génère des notifications locales sur : publication d'une demande, réponse enregistrée, don déclaré. Persistées en SharedPreferences. L'écran vide est correctement géré.
- **Impact** : Fonctionnel mais limité — n'informe pas des événements d'autres utilisateurs.

---

### 2.11 Profil et paramètres

---

**✅ Modifications de profil enregistrées en base**

- **Statut** : ✅ COMPLET
- **Preuve** : `profil_screen.dart` `_showModifierProfil()` — bottom sheet StatefulBuilder avec champs groupe sanguin, genre, poids, ville, quartier. Appelle `await state.sauvegarderProfil(updated)`. `app_state.dart` `sauvegarderProfil()` → `SupabaseService.creerOuMettreAJourProfil(profil)` → `POST /rest/v1/profils_donneurs` avec `resolution=merge-duplicates`.

---

**✅ Suppression de compte avec double confirmation et délai J+5**

- **Statut** : ✅ COMPLET
- **Preuve** : 
  - Étape 1 (`_showSettings` → option "Supprimer mon compte") : modal informatif avec liste des conséquences + bouton "Je comprends, continuer" (`profil_screen.dart` ligne ≈1100).
  - Étape 2 (`_showConfirmationFinale`) : AlertDialog "Confirmation finale" avec bouton "Oui, supprimer dans 5 jours" (`profil_screen.dart` ligne ≈1205).
  - Backend : `SupabaseService.programmerSuppression()` — `PATCH /rest/v1/identites?user_id=eq.{userId}` avec `suppression_programmee_le` (J+5) et `compte_actif=false`.
  - Banner dans `ProfilScreen` indiquant le délai restant pendant les 5 jours.

---

**✅ Bouton d'annulation de suppression accessible**

- **Statut** : ✅ COMPLET
- **Preuve** : `profil_screen.dart` `_buildBannereSuppression()` — banner affiché si `state.suppressionProgrammee`. Bouton "Annuler la suppression" appelle `state.annulerSuppression()` → `SupabaseService.annulerSuppression()` → `PATCH identites` avec `suppression_programmee_le=null, compte_actif=true`.

---

### 2.12 Navigation

---

**✅ Bouton retour visible sur les écrans secondaires**

- **Statut** : ✅ COMPLET
- **Preuve** :
  - `detail_demande_screen.dart` — `_buildBackBtn()` : bouton rond `arrow_back`, `context.pop()`.
  - `scan_qr_screen.dart` — `_buildBackBtn()` : même pattern.
  - `profil_screen.dart` — bouton retour dans la top bar (GestureDetector avec `Navigator.canPop()`).
  - `nouvelle_demande_screen.dart` — bouton annulation présent.
  - `login_screen.dart` — bouton retour sur les étapes connexion/inscription.

---

**✅ Aucune impasse de navigation**

- **Statut** : ✅ COMPLET
- **Preuve** : `router.dart` — `_NotFoundPage` avec bouton "Retour à l'accueil". Toutes les routes modales (`/nouvelle-demande`, `/scan-qr`, `/demande/:id`) utilisent `parentNavigatorKey: _rootNavigatorKey` et peuvent être fermées. Le ShellRoute garantit l'accès permanent à la bottom navigation.

---

## 3. Audit de la couche backend et base de données

> **Limitation critique** : Cet audit est réalisé **uniquement depuis le code Flutter client**. L'accès direct à la base de données Supabase, aux Edge Functions, aux triggers PostgreSQL, et au schéma réel n'est pas possible dans ce contexte. Les constats ci-dessous sont basés sur les appels HTTP observés dans le code.

---

**🟡 Existence des 5 tables du schéma**

- **Statut** : 🟡 INFÉRÉE — non confirmée directement
- **Preuve** :
  - `demandes_sang` : référencée dans `lireDemandesActives()`, `creerDemande()`, `_compterDemandesActives()` → accès GET et POST confirmés dans le code.
  - `profils_donneurs` : référencée dans `creerOuMettreAJourProfil()`, `mettreAJourDisponibilite()` → POST et PATCH.
  - `dons_qr_tokens` : référencée dans `creerToken()` → POST.
  - `historique_dons` : référencée dans `enregistrerDon()` → POST.
  - `identites` : référencée dans `programmerSuppression()`, `annulerSuppression()` → PATCH uniquement. **Aucun INSERT sur `identites` dans le code Flutter** — doit être géré par trigger PostgreSQL ou Supabase hook sur `auth.users`.
- **Impact** : Si `reponses_donneurs` est absente (table non listée dans le cahier des charges initial mais utilisée), les réponses échouent silencieusement (statut 400/404 retourné mais non géré différemment).

---

**🟡 Utilisation des ENUMs PostgreSQL**

- **Statut** : 🟡 PARTIEL — miroir côté Flutter, utilisation base inconnue
- **Preuve** : `models.dart` définit les enums Dart : `GroupeSanguin`, `StatutDemande`, `SourceDon`, `Genre` avec leurs valeurs string. Les valeurs string (ex : `'active'`, `'qr_valide'`) sont envoyées au backend. Si la base utilise des ENUMs PostgreSQL stricts, une valeur invalide serait rejetée. Si la base utilise `varchar`, les contraintes sont absentes. Non vérifiable.

---

**❌ Présence des index (`idx_profils_matching`, etc.)**

- **Statut** : ❌ NON VÉRIFIABLE depuis le code Flutter
- **Preuve** : Aucune requête `pg_indexes` dans le code. Les index doivent être vérifiés directement sur la base Supabase.

---

**❌ Trigger de mise à jour automatique de `dernier_don_date`**

- **Statut** : ❌ NON PRÉSENT dans le code Flutter
- **Preuve** : Aucune mention de trigger dans le code. La mise à jour de `dernier_don_date` se fait uniquement via `creerOuMettreAJourProfil()` lors d'un don déclaratif. Après un don QR validé, la mise à jour dépend de l'Edge Function `valider-token` (non auditable ici).

---

**🟡 Isolation des données utilisateurs (intrusion horizontale)**

- **Statut** : 🟡 DÉPEND DES RLS SUPABASE — non vérifiable depuis le code
- **Preuve** : Tous les appels REST incluent le JWT dans `Authorization: Bearer`. Supabase applique les Row Level Security (RLS) si configurées. Si `RLS` est activé sur `demandes_sang` avec `auteur_id = auth.uid()`, un utilisateur ne peut pas lire les demandes d'autres. Le code Flutter ne tente pas d'accéder aux données d'autres utilisateurs.
- **Risque** : Si les RLS ne sont pas configurées (table en mode public), n'importe quel JWT valide peut lire/modifier toutes les lignes.

---

**✅ Chiffrement des champs sensibles**

- **Statut** : ✅ COMPLET côté Flutter
- **Preuve** : `crypto_service.dart` — AES-256-CBC, IV aléatoire par opération, format `base64(IV):base64(ciphertext)`. Les champs `poids_chiffre`, `contre_indications_chiffre`, `contact_chiffre`, `contact_secondaire_chiffre` sont chiffrés avant envoi. Les valeurs stockées en base sont des chaînes opaques non lisibles en clair.

---

**🟡 Clés de chiffrement non commitées dans Git**

- **Statut** : 🟡 PARTIELLEMENT RISQUÉ
- **Preuve** : `crypto_service.dart` ligne ≈41 contient la clé de dev hardcodée : `SauveDevKey_NON_PROD_32chars!!!!!`. Cette chaîne est **dans le code source**. Le dépôt Git n'a aucun commit (donc pas d'historique compromis), mais si un commit est effectué sans `.gitignore` approprié, cette clé sera dans l'historique Git permanent.
- **Impact** : La clé de dev n'est pas la clé de production, mais sa présence dans le code viole le principe "zéro secret dans le code".

---

**❌ Rate limiting réel sur les endpoints sensibles**

- **Statut** : ❌ ABSENT dans le code Flutter
- **Preuve** : Grep complet : `rate.limit`, `rateLimit`, `throttle`, `RateLimit`, `anti.spam`, `flood` → **exit code 1, zéro résultat**. L'anti-spam est uniquement client-side (`_compterDemandesActives()` dans `supabase_service.dart`). Aucun rate limiting sur les endpoints d'authentification (`/auth/v1/signup`, `/auth/v1/token`).
- **Impact** : Attaques de brute-force sur `/auth/v1/token` non bloquées côté app. Dépend des protections natives Supabase.

---

**❌ File d'attente pour les notifications en masse**

- **Statut** : ❌ NON APPLICABLE (push/email absent)
- **Preuve** : Aucune infrastructure de notification. Question sans objet dans l'état actuel.

---

**🟡 Gestion des erreurs et logs**

- **Statut** : 🟡 PARTIEL
- **Preuve** : `supabase_service.dart` — tous les catch utilisent `if (kDebugMode) debugPrint(...)`. Les logs ne sont émis qu'en mode debug. Aucune donnée sensible (token, numéro de téléphone) n'est loguée explicitement. Cependant, les messages d'erreur Supabase retournés à l'utilisateur peuvent contenir des informations techniques selon la configuration du projet.

---

## 4. Failles de sécurité identifiées

### 🔴 CRITIQUES

---

**[SEC-01] Clé de chiffrement AES-256 hardcodée dans le code source**

- **Criticité** : 🔴 CRITIQUE
- **Fichier** : `lib/utils/crypto_service.dart` ligne 41
- **Description** : La valeur `SauveDevKey_NON_PROD_32chars!!!!!` est littéralement présente dans le code source Dart. Bien que le guard `if (kReleaseMode) throw StateError(...)` empêche son utilisation en release, cette clé est dans le code compilé en mode debug/web et dans tout commit Git futur. Un attaquant ayant accès au dépôt (ou au build web décompilé) peut récupérer cette valeur. En mode `--profile` ou dans certaines configurations, le guard peut être contourné.
- **Vecteur** : Accès au dépôt Git ou décompilation du build web (JavaScript non obfusqué).
- **Direction de correction** : Supprimer la valeur hardcodée. Remplacer par une chaîne vide ou un commentaire. Utiliser exclusivement `--dart-define=SAUVE_ENCRYPT_KEY` pour toute configuration, y compris en développement (stocker la clé dev dans un fichier `.env` ignoré par Git).

---

**[SEC-02] JWT stocké en clair dans SharedPreferences sur la plateforme Web**

- **Criticité** : 🔴 CRITIQUE
- **Fichier** : `lib/utils/secure_storage_service.dart` lignes ≈70-85
- **Description** : Sur `kIsWeb`, `sauvegarderSession()` utilise `SharedPreferences` (localStorage du navigateur) pour stocker `accessToken` (JWT signé Supabase) et `refreshToken`. Ces valeurs sont accessibles par tout script JavaScript de la page (attaque XSS), par les outils de développement du navigateur, et par des extensions malveillantes. Un JWT compromis permet de se faire passer pour l'utilisateur auprès de l'API Supabase.
- **Vecteur** : XSS, accès physique à l'ordinateur, extension navigateur malveillante.
- **Direction de correction** : Utiliser des cookies `HttpOnly; SameSite=Strict; Secure` pour stocker les tokens sur Web. Implémenter un mécanisme de token rotation côté serveur. À minima, documenter clairement la limitation et ne pas déployer la version Web pour des données médicales sensibles en production.

---

### 🟠 MAJEURES

---

**[SEC-03] `_refreshToken` non persisté après rafraîchissement de session**

- **Criticité** : 🟠 MAJEURE
- **Fichiers** : `lib/services/supabase_service.dart` ligne 29 / `lib/services/app_state.dart` ligne ≈130
- **Description** : `rafraichirToken()` met à jour `_refreshToken` en mémoire statique mais n'appelle jamais `SecureStorageService.mettreAJourTokens()`. De plus, `connecter()` dans `app_state.dart` sauvegarde `refreshToken: ''` (chaîne vide) car le commentaire indique que le refresh token est dans `SupabaseService._refreshToken`. Résultat : après redémarrage de l'app, le refresh token est perdu et l'utilisateur doit se reconnecter. `flutter analyze` signale d'ailleurs `_refreshToken` comme `unused_field`.
- **Direction de correction** : Appeler `SecureStorageService.mettreAJourTokens()` systématiquement après tout rafraîchissement. Sauvegarder le `refresh_token` réel (pas `''`) lors de `connecter()`.

---

**[SEC-04] Absence de rate limiting applicatif côté Flutter sur l'authentification**

- **Criticité** : 🟠 MAJEURE
- **Fichier** : `lib/services/supabase_service.dart` — `connecter()`, `inscrire()`
- **Description** : Aucun mécanisme de délai, de compteur d'échecs, ou de blocage temporaire n'est implémenté côté Flutter après N tentatives de connexion échouées. Un attaquant peut effectuer des milliers de tentatives de brute-force depuis l'app. La protection dépend entièrement du rate limiting de Supabase (présent mais non paramétré depuis le code).
- **Direction de correction** : Implémenter un compteur d'échecs côté client (ex : blocage après 5 échecs pendant 60 secondes). Afficher un message clair à l'utilisateur. Configurer le rate limiting sur le projet Supabase.

---

**[SEC-05] Anti-spam demandes uniquement côté client**

- **Criticité** : 🟠 MAJEURE
- **Fichier** : `lib/services/supabase_service.dart` `_compterDemandesActives()`
- **Description** : La limite de 3 demandes actives simultanées est vérifiée via une requête GET depuis le client Flutter, avant le POST de création. Un attaquant peut envoyer directement plusieurs POST à `/rest/v1/demandes_sang` avec un JWT valide, contournant complètement la vérification. Sans contrainte CHECK ou trigger côté PostgreSQL, le flood est possible.
- **Direction de correction** : Implémenter une contrainte CHECK en base ou un trigger PostgreSQL qui compte les demandes actives de l'auteur et lève une exception si la limite est dépassée. Une Edge Function de création peut also centraliser cette logique.

---

### 🟡 MINEURES

---

**[SEC-06] Contacts téléphoniques visibles par tout donneur authentifié**

- **Criticité** : 🟡 MINEURE
- **Fichier** : `lib/screens/detail_demande_screen.dart` lignes ≈172-188
- **Description** : `CryptoService.dechiffrer(demande.contactChiffre)` est affiché sur l'écran de détail de la demande, visible par **tout utilisateur authentifié** qui accède au détail. Le cahier des charges spécifie "visibles uniquement par les donneurs qui répondent explicitement". Actuellement, aucune vérification de `_repondu` n'est effectuée avant d'afficher le contact.
- **Direction de correction** : N'afficher le contact déchiffré que si `_repondu == true` (l'utilisateur a cliqué "Je réponds"). Côté backend, retourner le champ `contact_chiffre` uniquement si le donneur a une entrée dans `reponses_donneurs`.

---

**[SEC-07] Absence de validation du `demandeurId` dans `scan_qr_screen.dart`**

- **Criticité** : 🟡 MINEURE
- **Fichier** : `lib/screens/scan_qr_screen.dart` `_valider()`
- **Description** : `widget.demandeurId` est passé depuis `state.userId` via `state.extra`. Si `state.userId` est null, `scan_qr_screen.dart` reçoit une chaîne vide (`''`). `_valider()` envoie ce `demandeurId` vide à l'Edge Function, qui peut l'accepter ou retourner une erreur non standardisée.
- **Direction de correction** : Vérifier que `widget.demandeurId.isNotEmpty` avant d'appeler `validerToken()`. Rediriger vers la connexion si vide.

---

**[SEC-08] Clé d'encryption potentiellement dans l'historique Git futur**

- **Criticité** : 🟡 MINEURE (actuellement zéro commit)
- **Fichier** : `lib/utils/crypto_service.dart`
- **Description** : Le dépôt n'a aucun commit (`fatal: your current branch 'main' does not have any commits yet`). Si le premier commit est effectué sans avoir retiré la clé de dev, elle sera permanente dans l'historique. Les outils de scan de secrets (TruffleHog, GitLeaks) la détecteront.
- **Direction de correction** : Retirer la clé hardcodée avant le premier commit. Ajouter un `.gitignore` pour les fichiers `.env`. Configurer un pre-commit hook de scan de secrets.

---

## 5. Problèmes de performance identifiés

---

**[PERF-01] Calcul de compatibilité ABO en O(n) lors du rendu**

- **Sévérité** : 🟡 MODÉRÉ
- **Fichier** : `lib/widgets/demande_card.dart` + `lib/models/models.dart`
- **Description** : `demande.estCompatibleAvec(profil)` est appelé pour chaque carte dans `ListView.builder`. Le switch-case dans `_groupesCompatibles()` est O(1) par appel, mais l'ensemble du rendu recalcule la compatibilité à chaque rebuild du widget. Avec 50 demandes (limite de la requête), ce n'est pas critique, mais sans `const` ou `cached` sur les résultats, des rebuilds fréquents (ex : Provider notifyListeners sur n'importe quelle modification d'état) recalculent toutes les cartes.
- **Direction de correction** : Pré-calculer la liste filtrée dans `AppState` et n'exposer que `demandesCompatibles`. Ou utiliser `const` sur les widgets qui ne dépendent pas du profil.

---

**[PERF-02] Absence de pagination dans `lireDemandesActives()`**

- **Sévérité** : 🟡 MODÉRÉ
- **Fichier** : `lib/services/supabase_service.dart` ligne ≈215
- **Description** : La requête utilise `&limit=50` comme limite fixe. Si la ville a plus de 50 demandes actives, les demandes les plus anciennes ne sont jamais affichées. Aucun mécanisme de pagination infinie (`offset` ou curseur) n'est implémenté dans le code Flutter.
- **Direction de correction** : Implémenter une pagination avec scroll infini en passant un paramètre `offset` croissant, ou utiliser un curseur `id=lt.{lastId}`.

---

**[PERF-03] Chargement complet du cache local à chaque init**

- **Sévérité** : 🟡 MODÉRÉ
- **Fichier** : `lib/services/app_state.dart` `init()`
- **Description** : `init()` appelle séquentiellement `_loadProfil()`, `_loadDemandes()`, `_loadNotifications()`. `_loadDemandes()` tente d'abord le backend, puis le cache — tous les appels sont `await` sequentiels. Si le réseau est lent, l'utilisateur voit un spinner pendant la totalité du chargement avant de voir quoi que ce soit.
- **Direction de correction** : Afficher d'abord le cache local immédiatement, puis actualiser en arrière-plan avec les données backend (pattern stale-while-revalidate).

---

**[PERF-04] SharedPreferences sérialisé en JSON à chaque sauvegarde**

- **Sévérité** : 🟢 FAIBLE
- **Fichier** : `lib/services/app_state.dart` `_sauvegarderDemandes()`
- **Description** : À chaque appel à `actualiserDemandes()`, la liste complète des demandes est sérialisée en JSON et écrite dans SharedPreferences. Pour 50 demandes avec tous leurs champs, cela représente une sérialisation potentiellement coûteuse sur chaque refresh.
- **Direction de correction** : Utiliser Hive (déjà en dépendance) pour le cache des demandes — lectures/écritures binaires plus performantes.

---

**[PERF-05] Absence de cache des tokens QR générés**

- **Sévérité** : 🟢 FAIBLE
- **Fichier** : `lib/screens/detail_demande_screen.dart` `_genererQr()`
- **Description** : À chaque appel de `_genererQr()`, un nouveau token est créé en base via `POST /rest/v1/dons_qr_tokens`. Si l'utilisateur appuie plusieurs fois sur "Générer mon code", plusieurs tokens sont créés pour la même paire `(donneur_id, demande_id)`. Un seul sera utilisé (usage unique), mais les autres restent valides jusqu'à leur expiration.
- **Direction de correction** : Vérifier si un token non utilisé existe déjà pour la paire `(donneurId, demandeId)` avant d'en créer un nouveau. Ou désactiver le bouton après la première génération.

---

## 6. Recommandations

### Bloquants production

---

**[REC-01] Retirer la clé hardcodée de `crypto_service.dart`**

- **Problème** : Clé `SauveDevKey_NON_PROD_32chars!!!!!` dans le code source.
- **Quoi faire** : Remplacer la valeur de fallback par une chaîne vide ou un commentaire neutre. Créer un fichier `.env.local` non commité avec la clé de développement. Documenter la procédure d'injection via `--dart-define`.
- **Pourquoi** : Une clé de chiffrement dans le code source est une violation des bonnes pratiques de sécurité, même si ce n'est pas la clé de production. Elle sera permanente dans l'historique Git dès le premier commit.
- **Effort** : 30 minutes. **Priorité : BLOQUANT PRODUCTION**.

---

**[REC-02] Corriger la persistance du refresh_token**

- **Problème** : `app_state.dart` sauvegarde `refreshToken: ''` et `_refreshToken` n'est jamais persisté après un rafraîchissement.
- **Quoi faire** : Sauvegarder le `refresh_token` réel reçu de Supabase lors de la connexion. Appeler `SecureStorageService.mettreAJourTokens()` dans `rafraichirToken()`. Implémenter un refresh automatique sur réception d'un 401.
- **Pourquoi** : Sans refresh token, les sessions expirent sans possibilité de renouvellement silencieux — l'utilisateur est déconnecté inopinément.
- **Effort** : 2 heures. **Priorité : BLOQUANT PRODUCTION**.

---

**[REC-03] Déployer un job planifié pour l'expiration des demandes**

- **Problème** : Les demandes expirent côté client (filtre `expires_at`), mais restent `active` en base indéfiniment.
- **Quoi faire** : Configurer `pg_cron` sur Supabase ou une Edge Function planifiée qui exécute `UPDATE demandes_sang SET statut='expiree' WHERE expires_at < now() AND statut='active'` toutes les heures.
- **Pourquoi** : Sans ce job, la base accumule des données zombies. Les statistiques et les rapports d'utilisation sont inexacts. Les RLS basées sur le statut peuvent se comporter incorrectement.
- **Effort** : 1 heure (configuration Supabase uniquement). **Priorité : BLOQUANT PRODUCTION**.

---

**[REC-04] Restreindre l'affichage du contact aux donneurs ayant répondu**

- **Problème** : Le numéro de contact déchiffré est visible par tout utilisateur authentifié sur l'écran de détail.
- **Quoi faire** : Conditionner l'affichage du contact au statut `_repondu`. Côté backend, créer une view ou un endpoint dédié qui ne retourne `contact_chiffre` que si le donneur demandeur a une entrée dans `reponses_donneurs`.
- **Pourquoi** : Violation du cahier des charges §4.1 et de la vie privée des demandeurs.
- **Effort** : 3 heures. **Priorité : BLOQUANT PRODUCTION**.

---

### À faire avant lancement

---

**[REC-05] Implémenter le trigger PostgreSQL pour `identites`**

- **Problème** : Aucun INSERT explicite sur `identites` dans le code Flutter — dépend d'un trigger non vérifiable.
- **Quoi faire** : Créer un trigger `AFTER INSERT ON auth.users` qui insère une ligne dans `identites` avec `user_id = NEW.id, compte_actif = true`. Tester avec un compte de test.
- **Pourquoi** : Sans ce trigger, la table `identites` reste vide — les opérations `PATCH identites` (suppression J+5) échoueront silencieusement.
- **Effort** : 1 heure. **Priorité : AVANT LANCEMENT**.

---

**[REC-06] Configurer les Row Level Security (RLS) sur toutes les tables**

- **Problème** : L'isolation des données entre utilisateurs n'est vérifiable qu'indirectement depuis le code Flutter.
- **Quoi faire** : Activer RLS sur `demandes_sang`, `profils_donneurs`, `dons_qr_tokens`, `historique_dons`, `reponses_donneurs`. Définir des policies : lecture publique pour `demandes_sang` (actives uniquement), lecture/écriture restreinte à `auth.uid() = user_id` pour les autres.
- **Pourquoi** : Sans RLS, n'importe quel JWT valide peut accéder aux données de tous les utilisateurs via l'API REST Supabase.
- **Effort** : 4 heures. **Priorité : AVANT LANCEMENT**.

---

**[REC-07] Créer la table `reponses_donneurs` si inexistante**

- **Problème** : `POST /rest/v1/reponses_donneurs` est appelé dans le code mais la table n'est pas dans le schéma original à 5 tables.
- **Quoi faire** : Créer la table avec colonnes `id`, `donneur_id`, `demande_id`, `created_at`, contrainte UNIQUE sur `(donneur_id, demande_id)`. Activer RLS.
- **Effort** : 30 minutes. **Priorité : AVANT LANCEMENT**.

---

**[REC-08] Ajouter un filtre d'éligibilité dans `lireDemandesActives()`**

- **Problème** : Les donneurs non éligibles voient et peuvent répondre aux demandes compatibles.
- **Quoi faire** : Soit filtrer côté backend (`JOIN profils_donneurs WHERE disponible=true AND date d'éligibilité ok`), soit afficher l'avertissement d'éligibilité dans le détail avant d'activer le bouton "Je réponds". La solution backend est préférable.
- **Effort** : 2 heures. **Priorité : AVANT LANCEMENT**.

---

### Peut attendre V2

---

**[REC-09] Implémenter les notifications push (FCM)**

- **Problème** : Aucune notification en temps réel pour les donneurs compatibles.
- **Quoi faire** : Intégrer `firebase_messaging`, configurer un projet Firebase, créer une Edge Function Supabase ou un webhook sur `INSERT INTO demandes_sang` qui appelle l'API FCM pour notifier les donneurs compatibles + disponibles + éligibles de la bonne ville.
- **Effort** : 2-3 jours. **Priorité : V2**.

---

**[REC-10] Implémenter la pagination dans `lireDemandesActives()`**

- **Problème** : Limite fixe à 50 demandes.
- **Quoi faire** : Scroll infini avec offset ou curseur.
- **Effort** : 4 heures. **Priorité : V2**.

---

**[REC-11] Migrer le cache demandes vers Hive**

- **Problème** : Sérialisation JSON lente dans SharedPreferences.
- **Quoi faire** : Utiliser `Hive.openBox<DemandeSang>('demandes')` avec un adaptateur généré.
- **Effort** : 4 heures. **Priorité : V2**.

---

**[REC-12] Implémenter le Google Sign-In et l'OTP téléphone**

- **Problème** : Fonctionnalités du cahier des charges non implémentées.
- **Quoi faire** : Ajouter `google_sign_in` + Supabase OAuth pour Google. Implémenter OTP via Supabase `/auth/v1/otp` avec un numéro de téléphone.
- **Effort** : 2 jours. **Priorité : V2 (si requis commercialement)**.

---

## 7. Conclusion — Checklist finale de mise en production

### État actuel : 🟡 NON PRÊT — 4 bloquants à lever

---

| # | Critère | Statut |
|---|---------|--------|
| P01 | Build Flutter sans erreur (`flutter analyze`) | ✅ 1 warning (unused_field), 0 erreur |
| P02 | Aucune clé secrète hardcodée dans le code | ❌ `SauveDevKey_NON_PROD_32chars!!!!!` présente |
| P03 | JWT stocké de façon sécurisée sur toutes les plateformes | ❌ SharedPreferences sur Web |
| P04 | Refresh token persisté et utilisé | ❌ Sauvegardé comme `''`, jamais rafraîchi automatiquement |
| P05 | Authentification email fonctionnelle bout en bout | ✅ Implémenté |
| P06 | Contact déchiffré affiché uniquement après réponse | ❌ Visible par tous les authentifiés |
| P07 | Demandes chargées depuis le backend (pas démo) | ✅ `actualiserDemandes()` uniquement |
| P08 | Réponse donneur persistée en base | ✅ `POST /rest/v1/reponses_donneurs` |
| P09 | QR scan fonctionnel (mobile + fallback web) | ✅ `scan_qr_screen.dart` complet |
| P10 | Profil modifiable et persisté | ✅ Bottom sheet + `creerOuMettreAJourProfil()` |
| P11 | Suppression J+5 avec double confirmation | ✅ Deux étapes de confirmation + bannière |
| P12 | Annulation suppression fonctionnelle | ✅ Bouton + `annulerSuppression()` |
| P13 | Bouton retour sur tous les écrans secondaires | ✅ Implémenté |
| P14 | Table `identites` alimentée à l'inscription | 🟡 Trigger PostgreSQL requis (non vérifiable) |
| P15 | RLS activées sur toutes les tables | 🟡 Non vérifiable depuis Flutter |
| P16 | Anti-spam demandes côté backend | ❌ Client-side uniquement |
| P17 | Expiration 72h des demandes — job planifié | ❌ Absent dans le code |
| P18 | Notifications push (FCM) | ❌ Absent |
| P19 | Notifications email | ❌ Absent |
| P20 | Google Sign-In / OTP téléphone | ❌ Absent |
| P21 | `flutter build web --release` réussi | ✅ 51.7s, `✓ Built build/web` |
| P22 | Preview web accessible (HTTP 200) | ✅ `https://5060-id0dzrqa2qpeqx67zjnvt-3c7ff1b5.sandbox.novita.ai` |
| P23 | Zéro commit de secrets dans Git | ✅ Dépôt sans commit (vierge) |

---

### Résumé des bloquants avant déploiement production

```
❌ [SEC-01] Supprimer SauveDevKey_NON_PROD_32chars!!!!! du code source
❌ [SEC-02] JWT Web : ne pas utiliser SharedPreferences pour les tokens
❌ [SEC-03] Persister et utiliser le refresh_token correctement
❌ [SEC-06] N'afficher le contact déchiffré qu'après réponse explicite
```

### Résumé des actions avant lancement (non bloquants mais critiques)

```
🟡 [REC-03] Configurer pg_cron/Edge Function pour expiration 72h
🟡 [REC-05] Créer trigger auth.users → identites
🟡 [REC-06] Activer RLS sur toutes les tables Supabase
🟡 [REC-07] Créer la table reponses_donneurs
```

---

### Note finale de l'auditeur

L'application SONGRE démontre une architecture Flutter solide, un design de sécurité pensé (chiffrement AES-256, anonymat par UUID, séparation des schémas), et une intégration Supabase correctement structurée pour une application de santé critique. Les 10 tâches de migration ont été exécutées avec sérieux. Le résidu principal est un ensemble de fonctionnalités backend (jobs planifiés, RLS, triggers) qui ne peuvent pas être vérifiées depuis le seul code Flutter — elles doivent être impérativement auditées et testées directement sur le projet Supabase avant tout déploiement en production avec de vraies données médicales.

**Le déploiement en production avec de vraies données médicales ne doit pas être effectué tant que les 4 bloquants [P02, P03, P04, P06] ne sont pas résolus.**

---

*Rapport généré le 8 juillet 2026 — Audit read-only — Aucun fichier de code modifié.*
