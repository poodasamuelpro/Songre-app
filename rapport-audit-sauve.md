# Rapport d'audit production — Application Sauve

| Champ | Valeur |
|---|---|
| **Date de l'audit** | Session courante (après corrections Phase 2) |
| **Version du code auditée** | Commit post-corrections — `flutter analyze` : 0 issues |
| **Auditeur** | Analyse statique exhaustive ligne-par-ligne (16 fichiers Dart + pubspec.yaml) |
| **Périmètre** | Frontend Flutter complet + couche service Supabase REST + modèles + navigation |
| **Backend réel** | **Non accessible** — aucune instance Supabase fournie, aucun accès à la base de données, aucun test d'intrusion réel possible |

---

## 1. Synthèse exécutive

### Verdict global : 🟡 **Partiellement prêt — NON prêt pour la production en l'état**

L'application est visuellement complète, bien architecturée et compile sans erreur. Cependant, elle repose quasi-intégralement sur des données de démonstration codées en dur. Aucun flux de données réel frontend → backend → base de données n'a pu être vérifié bout en bout, faute d'instance Supabase active. Plusieurs failles de sécurité bloquantes pour une application de santé critique ont été identifiées.

### Comptage par statut

| Statut | Nombre de points audités |
|---|---|
| ✅ Complet et fonctionnel (code présent + logique cohérente) | **14** |
| 🟡 Partiel (code présent mais limites importantes) | **21** |
| ❌ Absent (aucun code, aucune trace) | **13** |

### Failles de sécurité identifiées

| Priorité | Nombre |
|---|---|
| 🔴 Critique | 3 |
| 🟠 Majeure | 4 |
| 🟡 Mineure | 3 |

---

## 2. Détail fonctionnalité par fonctionnalité

### 2.1 Inscription et authentification

#### Connexion Google Sign-In
**❌ Absent**
Aucune dépendance `google_sign_in` dans `pubspec.yaml`. Aucun import ni appel dans aucun fichier Dart. Le commentaire dans `supabase_service.dart` ligne 48 indique explicitement : `// En V2 : remplacer par Google Sign-In / OTP téléphone`. Le bouton "Commencer" dans `login_screen.dart` déclenche uniquement la création d'un UUID anonyme.

#### Connexion par téléphone OTP
**❌ Absent**
Aucune dépendance OTP. Aucun champ de saisie de numéro de téléphone pour l'authentification. Aucun appel SMS dans aucun fichier. Même commentaire `// En V2` dans `supabase_service.dart`.

#### Création d'une ligne dans `identites` à l'inscription
**🟡 Partiel**
Le code existe dans `supabase_service.dart` lignes 60–73 : POST vers `/rest/v1/identites` avec `user_id`, `auth_provider: 'anonymous'`, `compte_actif: true`. Cependant, le test de fonctionnement réel est impossible sans instance Supabase. En mode démo (`!estConfigured`), la ligne n'est jamais insérée réellement — `_sessionToken = 'DEMO_TOKEN_$userId'` (ligne 54) simule une session locale.

#### Génération UUID v4 non séquentiel
**✅ Complet**
`app_state.dart` ligne 28 : `final _uuid = const Uuid()`. Ligne 72 : `final newId = _uuid.v4()`. Le package `uuid: ^4.3.3` utilise RFC 4122 UUID v4 (aléatoire, non séquentiel). Preuve directe : `pubspec.yaml` ligne 31.

#### Création d'une ligne dans `profils_donneurs`
**🟡 Partiel**
Code présent dans `supabase_service.dart` lignes 99–126 : POST vers `/rest/v1/profils_donneurs` avec upsert (`resolution=merge-duplicates`). Les champs sensibles sont chiffrés avant envoi (`poids_chiffre`, `contre_indications_chiffre`). Toutefois, aucun test en base réelle possible. En mode démo, aucune ligne n'est insérée.

#### Formulaire de profil (groupe sanguin, poids, genre, ville, contre-indications)
**🟡 Partiel**
Le formulaire existe dans `login_screen.dart` et est complet visuellement (tous les champs présents, validateur pour le poids lignes 426–432). L'appel `sauvegarderProfil()` → `SupabaseService.creerOuMettreAJourProfil()` est en place. Cependant : (a) la persistance en base est non vérifiable ; (b) en mode démo, le profil n'est enregistré que dans `SharedPreferences` via `_keyProfil`.

**Note critique** : la ville est stockée en clair dans `profils_donneurs` (champ `ville` non chiffré), ce qui est cohérent avec son usage comme filtre de matching, mais à documenter dans la politique de confidentialité.

#### Gestion des erreurs d'inscription
**🟡 Partiel**
L'échec réseau est géré dans `login_screen.dart` lignes 566–589 : SnackBar rouge avec message "Impossible de créer le compte". Cependant, les cas d'erreur spécifiques (email déjà utilisé, champ invalide serveur) ne sont pas différenciés — seul le code HTTP est relayé (`'Erreur serveur (${resp.statusCode})'` dans `supabase_service.dart` ligne 76). L'authentification étant anonyme (pas d'email), le cas "email déjà utilisé" n'existe pas par design.

#### Session persistée de façon sécurisée
**🟡 Partiel**
Sur Android/iOS : `SecureStorageService` utilise `flutter_secure_storage` avec Android Keystore et iOS Keychain (code lignes 16–24 de `secure_storage_service.dart`). Sur Web : fallback `SharedPreferences` explicitement documenté comme non sécurisé en production (ligne 37 : `// Web : fallback SharedPreferences (acceptable en démo, pas en prod)`). En mode démo, `_sessionToken = 'DEMO_TOKEN_$userId'` est un token factice sans valeur cryptographique.

---

### 2.2 Connexion (utilisateur existant)

#### Connexion avec un compte déjà créé
**🟡 Partiel**
Il n'existe pas de flux de "connexion" distinct de l'inscription. `AppState.init()` (lignes 54–67) lit le `userId` depuis le stockage sécurisé au démarrage et restaure la session. Si le `userId` est présent, `_isAuthenticated = true` sans appel backend de vérification. Il n'y a aucun appel à un endpoint `/auth/sign_in` ou équivalent : l'app considère que la présence du UUID en stockage local suffit à prouver l'identité.

#### Token de session vérifié à chaque appel sensible
**🔴 Absent / Faille critique**
`_sessionToken` est positionné à la valeur du `userId` brut (UUID) dans `supabase_service.dart` ligne 72 : `_sessionToken = userId`. Ce n'est pas un JWT Supabase — c'est l'UUID lui-même utilisé comme Bearer token. Tous les appels avec `withAuth: true` envoient donc `Authorization: Bearer <UUID>`. Sans RLS Supabase correctement configurée, ce schéma ne valide rien côté serveur. La sécurité repose entièrement sur les Row-Level Security policies de Supabase, dont l'existence et la configuration ne peuvent être vérifiées depuis le code Flutter.

#### Gestion des erreurs de connexion
**🟡 Partiel**
L'erreur réseau est gérée (timeout 10s, catch bloc). Pas de message différencié pour "compte désactivé" (le champ `compte_actif` n'est pas lu au retour de la connexion). La vérification que `compte_actif = true` ne se fait pas côté Flutter.

#### Redirection vers l'accueil après connexion
**✅ Complet**
`router.dart` lignes 35–36 : si `isAuth && hasProfil && isLogin` → redirection vers `/home`. `login_screen.dart` ligne 609 : `context.go('/home')` après création réussie du profil. GoRouter's `refreshListenable: appState` déclenche la réévaluation du redirect automatiquement.

---

### 2.3 Déconnexion

#### Bouton de déconnexion présent et fonctionnel
**✅ Complet**
`profil_screen.dart` lignes 695–703 : item "Se déconnecter" dans le bottom sheet des paramètres, déclenche `await state.seDeconnecter()`. Le bouton est accessible et fonctionne de manière synchrone.

#### Token/session invalidé côté backend
**❌ Absent — Faille majeure**
`app_state.dart` lignes 90–107 (`seDeconnecter()`) : purge les SharedPreferences et appelle `SecureStorageService.supprimerSession()`, mais n'effectue **aucun appel réseau** vers Supabase. Il n'existe aucune méthode `signOut`, `revokeToken`, ou `invalidateSession` dans `supabase_service.dart`. Un token capturé (l'UUID en clair) reste techniquement valide côté serveur jusqu'à expiration ou révocation manuelle.

Preuve : `grep signOut|revokeToken|logout lib/services/supabase_service.dart` → résultat vide.

#### Redirection vers l'écran de connexion après déconnexion
**✅ Complet**
`seDeconnecter()` positionne `_isAuthenticated = false` et appelle `notifyListeners()`. GoRouter réagit via `refreshListenable` et la condition `if (!isAuth && !isLogin) return '/'` (ligne 34) force la redirection vers `/`.

#### Cache local sensible vidé à la déconnexion
**✅ Complet**
`app_state.dart` lignes 92–97 : boucle sur `_toutesLesClesCache` qui couvre `sauve_profil`, `sauve_demandes`, `sauve_notifications`, `sauve_dons_declares`. `SecureStorageService.supprimerSession()` supprime `sauve_secure_user_id` et `sauve_secure_auth_type`. Les variables en mémoire (`_userId`, `_profil`, `_demandes`, `_notifications`) sont nullifiées.

---

### 2.4 Accueil / liste des demandes

#### Demandes provenant réellement de la base de données
**❌ Non fonctionnel en pratique**
`home_screen.dart` ligne 42 : le `RefreshIndicator` appelle `state.chargerDemandesDemo(ville)` et non `state.actualiserDemandes()`. La méthode `chargerDemandesDemo()` génère 4 demandes codées en dur avec des UUIDs générés localement. Même avec un backend configuré, le pull-to-refresh sur l'écran d'accueil chargera toujours les données de démo.

`app_state.dart` ligne 340 : lors du démarrage `_loadDemandes()`, si la liste est vide, `chargerDemandesDemo()` est appelé inconditionnellement **sans tentative backend** au démarrage.

#### Filtrage par ville de l'utilisateur côté backend
**🟡 Partiel**
`SupabaseService.lireDemandesActives()` lignes 137–160 : la requête inclut `?ville=eq.${Uri.encodeComponent(ville)}`. Le filtrage est bien prévu côté API. Toutefois, comme démontré ci-dessus, cette méthode n'est jamais appelée dans le flux normal de l'écran d'accueil.

#### Badge "Compatible" reflète une vraie comparaison de groupes sanguins
**✅ Complet (logique, non vérifiable en temps réel)**
`demande_card.dart` lignes 30–32 : `widget.demande.estCompatibleAvec(widget.profil!)` appelle `models.dart` lignes 208–232 : matrice de compatibilité complète et médicalement correcte (O- compatible avec tous, AB+ receveur universel, etc.). Le calcul est purement client-side mais la logique est exacte.

#### La liste se rafraîchit
**🟡 Partiel**
Le `RefreshIndicator` existe dans `home_screen.dart` et `demandes_screen.dart`, mais les deux appellent `chargerDemandesDemo()` (non le backend). Il n'y a aucun rafraîchissement temps réel (pas de WebSocket, pas de Supabase Realtime).

#### Comportement correct si la liste est vide
**✅ Complet**
`home_screen.dart` lignes 79–81 : `if (demandes.isEmpty) _buildVide()` affiche un message avec icône. `demandes_screen.dart` lignes 163–194 : idem avec bouton "Effacer le filtre" si filtre actif.

---

### 2.5 Création d'une demande

#### Demande insérée dans `demandes_sang`
**🟡 Partiel**
Code présent dans `supabase_service.dart` lignes 202–235 : POST vers `/rest/v1/demandes_sang` avec tous les champs attendus. La réponse 201 est gérée et la demande désérialisée. Non vérifiable sans backend actif.

#### Validation des champs obligatoires côté backend
**❌ Absent (côté Supabase)**
La validation se fait uniquement côté Flutter dans `nouvelle_demande_screen.dart` : `_formKey.currentState!.validate()` et validator sur le contact principal (lignes 180–189). Il n'existe aucune Edge Function de validation ni de trigger Supabase visible depuis le code Flutter. Si les contraintes NOT NULL et CHECK sont définies en base PostgreSQL, elles bloqueront un appel direct, mais cela n'est pas vérifiable depuis ce code.

#### Numéro de téléphone obligatoire (§4.1)
**✅ Complet**
`nouvelle_demande_screen.dart` ligne 181 : validator retourne `'Le numéro de contact est obligatoire.'` si vide. Ligne 184–187 : validation minimale 8 chiffres. `supabase_service.dart` ligne 167 : paramètre `required String contactPrincipal`. Le contact est chiffré avant envoi (ligne 182 : `CryptoService.chiffrer(contactPrincipal)`).

#### Second numéro optionnel (§4.1)
**✅ Complet**
`nouvelle_demande_screen.dart` lignes 240–248 : validator retourne null si vide, valide seulement si non vide. `nouvelle_demande_screen.dart` lignes 409–411 : `contactSecondaire` est null si le champ est vide. `supabase_service.dart` ligne 183 : `CryptoService.chiffrer(contactSecondaire)` (retourne null si null en entrée, voir `crypto_service.dart` ligne 50).

#### Limite anti-spam (max 3 demandes actives)
**🟡 Partiel**
`supabase_service.dart` lignes 403–427 : `_compterDemandesActives()` fait une requête GET avec `Prefer: count=exact` mais utilise `list.length` (ligne 421) au lieu du header `Content-Range` qui contiendrait le compte exact. Le header `Prefer: count=exact` de Supabase retourne le compte dans `Content-Range: 0-X/TOTAL`. En chargeant jusqu'à 50 résultats (`&select=id`), `list.length` donnera le bon résultat si le count est ≤ 50, ce qui est vrai pour 3 demandes. La vérification est appliquée uniquement si `estConfigured` (ligne 171). En mode démo, aucune limite n'est vérifiée.

#### Expiration automatique après 72h
**❌ Absent (job planifié)**
Le champ `expires_at` est calculé côté Flutter à `DateTime.now().add(const Duration(hours: 72))` et envoyé en base. La colonne `expires_at` existe dans le modèle. La requête de lecture filtre `&expires_at=gt.${DateTime.now()}`. Cependant, il n'existe **aucun cron job, aucune Edge Function planifiée, aucun trigger PostgreSQL** visible dans le code Flutter qui changerait le statut de `active` à `expiree` après 72h. Les demandes expirées sont simplement ignorées par le filtre côté Flutter, mais leur statut reste `active` en base de données.

Preuve : `grep cron|pg_cron|schedule|Edge|supabase_functions` → aucun résultat dans le code Flutter.

---

### 2.6 Détail d'une demande / réponse d'un donneur

#### Bouton "Je réponds" a un effet réel en base
**❌ Absent — Bug fonctionnel**
`detail_demande_screen.dart` lignes 391–405 : `_repondre()` positionne `_repondu = true` en mémoire locale et affiche un SnackBar. **Aucun appel HTTP n'est effectué.** Aucune table de "réponses donneurs" n'est mentionnée ni dans les modèles, ni dans `supabase_service.dart`. L'intérêt du donneur n'est jamais persisté nulle part.

#### Aucune donnée d'identité du donneur transmise au demandeur à ce stade
**✅ Complet (par design)**
Le bouton "Je réponds" étant purement local, aucune donnée n'est transmise. Par conception, le flux d'anonymat passe par le QR code. L'identité du donneur n'est jamais envoyée dans aucun appel HTTP du code audité.

---

### 2.7 QR code — génération et scan

#### QR généré correspond à un token en base (`dons_qr_tokens`)
**🟡 Partiel**
`supabase_service.dart` lignes 241–271 : `creerToken()` fait un POST vers `/rest/v1/dons_qr_tokens` avec `donneur_id` et `demande_id`. Le token retourné est le champ `token` de la réponse (ligne 263). En mode démo, un token factice `DEMO_${id}` est généré sans persistance. Le token est affiché via `qr_flutter` dans `detail_demande_screen.dart` (ligne 365 : `QrImageView(data: _qrData!)`).

**Problème identifié** : `detail_demande_screen.dart` lignes 205–211 — le contact est affiché comme `value: demande.contactChiffre!` — le texte chiffré brut (`base64(IV):base64(ciphertext)`) est affiché en clair à l'utilisateur. La fonction `CryptoService.dechiffrer()` existe dans `crypto_service.dart` mais **n'est jamais appelée dans aucun écran d'affichage**. C'est un bug critique de confidentialité.

#### Token expire après 24h
**🟡 Partiel**
Le message UI dans `detail_demande_screen.dart` ligne 345 indique "Valide 24h". Cependant, la durée de vie du token n'est pas gérée côté Flutter : il n'y a pas de champ `expires_at` envoyé lors de la création du token (POST ne contient que `donneur_id` et `demande_id`). L'expiration dépend entièrement d'une logique côté Supabase (trigger, RLS, ou default column) non vérifiable.

#### Scan déclenche un appel backend de validation
**🟡 Partiel**
`supabase_service.dart` lignes 273–308 : `validerToken()` appelle l'Edge Function `/functions/v1/valider-token`. Le code est présent et correct dans sa structure. Cependant, la fonctionnalité de scan (`mobile_scanner: ^5.2.3`) est déclarée dans `pubspec.yaml` ligne 29 mais **n'est jamais importée ni utilisée dans aucun fichier Dart**. Il n'existe aucun écran de scan dans l'application.

Preuve : `grep -r "mobile_scanner\|MobileScanner" lib/` → résultat vide.

#### Token déjà utilisé rejeté
**🟡 Partiel (supposé mais non vérifiable)**
La logique de vérification "usage unique" est déléguée à l'Edge Function `valider-token`. Son code source n'est pas accessible. Aucune vérification côté Flutter.

#### Validation met à jour `dernier_don_date`
**🟡 Partiel (supposé)**
Le commentaire dans `supabase_service.dart` ligne 286 indique `// Appel à une Edge Function Supabase (sécurité maximale)`. La mise à jour de `dernier_don_date` et la création d'un historique sont supposées être effectuées par cette Edge Function. Non vérifiable depuis Flutter.

#### Historique créé dans `historique_dons` avec `source = 'qr_valide'`
**🟡 Partiel (supposé)**
Même remarque que ci-dessus. Le modèle `SourceDon.qrValide` existe (ligne 39 de `models.dart`), mais son utilisation concrète en base dépend de l'Edge Function non accessible.

---

### 2.8 Déclaration manuelle de don

#### Bouton "J'ai fait un don" crée une ligne dans `historique_dons` avec `source = 'declaratif'`
**🟡 Partiel**
`app_state.dart` lignes 128–144 : `declarerDon()` appelle `SupabaseService.enregistrerDon()` avec `source: SourceDon.declaratif`. `supabase_service.dart` lignes 341–356 : POST vers `/rest/v1/historique_dons` avec `source: source.value` (= `'declaratif'`). Code présent et logique cohérente. Non vérifiable en base réelle.

#### `dernier_don_date` mis à jour
**🟡 Partiel**
`app_state.dart` ligne 130 : `_profil!.copyWith(dernierDonDate: dateDon)` suivi de `sauvegarderProfil(updated)` qui appelle `SupabaseService.creerOuMettreAJourProfil()` avec UPSERT. La date est mise à jour localement en mémoire immédiatement. La persistance backend est soumise aux mêmes réserves que §2.1.

---

### 2.9 Calcul d'éligibilité et disponibilité

#### Calcul 60j/90j implémenté côté backend
**❌ Absent (uniquement côté frontend)**
`models.dart` lignes 85–89 : `bool get estEligible` calcule le délai en Dart pure, côté client. Aucun paramètre d'éligibilité n'est envoyé dans les requêtes de matching, aucune Edge Function ne filtre par éligibilité.

#### Utilisateur non éligible exclu du matching
**❌ Absent côté backend**
`profil_screen.dart` affiche un avertissement visuel si `!profil.estEligible`, et le champ `disponible` peut être positionné à false manuellement. Mais rien n'empêche un donneur non éligible de répondre à une demande s'il laisse `disponible = true`. Il n'y a aucune vérification serveur.

#### Toggle disponible/indisponible modifie le champ en base
**🟡 Partiel**
`app_state.dart` ligne 124 : `SupabaseService.mettreAJourDisponibilite()`. `supabase_service.dart` lignes 313–327 : PATCH vers `/rest/v1/profils_donneurs?user_id=eq.$userId` avec `{'disponible': disponible}`. Code présent et cohérent. Non vérifiable sans backend.

---

### 2.10 Notifications

#### Notification push (Firebase Cloud Messaging)
**❌ Absent**
Aucune dépendance Firebase, aucun import FCM, aucune configuration dans `pubspec.yaml`. Recherche `grep -r "firebase|fcm|push_notification|FirebaseMessaging" lib/ pubspec.yaml` → résultat vide. Les notifications affichées sont uniquement locales et générées par `chargerNotificationsDemo()`.

#### Email réellement envoyé (Resend/Brevo)
**❌ Absent**
Aucune dépendance email, aucun appel à un service d'envoi d'email dans aucun fichier.

#### Notifications ciblées (compatibles + disponibles + éligibles + ville)
**❌ Absent**
Sans FCM, ce point n'est pas applicable. Les "notifications" dans l'app sont des données locales de démo.

#### Liste des notifications reflète les événements réels
**❌ Absent**
`app_state.dart` lignes 243–268 : `chargerNotificationsDemo()` génère 3 notifications codées en dur. `_loadNotifications()` (lignes 345–364) tente de lire depuis SharedPreferences, mais si vide, appelle `chargerNotificationsDemo()`. Il n'y a aucun endpoint Supabase pour lire une table `notifications`.

---

### 2.11 Profil et paramètres

#### Modifications de profil réellement enregistrées en base
**🟡 Partiel**
`_showModifierProfil()` dans `profil_screen.dart` lignes 633–645 affiche uniquement un SnackBar `'Modification de profil disponible prochainement.'`. **La fonctionnalité de modification de profil est un placeholder non implémenté.**

#### Suppression de compte avec double confirmation et délai J+5 (§4.2)
**✅ Complet (côté Flutter)**
Flux complet implémenté dans `profil_screen.dart` :
- Étape 1 : `_showConfirmationSuppression()` — bottom sheet avec 4 points d'information (lignes 734–856)
- Étape 2 : `_showConfirmationFinale()` — AlertDialog avec `barrierDismissible: false` (lignes 858–914)
- Appel backend : `supabase_service.dart` lignes 361–378 — PATCH sur `identites` avec `suppression_programmee_le` et `compte_actif: false`
- Bannière : `_buildBannereSuppression()` affiche les jours restants (lignes 143–216)

La colonne `suppression_programmee_le TIMESTAMPTZ` est bien utilisée. L'exécution réelle de la suppression à J+5 requiert un job Supabase non vérifiable depuis ce code.

#### Bouton d'annulation de suppression accessible pendant le délai
**✅ Complet**
`profil_screen.dart` ligne 190–211 : bouton "Annuler la suppression" dans la bannière. Lignes 683–691 : le bouton paramètres affiche "Suppression programmée (annuler)" si `suppressionProgrammee`. L'annulation appelle `SupabaseService.annulerSuppression()` qui remet `suppression_programmee_le: null` et `compte_actif: true`.

---

### 2.12 Navigation

#### Bouton retour sur tous les écrans secondaires (§4.3)
**✅ Complet**
- `detail_demande_screen.dart` ligne 88–102 : `_buildBackBtn()` avec `context.pop()`
- `nouvelle_demande_screen.dart` lignes 320–335 : `_buildBackBtn()` avec `context.pop()`
- `profil_screen.dart` lignes 41–60 : bouton retour avec `Navigator.of(context).canPop()` guard
- `login_screen.dart` (formulaire profil) lignes 182–214 : bouton retour via `findAncestorStateOfType<_LoginScreenState>()`

#### Aucune impasse de navigation
**✅ Complet**
`router.dart` ligne 267 : page `_NotFoundPage` propose un bouton `context.go('/home')`. La redirection GoRouter évite les états non gérés. L'écran de connexion est le terminus logique (pas d'écran précédent).

---

## 3. Audit de la couche backend et base de données

**Avertissement préliminaire** : l'intégralité de cette section se base sur l'analyse du code Flutter client. Aucune connexion directe à l'instance Supabase n'est disponible. Les items marqués ✅ signifient que le code Flutter envoie les données correctement structurées, non que la table existe réellement en base.

#### Existence des 5 tables du schéma
**🟡 Partiel (inféré du code uniquement)**
Les tables utilisées dans le code :
- `identites` — référencée dans connexionAnonyme, programmerSuppression, annulerSuppression
- `profils_donneurs` — référencée dans creerOuMettreAJourProfil, mettreAJourDisponibilite
- `demandes_sang` — référencée dans creerDemande, lireDemandesActives, _compterDemandesActives
- `dons_qr_tokens` — référencée dans creerToken
- `historique_dons` — référencée dans enregistrerDon

Aucune migration SQL ni schéma de base n'est présent dans le dépôt. L'existence réelle des tables ne peut être confirmée. La colonne `suppression_programmee_le` dans `identites` est utilisée dans le code mais son existence en base est non vérifiée.

#### Utilisation des enums PostgreSQL
**🟡 Partiel**
Les enums Dart (`GroupeSanguin`, `StatutDemande`, `SourceDon`, `Genre`) sont bien définis dans `models.dart` et leurs `.value` / `.label` sont envoyés en tant que strings dans les requêtes REST (ex: `'statut': 'active'`, `'genre': 'homme'`). Si les colonnes PostgreSQL sont de type `TEXT` avec contrainte CHECK, cela fonctionne. Si ce sont de vrais enums PostgreSQL, les valeurs doivent correspondre exactement. Non vérifiable.

#### Index mentionnés dans le cahier des charges
**❌ Non vérifiable**
Aucune requête sur `pg_indexes` n'est effectuée depuis Flutter. L'existence d'index (`idx_profils_matching`, etc.) ne peut être confirmée.

#### Trigger de mise à jour de `dernier_don_date`
**❌ Non vérifiable**
Aucun trigger n'est visible dans le code Flutter. La mise à jour de `dernier_don_date` lors de la validation QR est supposée être gérée par l'Edge Function `valider-token`, dont le code source n'est pas accessible.

#### Isolation des données entre utilisateurs (RLS)
**❌ Non vérifiable — Risque élevé**
L'identifiant utilisateur est le UUID brut lui-même, utilisé comme Bearer token. La sécurité des Row-Level Security (RLS) policies Supabase est la **seule** barrière entre les utilisateurs. Le code Flutter ne peut pas vérifier que ces policies existent ni qu'elles sont correctes. En l'absence de RLS, n'importe quel utilisateur authentifié pourrait lire les données de tous les autres (notamment les contacts chiffrés).

#### Chiffrement des champs `_chiffre`
**✅ Présent côté Flutter**
`crypto_service.dart` : AES-256-CBC avec IV aléatoire par opération, format `base64(IV):base64(ciphertext)`. Les contacts sont chiffrés avant envoi HTTP (`supabase_service.dart` lignes 182–183). Il n'est pas possible de vérifier que les valeurs stockées en base sont bien le ciphertext et non le plaintext sans accès direct à la base.

#### Clés de chiffrement dans le dépôt Git
**🟡 Partiel — Risque modéré**
La clé de production est injectée via `--dart-define=SAUVE_ENCRYPT_KEY` et n'est pas commitée. La clé de développement `'SauveDevKey_NON_PROD_32chars!!!!!'` est présente dans `crypto_service.dart` ligne 42, mais est protégée par un guard `kReleaseMode` qui lève une `StateError` en mode release (lignes 35–39). Un build de développement avec cette clé ne doit jamais atteindre la production. L'historique Git complet n'est pas accessible pour vérifier qu'une vraie clé n'a pas été commitée dans le passé.

#### Rate limiting sur les endpoints sensibles
**❌ Non configurable depuis Flutter**
Le rate limiting est une fonctionnalité côté Supabase / reverse proxy. Aucune configuration visible.

#### File d'attente pour les notifications en masse
**❌ Non applicable en l'état**
Sans FCM, il n'y a pas de système de notifications en masse à protéger. Ce point deviendra pertinent en V2.

#### Gestion des erreurs et logs (données sensibles)
**✅ Correct côté Flutter**
Tous les `catch` utilisent `kDebugMode` avant `debugPrint` (ex: `supabase_service.dart` ligne 80). Aucune donnée sensible (contacts en clair, UUID) n'est loguée. Le contact est chiffré avant tout appel réseau.

---

## 4. Failles de sécurité identifiées

### 🔴 CRITIQUE — 1 : Affichage du ciphertext brut comme contact

**Fichier** : `detail_demande_screen.dart` lignes 205–212  
**Description** : Le champ `demande.contactChiffre!` est affiché directement comme valeur de texte dans le widget contact, sans appel à `CryptoService.dechiffrer()`. L'utilisateur voit s'afficher la chaîne chiffrée brute au format `base64(IV):base64(ciphertext)` au lieu du numéro de téléphone. Ce bug a deux conséquences : (1) l'UX est cassée (contact illisible), (2) le ciphertext brut est exposé à l'utilisateur, ce qui, bien que peu exploitable seul, peut aider un attaquant à analyser les patterns de chiffrement.

La méthode `CryptoService.dechiffrer()` existe dans `crypto_service.dart` ligne 69 mais n'est jamais appelée dans aucun fichier d'affichage.

---

### 🔴 CRITIQUE — 2 : Token de session = UUID brut non signé

**Fichier** : `supabase_service.dart` ligne 72  
**Description** : `_sessionToken = userId` — l'UUID v4 de l'utilisateur est utilisé directement comme Bearer token dans toutes les requêtes authentifiées. Ce n'est pas un JWT Supabase avec signature cryptographique, expiration, et révocation. Tout acteur connaissant l'UUID d'un utilisateur peut forger des requêtes authentifiées. La sécurité repose entièrement sur l'impossibilité de deviner un UUID v4 (128 bits d'entropie, acceptable) et sur la configuration RLS de Supabase (non vérifiable). En cas de fuite d'un UUID (logs, URL, erreur d'affichage), un attaquant peut usurper l'identité de l'utilisateur sans expiration possible.

---

### 🔴 CRITIQUE — 3 : Absence de scan QR côté demandeur

**Fichier** : `pubspec.yaml` ligne 29, absence dans tous les fichiers Dart  
**Description** : `mobile_scanner: ^5.2.3` est déclaré comme dépendance mais jamais importé ni utilisé. Il n'existe aucun écran permettant au demandeur de scanner le QR du donneur. Le flux de validation du don (QR généré par le donneur → scanné par le demandeur → validation backend → mise à jour `dernier_don_date`) est **complètement incomplet** : la première moitié (génération) est implémentée, la seconde (scan + validation) est absente. La chaîne de confiance du don ne peut jamais être bouclée.

---

### 🟠 MAJEURE — 4 : Absence d'invalidation de session côté backend à la déconnexion

**Fichier** : `app_state.dart` lignes 90–107, `supabase_service.dart` (absence totale)  
**Description** : La déconnexion supprime le token côté app mais n'émet aucun appel API pour invalider la session côté Supabase. Avec le schéma actuel (UUID = token), un token capturé (réseau, logs) reste valide indéfiniment.

---

### 🟠 MAJEURE — 5 : Données de démo codées en dur dans le flux principal

**Fichier** : `home_screen.dart` ligne 42, `demandes_screen.dart` ligne 92, `app_state.dart` ligne 340  
**Description** : Le pull-to-refresh sur deux écrans principaux appelle `chargerDemandesDemo()` au lieu d'`actualiserDemandes()`. Au démarrage, `_loadDemandes()` appelle `chargerDemandesDemo()` sans tenter le backend. En production avec un backend Supabase configuré, les demandes réelles ne seraient **jamais affichées** sur l'écran d'accueil ni dans la liste des demandes — seulement les 4 demandes fictives.

---

### 🟠 MAJEURE — 6 : Modification de profil non implémentée

**Fichier** : `profil_screen.dart` lignes 633–645  
**Description** : `_showModifierProfil()` affiche `'Modification de profil disponible prochainement.'`. Un utilisateur ne peut pas modifier son groupe sanguin, son poids, sa ville, ou ses contre-indications après inscription. Si une erreur est commise à l'inscription, aucun recours n'est disponible. C'est une fonctionnalité essentielle dans une application médicale.

---

### 🟠 MAJEURE — 7 : Réponse d'un donneur non persistée

**Fichier** : `detail_demande_screen.dart` lignes 391–405  
**Description** : `_repondre()` ne fait aucun appel HTTP. L'intention d'un donneur de répondre à une demande n'est enregistrée nulle part. En conséquence, le demandeur ne peut jamais savoir si quelqu'un a répondu à sa demande, et le contact ne peut jamais être transmis au donneur via un canal sécurisé.

---

### 🟡 MINEURE — 8 : Clé de dev commitée dans le code source

**Fichier** : `crypto_service.dart` ligne 42  
**Description** : `'SauveDevKey_NON_PROD_32chars!!!!!'` est dans le code source, versionné dans le dépôt Git. Bien que protégée par le guard `kReleaseMode`, la clé de dev est visible de tout développeur ayant accès au dépôt. Des données chiffrées avec cette clé (enregistrées en base depuis un build debug) pourraient être déchiffrées par quiconque a accès au code source.

---

### 🟡 MINEURE — 9 : Stockage web non sécurisé

**Fichier** : `secure_storage_service.dart` lignes 35–43  
**Description** : Sur web, le fallback vers `SharedPreferences` est explicitement documenté comme non sécurisé (ligne 37 : `// acceptable en démo, pas en prod`). L'UUID session est stocké en LocalStorage non chiffré sur navigateur web. Acceptable en démo, bloquant en production web.

---

### 🟡 MINEURE — 10 : Badge notification non interactif

**Fichier** : `home_screen.dart` lignes 125–168  
**Description** : `_buildNotifBadge()` a `onTap: () {}` (lambda vide, ligne 128). Le badge de notification sur l'écran d'accueil ne navigue pas vers l'onglet notifications. C'est une incohérence UX attendue dans une app critique (l'utilisateur doit réagir rapidement aux alertes).

---

## 5. Problèmes de performance identifiés

### Performance — 1 : Requête anti-spam sans COUNT côté serveur

**Fichier** : `supabase_service.dart` lignes 403–427  
**Description** : `_compterDemandesActives()` récupère des objets JSON complets (`&select=id`, ce qui est déjà optimisé) et compte `list.length`. L'en-tête `Prefer: count=exact` est envoyé mais la valeur du header `Content-Range` n'est pas lue. Supabase retourne le count exact dans ce header sans nécessiter de charger les données. Pour 3 demandes, l'impact est négligeable. Pour une version à l'échelle, utiliser le header éviterait le chargement JSON.

### Performance — 2 : Chargement des demandes au démarrage sans backend

**Fichier** : `app_state.dart` lignes 325–343  
**Description** : `_loadDemandes()` lit depuis SharedPreferences, puis charge inconditionnellement les données de démo. Même avec un profil chargé, aucun appel à `SupabaseService.lireDemandesActives()` n'est effectué au démarrage. L'utilisateur en production ne verra jamais les vraies demandes sans pull-to-refresh, et même là, il voit les données de démo (voir faille 5).

### Performance — 3 : Pas de pagination dans la liste des demandes

**Fichier** : `supabase_service.dart` ligne 144 (`&limit=50`)  
**Description** : La requête est limitée à 50 résultats. En cas de forte activité, les demandes au-delà de 50 ne sont pas récupérables. Aucun système de pagination (offset, cursor) n'est implémenté.

### Performance — 4 : Notifications chargées à chaque démarrage

**Fichier** : `app_state.dart` lignes 345–364  
**Description** : `_loadNotifications()` tente de lire depuis SharedPreferences mais appelle systématiquement `chargerNotificationsDemo()` à la fin (comme fallback). Cela écrase toujours les notifications persistées localement avec les données de démo si les notifications sauvegardées sont vides.

### Performance — 5 : Animations pulse non arrêtées sur les anciennes demandes

**Fichier** : `demande_card.dart` ligne 44  
**Description** : `if (_estUrgente) _pulseCtrl.repeat()` — le critère d'urgence est calculé à `initState()` mais n'est pas réévalué. Si l'app reste ouverte plus de 30 minutes, les cartes initialement urgentes continuent d'animer. Mineur en termes de performance mais visuellement incorrect.

---

## 6. Recommandations (description uniquement — aucun code)

### R1 — Déchiffrement du contact dans l'écran de détail [BLOQUANT PRODUCTION]

**Priorité : Bloquant avant tout déploiement.**  
La valeur affichée dans la ligne "Contact" de `detail_demande_screen.dart` doit passer par la fonction de déchiffrement avant affichage. Le service `CryptoService.dechiffrer()` existe et est fonctionnel. Il convient de l'appeler dans le widget d'affichage du contact, en gérant le cas où le déchiffrement retourne null (afficher "Contact indisponible" plutôt que planter). Cette correction est impérative — dans l'état actuel, la fonctionnalité de mise en contact entre donneur et demandeur est entièrement non fonctionnelle.

### R2 — Remplacement de l'UUID par un vrai JWT Supabase [BLOQUANT PRODUCTION]

**Priorité : Bloquant avant déploiement en production.**  
L'authentification anonyme actuelle doit être remplacée par le flux d'authentification officiel Supabase qui retourne un JWT signé avec expiration. Supabase Auth supporte les connexions anonymes qui retournent un vrai JWT. Ce changement permettrait la révocation de session à la déconnexion et renforcerait significativement la sécurité. Le commentaire dans le code (`// Simplifié — en prod utiliser JWT Supabase Auth`) confirme que l'équipe en est consciente.

### R3 — Implémentation du scan QR [BLOQUANT PRODUCTION]

**Priorité : Bloquant avant déploiement — fonctionnalité cœur métier.**  
Le scan QR est la seule fonctionnalité qui valide qu'un don a réellement eu lieu. Sans elle, aucun historique ne peut être créé via le flux QR, et aucun calcul d'éligibilité basé sur des dons vérifiés n'est possible. Le package `mobile_scanner` est déjà déclaré dans `pubspec.yaml` et prêt à l'emploi. Un écran dédié au scan (accessible depuis l'écran de détail d'une demande, côté demandeur) doit être créé et relié à `SupabaseService.validerToken()`.

### R4 — Correction du flux de données réelles sur l'écran d'accueil [BLOQUANT PRODUCTION]

**Priorité : Bloquant avant déploiement.**  
Le `RefreshIndicator` de l'écran d'accueil et de l'onglet "Demandes" doit appeler `state.actualiserDemandes()` au lieu de `state.chargerDemandesDemo()`. La méthode `actualiserDemandes()` existe déjà dans `app_state.dart` et gère le fallback démo automatiquement si le backend n'est pas configuré. De même, `_loadDemandes()` dans `app_state.dart` devrait appeler `actualiserDemandes()` au démarrage si un profil est disponible.

### R5 — Invalidation de session côté backend à la déconnexion [À faire avant lancement]

**Priorité : Majeure — à corriger avant lancement en production.**  
Ajouter un appel à l'endpoint Supabase Auth `/auth/v1/logout` lors de la déconnexion. Cet endpoint invalide le token de session côté serveur. Cette modification est indépendante de R2 mais complémentaire.

### R6 — Implémentation de la modification de profil [À faire avant lancement]

**Priorité : Majeure — fonctionnalité essentielle dans une application médicale.**  
La fonction `_showModifierProfil()` est un placeholder. Implémenter le formulaire de modification en réutilisant les composants existants du formulaire de création de profil. Les champs groupe sanguin, poids, genre, ville, quartier et contre-indications doivent être modifiables. L'appel `SupabaseService.creerOuMettreAJourProfil()` existe déjà avec la logique UPSERT nécessaire.

### R7 — Persistance de la réponse d'un donneur [À faire avant lancement]

**Priorité : Majeure — fonctionnalité cœur métier manquante.**  
La méthode `_repondre()` doit déclencher un appel backend qui enregistre l'intérêt du donneur. Une table `reponses_donneurs` ou une mise à jour du statut de la demande doit être prévue. Sans cette persistance, le flux donneur → demandeur est brisé.

### R8 — Notifications push (FCM) [Peut attendre V2]

**Priorité : V2 — fonctionnalité importante mais non bloquante pour un MVP.**  
Intégrer Firebase Cloud Messaging pour les alertes en temps réel. Le modèle de données Supabase doit prévoir une table de tokens FCM par utilisateur. Les triggers de notification (nouvelle demande compatible, confirmation de don) peuvent être implémentés via Supabase Edge Functions ou une webhooks database.

### R9 — Expiration automatique des demandes via cron [À faire avant lancement]

**Priorité : Majeure — intégrité des données.**  
Créer un cron job Supabase (via `pg_cron` ou Edge Function planifiée) qui met à jour `statut = 'expiree'` pour les demandes dont `expires_at < now()`. Sans ce mécanisme, la base de données accumule des demandes avec statut `active` expirées qui ne sont filtrées qu'au niveau applicatif.

### R10 — Remplacement de l'authentification anonyme par Google Sign-In ou OTP [V2]

**Priorité : V2 — identité vérifiable.**  
L'authentification anonyme par UUID ne permet pas de récupérer un compte, d'associer un historique de dons à une identité vérifiable, ni d'envoyer des notifications ciblées. La migration vers Google Sign-In ou OTP par téléphone est nécessaire pour une version production crédible d'une application de santé critique.

### R11 — Sécurisation du stockage web [Peut attendre V1 si web secondaire]

**Priorité : À faire si web est une cible de production.**  
Remplacer le fallback `SharedPreferences` sur web par une solution chiffrée (IndexedDB chiffré, ou session cookie HttpOnly si un backend intermédiaire est introduit).

### R12 — Suppression effective à J+5 via job planifié [À faire avant lancement]

**Priorité : Majeure — exigence légale/RGPD.**  
La colonne `suppression_programmee_le` est écrite mais aucun job ne lit cette colonne pour exécuter la suppression. Créer un cron Supabase quotidien qui supprime en cascade les enregistrements des utilisateurs dont `suppression_programmee_le <= now()`.

---

## 7. Conclusion — checklist finale de mise en production

| # | Point de contrôle | Statut actuel |
|---|---|---|
| 1 | `flutter analyze` passe sans erreur | ✅ 0 issues |
| 2 | Aucune donnée en clair dans les logs en mode release | ✅ `kDebugMode` guards en place |
| 3 | Clé de chiffrement AES absente du code de production | ✅ Guard `kReleaseMode` présent |
| 4 | Token de session = vrai JWT signé (pas UUID brut) | ❌ UUID brut utilisé |
| 5 | Invalidation session côté backend à la déconnexion | ❌ Absent |
| 6 | Déchiffrement contact affiché à l'utilisateur | ❌ Ciphertext brut affiché |
| 7 | Scan QR fonctionnel (côté demandeur) | ❌ Non implémenté |
| 8 | Données réelles chargées au démarrage (pas de démo hardcodée) | ❌ Démo forcée |
| 9 | Réponse donneur persistée en base | ❌ Non persistée |
| 10 | Modification de profil fonctionnelle | ❌ Placeholder "prochainement" |
| 11 | Expiration automatique des demandes (cron/trigger) | ❌ Absent |
| 12 | Suppression de compte exécutée à J+5 (cron/trigger) | ❌ Absent |
| 13 | Notifications push réelles (FCM configuré) | ❌ Absent |
| 14 | RLS Supabase configurée et testée | ⚠️ Non vérifiable |
| 15 | Tables et index Supabase créés et vérifiés | ⚠️ Non vérifiable |
| 16 | Edge Function `valider-token` déployée et testée | ⚠️ Non vérifiable |
| 17 | Test de pénétration basique (accès inter-utilisateurs) | ⚠️ Non effectué |
| 18 | Variables `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SAUVE_ENCRYPT_KEY` configurées en CI/CD | ⚠️ À vérifier |

### Résumé décisionnel

**L'application ne doit pas être déployée en production en l'état.**

Les blocages sont :
1. Le contact du demandeur est illisible (ciphertext brut affiché) — la fonctionnalité principale est non fonctionnelle.
2. Le scan QR côté demandeur est absent — la validation du don est impossible.
3. L'écran d'accueil affiche uniquement des données de démonstration codées en dur, même avec un backend Supabase configuré.
4. Le token de session n'est pas un JWT valide — la sécurité des données repose uniquement sur les RLS Supabase non vérifiées.

Ces 4 points doivent être corrigés avant tout déploiement. Les points R5, R6, R7, R9, R12 sont également requis avant un lancement public, mais peuvent être traités en parallèle avec les corrections critiques.

L'architecture générale (Provider, GoRouter, chiffrement AES-256, stockage sécurisé, anonymat par design) est solide et bien conçue. Le travail de fond est de qualité. Les corrections nécessaires sont ciblées et réalisables sans refonte majeure.

---

*Fin du rapport d'audit — Aucun fichier de code n'a été modifié dans le cadre de cet audit.*
