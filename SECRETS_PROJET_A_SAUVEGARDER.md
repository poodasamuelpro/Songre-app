# SECRETS PROJET SONGRE — Document maître de toutes les clés et variables d'environnement

> **⚠️ DOCUMENT CONFIDENTIEL**  
> Ce fichier est conservé dans le dépôt **privé** uniquement.  
> Ne jamais partager, publier, ni copier dans un dépôt public.  
> Sauvegarder également dans un coffre-fort de mots de passe personnel (Bitwarden, 1Password, etc.).

---

## 1. Variables Flutter — Injectées via `--dart-define` au build

Ces variables doivent être exportées dans le shell **avant** chaque `make apk` ou build Flutter release.

| Variable | Valeur actuelle | Rôle | Injection | Comportement si absente |
|---|---|---|---|---|
| `SONGRE_ENCRYPT_KEY` | `SongreProdBurkinaFaso2026_SecureKey!` | Clé AES-256-CBC pour chiffrer les contacts téléphoniques (profils donneurs + demandes sang). Min 32 caractères. | `--dart-define=SONGRE_ENCRYPT_KEY=$$SONGRE_ENCRYPT_KEY` dans `Makefile` | Dégradation gracieuse : app démarre normalement, chiffrement désactivé. Les contacts en base (chiffrés) s'affichent comme « Contact indisponible ». Aucun crash. |
| `WEBHOOK_SECRET` | `SongreWebhookSecret2026!` | Secret partagé entre l'app Flutter et les Edge Functions `valider-token`, `matcher-et-notifier`, `reponse-donneur`. Vérifié dans le header `X-Webhook-Secret`. | `--dart-define=WEBHOOK_SECRET=$$WEBHOOK_SECRET` dans `Makefile` | App démarre, mais la validation QR (`valider-token`) est rejetée systématiquement en production. |

### Commandes d'export avant build :
```bash
export SONGRE_ENCRYPT_KEY="SongreProdBurkinaFaso2026_SecureKey!"
export WEBHOOK_SECRET="SongreWebhookSecret2026!"
make apk
```

### Fichiers concernés côté Flutter :
- `lib/utils/crypto_service.dart` — lit `SONGRE_ENCRYPT_KEY` via `String.fromEnvironment`
- `lib/services/supabase_service.dart` — lit `WEBHOOK_SECRET` via `String.fromEnvironment`
- `Makefile` — cible `apk` injecte les deux variables via `$$SONGRE_ENCRYPT_KEY` et `$$WEBHOOK_SECRET`

---

## 2. Clés Supabase — Embarquées dans `lib/services/supabase_service.dart`

Ces valeurs sont hardcodées comme constantes de production dans le fichier source (dépôt privé). Elles peuvent être surchargées via `--dart-define` mais fonctionnent sans variable d'environnement.

| Variable | Valeur | Rôle | Localisation |
|---|---|---|---|
| `SUPABASE_URL` | `https://ptomqwucvveuflfnyczo.supabase.co` | URL de l'instance Supabase SONGRE | `lib/services/supabase_service.dart` lignes 24–25 (constante `_kSupabaseUrlProd`) |
| `SUPABASE_ANON_KEY` | `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB0b21xd3VjdnZldWZsZm55Y3pvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM0NjE4MDEsImV4cCI6MjA5OTAzNzgwMX0.5ATdPSNn5YxNKWyOu08NA4fj-hQYypF5StdN3z4-Efg` | Clé publique Supabase (anon key) — JWT signé, valable jusqu'en 2099. Permet les opérations publiques via RLS. | `lib/services/supabase_service.dart` lignes 26–29 (constante `_kAnonKeyProd`) |

> **Note :** La `SUPABASE_SERVICE_ROLE_KEY` (clé admin avec bypass RLS) n'est **jamais** dans le code Flutter. Elle est injectée exclusivement dans les Edge Functions via Supabase Vault / Dashboard → Project Settings → Edge Functions → Environment Variables.

---

## 3. Variables Edge Functions Supabase — Configurées dans Supabase Dashboard

### Comment les configurer :
**Supabase Dashboard → Project Settings → Edge Functions → Environment Variables**  
URL directe : `https://supabase.com/dashboard/project/ptomqwucvveuflfnyczo/settings/functions`

| Variable | Valeur actuelle | Rôle | Fonctions concernées | État |
|---|---|---|---|---|
| `WEBHOOK_SECRET` | `SongreWebhookSecret2026!` | Secret partagé côté serveur — vérifié dans le header `X-Webhook-Secret` entrant. Doit être identique à la valeur `--dart-define` Flutter. | `valider-token`, `matcher-et-notifier`, `reponse-donneur`, `reponse-donneur/index_2026-07-13.ts` | ⚠️ À vérifier dans Dashboard |
| `SUPABASE_URL` | `https://ptomqwucvveuflfnyczo.supabase.co` | URL Supabase — injectée automatiquement par Supabase dans les Edge Functions (variable système). | Toutes | ✅ Automatique |
| `SUPABASE_ANON_KEY` | (voir section 2 ci-dessus) | Clé anon — injectée automatiquement par Supabase. | `valider-token` (fallback) | ✅ Automatique |
| `SUPABASE_SERVICE_ROLE_KEY` | **Non stockée ici** — récupérer depuis Dashboard → Settings → API | Clé admin avec bypass RLS. Utilisée par les Edge Functions pour écrire en DB sans contraintes RLS. | `valider-token`, `matcher-et-notifier`, `lire-notifications`, `reponse-donneur`, `don-manuel`, `envoyer-email`, `bienvenue-auth`, et autres | ⚠️ Configurer dans Vault |
| `EMAIL_FROM` | `SONGRE <noreply@songre.bf>` | Expéditeur affiché dans les emails envoyés. Valeur par défaut dans `_shared/email.ts` si variable absente. | Toutes les fonctions email | ✅ Défaut embarqué |
| `EMAIL_PROVIDER` | `auto` (valeur par défaut si absente) | Forcer un fournisseur email : `brevo`, `resend`, ou `auto` (essai Brevo d'abord, fallback Resend). | `_shared/email.ts` | ⚠️ Configurer si besoin |
| `BREVO_API_KEY` | **Valeur dans Supabase Dashboard uniquement** | Clé API Brevo principale pour l'envoi d'emails transactionnels. | `_shared/email.ts` | ⚠️ Vérifier dans Dashboard |
| `BREVO_API_KEY_2` | **Valeur dans Supabase Dashboard uniquement** | Clé API Brevo de secours (rotation automatique si quota atteint). | `_shared/email.ts` | ⚠️ Vérifier dans Dashboard |
| `RESEND_API_KEY` | **Valeur dans Supabase Dashboard uniquement** | Clé API Resend principale (fallback si Brevo échoue). | `_shared/email.ts` | ⚠️ Vérifier dans Dashboard |
| `RESEND_API_KEY_2` | **Valeur dans Supabase Dashboard uniquement** | Clé API Resend de secours. | `_shared/email.ts` | ⚠️ Vérifier dans Dashboard |
| `FCM_SERVICE_ACCOUNT_JSON` | **Valeur dans Supabase Dashboard uniquement** | JSON complet du compte de service Firebase pour FCM v1 (contient `private_key`, `client_email`, etc.). | `_shared/fcm.ts` | ⚠️ Vérifier dans Dashboard |
| `FCM_PROJECT_ID` | **Valeur dans Supabase Dashboard uniquement** | Project ID Firebase (ex: `songre-XXXXX`). Utilisé pour construire l'URL FCM v1. | `_shared/fcm.ts` | ⚠️ Vérifier dans Dashboard |
| `INTERNAL_SECRET` | **Valeur dans Supabase Dashboard uniquement** | Secret interne pour l'Edge Function `envoyer-email` (appels internes entre fonctions). | `envoyer-email/index.ts` | ⚠️ Vérifier dans Dashboard |

---

## 4. Identifiants Supabase — Tableau de bord

| Accès | Valeur |
|---|---|
| URL Dashboard | `https://supabase.com/dashboard/project/ptomqwucvveuflfnyczo` |
| Project Reference ID | `ptomqwucvveuflfnyczo` |
| Région | (vérifier dans Dashboard → Settings → General) |

---

## 5. Identifiants Firebase (FCM)

| Accès | Valeur |
|---|---|
| Console Firebase | `https://console.firebase.google.com/` |
| Project ID | (voir valeur de `FCM_PROJECT_ID` dans Supabase Dashboard) |
| Service Account JSON | (voir valeur de `FCM_SERVICE_ACCOUNT_JSON` dans Supabase Dashboard) |

---

## 6. Résumé — Checklist avant chaque build APK release

```bash
# 1. Vérifier que les variables sont exportées :
echo "SONGRE_ENCRYPT_KEY: ${SONGRE_ENCRYPT_KEY:0:10}..."  # affiche les 10 premiers caractères
echo "WEBHOOK_SECRET: ${WEBHOOK_SECRET:0:10}..."

# 2. Builder :
make apk

# 3. Vérifier l'APK généré :
# build/app/outputs/flutter-apk/app-release.apk (~73.7 MB)
```

---

## 7. Checklist Dashboard Supabase avant mise en production

- [ ] `WEBHOOK_SECRET` configuré dans Edge Functions → Environment Variables
- [ ] `SUPABASE_SERVICE_ROLE_KEY` configuré dans Vault ou Edge Functions
- [ ] `BREVO_API_KEY` et `BREVO_API_KEY_2` configurés
- [ ] `RESEND_API_KEY` et `RESEND_API_KEY_2` configurés
- [ ] `FCM_SERVICE_ACCOUNT_JSON` configuré (JSON complet, pas juste le chemin)
- [ ] `FCM_PROJECT_ID` configuré
- [ ] `EMAIL_FROM` configuré (ou laisser la valeur par défaut `SONGRE <noreply@songre.bf>`)
- [ ] `INTERNAL_SECRET` configuré (pour `envoyer-email`)
- [ ] Table `public.app_config` créée (voir `MODIFICATIONS_MANUELLES_CARTE.sql`)
- [ ] Colonnes `latitude`, `longitude` ajoutées à `public.villes` et `public.structures_sanitaires`

---

## 8. Historique des modifications de clés

| Date | Clé | Modification | Raison |
|---|---|---|---|
| 2026-07-19 | `SONGRE_ENCRYPT_KEY` | Retrait du `defaultValue` hardcodé dans `CryptoService` | Nettoyage sécurité — la valeur n'est plus embarquée dans le binaire APK. Valeur inchangée. |
| 2026-07-19 | `WEBHOOK_SECRET` | Déjà géré via `$$WEBHOOK_SECRET` dans Makefile depuis session 4 | — |

> **Note sur la rotation de clé AES :** Si `SONGRE_ENCRYPT_KEY` est un jour changée, toutes les données chiffrées en base (`contact_chiffre`, `contact_secondaire_chiffre`, `telephone_chiffre`) doivent être rechiffrées avec la nouvelle clé avant de déployer un build utilisant la nouvelle clé. Sans rechiffrement, les contacts existants seront illisibles.

---

*Document créé le 2026-07-19 — Session 6 SONGRE*  
*Dépôt privé : `https://github.com/poodasamuelpro/Songre-app`*
