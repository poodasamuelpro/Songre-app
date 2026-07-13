# SONGRE — Application de don de sang anonyme · Burkina Faso

> **Application mobile Flutter** de mise en relation anonyme entre donneurs et demandeurs de sang au Burkina Faso.  
> Package Android : `com.lifesaver.save` · Version : `1.0.0+1` · Flutter 3.35.4 / Dart 3.9.2

---

## Table des matières

1. [Présentation générale](#1-présentation-générale)
2. [Documentation fonctionnelle écran par écran](#2-documentation-fonctionnelle-écran-par-écran)
3. [Logique métier et règles importantes](#3-logique-métier-et-règles-importantes)
4. [Architecture technique](#4-architecture-technique)
5. [Points de vigilance et sécurité](#5-points-de-vigilance-et-sécurité)
6. [FAQ](#6-faq)
7. [Liens utiles](#7-liens-utiles)

---

## 1. Présentation générale

### Mission

SONGRE est une application mobile permettant à des personnes ayant besoin de sang de publier une demande anonyme, et à des donneurs bénévoles de répondre à ces demandes. L'application protège l'identité des deux parties en chiffrant les coordonnées (contact téléphonique) côté application (AES-256-CBC) avant tout stockage en base de données. Le contact du demandeur n'est révélé au donneur qu'après que la demande est confirmée ; le téléphone du donneur n'est accessible à l'auteur de la demande qu'après une réponse enregistrée.

### Contexte géographique

L'application cible le Burkina Faso. Les villes et les structures sanitaires (hôpitaux, centres de santé) sont stockées dans la base Supabase et chargées dynamiquement. L'utilisateur peut aussi saisir un nom libre si sa ville ou structure ne figure pas dans la liste.

### URLs publiques

| Environnement | URL |
|---|---|
| Site web officiel | `https://songre.bf` |
| Application Web (démonstration) | `https://songre.bf/app` |
| Politique de confidentialité | `https://songre.bf/politique-confidentialite` |
| Conditions générales d'utilisation | `https://songre.bf/cgu` |
| FAQ publique | `https://songre.bf/faq` |
| À propos | `https://songre.bf/a-propos` |

> **Note :** La version Web est en mode démonstration uniquement. Les tokens JWT y sont stockés dans `localStorage` (non sécurisé). L'application mobile APK est la version destinée aux utilisateurs réels.

---

## 2. Documentation fonctionnelle écran par écran

### Écran 1 — Connexion / Inscription (`login_screen.dart`)

**Routes GoRouter :** `/` (LoginScreen) · `/completer-profil` (LoginScreen avec `initialStep: 3`)

L'écran de connexion est un formulaire multi-étapes géré par un unique `StatefulWidget` (`LoginScreen`) avec un paramètre `initialStep` :

| Étape | Contenu |
|---|---|
| 0 | Accueil — boutons « Se connecter » et « S'inscrire » |
| 1 | Formulaire de connexion (email + mot de passe) · Lien « Mot de passe oublié » |
| 2 | Formulaire d'inscription (email + mot de passe) |
| 3 | Formulaire de création de profil donneur (post-inscription ou `/completer-profil`) |

**Flux inscription (étape 2 → 3) :**
1. L'utilisateur saisit email + mot de passe et valide.
2. `AppState.inscrire()` appelle `SupabaseService.inscrire()` (POST `/auth/v1/signup`).
3. Si Supabase retourne une session immédiate → `_userId` et `_emailCourant` sont définis, l'utilisateur passe à l'étape 3 (formulaire profil).
4. Si Supabase ne retourne pas de session (état transitoire) → `AppState._connecterInterne()` tente une reconnexion automatique silencieuse (POST `/auth/v1/token?grant_type=password`). Si succès → étape 3. Si échec (confirmation email requise) → message d'erreur explicite.

**Formulaire de profil (étape 3 / `/completer-profil`) — `_ProfilFormState` :**
- Champs : Prénom · Groupe sanguin (sélecteur 8 valeurs) · Genre · Ville (liste déroulante ou saisie libre) · Quartier (optionnel) · **Numéro de téléphone (optionnel, chiffré AES-256 avant enregistrement)**
- Le téléphone est visible uniquement par l'auteur d'une demande après réponse enregistrée.
- Consentements RGPD : `consentement_sante` et `consentement_geoloc` (cases à cocher obligatoires).

**Bannière sécurité Web (`WebSecurityBanner`) :**  
Sur `kIsWeb`, un bandeau orange avertit que l'authentification sur navigateur utilise un stockage non sécurisé et que l'application mobile doit être utilisée pour des données médicales réelles. L'utilisateur peut le fermer.

---

### Écran 2 — Accueil (`home_screen.dart`)

**Route :** `/home`

Affiche les demandes de sang **actives filtrées par la ville du profil connecté**. Les données proviennent du cache `AppState._demandes` mis à jour par `SupabaseService.lireDemandesActives(villeId)`.

**Fonctionnalités :**
- En-tête avec logo SONGRE et badge de notifications non lues.
- Bandeau CTA rouge « Urgence — Publier une demande » → navigue vers `/nouvelle-demande`.
- Liste de `DemandeCard` avec groupe sanguin, ville, heure de publication, indicateur de compatibilité.
- Pull-to-refresh → `AppState.actualiserDemandes()`.
- Tap sur une carte → `/demande/:id` (passage de l'objet `DemandeSang` en `extra`).

**Compatibilité affichée :** Un donneur voit immédiatement si une demande est compatible avec son groupe sanguin (étoile / couleur distincte).

---

### Écran 3 — Demandes (`demandes_screen.dart`)

**Route :** `/demandes`

Affiche **toutes les demandes actives, toutes villes confondues** (`AppState._toutesLesDemandes`). Contrairement à l'Accueil filtré par ville, cet onglet donne une vue globale nationale.

**Fonctionnalités :**
- Tri par date (plus récentes en premier).
- Filtrage par groupe sanguin (barre de filtres horizontale).
- Pull-to-refresh.
- Tap sur une carte → `/demande/:id`.

---

### Écran 4 — Détail d'une demande (`detail_demande_screen.dart`)

**Route :** `/demande/:id` (objet `DemandeSang` passé en `extra`)

Affiche le détail d'une demande et gère la logique de réponse et de contact, avec **deux branches distinctes selon que l'utilisateur est l'auteur ou un donneur** :

**Vue donneur (non-auteur) :**
- Informations de la demande (groupe sanguin, ville, structure, date d'expiration).
- Bouton « Répondre » → appel `SupabaseService.repondreADemande()` → INSERT dans `reponses_donneurs`.
- Après réponse : affichage du contact déchiffré du demandeur (`contact_chiffre` et `contact_secondaire_chiffre` déchiffrés via `CryptoService`).
- Bouton de génération du QR code donneur (librairie `qr_flutter`) → code à présenter au demandeur pour confirmation du don.

**Vue auteur de la demande :**
- Bouton « Annuler la demande » (met le statut à `annulee`).
- Bouton « Scanner le QR donneur » → `/scan-qr` (pour confirmer le don via le token QR).
- Section contacts donneurs : chargée de manière asynchrone via `SupabaseService.lireContactsDonneurs(demandeId)`. Affiche le numéro de téléphone déchiffré de chaque donneur ayant répondu (si renseigné). Si aucun donneur n'a répondu ou n'a de téléphone, un message adapté est affiché.

---

### Écran 5 — Nouvelle demande (`nouvelle_demande_screen.dart`)

**Route :** `/nouvelle-demande` (slide-up depuis le bas)

Formulaire de publication d'une nouvelle demande de sang.

**Champs :**
- Groupe sanguin recherché (sélecteur 8 valeurs).
- Ville (liste déroulante ou saisie libre).
- Structure sanitaire (liste déroulante ou saisie libre).
- Contact principal (chiffré AES-256 avant envoi — jamais stocké en clair).
- Contact secondaire (optionnel, chiffré de même).

**Anti-spam :** Maximum **3 demandes actives simultanées** par utilisateur. Si dépassé, la soumission est refusée avec un message explicite. Vérification effectuée côté client (comptage via API) et côté base de données (contrainte `CHECK`).

---

### Écran 6 — Scan QR (`scan_qr_screen.dart`)

**Route :** `/scan-qr` (slide-up · guard sécurité : `demandeurId` obligatoire)

Permet à l'auteur d'une demande de scanner le QR code du donneur pour confirmer le don réel.

**Comportement :**
- Sur **mobile** : scanner natif `mobile_scanner` (caméra arrière, déduplication automatique).
- Sur **Web** : fallback de saisie manuelle du token (la librairie `mobile_scanner` n'est pas disponible sur Web).
- Après scan → appel `SupabaseService.validerToken(token, demandeurId)` → Edge Function `valider-token`.
- Si valide : message de succès, mise à jour `reponses_donneurs.statut = 'confirme'`, notifications envoyées au donneur et au demandeur.
- Guard de sécurité (GoRouter) : si `demandeurId` vide → redirection `/home` immédiate.

---

### Écran 7 — Notifications (`notifications_screen.dart`)

**Route :** `/alertes`

Liste des notifications de l'utilisateur, chargées depuis `public.notifications_envoyees` via l'Edge Function `lire-notifications`.

**Types de notifications gérés (10 valeurs) :**

| Type | Déclenchement |
|---|---|
| `demande_compatible` | Nouvelle demande compatible publiée |
| `don_confirme` | Don confirmé via scan QR (donneur) |
| `don_confirme_demandeur` | Don confirmé (auteur demande) |
| `reponse_recue` | Un donneur a répondu à la demande |
| `reponse_encouragement` | Encouragement au donneur après réponse |
| `don_enregistre_manuel` | Don déclaratif enregistré |
| `retour_eligibilite` | Donneur de nouveau éligible |
| `suppression_demandee` | Suppression de compte programmée |
| `bienvenue` | Notification de bienvenue à l'inscription |
| `mdp_modifie` | Mot de passe modifié |

**Fonctionnalités :** Marquer une notification comme lue · Tout marquer comme lu · Badge sur l'onglet navigation (nombre de non-lues).

---

### Écran 8 — Profil (`profil_screen.dart`)

**Route :** `/profil`

Écran central de gestion du compte utilisateur.

**Sections :**

**Informations du compte :**
- **Email du compte** affiché en lecture seule depuis `AppState.emailCourant` (mémorisé à la connexion, sans appel réseau).
- Groupe sanguin · Genre · Ville · Quartier.

**Édition du profil :**
- Bottom sheet modal d'édition avec tous les champs incluant le **téléphone (optionnel)** pré-rempli depuis `profil.telephone`.
- Sauvegarde via `AppState.sauvegarderProfil()` → `SupabaseService.mettreAJourProfil()` (PATCH `/rest/v1/profils_donneurs`).

**Disponibilité au don :**
- Toggle « Disponible / Non disponible » → mise à jour immédiate dans `profils_donneurs.disponible`.
- Date du dernier don affichée.
- Bouton « Déclarer un don » → bottom sheet avec sélecteur de date → Edge Function `don-manuel`.

**Historique des dons :** Bouton vers `HistoriqueScreen`.

**Paramètres :** Bouton vers `ParametresScreen`.

**Gestion du compte :**
- Bouton « Mon consentement » → consultation des consentements enregistrés (`consentement_sante`, `consentement_geoloc`, date).
- Bouton « Changer de mot de passe » → `ChangePasswordScreen` (email passé depuis `state.emailCourant`).
- Bouton « Supprimer mon compte » → flow J+5 (voir ci-dessous).
- Bouton « Se déconnecter ».

**Suppression de compte (J+5) :**
1. Double confirmation utilisateur (dialogue de confirmation avec saisie libre).
2. `SupabaseService.programmerSuppression()` → PATCH `public.identites` avec `date_suppression = now() + 5 days`.
3. Bannière rouge visible jusqu'à la date de suppression avec bouton « Annuler ».
4. L'Edge Function `executer-suppressions-programmees` (cron pg_cron) exécute les suppressions à échéance.

---

### Écran 9 — Historique (`historique_screen.dart`)

**Route :** Accessible depuis le Profil

Affiche l'historique des dons de l'utilisateur depuis `public.historique_dons` :
- Dons via QR validé (`source: 'qr_valide'`) avec date et demande liée.
- Dons déclaratifs (`source: 'declaratif'`) déclarés manuellement.

Chargement paginé. Affiche l'éligibilité au prochain don calculée côté client (`ProfilDonneur.prochainDon` et `ProfilDonneur.estEligible`).

---

### Écran 10 — Paramètres et liens externes (`parametres_screen.dart`)

**Route :** Accessible depuis le Profil

Affiche une liste de liens externes chargés dynamiquement depuis `public.liens_externes` (Supabase). Les liens sont ouverts dans le navigateur externe via `url_launcher`.

**Liens par défaut (configurables dans la table `liens_externes`) :**
- Politique de confidentialité
- Conditions générales d'utilisation
- Site web SONGRE
- Questions fréquentes
- À propos de SONGRE

Pour ajouter ou modifier un lien : INSERT/UPDATE dans `public.liens_externes` (aucun rebuild Flutter nécessaire).

---

### Écran 11 — Réinitialisation mot de passe (`reset_password_screen.dart`)

**Route :** `/reset-password` (toujours accessible, même déconnecté)

Flux OTP en deux étapes (aucun deep link) :

**Étape A — Envoi du code OTP :**
- L'utilisateur saisit son email.
- Supabase envoie un code OTP 6 chiffres par email.

**Étape B — Vérification OTP + nouveau mot de passe :**
- L'utilisateur saisit le code OTP reçu + son nouveau mot de passe.
- `SupabaseService.verifierOtpEtChangerMotDePasse()` : POST `/auth/v1/verify` (type: `recovery`) puis PATCH `/auth/v1/user`.
- Redirection vers `/` après succès.

> **Note :** Ce flux ne dépend pas des deep links (`app.link://`). Il fonctionne entièrement via des formulaires dans l'app, ce qui le rend compatible avec tous les environnements (Android, iOS, Web, APK debug).

---

### Écran 12 — Changement de mot de passe (`change_password_screen.dart`)

**Route :** Modal depuis `/profil` (utilisateur déjà connecté)

Permet à un utilisateur authentifié de changer son mot de passe :
- Saisie ancien mot de passe + nouveau mot de passe.
- Vérification côté client (longueur, correspondance).
- `SupabaseService.changerMotDePasse()` → PATCH `/auth/v1/user` avec `access_token` courant.

---

### Écran 13 — Contact Support (`contact_screen.dart`)

**Route :** Accessible depuis le Profil ou les Paramètres

Formulaire de contact vers l'équipe SONGRE :
- Champs : objet + message.
- Envoi via Edge Function `contacter-support` (anti-spam via `public.contact_spam_log`).

---

## 3. Logique métier et règles importantes

### 3.1 Compatibilité des groupes sanguins

Implémentée dans `DemandeSang._groupesCompatibles()` (`lib/models/models.dart`) :

| Groupe recherché | Donneurs compatibles |
|---|---|
| O- | O- uniquement |
| O+ | O-, O+ |
| A- | O-, A- |
| A+ | O-, O+, A-, A+ |
| B- | O-, B- |
| B+ | O-, O+, B-, B+ |
| AB- | O-, A-, B-, AB- |
| AB+ | Tous (donneur universel reçu) |

Cette règle est utilisée pour l'affichage « demandes compatibles » (`AppState._demandesCompatibles`) et les notifications `demande_compatible`.

### 3.2 Éligibilité au don — Espacement entre dons

Défini dans `ProfilDonneur` (`lib/models/models.dart`, lignes ~224-234) :

```dart
bool get estEligible {
  final joursDepuis = DateTime.now().difference(dernierDonDate!).inDays;
  return genre == Genre.homme ? joursDepuis >= 60 : joursDepuis >= 90;
}
```

| Genre | Délai minimum entre deux dons |
|---|---|
| Homme | 60 jours |
| Femme | 90 jours |

Affiché dans l'écran Profil et l'écran Historique. Utilisé par `retour-eligibilite-cron` (pg_cron quotidien 08h00 UTC) pour notifier les donneurs qui redeviennent éligibles.

### 3.3 Anti-spam — Maximum de demandes actives

Maximum **3 demandes actives simultanées** par utilisateur (`SupabaseService.creerDemande()`).

Vérification côté client : `_compterDemandesActives(userId)` → GET `/rest/v1/demandes_sang?auteur_id=eq.{userId}&statut=eq.active` avec `count: exact`.

Si `count >= 3` → retour immédiat avec message d'erreur explicite, sans appel réseau supplémentaire.

### 3.4 Chiffrement des contacts — AES-256-CBC

**Service :** `lib/utils/crypto_service.dart`

**Champs chiffrés :**

| Champ base de données | Champ Dart en clair | Qui peut déchiffrer |
|---|---|---|
| `demandes_sang.contact_chiffre` | Contact principal demandeur | Donneurs ayant répondu |
| `demandes_sang.contact_secondaire_chiffre` | Contact secondaire demandeur | Donneurs ayant répondu |
| `profils_donneurs.telephone_chiffre` | Téléphone optionnel donneur | Auteur demande (après réponse) |

**Format chiffré :** `base64(IV_16B) + ":" + base64(ciphertext)`  
**IV :** Généré aléatoirement par opération (jamais réutilisé).  
**Clé :** Injectée via `--dart-define=SONGRE_ENCRYPT_KEY=<min 32 chars>`. Fallback: clé de production historique `SongreProdBurkinaFaso2026_SecureKey!` embarquée dans le binaire comme `defaultValue`.

> **IMPORTANT :** La clé `defaultValue` garantit la compatibilité des données existantes en base mais est embarquée dans le binaire APK. Pour une rotation de clé, les données en base doivent être rechiffrées avec la nouvelle clé avant de déployer un build avec `--dart-define` différent.

### 3.5 Visibilité conditionnelle du contact du donneur (P2)

Après qu'un donneur a répondu à une demande (`reponses_donneurs` INSERT) :

- **Côté donneur :** Peut voir le contact déchiffré du demandeur immédiatement (affiché dans `DetailDemandeScreen` vue donneur).
- **Côté auteur :** Peut voir le téléphone des donneurs via `SupabaseService.lireContactsDonneurs(demandeId)` :
  1. Lit `reponses_donneurs?demande_id=eq.$id` → liste des `donneur_id`.
  2. Lit `profils_donneurs?user_id=in.($ids)&select=user_id,telephone_chiffre`.
  3. Déchiffre `telephone_chiffre` côté client via `CryptoService.dechiffrer()`.
  4. Affiche les numéros (ou « aucun téléphone fourni » si le champ est vide).

**Prérequis base de données :** La colonne `telephone_chiffre text` doit exister dans `public.profils_donneurs` :
```sql
ALTER TABLE public.profils_donneurs ADD COLUMN telephone_chiffre text;
```

### 3.6 Flux d'authentification complet

```
Inscription (email+mdp)
    ↓
SupabaseService.inscrire() → POST /auth/v1/signup
    ↓
┌── Session immédiate (userId + token) ──────────────────────────────┐
│   → _userId = result.userId                                        │
│   → _emailCourant = email                                          │
│   → SecureStorageService.sauvegarderSession(...)                   │
│   → _isAuthenticated = false (en attente création profil)          │
│   → Formulaire profil (étape 3)                                    │
└────────────────────────────────────────────────────────────────────┘
    ↓ (si pas de session immédiate)
AppState._connecterInterne() → POST /auth/v1/token?grant_type=password
    ↓
┌── Reconnexion réussie ──────────────────────────────────────────────┐
│   → _userId défini, _emailCourant défini                           │
│   → _isAuthenticated = false (le profil n'existe pas encore)       │
│   → Formulaire profil (étape 3)                                    │
└────────────────────────────────────────────────────────────────────┘
    ↓ (si échec reconnexion = email confirmation réelle)
Message d'erreur explicite → l'utilisateur doit confirmer son email

Connexion normale (email+mdp)
    ↓
AppState.connecter() → _connecterInterne() + chargement données
    → _isAuthenticated = true → GoRouter → /home
```

**Tokens :** Stockés dans `flutter_secure_storage` (Keystore Android / Keychain iOS) via `SecureStorageService`. Sur Web : `localStorage` (non sécurisé — bannière d'avertissement affichée).

### 3.7 Logique de redirection de navigation (GoRouter)

Définie dans `lib/router.dart`, function `buildRouter()` → `redirect` :

| État | Location cible | Règle |
|---|---|---|
| `isLoading = true` | Aucune redirection | Guard de transition |
| `/reset-password` | Aucune redirection | Toujours accessible |
| Non authentifié + hors `/` | `/` | Retour login |
| Authentifié + profil + sur `/` | `/home` | Quitte login |
| Authentifié + sans profil + hors `/completer-profil` | `/completer-profil` | Création profil obligatoire |

> **CRITIQUE :** `SauveApp` est un `StatefulWidget` (pas `StatelessWidget`). Si `buildRouter()` était appelé dans `build()`, un nouveau `GoRouter` serait créé à chaque `notifyListeners()`, perdant tout l'état de navigation (écran noir). Le router est créé une seule fois dans `initState()`.

### 3.8 Durée de validité des demandes

**Affichage UI :** `kDureeValiditeDemande = Duration(hours: 168)` (7 jours) dans `lib/models/models.dart`.  
**Label affiché :** `kDureeValiditeDemandeLabel` → `"7 jours"` (168h ÷ 24 = 7).

**Durée réelle (base de données) :** Le DEFAULT PostgreSQL sur `demandes_sang.expires_at` doit être synchronisé via :
```sql
-- Script : scripts/migration_expires_at_7jours.sql
ALTER TABLE public.demandes_sang
  ALTER COLUMN expires_at SET DEFAULT now() + interval '7 days';
```

> **Note :** `expires_at` n'est **pas** envoyé dans le `bodyMap` lors de `creerDemande()`. La durée réelle est donc celle du DEFAULT PostgreSQL. La constante Dart ne sert qu'à l'affichage dans l'UI (exemple : « Expire dans 7 jours »).

### 3.9 Stale-While-Revalidate (PERF-03)

Au démarrage de l'app (`AppState.init()`), deux phases :
1. **Phase 1 (synchrone) :** Chargement depuis le cache local (`SharedPreferences`) → affichage immédiat.
2. **Phase 2 (background, non bloquante) :** Rafraîchissement depuis Supabase via `_rafraichirDonneesBackground()` (`unawaited()`).

Cela garantit un affichage instantané même sans réseau, avec mise à jour silencieuse quand les données fraîches arrivent.

---

## 4. Architecture technique

### 4.1 Stack

| Couche | Technologie | Version |
|---|---|---|
| Frontend mobile | Flutter | 3.35.4 |
| Langage | Dart | 3.9.2 |
| Backend Auth | Supabase Auth | API v1 |
| Base de données | PostgreSQL (Supabase) | — |
| Edge Functions | Deno (TypeScript) | — |
| Notifications push | Firebase Cloud Messaging (FCM v1) | firebase_messaging 15.1.3 |
| Notifications email | Brevo (principal) / Resend (fallback) | — |
| Navigation | GoRouter | ^13.2.0 |
| State management | Provider + ChangeNotifier | 6.1.5+1 |
| Chiffrement | encrypt (AES-256-CBC) + pointycastle | ^5.0.3 / ^3.9.1 |
| Stockage sécurisé | flutter_secure_storage | ^9.2.2 |
| Stockage local | SharedPreferences | 2.5.3 |
| Polices | Google Fonts (Archivo + Inter) | ^6.2.1 |
| Scan QR | mobile_scanner | ^5.2.3 |
| Génération QR | qr_flutter | ^4.1.0 |
| Liens externes | url_launcher | ^6.3.2 |

### 4.2 Structure des dossiers

```
flutter_app/
├── android/                        # Configuration Android (Gradle, Manifest, signatures)
│   └── app/
│       ├── build.gradle.kts        # applicationId: com.lifesaver.save
│       └── src/main/
│           ├── AndroidManifest.xml
│           └── kotlin/com/lifesaver/save/
│               └── MainActivity.kt
├── lib/
│   ├── main.dart                   # Point d'entrée, init Firebase, init AppState, runApp
│   ├── router.dart                 # GoRouter — routes, guards, ShellRoute, MainShell
│   ├── models/
│   │   └── models.dart             # Tous les modèles Dart : ProfilDonneur, DemandeSang,
│   │                               # GroupeSanguin, Genre, StatutDemande, TypeNotification,
│   │                               # NotificationSauve, Ville, LienExterne, HistoriqueDon
│   ├── services/
│   │   ├── app_state.dart          # ChangeNotifier central — auth, profil, demandes,
│   │   │                           # notifications, villes, cache, init(), inscrire(),
│   │   │                           # connecter(), _connecterInterne(), seDeconnecter()
│   │   ├── supabase_service.dart   # Toutes les requêtes HTTP Supabase REST + Edge Functions
│   │   └── notification_service.dart # Initialisation FCM, enregistrement token
│   ├── utils/
│   │   ├── crypto_service.dart     # AES-256-CBC : init(), chiffrer(), dechiffrer()
│   │   └── secure_storage_service.dart # flutter_secure_storage : userId, accessToken,
│   │                                    # refreshToken (per-key try/catch)
│   ├── screens/                    # 13 écrans (voir section 2)
│   ├── widgets/
│   │   ├── demande_card.dart       # Carte de demande réutilisable (accueil + liste)
│   │   └── web_security_banner.dart # Bannière avertissement sécurité Web (SEC-02)
│   └── theme/
│       └── sauve_theme.dart        # Thème Material3 SONGRE — couleurs, typographie
├── supabase/
│   └── functions/
│       ├── _shared/
│       │   ├── cors.ts             # Headers CORS + helpers jsonResponse
│       │   ├── email.ts            # Templates HTML emails + rotation Brevo/Resend
│       │   ├── fcm.ts              # Envoi notifications FCM v1
│       │   └── notifier.ts         # Orchestrateur central : email + FCM + DB insert
│       ├── bienvenue-auth/         # Webhook auth.users INSERT → email bienvenue + upsert identites
│       ├── contacter-support/      # Formulaire contact avec anti-spam contact_spam_log
│       ├── don-manuel/             # Enregistrement don déclaratif + notification
│       ├── envoyer-email/          # Envoi email générique (usage interne)
│       ├── executer-suppressions-programmees/ # Cron : exécute suppressions J+5
│       ├── lire-notifications/     # GET/POST notifications utilisateur paginées
│       ├── matcher-et-notifier/    # Webhook demandes_sang INSERT → notif donneurs compatibles
│       ├── mdp-modifie-auth/       # Webhook auth.users UPDATE → notif mdp_modifie
│       ├── reponse-donneur/
│       │   ├── index.ts            # VERSION ORIGINALE — Webhook reponses_donneurs INSERT
│       │   └── index_2026-07-13.ts # VERSION DATÉE (P2) — idem + has_telephone dans FCM data
│       ├── retour-eligibilite-cron/ # Cron quotidien → notif donneurs redevenant éligibles
│       └── valider-token/          # Validation QR code don → confirme reponses_donneurs
├── scripts/
│   ├── pre_build_check.sh          # Vérifie android:label avant chaque build APK
│   └── migration_expires_at_7jours.sql # Script SQL : expires_at DEFAULT 7 jours
├── Makefile                        # Commandes build standardisées
└── pubspec.yaml
```

### 4.3 Tables principales de la base de données

| Table | Rôle |
|---|---|
| `auth.users` | Comptes Supabase Auth (géré par Supabase) |
| `public.profils_donneurs` | Profil donneur : groupe sanguin, genre, ville, disponible, dernier_don_date, **telephone_chiffre** |
| `public.demandes_sang` | Demandes publiées : groupe cherché, ville, structure, contact_chiffre, statut, expires_at |
| `public.reponses_donneurs` | Réponses des donneurs aux demandes : donneur_id, demande_id, statut (`en_attente`/`confirme`/`annule`) |
| `public.historique_dons` | Dons confirmés : donneur_id, demande_id, date_don, source (`qr_valide`/`declaratif`) |
| `public.notifications_envoyees` | Notifications envoyées : user_id, demande_id, type, lu |
| `public.dons_qr_tokens` | Tokens QR pour confirmation don : token (PK), donneur_id, demande_id, expires_at, used_at |
| `public.villes` | Référentiel villes Burkina Faso |
| `public.structures_sanitaires` | Référentiel hôpitaux/centres de santé |
| `public.liens_externes` | Liens dynamiques affichés dans Paramètres |
| `public.identites` | Gestion suppression de compte : compte_actif, date_suppression |
| `public.contact_spam_log` | Anti-spam formulaire contact support |

### 4.4 Edge Functions — Liste complète et rôle

| Fonction | Déclenchement | Rôle |
|---|---|---|
| `bienvenue-auth` | Webhook INSERT `auth.users` | Email de bienvenue + création ligne `identites` |
| `contacter-support` | Appel Flutter (POST) | Envoi message support avec anti-spam |
| `don-manuel` | Appel Flutter (POST, JWT auth) | Enregistrement don déclaratif + notif `don_enregistre_manuel` |
| `envoyer-email` | Appel interne | Envoi email générique via rotation Brevo/Resend |
| `executer-suppressions-programmees` | Cron pg_cron | Suppression définitive comptes après délai J+5 |
| `lire-notifications` | Appel Flutter (GET/POST, JWT auth) | Lecture + marquage des notifications utilisateur |
| `matcher-et-notifier` | Webhook INSERT `demandes_sang` | Trouve les donneurs compatibles → notif `demande_compatible` |
| `mdp-modifie-auth` | Webhook UPDATE `auth.users` | Notif `mdp_modifie` après changement mot de passe |
| `reponse-donneur` *(original)* | Webhook INSERT `reponses_donneurs` | Notifie demandeur (`reponse_recue`) + donneur (`reponse_encouragement`) |
| `reponse-donneur` *(v2026-07-13)* | idem | Idem + enrichit FCM data avec `has_telephone` (P2 — 2026-07-13) |
| `retour-eligibilite-cron` | Cron pg_cron quotidien 08h00 UTC | Notifie donneurs redevenant éligibles (J+0 ou J+1) |
| `valider-token` | Appel Flutter (POST, JWT + WEBHOOK_SECRET) | Valide token QR → confirme don + double notification |

**Versions datées d'Edge Functions :**

| Fichier | Date | Raison |
|---|---|---|
| `reponse-donneur/index.ts` | original | Version de référence, conservée intacte |
| `reponse-donneur/index_2026-07-13.ts` | 2026-07-13 | P2 : lit `telephone_chiffre` du donneur et passe `has_telephone` dans les données FCM pour personnaliser le corps de la notification push selon disponibilité du téléphone. Pour adopter définitivement : renommer en `index.ts` avant `supabase functions deploy`. |

---

## 5. Points de vigilance et sécurité

### 5.1 Clé de chiffrement AES-256 embarquée dans le binaire

**Problème :** La clé `SongreProdBurkinaFaso2026_SecureKey!` est embarquée comme `defaultValue` dans `CryptoService`. Elle est visible par décompilation de l'APK.

**Pourquoi c'est acceptable pour l'instant :** Cette clé chiffre les contacts pour empêcher un accès direct à la base de données Supabase (script, injection). Elle n'est pas un secret de session utilisateur.

**Pour une sécurité renforcée :** Utiliser toujours `--dart-define=SONGRE_ENCRYPT_KEY=<nouvelle_clé>` lors des builds de production. Si la clé change, toutes les données en base doivent être rechiffrées.

### 5.2 Stockage tokens sur Web (SEC-02)

Les tokens JWT sont stockés dans `localStorage` sur Web. Un bandeau d'avertissement (`WebSecurityBanner`) informe l'utilisateur. La version Web est destinée à la démonstration, pas à la production médicale.

**Règle :** Ne jamais déployer la version Web en production sans remplacer `SharedPreferences`/`localStorage` par un mécanisme sécurisé (HttpOnly cookies côté serveur, etc.).

### 5.3 GoRouter — SauveApp DOIT être StatefulWidget

**Régression connue (corrigée en session 2) :** Si `SauveApp` devient `StatelessWidget`, `buildRouter()` est appelé à chaque `notifyListeners()` → création d'un nouveau `GoRouter` → perte de l'état de navigation → écran noir sur APK réel.

**Règle :** Ne jamais convertir `SauveApp` en `StatelessWidget`.

### 5.4 android:label ne doit pas être une chaîne littérale

**Régression connue (corrigée avec `pre_build_check.sh`) :** Si `android:label` dans `AndroidManifest.xml` contient une chaîne littérale (ex: `"Songre"`) au lieu de `"@string/app_name"`, le nom de l'app peut être écrasé à chaque rebuild Gradle.

**Règle :** Toujours utiliser `android:label="@string/app_name"`. Le script `scripts/pre_build_check.sh` vérifie et corrige automatiquement avant chaque build.

### 5.5 Deep links OTP — Flux sans deep link retenu

**Décision architecturale :** Le flux de réinitialisation de mot de passe utilise un OTP 6 chiffres saisi manuellement, sans deep link `app.link://`. Raison : les deep links sont fragiles sur Android (nécessitent une configuration App Links SHA-256, souvent défaillante sur APK non signés ou hors Play Store), et non testables facilement en développement.

### 5.6 Colonne telephone_chiffre — prérequis base de données

La fonctionnalité téléphone donneur (P2) nécessite la colonne `telephone_chiffre text` dans `public.profils_donneurs`. Cette colonne **n'est pas créée automatiquement** par l'application Flutter. Elle doit être créée manuellement :

```sql
ALTER TABLE public.profils_donneurs ADD COLUMN telephone_chiffre text;
```

Sans cette colonne, les téléphones ne s'enregistrent pas (l'erreur Supabase est silencieuse côté Flutter — le profil est sauvegardé sans ce champ).

### 5.7 Règles de bonne pratique pour toute future modification

1. **Toujours exécuter `flutter analyze`** avant un build. Zéro issue est la cible.
2. **Toujours exécuter `bash scripts/pre_build_check.sh`** avant un build APK.
3. **Toujours tester un build APK réel** (pas seulement Web ou debug) avant livraison.
4. **Ne jamais exposer `SUPABASE_SERVICE_ROLE_KEY`** dans le code Flutter. Elle n'appartient qu'aux Edge Functions côté serveur.
5. **Ne jamais écraser une Edge Function existante** sans conserver une version de sauvegarde (nommée `index_AAAA-MM-JJ.ts`).
6. **Avant tout changement de package_name Android** : synchroniser 4 fichiers (`build.gradle.kts`, `AndroidManifest.xml`, `MainActivity.kt` et son dossier, et éventuellement `google-services.json`).
7. **Ne jamais appeler `flutter upgrade`** dans cet environnement. Flutter 3.35.4 et Dart 3.9.2 sont verrouillés pour la stabilité.
8. **Le `isLoading` guard dans GoRouter est critique.** Sans ce guard, une déconnexion en cours peut déclencher une redirection vers `/completer-profil` (état transitoire `isAuth=true, profil=null`).

---

## 6. FAQ

### Comment lancer le projet en local ?

```bash
# Cloner le dépôt
git clone https://github.com/poodasamuelpro/Songre-app.git
cd Songre-app

# Installer les dépendances
flutter pub get

# Lancer en debug (web)
flutter run -d chrome

# Build APK release
flutter build apk --release \
  --dart-define=SONGRE_ENCRYPT_KEY=SongreProdBurkinaFaso2026_SecureKey!
```

### Comment configurer les variables Supabase ?

Les variables Supabase (`SUPABASE_URL`, `SUPABASE_ANON_KEY`) sont définies dans `lib/services/supabase_service.dart` en constantes statiques. Pour modifier l'environnement cible, modifier ces valeurs directement dans ce fichier.

Pour les Edge Functions, les variables d'environnement sont configurées dans le Dashboard Supabase :  
**Project Settings → Edge Functions → Environment Variables**

Variables requises :
- `WEBHOOK_SECRET` — Secret partagé entre l'app Flutter et les Edge Functions
- `BREVO_API_KEY` — Clé API Brevo pour l'envoi d'emails
- `RESEND_API_KEY` — Clé API Resend (fallback email)
- `EMAIL_FROM` — Expéditeur email (ex: `SONGRE <noreply@songre.bf>`)
- `FCM_SERVICE_ACCOUNT_JSON` — JSON du compte de service Firebase pour FCM v1

### Comment fonctionne le flux OTP de réinitialisation ?

1. L'utilisateur clique « Mot de passe oublié » sur l'écran de connexion.
2. `SupabaseService.envoyerOtpReinitialisation(email)` → POST `/auth/v1/otp` (type: `recovery`).
3. Supabase envoie un email avec un code OTP 6 chiffres.
4. L'utilisateur est redirigé vers `/reset-password` (email passé en `extra`).
5. `ResetPasswordScreen` : étape 1 = code OTP, étape 2 = nouveau mot de passe.
6. `SupabaseService.verifierOtpEtChangerMotDePasse()` :
   - POST `/auth/v1/verify` (type: `recovery`, token: code OTP) → obtient `access_token`
   - PATCH `/auth/v1/user` (avec le nouveau `access_token`) → change le mot de passe

### Pourquoi les demandes de ma ville ne s'affichent-elles pas ?

Vérifier que votre profil a une `ville_id` > 0. Si vous avez saisi une ville libre lors de la création du profil, elle n'est pas filtrée par `lireDemandesActives(villeId)` (qui nécessite un `villeId` entier). Mettre à jour le profil en sélectionnant une ville dans la liste déroulante.

### Comment ajouter une nouvelle ville ?

INSERT dans `public.villes` (Dashboard Supabase → Table Editor). Les villes sont chargées au démarrage de l'app et mises en cache. Aucun rebuild Flutter nécessaire.

### Comment ajouter un nouveau lien dans les Paramètres ?

INSERT dans `public.liens_externes` :
```sql
INSERT INTO public.liens_externes (cle, libelle, url, icone, ordre_affichage)
VALUES ('mon_lien', 'Mon Lien', 'https://exemple.com', 'link', 60);
```
Les icônes sont des noms de `Icons` Material Flutter (ex: `language`, `help_outline`, `gavel`).

### Comment déployer une Edge Function ?

```bash
# Installer Supabase CLI
npm install -g supabase

# Déployer une fonction spécifique
supabase functions deploy reponse-donneur --project-ref <PROJECT_REF>

# IMPORTANT : Pour adopter la version datée de reponse-donneur :
cp supabase/functions/reponse-donneur/index_2026-07-13.ts \
   supabase/functions/reponse-donneur/index.ts
supabase functions deploy reponse-donneur --project-ref <PROJECT_REF>
```

### Pourquoi l'écran de profil affiche-t-il l'email sans appel réseau ?

L'email est mémorisé dans `AppState._emailCourant` lors de la connexion (`connecter()`) et de l'inscription (`inscrire()` / `_connecterInterne()`). Il est accessible via le getter `state.emailCourant` sans aucun appel Supabase supplémentaire.

### Pourquoi le Makefile interdit-il `flutter_signing_tool` ?

L'environnement de build utilise un processus de signature personnalisé via `release-key.jks` et `key.properties`. `flutter_signing_tool` est une abstraction de l'agent d'IA qui conflicte avec ce setup. Toujours utiliser `make apk-release` ou la commande `flutter build apk --release` directement.

### Comment fonctionne la suppression de compte J+5 ?

1. L'utilisateur confirme en double depuis `/profil`.
2. `SupabaseService.programmerSuppression(userId)` → PATCH `public.identites?user_id=eq.$userId` avec `date_suppression = now() + 5 days`.
3. Une bannière rouge avec date d'échéance est affichée dans le profil.
4. L'utilisateur peut annuler via `SupabaseService.annulerSuppression()` avant la date.
5. Le cron `executer-suppressions-programmees` (pg_cron) s'exécute quotidiennement et supprime définitivement les comptes arrivés à échéance.

---

## 7. Liens utiles

| Ressource | URL |
|---|---|
| Site web officiel SONGRE | https://songre.bf |
| Application Web (démo) | https://songre.bf/app |
| Politique de confidentialité | https://songre.bf/politique-confidentialite |
| CGU | https://songre.bf/cgu |
| FAQ publique | https://songre.bf/faq |
| À propos | https://songre.bf/a-propos |
| Dépôt GitHub | https://github.com/poodasamuelpro/Songre-app |
| Dashboard Supabase | https://supabase.com/dashboard (accès restreint) |
| Firebase Console | https://console.firebase.google.com (accès restreint) |
| Documentation Supabase Auth | https://supabase.com/docs/reference/dart/auth-signup |
| Documentation GoRouter | https://pub.dev/packages/go_router |
| Documentation encrypt (AES) | https://pub.dev/packages/encrypt |

---

*README généré le 2026-07-13 — basé sur examen du code source réel au commit de référence.*  
*Pour toute question : utiliser le formulaire de contact in-app ou ouvrir une issue GitHub.*
