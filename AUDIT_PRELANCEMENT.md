# AUDIT PRÉ-LANCEMENT — SONGRE
**Application don de sang anonyme — Burkina Faso**

- **Date d'audit** : 2026-07-09
- **Auditeur** : Agent IA (lecture exhaustive du code source)
- **Branche** : `main` — commit `529989c`
- **Flutter** : 3.35.4 / Dart 3.9.2
- **Périmètre** : Code source Flutter (`/lib/`), 15 Edge Functions Supabase (`/supabase/functions/`), 5 fichiers SQL, configuration Android
- **`flutter analyze`** : `No issues found` ✅
- **Exclusion explicite** : Authentification SMS/OTP et Google Sign-In (retraits volontaires, non audités)

---

## Table des matières

1. [Étape 0 — Inventaire exhaustif](#étape-0--inventaire-exhaustif)
   - [0a — Tables de base de données](#0a--tables-de-base-de-données)
   - [0b — Edge Functions](#0b--edge-functions)
   - [0c — Triggers et jobs cron](#0c--triggers-et-jobs-cron)
   - [0d — Écrans Flutter](#0d--écrans-flutter)
   - [0e — Secrets et variables d'environnement Supabase](#0e--secrets-et-variables-denvironnement-supabase)
   - [0f — Clés et identifiants sensibles côté Flutter](#0f--clés-et-identifiants-sensibles-côté-flutter)
2. [AXE 1 — Fonctionnalité et logique métier](#axe-1--fonctionnalité-et-logique-métier)
3. [AXE 2 — Sécurité](#axe-2--sécurité)
4. [AXE 3 — Performance](#axe-3--performance)
5. [AXE 4 — Scalabilité](#axe-4--scalabilité)
6. [AXE 5 — Réseau et fiabilité](#axe-5--réseau-et-fiabilité)
7. [AXE 6 — Points bloquants avant publication stores](#axe-6--points-bloquants-avant-publication-stores)
8. [Résumé exécutif](#résumé-exécutif)
9. [Points non vérifiables](#points-non-vérifiables)

---

## Étape 0 — Inventaire exhaustif

### 0a — Tables de base de données

> **Note** : L'inventaire est établi à partir des fichiers SQL (`supabase-addendum.sql`, `supabase-fix-signup-500.sql`, `mission-e.sql`, `supabase-schema-corrections.sql`) et des requêtes REST dans `supabase_service.dart`. L'accès direct à la console Supabase n'est pas disponible — les colonnes, index, statuts RLS et policies sont partiellement vérifiables.

| Table | Colonnes connues (preuve fichier) | RLS | Policies | Index | Triggers | Statut audit |
|-------|-----------------------------------|-----|----------|-------|----------|--------------|
| `public.demandes_sang` | `id`, `auteur_id`, `groupe_sanguin_recherche`, `contact_chiffre`, `contact_secondaire_chiffre`, `ville_id`, `ville_libre`, `structure_id`, `structure_libre`, `statut`, `expires_at`, `created_at` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | `bienvenue-auth` déclenche via insert auth.users (indirect) | **Problème P5** (expires_at DEFAULT 72h vs Flutter 168h) |
| `public.profils_donneurs` | `user_id`, `groupe_sanguin`, `poids`, `genre`, `ville_id`, `quartier`, `telephone_chiffre`, `disponible`, `dernier_don_date`, `contre_indications`, `created_at`, `updated_at` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | aucun trigger connu | Examiné — aucun problème supplémentaire trouvé |
| `public.reponses_donneurs` | `donneur_id`, `demande_id`, `statut`, `created_at` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | Webhook `reponse-donneur` sur INSERT | **P3** (webhook DB non vérifiable) |
| `public.dons_qr_tokens` | `token`, `donneur_id`, `demande_id`, `expires_at`, `used_at`, `created_at` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | aucun | Examiné — valider-token applique la logique |
| `public.historique_dons` | `id`, `donneur_id`, `demande_id`, `date_don`, `source`, `created_at` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | aucun | Examiné — aucun problème supplémentaire trouvé |
| `public.notifications_envoyees` | `id`, `user_id`, `demande_id`, `type`, `lu`, `created_at` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | aucun | Examiné — messages générés côté client (acceptable) |
| `public.device_tokens` | `user_id`, `token`, `plateforme`, `created_at` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | aucun | Examiné — aucun problème trouvé |
| `public.villes` | `id`, `nom` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | aucun | Examiné — lecture avec `_restHeaders(withAuth: false)`, accès public OK |
| `public.structures_sanitaires` | `id`, `nom`, `ville_id` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | aucun | Examiné — même cas que villes |
| `public.identites` | `user_id`, `suppression_programmee_le`, `compte_actif` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | `trg_creer_identite_safe` (INSERT après auth.users) | **P13** (cohérence avec EF à confirmer) |
| `public.consentements` | `user_id`, `consentement_sante`, `consentement_geoloc`, `version_politique`, `created_at` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | aucun | Examiné — fire-and-forget à la création profil |
| `public.contact_spam_log` | `user_id`, `created_at` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | aucun | **P-SPAM** (voir AXE 1) |
| `public.liens_externes` | `id`, `titre`, `url`, `actif`, `ordre_affichage` | ⚠️ Non vérifiable | ⚠️ Non vérifiable | ⚠️ Non vérifiable | aucun | Examiné — accès sans auth (`withAuth: false`) |
| `public.demandes_sang_avec_contact` (vue) | `id`, `a_repondu` (+ autres colonnes) | ⚠️ Non vérifiable | N/A | N/A | N/A | Examiné — utilisée par `verifierReponduDemande()` |

> **Note RLS** : La non-vérifiabilité des policies RLS est le point le plus critique de cet inventaire. Sans accès à la console Supabase, il est impossible de confirmer que chaque table a des policies correctement configurées. Ce risque est classifié non-vérifiable mais à traiter en priorité avant tout déploiement public (voir section Points non vérifiables).

---

### 0b — Edge Functions

| Fonction | Rôle | Déclencheur | `_shared/` importés | Auth | Statut audit |
|----------|------|-------------|---------------------|------|--------------|
| `bienvenue-auth` | Email de bienvenue + création ligne `identites` | Webhook DB (INSERT `auth.users`) | `cors.ts`, `notifier.ts` | `x-webhook-secret` | Examiné — création identites correcte ; lié à **P-BIENV** |
| `contacter-support` | Envoi message support → `SUPPORT_EMAIL` | Appel direct Flutter (JWT Bearer) | `cors.ts`, `email.ts` | JWT Bearer | Examiné — **P-SPAM** (anti-spam basé sur INSERT sans lecture préalable) |
| `don-manuel` | Mise à jour `dernier_don_date` + historique déclaratif | Appel direct Flutter (JWT Bearer) | `cors.ts` | JWT Bearer | Examiné — **P-DON-DATE** (pas de validation date future côté EF) |
| `envoyer-email` | Envoi d'email générique (template ou HTML custom) | Interne (appelé par d'autres EF) | `cors.ts`, `email.ts` | `x-internal-secret` OU service role key | Examiné — **P-EMAIL-AUTH** (si INTERNAL_SECRET absent, seul service role key accepté) |
| `executer-suppressions-programmees` | Suppression effective des comptes programmés | Cron `pg_cron` | `cors.ts`, `notifier.ts` | Service role key | Examiné — lit `identites` ; **P13** ; email avant suppression OK |
| `lire-notifications` | Lecture et marquage des notifications | Appel direct Flutter (JWT Bearer) | `cors.ts` | JWT Bearer (via `adminClient.auth.getUser`) | Examiné — aucun problème supplémentaire trouvé |
| `matcher-et-notifier` | Notification des donneurs compatibles lors d'une nouvelle demande | Webhook DB (INSERT `demandes_sang`) | `cors.ts`, `notifier.ts`, `email.ts` | `x-webhook-secret` | **P3** (webhook non vérifiable) |
| `mdp-modifie-auth` | Notification changement de mot de passe | Webhook DB (UPDATE `auth.users`) OU appel JWT direct Flutter | `cors.ts`, `notifier.ts` | Dual : `x-webhook-secret` OU JWT Bearer | Examiné — dual mode correctement implémenté ; aucun problème supplémentaire |
| `reponse-donneur` | Notification au demandeur et au donneur après réponse | Webhook DB (INSERT `reponses_donneurs`) | `cors.ts`, `notifier.ts` | `x-webhook-secret` | **P3** (webhook non vérifiable) |
| `retour-eligibilite-cron` | Notification de retour d'éligibilité | Cron `pg_cron` | `cors.ts`, `notifier.ts` | Service role key | Examiné — **P10** (scan sans `.limit()`) |
| `valider-token` | Validation QR code don + mise à jour historique | Appel direct Flutter + auth double | `cors.ts`, `notifier.ts` | `x-webhook-secret` + JWT Bearer | **P2** (WEBHOOK_SECRET vide si non fourni au build Flutter) |

> **EF non présente dans le code source mais référencée** : `mdp-modifie-auth` référence `action=suppression_demandee` — vérifiable dans le code (`_declencherNotificationSuppressionDemandee()`). 15 EF au total, toutes présentes et lues.

---

### 0c — Triggers et jobs cron

| Élément | Fréquence / Déclencheur | Fonction | Statut audit |
|---------|------------------------|----------|--------------|
| `trg_creer_identite_safe` | INSERT sur `auth.users` (DB trigger) | Créé dans `supabase-fix-signup-500.sql` — crée une ligne dans `public.identites` | **P-DOUB** : doublon avec `bienvenue-auth` qui fait également un upsert `identites`. Risque de conflits ou de redondance. Vérifier si les deux coexistent en production. |
| Cron `retour-eligibilite-cron` | Défini dans `mission-d.sql §9` | Planifié via `pg_cron` + URL EF Supabase | **P4** : placeholders `<PROJECT_REF>` et `<SERVICE_ROLE_KEY>` non substitués dans `mission-d.sql`. Non exécutable tel quel. Statut réel en production : non vérifiable. |
| Cron `executer-suppressions-programmees` | Défini dans `mission-d.sql §9` | Planifié via `pg_cron` + URL EF Supabase | **P4** : même problème de placeholders. |
| Webhooks DB `matcher-et-notifier` | INSERT sur `public.demandes_sang` | Déclenche notification aux donneurs compatibles | **P3** : configuration effective non vérifiable depuis sandbox. |
| Webhooks DB `reponse-donneur` | INSERT sur `public.reponses_donneurs` | Déclenche notification demandeur/donneur | **P3** : configuration effective non vérifiable depuis sandbox. |
| Webhooks Auth `bienvenue-auth` | INSERT sur `auth.users` | Email de bienvenue | ⚠️ Non vérifiable depuis sandbox. Implémentation correcte côté EF. |
| Webhooks Auth `mdp-modifie-auth` (mode webhook) | UPDATE sur `auth.users` | Notification changement mdp | ⚠️ Non vérifiable depuis sandbox. Fallback JWT disponible. |

---

### 0d — Écrans Flutter

| Écran | Fichier | Rôle | Actions utilisateur | Appels réseau | Cas limites vérifiés | Statut audit |
|-------|---------|------|--------------------|--------------|--------------------|--------------|
| `LoginScreen` | `login_screen.dart` (1449L) | Auth : connexion, inscription, profil, mdp oublié | Login, signup, création profil, mdp oublié | `connecter()`, `inscrire()`, `sauvegarderProfil()`, `lireVilles()`, `envoyerEmailReinitialisation()` | ✅ Erreur réseau affichée (SnackBar) ; ✅ ville non chargée gérée ; ⚠️ Rate limiting client-side (voir **P9**) | Examiné — **P9** |
| `HomeScreen` | `home_screen.dart` (280L) | Liste des demandes actives filtrées par ville profil | Rafraîchir, naviguer vers détail, accéder aux alertes | `actualiserDemandes()` | ✅ RefreshIndicator ; ⚠️ pas de message "liste vide" explicite auditable | Examiné — aucun problème bloquant |
| `DemandesScreen` | `demandes_screen.dart` (211L) | Toutes les demandes actives, toutes villes | Filtrer par groupe sanguin | `lireToutesDemandesActives()` | ✅ Filtre en mémoire ; ⚠️ pas de limite de résultats côté requête | Examiné — **P10-bis** |
| `NouvelleDemandeScreen` | `nouvelle_demande_screen.dart` (817L) | Créer une demande de sang | Saisie groupe/ville/structure/contact, soumettre | `lireVilles()`, `lireStructures()`, `creerDemande()` | ✅ Contact min 8 chiffres ; ✅ ville obligatoire ; ✅ max 3 demandes actives (anti-spam côté client ET serveur) | Examiné — aucun problème bloquant |
| `DetailDemandeScreen` | `detail_demande_screen.dart` (719L) | Détail demande, répondre, générer/scanner QR | Répondre, générer QR, scanner QR | `verifierReponduDemande()`, `enregistrerReponseDonneur()`, `creerToken()`, `lireTokenQrExistant()` | ✅ Contact masqué avant réponse confirmée ; ⚠️ bouton "Scanner un code" visible pour tous (voir **P-SCANALL**) | Examiné — **P-SCANALL** |
| `ScanQrScreen` | `scan_qr_screen.dart` (567L) | Scan QR ou saisie manuelle du code | Scanner, valider | `validerToken()` | ✅ Guard `demandeurId` non vide ; ✅ fallback manuel Web ; **P2** (WEBHOOK_SECRET vide) | Examiné — **P2** |
| `ProfilScreen` | `profil_screen.dart` (1594L) | Profil, disponibilité, don déclaratif, paramètres compte | Toggle disponible, déclarer don, modifier profil, supprimer compte | `mettreAJourDisponibilite()`, `enregistrerDon()`, `sauvegarderProfil()`, `programmerSuppression()` | ✅ Double confirmation suppression ; ✅ lastDate: DateTime.now() pour don ; ✅ bannière suppression programmée | Examiné — **P-DON-DATE** (validation date uniquement client-side) |
| `AlertesScreen` (notifications) | `notifications_screen.dart` (278L) | Liste des notifications | Marquer lue / tout marquer lu | `lireNotifications()`, `marquerNotificationLue()`, `marquerToutesLues()` | ✅ Pagination implicite (50 dernières) ; ⚠️ messages texte générés côté client | Examiné — aucun problème bloquant |
| `HistoriqueScreen` | `historique_screen.dart` (482L) | Historique des dons et demandes | Pagination scroll-to-load | `lireHistoriqueUtilisateur()` | ✅ Pagination 25/page ; ✅ combinaison dons+demandes triée en mémoire ; ✅ scroll-to-load | Examiné — aucun problème bloquant |
| `ResetPasswordScreen` | `reset_password_screen.dart` (731L) | Réinitialisation mot de passe via OTP email | Email → code 6 chiffres → nouveau mdp | `envoyerEmailReinitialisation()`, `verifierCodeReinitialisation()`, `changerMotDePasseAvecToken()` | ✅ Flux 3 étapes ; ✅ anti-énumération (Supabase retourne 200 même si email inconnu) | Examiné — aucun problème bloquant |
| `ChangePasswordScreen` | `change_password_screen.dart` (853L) | Modifier mdp (connu) ou mdp oublié (email) | Saisir ancien+nouveau mdp OU envoyer email | `verifierMotDePasse()`, `changerMotDePasse()`, `declencherNotificationMdpModifie()`, `envoyerEmailReinitialisation()` | ✅ Vérification ancien mdp avant changement ; ✅ indicateurs robustesse (8 car., majuscule, chiffre) ; ✅ notification fire-and-forget | Examiné — aucun problème bloquant |
| `ContactScreen` (Aide) | `contact_screen.dart` (704L) | FAQ accordéon + formulaire support | Ouvrir FAQ, envoyer message | `envoyerMessageSupport()` | ✅ Validation objet (max 100 car.) et message (20-2000 car.) ; ✅ anti-spam 429 géré | Examiné — aucun problème bloquant |
| `ParametresScreen` | `parametres_screen.dart` (392L) | Liens externes, version app, accès settings | Ouvrir URL externe | `lireLiensExternes()` | ✅ url_launcher pour URLs externes ; **P-VER** : version "1.0.0" hardcodée | Examiné — **P-VER** |
| `CompleterProfilScreen` | `login_screen.dart` (imbriqué — `_ProfilForm`) | Compléter profil après inscription | Saisir groupe/genre/poids/ville/téléphone/consentement | `sauvegarderProfil()`, `enregistrerConsentement()` | ✅ Consentement obligatoire vérifié ; ✅ `consentementGeoloc: false` explicite | Examiné — aucun problème bloquant |

---

### 0e — Secrets et variables d'environnement Supabase

| Variable | Utilisée dans | Valeur par défaut déclarée | Risque si absente | Statut |
|----------|---------------|---------------------------|-------------------|--------|
| `SUPABASE_URL` | Toutes les EF, `supabase_service.dart` | Hardcodée côté Flutter (`_kSupabaseUrlProd`) | Bloquant pour EF | ⚠️ Non vérifiable si configurée dans le dashboard Supabase |
| `SUPABASE_SERVICE_ROLE_KEY` | Toutes les EF (adminClient) | Aucune — injectée via dashboard | EF inopérantes | ⚠️ Non vérifiable depuis sandbox |
| `SUPABASE_ANON_KEY` | `supabase_service.dart` | Hardcodée (`_kAnonKeyProd`) | Aucun (Flutter a fallback) | ✅ Présente dans le code ; clé anon = publique par nature |
| `WEBHOOK_SECRET` | `bienvenue-auth`, `matcher-et-notifier`, `reponse-donneur`, `valider-token`, `mdp-modifie-auth` (mode webhook) | Aucune (côté Supabase) — côté Flutter : aucune (voir **P2**) | **Bloquant** pour `valider-token` si absent du build Flutter | **P2** |
| `BREVO_API_KEY` | `_shared/email.ts` (prioritaire) | Aucune | Bascule sur Resend | ⚠️ Non vérifiable |
| `RESEND_API_KEY` | `_shared/email.ts` (fallback) | Aucune | Emails non envoyés | ⚠️ Non vérifiable |
| `FCM_SERVICE_ACCOUNT_JSON` | `_shared/fcm.ts` | Aucune | Notifications push désactivées | ⚠️ Non vérifiable |
| `SUPPORT_EMAIL` | `contacter-support/index.ts` | `songre.contact@gmail.com` (défaut codé) | Emails support à adresse par défaut | Examiné — valeur par défaut acceptable |
| `INTERNAL_SECRET` | `envoyer-email/index.ts` | Aucune | Auth restreinte au service role key uniquement | Examiné — non bloquant (fallback service role key existe) |
| `APP_URL` | `_shared/email.ts` (templates) | Aucune | URLs dans emails cassées | ⚠️ Non vérifiable |

---

### 0f — Clés et identifiants sensibles côté Flutter

| Identifiant | Fichier + ligne | Nature | Présence client nécessaire ? | Risque | Statut |
|-------------|-----------------|--------|------------------------------|--------|--------|
| `_kSupabaseUrlProd` = `https://ptomqwucvveuflfnyczo.supabase.co` | `supabase_service.dart` L24-25 | URL projet Supabase | ✅ Oui (endpoint public) | Faible — URL prévisible, pas un secret | Acceptable |
| `_kAnonKeyProd` (JWT anon signé) | `supabase_service.dart` L27-29 | Clé anonyme Supabase | ✅ Oui (conçu pour être public) | Faible — rôle limité, RLS protège les données | Acceptable |
| `SONGRE_ENCRYPT_KEY` defaultValue `'SongreProdBurkinaFaso2026_SecureKey!'` | `crypto_service.dart` (defaultValue hardcodé) | Clé AES-256-CBC symétrique | ⚠️ Non — devrait être injectée uniquement via `--dart-define` | **Critique** — clé de déchiffrement des contacts dans l'APK | **P1 BLOQUANT** |
| `WEBHOOK_SECRET` (sans defaultValue) | `supabase_service.dart` L53-55 | Secret partagé Flutter → EF `valider-token` | ✅ Oui (nécessaire pour valider-token) | Élevé si absent au build (QR inopérant) | **P2 BLOQUANT** |
| `AIzaSyCYoh65TZC5jfb9WEQGszLa6wK16pJupCI` (`current_key`) | `android/app/google-services.json` | Clé API Firebase (Android Restricted) | ✅ Oui (intégration FCM Android) | Faible si correctement restreinte côté Firebase Console | **P-FCM-KEY** : vérifier restrictions |
| Package name `com.songre.app` | `build.gradle.kts`, `google-services.json`, `AndroidManifest.xml` | Identifiant Android | ✅ Oui | Cohérent avec l'identité SONGRE | **P11 RÉSOLU** |

---

## AXE 1 — Fonctionnalité et logique métier

### F1 — Inscription et connexion

**Inscription (étape email/mdp)** — `login_screen.dart` L699-731, `app_state.dart`
- ✅ Validation email (`contains('@') && contains('.')`) et mdp (min 8 caractères) côté Flutter
- ✅ En cas d'échec, `state.authError` affiché en SnackBar rouge
- ✅ Après inscription réussie, passage automatique à l'étape profil (`onSuccess`)
- ✅ Guard router : si `isAuthenticated && profil == null` → redirige vers `/completer-profil`

**Création de profil** — `login_screen.dart` L1112-1209
- ✅ Groupe sanguin, genre, poids (50-150 kg validé), ville (obligatoire), quartier (optionnel), téléphone (optionnel, chiffré avant envoi), contre-indications, consentement RGPD
- ✅ Consentement coché obligatoire — vérifié avant soumission
- ✅ `consentementGeoloc: false` déclaré explicitement (géolocalisation non implémentée)
- ⚠️ `enregistrerConsentement()` appelé en fire-and-forget — si réseau défaillant à cet instant, le consentement n'est jamais enregistré. Ce point est documenté dans le code (`// une erreur réseau ici ne bloque pas`) mais constitue un risque RGPD à mentionner.

**Connexion** — `login_screen.dart` L380-463
- ✅ Rate limiting client-side (5 échecs → 60s blocage)
- ⚠️ **P9** : Ce rate limiting est purement client-side, réinitialisé si l'utilisateur quitte et revient sur l'écran. Documenté comme tel dans le code (`// limitation inhérente, acceptable`). La vraie protection anti-bruteforce repose sur les codes 429 de Supabase Auth.
- ✅ Gestion correcte du cas `state.authError != null` après connexion réussie (profil non chargé)
- ✅ Fallback `context.go('/home')` si GoRouter ne redirige pas immédiatement

### F2 — Création d'une demande de sang

**`nouvelle_demande_screen.dart`** (817L) + `supabase_service.dart` L802-890
- ✅ Contact principal obligatoire (min 8 chiffres, validé côté Flutter)
- ✅ Ville ou ville libre obligatoire (`chk_ville_renseignee` respectée dans le body)
- ✅ Structure ou structure libre (`chk_structure_renseignee` respectée)
- ✅ Anti-spam max 3 demandes actives — vérifié côté client via `_compterDemandesActives()` qui utilise `Prefer: count=exact` (header Content-Range) — robuste depuis correction S-08
- ✅ Contact chiffré AES-256-CBC avant envoi en base
- ⚠️ **P8** : Aucun email de confirmation de publication de demande n'est envoyé au demandeur. `app_state.dart` `publierDemande()` ne déclenche qu'une notification in-app locale. Fonctionnalité absente (pas défaillante).

**Durée de validité** — **P5 IMPORTANT**
- Preuve : `models.dart` → `kDureeValiditeDemande = const Duration(hours: 168)` (7 jours)
- Preuve : `mission-e.sql §3` → `expires_at TIMESTAMP DEFAULT (NOW() + INTERVAL '72 hours')` (3 jours)
- **Impact** : L'application affiche "valide 7 jours" (`kDureeValiditeDemandeLabel`) mais la base de données expire les demandes à 72h. L'utilisateur voit ses demandes expirer 4 jours avant ce qu'affiche l'interface. Confusion garantie, perte de confiance.

### F3 — Parcours de réponse donneur et confirmation QR

**Répondre à une demande** — `detail_demande_screen.dart` + `supabase_service.dart` L1163
- ✅ Vérification serveur (`verifierReponduDemande()`) avant d'afficher le contact chiffré
- ✅ INSERT `reponses_donneurs` avec `Prefer: return=minimal,resolution=ignore-duplicates` (idempotent)
- ✅ Déchiffrement AES du contact uniquement si `_repondu && demande.contactChiffre != null`

**Génération QR** — `detail_demande_screen.dart` + `supabase_service.dart` L898-966
- ✅ `lireTokenQrExistant()` vérifie d'abord s'il existe un token valide non expiré avant d'en créer un nouveau — évite les tokens orphelins
- ✅ `expires_at` contrôlé par SQL (`mission-e.sql §3`)

**Validation QR (scan)** — `scan_qr_screen.dart` + `supabase_service.dart` L968-1013
- ⚠️ **P2 BLOQUANT** : `_webhookSecret` est `String.fromEnvironment('WEBHOOK_SECRET')` sans defaultValue → chaîne vide si `--dart-define=WEBHOOK_SECRET=...` non fourni au build. L'EF `valider-token` vérifie explicitement que le secret est non vide et non null, sinon retourne 500. Avec secret vide, elle retourne 401 (secret reçu ≠ secret attendu). **Tous les scans QR échouent en production si ce `--dart-define` est oublié.**
- ✅ Guard `demandeurId.isEmpty` → redirige vers `/home` (évite l'accès non authentifié)
- ⚠️ **P-SCANALL** : Le bouton "Scanner un code" dans `detail_demande_screen.dart` est visible pour tous les utilisateurs (pas seulement les demandeurs). La navigation vers `/scan-qr` a bien un guard `demandeurId`, mais l'affichage du bouton lui-même n'est pas conditionné à être l'auteur de la demande. Confusion UX possible.

### F4 — Calcul d'éligibilité et compatibilité sanguine

**Éligibilité** — `models.dart` (ProfilDonneur.estEligible)
- ✅ 60 jours homme, 90 jours femme — cohérent avec la FAQ (`contact_screen.dart` L67)
- ✅ `retour-eligibilite-cron` utilise également 60j/90j — cohérent

**Compatibilité** — `models.dart` (DemandeSang.estCompatibleAvec)
- ✅ Matrice de compatibilité ABO/Rh implémentée côté Flutter
- ⚠️ La matrice n'est pas vérifiable côté serveur (pas d'EF qui valide la compatibilité) — c'est uniquement UX, le serveur accepte n'importe quelle réponse

**Délai de notification retour d'éligibilité** — `retour-eligibilite-cron/index.ts`
- ⚠️ Filtre : `dernier_don_date` entre `now - 91j` et `now - 59j`. Logique : on notifie les utilisateurs qui approchent de leur délai (< 1 jour restant). Fenêtre de 59-91 jours = couvre les cas près du délai pour les deux genres. Logique correcte mais nom de variable `dateMin60` trompeur.

### F5 — Notifications

| Notification | Déclencheur | Email | FCM | In-app | Statut |
|-------------|------------|-------|-----|--------|--------|
| `bienvenue` | INSERT auth.users → webhook | ✅ EF `bienvenue-auth` | ✗ | ✅ INSERT `notifications_envoyees` | Fonctionnel si webhook configuré |
| `nouvelle_demande_compatible` | INSERT demandes_sang → webhook `matcher-et-notifier` | ✅ | ✅ | ✅ | **P3** — webhook non vérifié |
| `reponse_recue` (demandeur) | INSERT reponses_donneurs → webhook `reponse-donneur` | ✅ | ✅ | ✅ | **P3** — webhook non vérifié |
| `reponse_confirmee` (donneur) | INSERT reponses_donneurs → webhook | ✅ | ✅ | ✅ | **P3** — webhook non vérifié |
| `don_confirme` (donneur) | `valider-token` EF | ✅ | ✅ | ✅ | Fonctionnel si **P2** résolu |
| `don_confirme_demandeur` | `valider-token` EF | ✅ | ✅ | ✅ | Fonctionnel si **P2** résolu |
| `don_enregistre_manuel` | `don-manuel` EF | ✅ | ✅ | ✅ | Fonctionnel |
| `mdp_modifie` | `mdp-modifie-auth` (dual mode) | ✅ | ✅ | ✅ | Fonctionnel (dual mode = fallback JWT si webhook absent) |
| `suppression_demandee` | `programmerSuppression()` → `mdp-modifie-auth` | ✅ | ✅ | ✅ | Fonctionnel |
| `suppression_confirmee` | `executer-suppressions-programmees` cron | ✅ | ✗ | ✗ | Fonctionnel si cron actif (**P4**) |
| `retour_eligibilite` | `retour-eligibilite-cron` | ✅ | ✅ | ✅ | Fonctionnel si cron actif (**P4**) |

### F6 — Gestion de profil

- ✅ Toggle disponibilité : PATCH `profils_donneurs.disponible`
- ✅ Don déclaratif : sélecteur de date avec `lastDate: DateTime.now()` — validation Flutter uniquement (voir **P-DON-DATE**)

**P-DON-DATE** (MINEUR) : `don-manuel` EF ne valide pas que `date_don` n'est pas dans le futur. Un utilisateur qui modifie la requête directement (hors UI Flutter) peut entrer une date future. Côté Flutter, la validation est correcte (`lastDate: DateTime.now()`). Impact limité en pratique.

### F7 — Suppression de compte

- ✅ Double confirmation UI (bottom sheet → AlertDialog)
- ✅ Délai 5 jours (`Duration(days: 5)`) — documenté en FAQ (`contact_screen.dart` L87 : "5 jours")
- ✅ Bannière de suppression programmée affichée sur `profil_screen.dart`
- ✅ Annulation possible via `annulerSuppression()`
- ✅ `executer-suppressions-programmees` envoie email de confirmation AVANT suppression
- ⚠️ `executer-suppressions-programmees` lit depuis `identites.suppression_programmee_le` — `programmerSuppression()` écrit dans `identites?user_id=eq.$userId` → cohérent ✅
- ⚠️ **P4** : Si le cron `pg_cron` n'est pas configuré, les suppressions programmées ne sont jamais exécutées → les utilisateurs ayant demandé la suppression restent en base indéfiniment. Problème RGPD potentiel.

### F8 — Réinitialisation de mot de passe

- ✅ Flux 3 étapes : email → code OTP 6 chiffres → nouveau mdp
- ✅ Supabase retourne 200 même si email inexistant (anti-énumération)
- ✅ `context.push('/reset-password', extra: email)` correctement passé
- ⚠️ Dans `change_password_screen.dart` mode "mdp oublié", l'email est envoyé mais redirige vers un écran de confirmation simple sans OTP (chemin différent de `login_screen.dart` → `/reset-password`). Les deux implémentations coexistent avec des comportements légèrement différents mais non contradictoires.

### F9 — Contact support

**P-SPAM (MINEUR)** : `contacter-support/index.ts` — Anti-spam basé sur INSERT dans `contact_spam_log` sans lecture préalable du comptage. Pseudocode actuel :
```
INSERT INTO contact_spam_log (user_id) → si conflit (unique constraint) → retourne 429
```
Si l'unicité n'est pas contrainte sur `(user_id, timestamp/window)` mais sur `user_id` seul, un utilisateur ne peut envoyer qu'un seul message à vie. Si aucune contrainte n'existe, il n'y a pas d'anti-spam effectif. Le mécanisme exact dépend du schéma de `contact_spam_log` (non vérifiable sans accès DB).

### F10 — Historique et pagination

- ✅ Pagination 25 items/page avec `lireHistoriqueUtilisateur()`
- ✅ `aUnePageSuivante` calculé avec `pageSize + 1` (pattern correct)
- ✅ Combine dons et demandes triés par date DESC en mémoire
- ✅ Scroll-to-load correctement implémenté

---

## AXE 2 — Sécurité

### SEC-01 — Clé AES hardcodée — **BLOQUANT (P1)**

**Preuve** : `lib/utils/crypto_service.dart`
```dart
static const String _encryptionKey = String.fromEnvironment(
  'SONGRE_ENCRYPT_KEY',
  defaultValue: 'SongreProdBurkinaFaso2026_SecureKey!',
);
```

**Risque** : CRITIQUE. Si le build APK de production est réalisé sans `--dart-define=SONGRE_ENCRYPT_KEY=<valeur>`, la clé AES apparaît en clair dans le binaire compilé. Un attaquant avec accès à l'APK (disponible publiquement sur le Play Store) peut extraire cette clé avec des outils basiques (strings, jadx sur la partie dart2js, ou extraction des constantes Dart compilées). La clé permet de déchiffrer tous les contacts et numéros de téléphone stockés dans la base de données — données médicales sensibles.

**Impact** : Violation RGPD, violation de la confidentialité des donneurs, risque de harcèlement si des contacts sont exposés.

**Difficulté de correction** : Faible. Fournir `--dart-define=SONGRE_ENCRYPT_KEY=<clé_production>` à CHAQUE build release. Si la clé a déjà été exposée dans l'APK public, régénérer la clé ET rechiffrer toutes les données en base.

**Solution** : `flutter build apk --release --dart-define=SONGRE_ENCRYPT_KEY=<secret_non_connu>`

---

### SEC-02 — WEBHOOK_SECRET vide → QR inopérant en production — **BLOQUANT (P2)**

**Preuve** : `lib/services/supabase_service.dart` L53-55
```dart
static const String _webhookSecret = String.fromEnvironment('WEBHOOK_SECRET');
// Pas de defaultValue → chaîne vide si non fourni au build
```
**Preuve** : `supabase/functions/valider-token/index.ts`
```typescript
const webhookSecret = Deno.env.get("WEBHOOK_SECRET");
if (!webhookSecret || webhookSecret.trim().length === 0) {
  return errorResponse("Configuration serveur incomplète...", 500, corsHeaders);
}
const receivedSecret = req.headers.get("x-webhook-secret");
if (receivedSecret !== webhookSecret) {
  return errorResponse("Authentification webhook invalide.", 401, corsHeaders);
}
```

**Comportement** : `validerToken()` ajoute `'x-webhook-secret': _webhookSecret` uniquement si `_webhookSecret.isNotEmpty`. Si vide, le header n'est pas envoyé → EF reçoit `null` → 401 retourné.

**Impact** : CRITIQUE. Tous les scans QR échouent avec "Authentification webhook invalide". Le flux de confirmation de don via QR est totalement inopérant.

**Difficulté de correction** : Faible. Ajouter `--dart-define=WEBHOOK_SECRET=<secret_supabase_vault>` au build release.

**Solution** : `flutter build apk --release --dart-define=WEBHOOK_SECRET=<valeur_vault_supabase>`

---

### SEC-03 — Firebase.initializeApp() sans DefaultFirebaseOptions — IMPORTANT (P6)

**Preuve** : `lib/main.dart` L17 :
```dart
await Firebase.initializeApp(); // sans DefaultFirebaseOptions
```

**Risque** : Crash de l'application sur la plateforme Web avec "No Firebase App '[DEFAULT]' has been created". Sur Android, `google-services.json` fournit automatiquement la configuration via le plugin Gradle, donc cela ne pose pas de problème pour le déploiement Android APK.

**Impact** : La version Web de l'application (utilisée pour la démonstration) crashe au démarrage.

**Difficulté de correction** : Modérée. Créer `firebase_options.dart` avec la configuration multi-plateforme.

---

### SEC-04 — Code non obfusqué / APK non compressé — IMPORTANT (P7)

**Preuve** : `android/app/build.gradle.kts` L53 :
```kotlin
isMinifyEnabled = false     // ⚠️ pas d'obfuscation
isShrinkResources = false   // ⚠️ APK non compressé
```

**Risque** : Sans obfuscation, les noms de classes et méthodes Dart/Java restent lisibles dans l'APK. Couplé au problème **P1** (clé AES récupérable), l'extraction des secrets est facilitée. L'APK de 74 MB est plus volumineux que nécessaire (compression désactivée).

**Impact** : Facilite la rétro-ingénierie, expose les URLs hardcodées, les noms de classes métier, les constantes.

**Difficulté de correction** : Faible. Activer `isMinifyEnabled = true` et `isShrinkResources = true`, tester que l'app fonctionne après obfuscation (risque de crash Dart si des bibliothèques de réflexion sont utilisées — à vérifier).

---

### SEC-05 — Stockage non sécurisé sur Web — DOCUMENTÉ, ACCEPTABLE

**Preuve** : `lib/utils/secure_storage_service.dart` — commentaire explicite :
```dart
// Web : SharedPreferences (localStorage) ⚠️ NON SÉCURISÉ — documenté comme tel
static bool get estPlatformeNonSecurisee => kIsWeb;
```
**Preuve** : `lib/widgets/web_security_banner.dart` — bannière affichée sur Web avec avertissement.

La bannière Web (`web_security_banner.dart`) affiche explicitement : *"Version Web — démonstration uniquement. L'authentification sur navigateur utilise un stockage non sécurisé. Utilisez l'application mobile pour des données médicales réelles."*

**Statut** : Documenté, acceptable. La version Web est explicitement présentée comme démo uniquement. Non bloquant pour le store Android.

---

### SEC-06 — Clé API Firebase dans google-services.json — MINEUR

**Preuve** : `android/app/google-services.json` :
```json
"current_key": "AIzaSyCYoh65TZC5jfb9WEQGszLa6wK16pJupCI"
```

Cette clé API est destinée à être présente dans l'APK Android (Google le sait et la conçoit comme telle). **Cependant**, il est impératif qu'elle soit correctement restreinte dans la Firebase Console (restriction par package Android + SHA-1). Si elle n'est pas restreinte, elle peut être utilisée pour des appels API frauduleux.

**Difficulté de correction** : Faible. Vérifier les restrictions dans Firebase Console → APIs & Services → Credentials.

---

### SEC-07 — RLS Supabase non vérifiable — NON VÉRIFIABLE

L'absence d'accès direct à la console Supabase empêche de confirmer que les policies RLS sont correctement configurées sur toutes les tables. C'est le risque de sécurité le plus important à vérifier avant le lancement :

- Un utilisateur pourrait lire les profils d'autres utilisateurs (`profils_donneurs`)
- Un utilisateur pourrait accéder aux contacts chiffrés de demandes auxquelles il n'a pas répondu
- Un utilisateur pourrait modifier les données d'autres utilisateurs

**Action requise** : Audit RLS complet dans la console Supabase avant tout lancement public.

---

### SEC-08 — Package name incohérent — MINEUR (P11)

**Preuve** : `build.gradle.kts` + `google-services.json` : `com.songre.app`

Le package name `com.songre.app` est désormais cohérent avec l'identité SONGRE. Nouveau projet Firebase : `songre-88f2a` (project_number : `855352190629`). **RÉSOLU le 2026-07-17.**

**Impact** : Cosmétique mais définitif. Toute mise à jour future devra utiliser ce même package name. Si l'identité de marque SONGRE est importante, ce nom pourrait créer de la confusion.

---

## AXE 3 — Performance

### PERF-01 — Absence de limite sur `lireToutesDemandesActives()`

**Preuve** : `supabase_service.dart` L761-800
```dart
static Future<List<DemandeSang>> lireToutesDemandesActives({...}) async {
  // Pas de LIMIT sur la requête
  final url = Uri.parse('$_supabaseUrl/rest/v1/demandes_sang?statut=eq.active...');
```

**Impact** : Avec peu d'utilisateurs actuellement, cela n'est pas problématique. Avec une croissance significative (centaines de demandes actives simultanées), le chargement de la liste sans pagination peut devenir lent et consommer beaucoup de mémoire côté client.

**Solution** : Ajouter `&limit=50&offset=...` et implémenter une pagination similaire à `lireHistoriqueUtilisateur()`.

---

### PERF-02 — `retour-eligibilite-cron` sans `.limit()` — MINEUR (P10)

**Preuve** : `supabase/functions/retour-eligibilite-cron/index.ts` — requête sans `.limit()` sur `profils_donneurs`.

**Impact** : À l'échelle actuelle (Burkina Faso, utilisateurs limités), impact négligeable. Avec des milliers de profils, la requête scanne la table entière à chaque exécution cron.

---

### PERF-03 — Absence de mise en cache des listes statiques (villes, structures)

**Preuve** : `app_state.dart` stocke `villes` en cache — logique correcte. `login_screen.dart` vérifie `appState.villes.isEmpty` avant d'appeler `SupabaseService.lireVilles()`. ✅ Cache présent.

**Preuve** : `lireStructures(villeId)` n'est pas mise en cache — appeléé à chaque sélection de ville dans `nouvelle_demande_screen.dart`.

**Impact** : Mineur — appel réseau répété pour les structures à chaque changement de ville. Acceptable pour l'usage actuel.

---

### PERF-04 — Taille APK (74 MB)

**Preuve** : Dernier build `flutter build apk --release` → 74.0 MB (session précédente).

**Impact** : 74 MB est dans la norme pour une app Flutter avec Firebase et polices Google Fonts. Sans `isShrinkResources = true`, l'APK contient des ressources non utilisées. Activation de la minification pourrait réduire significativement la taille.

---

### PERF-05 — Requête double dans `lireContactsDonneurs()`

**Preuve** : `supabase_service.dart` L1103-1158 — 2 requêtes séquentielles (d'abord les réponses, puis les profils).

**Impact** : Deux aller-retours réseau séquentiels. Acceptable pour l'usage actuel (peu de donneurs par demande). Une jointure côté PostgREST (via `select=donneur_id,profils_donneurs(telephone_chiffre)`) serait plus efficace.

---

## AXE 4 — Scalabilité

### SCALE-01 — Architecture crons pg_cron non déployée — BLOQUANT (P4)

**Preuve** : `supabase/functions/mission-d.sql §9` :
```sql
SELECT cron.schedule('retour-eligibilite', '0 8 * * *',
  $$SELECT net.http_post(url := 'https://<PROJECT_REF>.supabase.co/functions/v1/retour-eligibilite-cron', ...)$$
);
```

Les placeholders `<PROJECT_REF>` et `<SERVICE_ROLE_KEY>` sont des valeurs littérales non substituées. Ce script SQL ne peut pas être exécuté tel quel. Si `pg_cron` n'a jamais été configuré avec des vraies valeurs, les deux jobs automatiques (`executer-suppressions-programmees` + `retour-eligibilite-cron`) ne s'exécutent jamais.

**Impact** :
- Les suppressions de comptes programmées ne s'exécutent pas → violation RGPD (données non supprimées)
- Les notifications de retour d'éligibilité ne sont jamais envoyées → feature manquante

---

### SCALE-02 — `matcher-et-notifier` : boucle sans limite sur N donneurs compatibles

**Preuve** : `supabase/functions/matcher-et-notifier/index.ts` — itère sur tous les donneurs compatibles dans la ville.

**Impact** : Si 500 donneurs O+ sont disponibles à Ouagadougou lors d'une demande O+, l'EF envoie 500 emails et 500 FCM dans une boucle. Supabase Edge Functions ont une limite d'exécution (temps CPU, mémoire). Au-delà d'un certain nombre, les notifications seraient tronquées ou l'EF échouerait en timeout.

**Solution** : Limiter les notifications aux N premiers donneurs compatibles (ex : `LIMIT 50`) ou implémenter une file d'attente.

---

### SCALE-03 — Limites services tiers (email, FCM)

| Service | Limite plan gratuit / standard | Risque |
|---------|-------------------------------|--------|
| Brevo | 300 emails/jour (plan gratuit) | Insuffisant dès 30+ demandes/jour (10 emails par demande) |
| Resend | 100 emails/jour (plan gratuit) | Fallback encore plus limité |
| FCM | Illimité (gratuit pour mobile) | Pas de risque à l'échelle actuelle |
| Supabase Edge Functions | 500K invocations/mois (plan gratuit), 2M CPU ms | À surveiller selon la croissance |

**Impact** : Avec seulement 30+ nouvelles demandes par jour, le quota Brevo gratuit peut être dépassé, coupant les emails pour tous les utilisateurs.

---

### SCALE-04 — Webhooks Supabase : fiabilité et retries

Les webhooks Supabase DB ont un mécanisme de retry limité. Si `matcher-et-notifier` échoue (timeout, erreur réseau), la notification aux donneurs est perdue sans replay automatique garanti.

---

## AXE 5 — Réseau et fiabilité

### NET-01 — Timeouts définis et cohérents

Revue complète des timeouts dans `supabase_service.dart` :

| Opération | Timeout Flutter | Timeout EF | Cohérence |
|-----------|----------------|------------|-----------|
| `inscrire()` | 20s | N/A (Supabase Auth) | ✅ |
| `connecter()` | 20s | N/A | ✅ |
| `creerDemande()` | 10s | N/A | ✅ |
| `validerToken()` | 10s | Deno default ~60s | ✅ |
| `envoyerEmailReinitialisation()` | 15s | N/A | ✅ |
| `envoyerMessageSupport()` | 12s | Deno default ~60s | ✅ |
| `lireVilles()` | 8s | N/A | ✅ |
| `retour-eligibilite-cron` | N/A | Deno default ~60s | ✅ (cron, pas de timeout Flutter) |

**Constat** : Les timeouts Flutter sont systématiquement définis sur toutes les requêtes HTTP. Aucune requête sans timeout trouvée dans `supabase_service.dart`.

---

### NET-02 — Mécanisme de refresh token

**Preuve** : `supabase_service.dart` L261-299 — `_requeteAvecRefresh()` : si une requête retourne 401, tente automatiquement un refresh du token, puis rejoue la requête.

✅ Mécanisme de refresh implémenté et appliqué à la quasi-totalité des requêtes.

⚠️ `declencherNotificationMdpModifie()` et `_declencherNotificationSuppressionDemandee()` n'utilisent pas `_requeteAvecRefresh()` (fire-and-forget, acceptable).

---

### NET-03 — Gestion des erreurs réseau côté UI

**Revue** :
- ✅ `creerDemande()` retourne un message d'erreur explicite en cas d'exception réseau ("Impossible de publier. Vérifiez votre connexion.")
- ✅ `validerToken()` : "Erreur réseau lors de la validation."
- ✅ `login_screen.dart` : SnackBar en cas d'échec de connexion
- ✅ `scan_qr_screen.dart` : affichage d'erreur si validerToken échoue
- ✅ `nouvelle_demande_screen.dart` : erreur affichée si création échoue
- ✅ `historique_screen.dart` : `_error` state avec message d'erreur affiché
- ⚠️ `lireVilles()` en cas d'échec : `_villeSelectionnee` reste null → la validation de soumission retourne une erreur SnackBar explicite. ✅ Géré.

**Constat général** : La gestion des erreurs réseau est correcte et cohérente. L'utilisateur est toujours informé.

---

### NET-04 — Comportement hors ligne

**Preuve** : `contact_screen.dart` FAQ L91 : "Vos données de profil sont accessibles hors ligne. Cependant, les notifications, les nouvelles demandes et les validations de don nécessitent une connexion internet."

**Implémentation côté code** : Pas de cache local Hive/SharedPreferences pour les demandes actives. En cas de perte de connexion, la liste des demandes affiche les données en mémoire (état AppState) mais ne se rafraîchit pas. Aucune logique offline-first n'est implémentée au-delà du cache AppState en RAM.

**Constat** : Acceptable pour le contexte d'usage (application médicale urgente = connexion supposée disponible). La FAQ documente correctement les limitations.

---

### NET-05 — Absence de retry sur les opérations critiques

**P2-BIS (MINEUR)** : `enregistrerReponseDonneur()` — si l'INSERT en base échoue (réseau instable), aucun retry n'est effectué. L'utilisateur voit un échec mais doit recommencer manuellement. La logique d'idempotence (`resolution=ignore-duplicates`) protège contre les doublons en cas de double-envoi accidentel, mais ne gère pas le cas d'un premier échec.

---

## AXE 6 — Points bloquants avant publication stores

### STORE-01 — Politique de confidentialité

**Preuve** : `lib/screens/parametres_screen.dart` charge les `liens_externes` depuis la base de données. La politique de confidentialité est attendue à l'URL `https://songre.bf/politique-confidentialite` (mentionnée dans `login_screen.dart` L1098 : référence à la loi burkinabè n°010-2004/AN).

⚠️ **P14 NON VÉRIFIABLE** : L'URL `https://songre.bf/politique-confidentialite` n'est pas accessible depuis le sandbox. Sa disponibilité réelle ne peut pas être confirmée.

**Exigence Play Store** : Une politique de confidentialité accessible est **obligatoire** pour toute application collectant des données personnelles. Sans cette URL fonctionnelle, le dossier de soumission sera rejeté.

**Exigence App Store** : Identique.

---

### STORE-02 — Déclaration des données collectées

L'application collecte : email, groupe sanguin, genre, poids, numéro de téléphone (optionnel), ville, quartier, contre-indications médicales, historique des dons, tokens FCM.

**Play Store (Data Safety)** : La section "Sécurité des données" doit déclarer explicitement toutes ces données avec leur finalité, rétention, et partage éventuel. Les données médicales (groupe sanguin, contre-indications) entrent dans la catégorie "données sensibles" nécessitant une déclaration renforcée.

**App Store (Privacy Nutrition Labels)** : Identique. "Health & Fitness" et "Sensitive Info" devront être déclarés.

---

### STORE-03 — Permissions Android

**Preuve** : `android/app/src/main/AndroidManifest.xml` :
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

- `INTERNET` : ✅ Justifiée (API Supabase, emails, FCM)
- `CAMERA` : ✅ Justifiée (scanner QR code — `mobile_scanner`)
- `POST_NOTIFICATIONS` : ✅ Justifiée (FCM)

**Constat** : Aucune permission superflue. Cohérent avec les fonctionnalités de l'application.

---

### STORE-04 — Package name définitif

**P11** : `com.songre.app` — voir SEC-08. Package name changé vers `com.songre.app` (projet Firebase `songre-88f2a`). **RÉSOLU avant publication.** ✅

---

### STORE-05 — Version hardcodée

**P-VER (MINEUR)** : `lib/screens/parametres_screen.dart` : version "SONGRE v1.0.0" hardcodée dans la chaîne de caractères. Le `pubspec.yaml` déclare `version: 1.0.0+1`. Les deux sont cohérents pour la v1, mais cette version devra être mise à jour manuellement à chaque release.

---

### STORE-06 — Contenu de test ou de démonstration

✅ Aucun compte de test, compte démo, mode invité ou données factices n'ont été trouvés dans le code source Flutter. La bannière Web est correctement libellée "démonstration uniquement" et n'est affichée que sur Web.

⚠️ `_kAnonKeyProd` et `_kSupabaseUrlProd` dans `supabase_service.dart` pointent vers le projet Supabase de production (`ptomqwucvveuflfnyczo`). Il n'existe pas de séparation environnement staging/production dans le code Flutter. Toute version publiée utilise directement le backend de production.

---

### STORE-07 — `debugShowCheckedModeBanner: false`

**Preuve** : `lib/main.dart`
```dart
debugShowCheckedModeBanner: false,
```

✅ Le bandeau "DEBUG" ne s'affiche pas en production.

---

### STORE-08 — Icône d'application

**Preuve** : `pubspec.yaml` — `flutter_launcher_icons` configuré pour Android (`adaptive_icon_background`, `adaptive_icon_foreground`). iOS : `ios: false`.

✅ Icône Android configurée. iOS non ciblé actuellement.

---

### STORE-09 — Compatibilité Android minimale

**Preuve** : `android/app/build.gradle.kts` — `minSdk = 23` (Android 6.0).

✅ Acceptable. Couvre >95% des appareils Android actifs.

---

## Résumé exécutif

### Décompte par gravité

| Catégorie | Nombre | Identifiants |
|-----------|--------|-------------|
| 🔴 **BLOQUANT avant publication** | 4 | P1, P2, P3, P4 |
| 🟠 **IMPORTANT (non bloquant immédiatement)** | 5 | P5, P6, P7, P8, SEC-07 |
| 🟡 **MINEUR** | 9 | P9, P10, P11, P-DON-DATE, P-SCANALL, P-SPAM, P-VER, NET-05, SCALE-02 |
| ❓ **NON VÉRIFIABLE** | 8 | P3 (config effective), P4 (crons actifs), P12, P13, P14, SEC-07, SCALE-03, STORE-01 |

---

### 🔴 BLOQUANTS — À corriger avant toute publication

#### P1 — Clé AES hardcodée dans l'APK
- **Fichier** : `lib/utils/crypto_service.dart` — `defaultValue: 'SongreProdBurkinaFaso2026_SecureKey!'`
- **Correction** : Compiler avec `--dart-define=SONGRE_ENCRYPT_KEY=<clé_secrète>` sans defaultValue. Si une version APK a déjà été distribuée avec cette clé, régénérer la clé ET rechiffrer toutes les données en base.

#### P2 — WEBHOOK_SECRET absent au build → tous les scans QR échouent
- **Fichier** : `lib/services/supabase_service.dart` L53 + `supabase/functions/valider-token/index.ts`
- **Correction** : Compiler avec `--dart-define=WEBHOOK_SECRET=<valeur_vault>`. Vérifier que la valeur correspond au secret configuré dans le Vault Supabase.

#### P3 — Webhooks DB non vérifiables → emails nouvelle demande et réponse potentiellement absents
- **Fichier** : `supabase/functions/matcher-et-notifier/index.ts` + `supabase/functions/reponse-donneur/index.ts`
- **Correction** : Vérifier dans la console Supabase (Database → Webhooks) que `matcher-et-notifier` est configuré sur INSERT `public.demandes_sang` et `reponse-donneur` sur INSERT `public.reponses_donneurs`, avec le bon `WEBHOOK_SECRET`.

#### P4 — Crons pg_cron non configurés → suppressions et retours éligibilité inopérants
- **Fichier** : `supabase/functions/mission-d.sql §9` — placeholders `<PROJECT_REF>` et `<SERVICE_ROLE_KEY>` non substitués
- **Correction** : Substituer les placeholders et exécuter le SQL dans l'éditeur SQL Supabase. Vérifier que `pg_cron` est activé (Extension → pg_cron). Valider l'exécution réelle dans les logs.

---

### 🟠 IMPORTANTS — À corriger avant lancement grand public

#### P5 — Incohérence durée validité demande : 7j Flutter vs 72h SQL
- **Fichiers** : `lib/models/models.dart` (`kDureeValiditeDemande = Duration(hours: 168)`) vs `mission-e.sql §3` (`DEFAULT '72 hours'`)
- **Correction** : Aligner les deux. Recommandation : modifier `models.dart` pour correspondre au SQL (72h), OU modifier le SQL pour passer à 168h selon la décision métier.

#### P6 — Firebase.initializeApp() sans DefaultFirebaseOptions (crash Web)
- **Fichier** : `lib/main.dart` L17
- **Correction** : Créer `lib/firebase_options.dart` avec la configuration multi-plateforme, puis `await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`.

#### P7 — APK non obfusqué (isMinifyEnabled = false)
- **Fichier** : `android/app/build.gradle.kts` L53
- **Correction** : Activer `isMinifyEnabled = true` + `isShrinkResources = true` + configurer les règles ProGuard/R8 si nécessaire. Tester l'APK obfusqué avant soumission.

#### P8 — Pas d'email de confirmation de publication de demande
- **Fichier** : `lib/services/app_state.dart` — `publierDemande()` ne déclenche aucune notification email au demandeur
- **Correction** : Implémenter un webhook DB sur INSERT `demandes_sang` (ou un appel EF direct) pour envoyer un email de confirmation au demandeur.

#### SEC-07 — RLS Supabase non audités
- **Action** : Audit manuel dans la console Supabase de toutes les policies RLS sur toutes les tables contenant des données personnelles.

---

### 🟡 MINEURS — À corriger pour la qualité et la robustesse

| ID | Description | Correction |
|----|-------------|------------|
| P9 | Rate limiting connexion purement client-side (réinitialisé à la navigation) | Acceptable — Supabase Auth gère le 429 côté serveur. Documenter. |
| P10 | `retour-eligibilite-cron` sans `.limit()` | Ajouter `.limit(500)` sur la requête |
| P11 | Package name `com.songre.app` — nouveau projet Firebase `songre-88f2a` | RÉSOLU — changé vers `com.songre.app` avant publication |
| P-DON-DATE | Date de don non validée côté EF `don-manuel` | Ajouter validation `date_don <= today` dans l'EF |
| P-SCANALL | Bouton "Scanner un code" visible pour tous | Conditionner l'affichage à `demande.auteurId == userId` |
| P-SPAM | Anti-spam `contacter-support` incertain | Vérifier le schéma de `contact_spam_log` (contrainte unique nécessaire) |
| P-VER | Version "SONGRE v1.0.0" hardcodée | Utiliser `PackageInfo.fromPlatform()` pour affichage dynamique |
| NET-05 | Pas de retry sur `enregistrerReponseDonneur()` | Ajouter un retry simple (1 tentative après 2s) |
| SCALE-02 | `matcher-et-notifier` sans limite sur N donneurs | Ajouter `LIMIT 50` sur la requête des donneurs compatibles |

---

## Points non vérifiables

Les points suivants n'ont **pas pu être vérifiés avec certitude** depuis le sandbox de développement, faute d'accès à la console Supabase ou aux services externes :

| ID | Point | Action requise pour vérifier |
|----|-------|------------------------------|
| P3 | Webhooks DB `matcher-et-notifier` et `reponse-donneur` réellement configurés et actifs | Vérifier dans Supabase Dashboard → Database → Webhooks |
| P4 | Jobs pg_cron `retour-eligibilite-cron` et `executer-suppressions-programmees` actifs avec vraies valeurs | Vérifier dans Supabase Dashboard → Extensions → pg_cron → `cron.job` table |
| P12 | Secrets Supabase Vault (`WEBHOOK_SECRET`, `BREVO_API_KEY`, `RESEND_API_KEY`, `FCM_SERVICE_ACCOUNT_JSON`, `SUPABASE_SERVICE_ROLE_KEY`) réellement configurés avec vraies valeurs non factices | Vérifier dans Supabase Dashboard → Project Settings → Vault |
| P13 | Table `public.identites` existante en production avec colonnes `user_id`, `suppression_programmee_le`, `compte_actif` | Vérifier dans Supabase Dashboard → Table Editor ou SQL Editor (`\d identites`) |
| P14 | URL `https://songre.bf/politique-confidentialite` accessible et à jour | Test manuel depuis un navigateur |
| SEC-07 | Policies RLS correctement configurées sur toutes les tables | Audit complet dans Supabase Dashboard → Authentication → Policies |
| SCALE-03 | Quotas email (Brevo/Resend) suffisants pour le volume prévu | Vérifier les plans souscrits et les quotas dans les dashboards Brevo/Resend |
| P-BIENV | Webhook Auth `bienvenue-auth` correctement configuré (INSERT auth.users) | Vérifier dans Supabase Dashboard → Database → Webhooks ou Authentication → Hooks |
| P-DOUB | Coexistence de `trg_creer_identite_safe` (SQL trigger) et upsert `bienvenue-auth` sans conflit | Vérifier le comportement en test d'inscription |
| FCM-KEY | Clé API Firebase `AIzaSyCYoh65TZC5jfb9WEQGszLa6wK16pJupCI` restreinte au package Android | Vérifier dans Firebase Console → APIs & Services → Credentials |

---

*Ce rapport constitue un diagnostic en lecture seule. Aucune modification n'a été apportée au code source lors de sa rédaction. Il sert de base à la planification des corrections avant publication.*

*`flutter analyze` : `No issues found` ✅ — vérifié lors de la rédaction de ce rapport.*
