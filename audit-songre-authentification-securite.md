# Audit SONGRE — Authentification, Sécurité, Fonctionnalités, Performance

> **Document auto-suffisant** — compréhensible sans relire la conversation de développement.  
> Basé sur l'analyse du code réel (pas d'inférences théoriques).  
> Date d'audit : 2026-07-09  
> Versions : Flutter 3.35.4 / Dart 3.9.2 / Supabase Auth V2

---

## Résumé exécutif

| Gravité | Nb de problèmes |
|---------|----------------|
| 🔴 Critique | 4 |
| 🟠 Majeur | 5 |
| 🟡 Modéré | 6 |
| 🔵 Mineur / Amélioration | 6 |
| **Total** | **21** |

**Verdict global :** L'architecture de l'application est solide (chiffrement AES-256, RLS activé, tokens JWT, pattern stale-while-revalidate). Quatre problèmes critiques doivent être traités avant une mise en production sérieuse : le spinner infini à la connexion (S1), le nom d'application incorrect (S3), l'absence de contact symétrique donneur→demandeur (S6), et la clé de chiffrement fallback exposée dans le dépôt (S10-SEC-01). Les sections S7 (email compte), S8 (téléphone), et S9 (historique) sont des fonctionnalités manquantes clairement documentées à implémenter.

---

## Section 1 — Bug critique : connexion bloquée (spinner infini)

### Contexte

Après une déconnexion ou sur un nouvel appareil, cliquer sur "Se connecter" déclenche un indicateur de chargement qui tourne indéfiniment, sans aboutir (ni succès, ni message d'erreur).

### Cause racine — Double source confirmée dans le code

#### Cause A — `app_state.dart` lignes 272–282 : pas de `try/catch` global dans `connecter()`

```dart
// lib/services/app_state.dart — lignes 272-282
_isAuthenticated = true;

// Charger les référentiels + données métier
await _chargerVilles();           // ← Exception réseau possible ici
await _loadProfilAvecFallback();  // ← ... ou ici
await _loadDemandes();            // ← ... ou ici
await _chargerNotificationsBackend(); // ← ... ou ici

_recalculerCompatibilite();
_setLoading(false);               // ← JAMAIS ATTEINT si exception ci-dessus
return true;
```

**Mécanisme de blocage :** Si `_chargerVilles()` ou l'un des appels suivants lève une exception non catchée (timeout réseau, `SocketException`, `TimeoutException` après 10s), l'exception remonte en sortant prématurément de `connecter()`. Le `_setLoading(false)` en ligne 281 n'est **jamais exécuté**. `_isLoading` reste `true` dans `AppState`, ce qui maintient le spinner dans `_ConnexionFormState` indéfiniment.

**Note importante :** `_chargerNotificationsBackend()` a bien son propre `try/catch` (lignes 441-452), mais `_chargerVilles()`, `_loadProfilAvecFallback()` et `_loadDemandes()` **n'ont pas de try/catch** dans ce contexte.

#### Cause B — `login_screen.dart` lignes ~400-412 : `if (!mounted) return` avant le reset

```dart
// lib/screens/login_screen.dart — _ConnexionFormState._connecter()
final ok = await state.connecter(email: _emailCtrl.text.trim(), motDePasse: _mdpCtrl.text);
if (!mounted) return;         // ← Si widget unmounted ici...
setState(() => _loading = false); // ← ...cette ligne n'est JAMAIS exécutée
```

**Mécanisme de blocage :** Si l'utilisateur navigue vers un autre écran pendant l'attente de `state.connecter()`, le widget est `unmounted`. Le garde `if (!mounted) return` court-circuite le `setState(() => _loading = false)`. Le `_loading` local du widget reste `true`. Si le même widget est remonté (ex: retour arrière), il affiche un spinner figé.

### Niveau de risque
🔴 **Critique** — Bloque l'accès à l'application dans des conditions réseau normales (timeout ~10s sur mobile BF).

### Difficulté de correction
⚡ **Faible** — Ajout d'un `try/catch/finally` + correction du guard `mounted`.

### Solution proposée

**Correctif A — `lib/services/app_state.dart`**

```dart
// AVANT (lignes 272-282) :
_isAuthenticated = true;
await _chargerVilles();
await _loadProfilAvecFallback();
await _loadDemandes();
await _chargerNotificationsBackend();
_recalculerCompatibilite();
_setLoading(false);
return true;

// APRÈS :
_isAuthenticated = true;
try {
  await _chargerVilles();
  await _loadProfilAvecFallback();
  await _loadDemandes();
  await _chargerNotificationsBackend();
  _recalculerCompatibilite();
} catch (e) {
  // Les données de fallback du cache seront utilisées — connexion quand même réussie
  if (kDebugMode) debugPrint('[AppState.connecter] Erreur chargement post-auth: $e');
} finally {
  _setLoading(false); // ← Toujours exécuté, même en cas d'exception
}
return true;
```

**Correctif B — `lib/screens/login_screen.dart`**

```dart
// AVANT :
if (!mounted) return;
setState(() => _loading = false);

// APRÈS :
if (mounted) {
  setState(() => _loading = false);
}
// Si !mounted : le widget sera garbage-collecté, pas besoin de setState.
// _loading local sera réinitialisé à la prochaine création du widget.
```

### Fichiers à modifier
- `lib/services/app_state.dart` — méthode `connecter()`, lignes 272-282
- `lib/screens/login_screen.dart` — méthode `_connecter()`, ligne ~403

### Risque de régression
Nul — le `finally` garantit que `_setLoading(false)` est toujours appelé, y compris sur le chemin nominal.

---

## Section 2 — Réinitialisation de mot de passe

### Contexte

Le flux de réinitialisation existe à trois niveaux. L'email part correctement, mais le deep link ouvre l'écran de connexion au lieu de l'écran de réinitialisation.

### Diagnostic niveau par niveau

#### a) Niveau Flutter — L'écran existe et est accessible

- **Fichier :** `lib/screens/reset_password_screen.dart` ✅ existe
- **Route :** `/reset-password` déclarée dans `lib/router.dart` ✅
- **Accès depuis login :** `_MotDePasseOublieFormState` dans `login_screen.dart` appelle `SupabaseService.reinitialiserMotDePasse(email: ...)` ✅
- **Implémentation :** `ResetPasswordScreen` utilise `widget.accessToken` comme Bearer pour `PUT /auth/v1/user` ✅ — mécanisme correct

**Redirect guard dans `router.dart` (corrigé session précédente) :**
```dart
final isResetPassword = location == '/reset-password' ||
    location.startsWith('/reset-password');
```
✅ La redirection est correctement étendue pour ne pas bloquer l'accès à `/reset-password`.

**Parsing du fragment URL (corrigé session précédente) :**
```dart
// lib/router.dart — lignes 121-139
if (accessToken.isEmpty) {
  final fragment = state.uri.fragment;
  if (fragment.isNotEmpty) {
    final fragmentParams = Uri.splitQueryString(fragment);
    accessToken = fragmentParams['access_token'] ?? fragmentParams['token'] ?? '';
    if (type.isEmpty) { type = fragmentParams['type'] ?? ''; }
  }
}
```
✅ Le parsing du fragment `#access_token=...` est maintenant implémenté.

#### b) Niveau backend — Problème résiduel identifié

**`supabase_service.dart` ligne 1264-1280 : `reinitialiserMotDePasse()` sans `redirectTo`**

```dart
// lib/services/supabase_service.dart — ligne 1267-1273
final resp = await http.post(
  Uri.parse('$_supabaseUrl/auth/v1/recover'),
  headers: _headers(),
  body: jsonEncode({'email': email}),  // ← PAS de redirectTo !
).timeout(const Duration(seconds: 10));
```

**Impact :** Sans `redirectTo`, Supabase utilise le "Redirect URL" configuré dans le Dashboard (Authentication → URL Configuration). Si cette URL est `https://songre.vercel.app/reset-password` ou n'est pas configurée du tout, le lien email ne déclenchera **pas** le deep link `songre://reset-password` attendu par l'app Android. L'utilisateur atterrit sur une page web (ou une erreur), et l'app s'ouvre sur la page d'accueil.

#### c) Niveau base de données

Aucune table ni trigger nécessaire pour ce flux — Supabase Auth gère le token de reset nativement. Pas de dépendance DB identifiée.

### Niveau de risque
🟠 **Majeur** — Le flux de réinitialisation peut être totalement non fonctionnel sur Android si le Dashboard n'est pas configuré avec le schéma `songre://`.

### Difficulté de correction
⚡ **Faible** — Ajouter `redirectTo` dans l'appel + configuration Dashboard.

### Solution proposée (3 niveaux)

**Correctif 1 — `lib/services/supabase_service.dart`**

```dart
// AVANT (ligne 1270-1272) :
body: jsonEncode({'email': email}),

// APRÈS :
body: jsonEncode({
  'email': email,
  'redirectTo': 'songre://reset-password',
}),
```

**Correctif 2 — Supabase Dashboard**

1. Aller dans **Authentication → URL Configuration**
2. Ajouter dans "Redirect URLs" : `songre://reset-password`
3. Optionnel (web): ajouter aussi `https://songre.vercel.app/reset-password`

**Correctif 3 — `AndroidManifest.xml` (vérification)**

Confirmer que le deep link `songre://` est bien configuré avec `android:scheme="songre"` et `android:host="reset-password"`. ✅ Déjà présent dans les modifications antérieures.

### Fichiers à modifier
- `lib/services/supabase_service.dart` — méthode `reinitialiserMotDePasse()`, ligne 1270
- Supabase Dashboard → Authentication → URL Configuration (hors code)

---

## Section 3 — Nom et icône incorrects après installation

### Contexte

L'application affichait "Life Saver" sur l'écran d'accueil Android au lieu de "SONGRE". **Ce bug est résolu** : le label pointe maintenant vers `@string/app_name` = `Songre`.

### Cause racine — `AndroidManifest.xml` : label hardcodé

**Fichier :** `android/app/src/main/AndroidManifest.xml` — ligne 5

```xml
<!-- ÉTAT ACTUEL — INCORRECT -->
<application
    android:label="Life Saver"    ← hardcodé, ne pointe pas vers strings.xml
    ...>
```

**Fichier :** `android/app/src/main/res/values/strings.xml`

```xml
<!-- VALEUR CORRECTE — non utilisée -->
<string name="app_name">Songre</string>
```

**Fichier :** `pubspec.yaml` — ligne 1

```yaml
name: songre   ← correct (nom technique Flutter, n'affecte pas l'affichage Android)
```

**Fichier :** `android/app/build.gradle.kts` — ligne 15, 29

```kotlin
namespace = "com.songre.app"
applicationId = "com.songre.app"
```

Le `namespace` et `applicationId` utilisent désormais `com.songre.app` — cohérent avec l'identité SONGRE. **RÉSOLU le 2026-07-17.** Nouveau projet Firebase : `songre-88f2a`.

**Icône :** `pubspec.yaml` lignes 71-75 configure `flutter_launcher_icons` avec `image_path: "assets/icon/app_icon.png"`. La commande `flutter pub run flutter_launcher_icons` a-t-elle été exécutée avec le bon fichier source après configuration ? À vérifier.

### Niveau de risque
🔴 **Critique (UX)** — Le nom affiché sur l'écran Android est incorrect. Visible par tous les utilisateurs immédiatement après installation.

### Difficulté de correction
⚡ **Très faible** — Une ligne dans AndroidManifest.xml.

### Solution proposée

**Correctif 1 — `android/app/src/main/AndroidManifest.xml`**

```xml
<!-- AVANT -->
android:label="Life Saver"

<!-- APRÈS -->
android:label="@string/app_name"
```

`@string/app_name` pointe vers `strings.xml` qui contient `Songre` — valeur correcte déjà présente.

**Correctif 2 — Régénérer l'icône (si nécessaire)**

```bash
cd /home/user/flutter_app
# Vérifier que assets/icon/app_icon.png est le bon logo SONGRE
flutter pub run flutter_launcher_icons
flutter build apk --release
```

**Rebuild obligatoire :** Les caches Android conservent l'ancien nom/icône. Un `flutter clean && flutter build apk --release` est nécessaire après ces modifications.

### Fichiers à modifier
- `android/app/src/main/AndroidManifest.xml` — attribut `android:label`
- Rebuild APK release obligatoire après modification

---

## Section 4 — Modification du mot de passe : erreur "mauvais mot de passe" malgré un MDP correct

### Contexte

Dans Paramètres > Modifier le mot de passe, saisir l'ancien mot de passe correct retourne systématiquement une erreur "Mot de passe actuel incorrect."

### Cause racine — Double problème identifié

#### Cause A — `verifierMotDePasse()` : ré-authentification hors session

**Fichier :** `lib/services/supabase_service.dart` — lignes 1206-1224

```dart
static Future<bool> verifierMotDePasse({
  required String email,
  required String motDePasse,
}) async {
  if (!estConfigured) return false;
  try {
    final resp = await http.post(
      Uri.parse('$_supabaseUrl/auth/v1/token?grant_type=password'),
      headers: _headers(),               // ← PAS de withAuth:true
                                         //   PAS de _requeteAvecRefresh()
      body: jsonEncode({'email': email, 'password': motDePasse}),
    ).timeout(const Duration(seconds: 10));
    return resp.statusCode == 200;
  } catch (e) { ... }
}
```

**`_headers()` sans `withAuth: true`** : les headers envoyés sont `Content-Type` + `apikey` uniquement. Il n'y a pas de Bearer token. C'est **correct pour cette API** (`/token?grant_type=password` n'exige pas de JWT existant — c'est une authentification fraîche). Ce n'est donc pas la cause du problème.

**La vraie cause :** `verifierMotDePasse()` effectue une authentification complète (`grant_type=password`), ce qui crée une **nouvelle session Supabase**. Si le compte a des restrictions (rate limiting, IP ban temporaire, ou l'email n'est pas encore confirmé), cette deuxième authentification peut échouer même si les identifiants sont corrects.

**Problème plus grave :** Si `obtenirEmailCourant()` retourne `null` (car `_accessToken == null`, voir Cause B), la méthode `verifierMotDePasse()` n'est jamais appelée.

#### Cause B — `obtenirEmailCourant()` retourne `null` si session expirée

**Fichier :** `lib/services/supabase_service.dart` — ligne 1182-1201

```dart
static Future<String?> obtenirEmailCourant() async {
  if (!estConfigured || _accessToken == null) return null; // ← Blocage prématuré
  try {
    final resp = await _requeteAvecRefresh(  // ← _requeteAvecRefresh peut rafraîchir
      ...
    );
  }
}
```

**Contradiction interne :** La garde `_accessToken == null` empêche d'appeler `_requeteAvecRefresh()`, qui aurait pu rafraîchir le token automatiquement. Si la session est expirée (`_accessToken` null ou invalide), `obtenirEmailCourant()` retourne immédiatement `null` sans tenter de rafraîchir.

**Impact dans `change_password_screen.dart` (lignes ~249-258) :**

```dart
final emailResult = await SupabaseService.obtenirEmailCourant();
if (emailResult == null) {
  setState(() { _erreur = 'Session invalide.'; _loading = false; });
  return; // ← L'utilisateur voit "Session invalide" sans même avoir entré son MDP
}
```

#### Cause C — `.trim()` sur l'ancien MDP (ligne ~249)

```dart
motDePasse: _ancienCtrl.text.trim(), // ← .trim() est correct mais documenté
```

Si l'utilisateur a créé son compte avec un mot de passe contenant des espaces en début/fin (rare mais possible), le `.trim()` tronque silencieusement. **Risque faible** — à documenter uniquement.

### Niveau de risque
🟠 **Majeur** — Fonctionnalité de sécurité critique non opérationnelle pour les sessions expirées.

### Difficulté de correction
🔧 **Modérée** — Restructuration du flux `obtenirEmailCourant()`.

### Solution proposée

**Correctif — `lib/services/supabase_service.dart`**

```dart
// AVANT :
static Future<String?> obtenirEmailCourant() async {
  if (!estConfigured || _accessToken == null) return null;
  // ...
}

// APRÈS — permettre à _requeteAvecRefresh() de rafraîchir si nécessaire :
static Future<String?> obtenirEmailCourant() async {
  if (!estConfigured) return null;
  // Si pas de token, tenter de restaurer depuis SecureStorage
  // est la responsabilité de l'appelant (AppState.init).
  // Ici on tolère _accessToken == null et laisse _requeteAvecRefresh gérer.
  if (_accessToken == null && _refreshToken == null) return null;
  try {
    final resp = await _requeteAvecRefresh(
      () => http.get(
        Uri.parse('$_supabaseUrl/auth/v1/user'),
        headers: _headers(withAuth: true),
      ).timeout(const Duration(seconds: 8)),
    );
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return data['email'] as String?;
    }
    return null;
  } catch (e) {
    if (kDebugMode) debugPrint('[SupabaseService] obtenirEmailCourant: $e');
    return null;
  }
}
```

**Alternative plus simple pour `change_password_screen.dart` :** Plutôt que d'appeler `obtenirEmailCourant()` à chaque fois, passer l'email depuis l'écran appelant (il est connu de l'`AppState` ou du profil) :

```dart
// Dans profil_screen.dart — _showSettings() → ChangePasswordScreen
// Passer l'email déjà chargé depuis l'AppState ou le profil
Navigator.push(context, MaterialPageRoute(
  builder: (_) => ChangePasswordScreen(emailConnu: emailDejaCharge),
));
```

### Fichiers à modifier
- `lib/services/supabase_service.dart` — méthode `obtenirEmailCourant()`, ligne 1183
- `lib/screens/change_password_screen.dart` — méthode `_soumettre()`, ligne ~249

---

## Section 5 — Emails envoyés à la mauvaise adresse

### Contexte

Analyse exhaustive de toutes les Edge Functions envoyant des emails pour détecter des inversions de destinataires.

### Tableau des 11 cas de notification et leur destinataire

| EF | Type notification | Appelant | userId passé | Destinataire réel | Correct ? |
|----|------------------|----------|-------------|-------------------|-----------|
| `reponse-donneur` | `reponse_recue` | `reponse-donneur/index.ts` | `demande.auteur_id` | Demandeur | ✅ |
| `reponse-donneur` | `reponse_encouragement` | `reponse-donneur/index.ts` | `donneur_id` | Donneur | ✅ |
| `valider-token` | `don_confirme` | `valider-token/index.ts` | `qr.donneur_id` | Donneur | ✅ |
| `valider-token` | `don_confirme_demandeur` | `valider-token/index.ts` | `demande.auteur_id` | Demandeur | ✅ |
| `matcher-et-notifier` | `demande_compatible` | `matcher-et-notifier/index.ts` | `donneurId` (boucle) | Donneurs compatibles | ✅ |
| `mdp-modifie-auth` | `mdp_modifie` | Mode webhook/explicite | `updatedUser.id` / `user.id` | Utilisateur modifiant | ✅ |
| `bienvenue-auth` | `bienvenue` | Webhook inscription | `record.id` | Nouvel inscrit | ✅ (présumé) |
| `don-manuel` | `don_enregistre_manuel` | EF `don-manuel` | `donneurId` | Donneur | ✅ (présumé) |
| `retour-eligibilite-cron` | `retour_eligibilite` | Cron | `profil.user_id` | Donneur éligible | ✅ (présumé) |
| `executer-suppressions` | `suppression_demandee` | Cron | `identite.user_id` | Utilisateur demandant | ✅ (présumé) |

**Conclusion :** Aucune inversion de destinataire confirmée dans le code lu. `notifierUtilisateur()` dans `_shared/notifier.ts` utilise `adminClient.auth.admin.getUserById(userId)` pour récupérer l'email — mécanisme fiable.

### Risque résiduel identifié — `emailsMap` dans `matcher-et-notifier`

```typescript
// matcher-et-notifier/index.ts — emailsMap
const { data: usersData } = await adminClient.auth.admin.listUsers({
  perPage: donneurIds.length,
});
const emailsMap = new Map(usersData?.users?.map(u => [u.id, u.email]) ?? []);
```

**Risque :** `listUsers` avec `perPage` basé sur `donneurIds.length` peut tronquer si la liste dépasse la limite API de Supabase (max 1000). Pour des volumes faibles (Burkina Faso, démarrage), risque pratiquement nul.

### Problème trouvé — `LOGO_URL` dans `_shared/email.ts` ligne 42

```typescript
const LOGO_URL = "https://songre.bf/assets/logo_songre.png";
```

Le domaine `songre.bf` n'est pas enregistré (TLD `.bf` — Burkina Faso). Cette URL retourne une erreur 404 dans tous les emails envoyés. Le logo est absent de tous les emails SONGRE actuellement.

### Niveau de risque
🟡 **Modéré** (LOGO_URL mort) — Les emails s'affichent sans logo, `onerror="this.style.display='none'"` masque l'erreur proprement mais l'image est absente.

### Difficulté de correction
⚡ **Faible** — Uploader le logo sur Supabase Storage + mettre à jour la constante.

### Solution proposée

```typescript
// APRÈS — utiliser Supabase Storage public (bucket "assets" à créer) :
const LOGO_URL = "https://ptomqwucvveuflfnyczo.supabase.co/storage/v1/object/public/assets/logo_songre.png";
```

**Étapes :**
1. Supabase Dashboard → Storage → Créer bucket `assets` (public)
2. Uploader `logo_songre.png`
3. Copier l'URL publique
4. Mettre à jour `_shared/email.ts` ligne 42
5. Redéployer toutes les EF qui importent `_shared/email.ts`

### Fichiers à modifier
- `supabase/functions/_shared/email.ts` — ligne 42 (`LOGO_URL`)
- Redéploiement de toutes les EF qui importent ce module

---

## Section 6 — Asymétrie contact donneur/demandeur

### Contexte

Un donneur qui accepte une demande voit le contact du demandeur (via la vue `demandes_sang_avec_contact`). Mais le demandeur ne voit jamais le contact du donneur qui a accepté.

### Schéma actuel — Confirmé par `supabase-addendum.sql`

**Vue `public.demandes_sang_avec_contact` :**
```sql
CASE WHEN EXISTS (
  SELECT 1 FROM public.reponses_donneurs r
  WHERE r.demande_id = d.id AND r.donneur_id = auth.uid()
) THEN d.contact_chiffre ELSE NULL END AS contact_chiffre
```

Cette vue expose le contact du **demandeur** (`d.contact_chiffre`) uniquement au donneur ayant répondu. Elle ne contient aucune colonne de contact pour le **donneur**.

**Table `reponses_donneurs` — colonnes confirmées par `supabase-schema-corrections.sql` :**
```sql
-- id, donneur_id, demande_id, repondu_le, statut
```
Aucune colonne `contact_chiffre` côté donneur dans cette table.

**Table `profils_donneurs` — colonnes confirmées par `models.dart` :**
```
user_id, groupe_sanguin, poids_chiffre, genre, ville_id, quartier,
contre_indications_chiffre, dernier_don_date, disponible, created_at, updated_at
```
Aucun champ de contact dans `profils_donneurs`.

### Impact
Le demandeur reçoit une notification "Un donneur a répondu" mais ne peut pas contacter le donneur. La mise en relation est à sens unique — **le demandeur doit attendre que le donneur le contacte** via les coordonnées du demandeur que le donneur a vues.

### Niveau de risque
🔴 **Critique (fonctionnel)** — Asymétrie incompatible avec une mise en relation efficace dans le cadre médical urgent.

### Difficulté de correction
🔧 **Modérée** — Nécessite migration SQL + nouvelle policy RLS + modification Flutter + Edge Function.

### Solution recommandée — Option A : colonne contact dans `reponses_donneurs`

**Avantage :** Contact du donneur lié à la réponse spécifique (le donneur peut avoir un contact différent selon les demandes). Cohérent avec le flux existant. Ne touche pas `profils_donneurs`.

**Migration SQL complète :**

```sql
-- Étape 1 : Ajouter la colonne contact chiffré dans reponses_donneurs
ALTER TABLE public.reponses_donneurs
  ADD COLUMN IF NOT EXISTS contact_chiffre TEXT;

-- Étape 2 : Créer la vue symétrique pour le demandeur
CREATE OR REPLACE VIEW public.reponses_avec_contact_donneur AS
SELECT
  r.id,
  r.donneur_id,
  r.demande_id,
  r.repondu_le,
  r.statut,
  -- Contact du donneur visible uniquement par l'auteur de la demande
  CASE
    WHEN EXISTS (
      SELECT 1 FROM public.demandes_sang d
      WHERE d.id = r.demande_id AND d.auteur_id = auth.uid()
    )
    THEN r.contact_chiffre
    ELSE NULL
  END AS contact_chiffre_donneur
FROM public.reponses_donneurs r;

-- Étape 3 : RLS sur la vue (hérité de la table + policy supplémentaire)
-- La vue filtre déjà via le CASE WHEN, mais on sécurise aussi la table :
CREATE POLICY "Demandeur voit les reponses a ses demandes"
  ON public.reponses_donneurs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.demandes_sang d
      WHERE d.id = reponses_donneurs.demande_id
        AND d.auteur_id = auth.uid()
    )
    OR donneur_id = auth.uid()
  );

-- Étape 4 : Index pour performance
CREATE INDEX IF NOT EXISTS idx_reponses_demande_id
  ON public.reponses_donneurs(demande_id);
```

**Modification `reponse-donneur/index.ts` :** Inclure le contact chiffré du donneur lors de l'insertion dans `reponses_donneurs` :

```typescript
// Dans reponse-donneur/index.ts — lors de l'INSERT dans reponses_donneurs
const { error: insertError } = await adminClient
  .from('reponses_donneurs')
  .insert({
    donneur_id: donneurId,
    demande_id: demandeId,
    statut: 'acceptee',
    contact_chiffre: body.contact_chiffre ?? null, // ← Nouveau champ
  });
```

**Modification `SupabaseService` Flutter :** Passer le contact chiffré lors de l'appel à `enregistrerReponseDonneur()` :

```dart
// lib/services/supabase_service.dart — enregistrerReponseDonneur()
static Future<bool> enregistrerReponseDonneur({
  required String donneurId,
  required String demandeId,
  String? contactChiffre, // ← Nouveau paramètre optionnel
}) async {
  // ...
  body: jsonEncode({
    'donneur_id': donneurId,
    'demande_id': demandeId,
    'contact_chiffre': contactChiffre, // ← Inclure dans le body EF
  }),
  // ...
}
```

**Affichage dans Flutter :** Ajouter dans l'écran de détail d'une demande (côté demandeur) la récupération et le déchiffrement du contact du donneur :

```dart
// Lecture depuis la vue reponses_avec_contact_donneur
// Déchiffrement : CryptoService.dechiffrer(reponse['contact_chiffre_donneur'])
```

### Fichiers à modifier / créer
- `supabase-addendum.sql` — ou nouveau fichier de migration SQL
- `supabase/functions/reponse-donneur/index.ts` — inclure `contact_chiffre` dans l'INSERT
- `lib/services/supabase_service.dart` — méthode `enregistrerReponseDonneur()`
- `lib/screens/demande_detail_screen.dart` (ou équivalent) — affichage du contact donneur
- Supabase Dashboard → activer RLS sur `reponses_donneurs`

---

## Section 7 — Afficher l'email du compte + possibilité de modification

### Contexte

L'email du compte connecté n'est affiché nulle part dans l'application. La modification d'email n'est pas disponible.

### État actuel confirmé par lecture du code

**`profil_screen.dart` :** Affiche groupe sanguin, poids, genre, ville, quartier, dernier don, prochain don, contre-indications. **Aucun email.**

**`parametres_screen.dart` :** Affiche les liens externes depuis `liens_externes` + la version de l'app. **Aucun email.**

**`supabase_service.dart` ligne 1182 :** `obtenirEmailCourant()` existe mais n'est utilisée que dans `change_password_screen.dart`.

### Niveau de risque
🟡 **Modéré** — Fonctionnalité absente (pas un bug de données).

### Difficulté de correction
🔧 **Modérée** — Modification Flutter uniquement pour l'affichage. Plus complexe pour la modification (flux de confirmation email).

### Solution proposée

#### 7a — Affichage de l'email (priorité haute)

Ajouter dans `profil_screen.dart`, dans `_buildInfosSection()`, un appel asynchrone à `obtenirEmailCourant()` :

```dart
// Dans ProfilScreen — state StatefulWidget pour stocker l'email
class _ProfilScreenState extends State<ProfilScreen> {
  String? _email;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _chargerEmail());
  }

  Future<void> _chargerEmail() async {
    final email = await SupabaseService.obtenirEmailCourant();
    if (mounted) setState(() => _email = email);
  }
  // ...
  // Dans _buildInfosSection() :
  if (_email != null)
    _buildInfoRow('Email', _email!, maskable: true),
```

**Note :** `ProfilScreen` est actuellement un `StatelessWidget`. Il doit être converti en `StatefulWidget` pour stocker `_email` localement.

#### 7b — Modification d'email (priorité basse)

Le flux de modification d'email via Supabase Auth (`PUT /auth/v1/user { email: nouveau }`) déclenche un email de confirmation à la nouvelle adresse. Le changement n'est effectif qu'après clic sur le lien de confirmation.

**Méthode à ajouter dans `supabase_service.dart` :**

```dart
static Future<AuthResult> modifierEmail({
  required String nouvelEmail,
}) async {
  if (!estConfigured || _accessToken == null) {
    return const AuthResult(success: false, error: 'Session invalide.');
  }
  try {
    final resp = await _requeteAvecRefresh(
      () => http.put(
        Uri.parse('$_supabaseUrl/auth/v1/user'),
        headers: _headers(withAuth: true),
        body: jsonEncode({'email': nouvelEmail}),
      ).timeout(const Duration(seconds: 10)),
    );
    if (resp.statusCode == 200) {
      return const AuthResult(success: true);
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return AuthResult(
      success: false,
      error: data['message'] as String? ?? 'Erreur lors de la modification.',
    );
  } catch (e) {
    return const AuthResult(success: false, error: 'Erreur réseau.');
  }
}
```

**Enum à étendre (si notification email_modifie souhaitée) :**

```dart
// lib/models/models.dart — TypeNotification
emailModifie('email_modifie');
```

```sql
-- SQL : étendre l'enum
ALTER TYPE public.type_notification_enum ADD VALUE IF NOT EXISTS 'email_modifie';
```

### Fichiers à modifier
- `lib/screens/profil_screen.dart` — conversion StatelessWidget → StatefulWidget + affichage email
- `lib/services/supabase_service.dart` — nouvelle méthode `modifierEmail()`
- `lib/models/models.dart` — nouvelle valeur `TypeNotification.emailModifie` (optionnel)
- `lib/screens/change_password_screen.dart` — peut servir de template pour l'écran de modification d'email

---

## Section 8 — Numéro de téléphone optionnel chiffré dans le profil

### Contexte

La table `identites` contient `telephone_hash` (un hash SHA-256 ou bcrypt) — non récupérable, utilisable uniquement pour la recherche/déduplication. Pour transmettre le numéro de téléphone par email lors d'une mise en relation, il faut un champ **chiffré de façon réversible**.

### État actuel confirmé par `mission-e.sql`

```sql
-- Table identites (schéma existant confirmé) :
CREATE TABLE IF NOT EXISTS public.identites (
  user_id     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  compte_actif BOOLEAN NOT NULL DEFAULT true,
  suppression_programmee_le TIMESTAMP WITH TIME ZONE,
  created_at  TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at  TIMESTAMP WITH TIME ZONE DEFAULT now()
);
```

**Pas de colonne `telephone_hash` dans ce schéma** — possiblement ajouté ailleurs (schéma `sante.*` dans `supabase-schema-corrections.sql`). Si `telephone_hash` est dans le schéma `sante.*` (ancien schéma non utilisé par le code Flutter), ce champ n'est pas du tout accessible.

### Algorithme de chiffrement existant — `crypto_service.dart`

```dart
// AES-256-CBC, IV aléatoire 16 bytes
// Format : base64(IV_16B) + ":" + base64(ciphertext)
// Clé : --dart-define=SONGRE_ENCRYPT_KEY ou fallback '[REDACTED]'
```

Même algorithme à utiliser pour `telephone_chiffre`.

### Niveau de risque
🔵 **Mineur** — Fonctionnalité manquante (pas un bug). Données personnelles sensibles nécessitant une attention RGPD.

### Difficulté de correction
🔧 **Modérée** — Migration SQL + formulaire Flutter + intégration email.ts.

### Solution proposée

**Migration SQL :**

```sql
-- Ajouter dans public.identites
ALTER TABLE public.identites
  ADD COLUMN IF NOT EXISTS telephone_chiffre TEXT;

-- RLS : l'utilisateur voit uniquement son propre enregistrement (déjà en place)
-- Aucune policy supplémentaire nécessaire si la table a déjà RLS + policy SELECT user_id = auth.uid()
```

**Validation Flutter (format téléphone BF/international) :**

```dart
// Regex pour téléphone Burkina Faso (ex: +226 XX XX XX XX) ou international
static bool validerTelephone(String tel) {
  final cleaned = tel.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  return RegExp(r'^\+?[0-9]{8,15}$').hasMatch(cleaned);
}
```

**Chiffrement avant envoi en base :**

```dart
// Dans le formulaire de profil — à ajouter dans sauvegarderIdentite()
final telChiffre = telephone != null && telephone.isNotEmpty
    ? CryptoService.chiffrer(telephone)
    : null;

await http.patch(
  Uri.parse('$_supabaseUrl/rest/v1/identites?user_id=eq.$userId'),
  headers: _restHeaders(withAuth: true),
  body: jsonEncode({'telephone_chiffre': telChiffre}),
);
```

**Intégration dans les templates email :** Ajouter dans `templateReponseRecue()` et `templateReponseEncouragement()` si le contact inclut le téléphone. Exemple :

```typescript
// _shared/email.ts — templateReponseEncouragement
const telephone = data["telephone"] ?? ""; // déchiffré côté Edge Function
```

**Important — Déchiffrement côté Edge Function :** Les Edge Functions Deno n'ont pas accès à la clé AES Flutter. Deux options :
- **Option recommandée :** Ne pas inclure le téléphone dans les emails — l'afficher uniquement dans l'app après déchiffrement côté Flutter.
- **Option avancée :** Implémenter le déchiffrement AES-256-CBC en Deno dans `_shared/` avec la même clé injectée via secret Supabase.

### Fichiers à modifier / créer
- `supabase-addendum.sql` — nouvelle colonne `telephone_chiffre` dans `identites`
- `lib/services/supabase_service.dart` — méthode `sauvegarderIdentite()` ou `mettreAJourTelephone()`
- `lib/screens/profil_screen.dart` — champ téléphone optionnel dans le formulaire de modification

---

## Section 9 — Écran "Historique" (demandes + dons combinés)

### Contexte

Aucun écran d'historique n'existe actuellement dans l'application. Les tables sources sont présentes en base.

### Tables sources confirmées

- **`public.demandes_sang`** — filtrée sur `auteur_id = user_id` → demandes créées par l'utilisateur
- **`public.historique_dons`** — filtrée sur `donneur_id = user_id` → dons effectués par l'utilisateur
- **`public.reponses_donneurs`** — filtrée sur `donneur_id = user_id` → réponses données (complément utile)

### Niveau de risque
🔵 **Mineur** — Fonctionnalité manquante (pas un bug). Utile pour la traçabilité et la confiance utilisateur.

### Difficulté de correction
🔧 **Modérée** — Nouveau fichier Flutter + éventuellement une vue SQL.

### Options proposées

#### Option A — Vue SQL UNION ALL (recommandée)

```sql
CREATE OR REPLACE VIEW public.historique_utilisateur AS
SELECT
  'demande' AS type_evenement,
  d.id,
  d.auteur_id AS user_id,
  d.groupe_sanguin_recherche AS groupe_sanguin,
  d.statut,
  d.created_at,
  NULL::DATE AS date_don,
  'demande_' || d.statut AS libelle_statut
FROM public.demandes_sang d

UNION ALL

SELECT
  'don' AS type_evenement,
  h.id,
  h.donneur_id AS user_id,
  h.groupe_sanguin AS groupe_sanguin,
  h.source AS statut,  -- 'qr_valide' ou 'declaratif'
  h.created_at,
  h.date_don,
  'don_' || h.source AS libelle_statut
FROM public.historique_dons h;

-- RLS : chaque utilisateur ne voit que ses propres événements
ALTER VIEW public.historique_utilisateur OWNER TO postgres;
-- (Les RLS des tables sources s'appliquent automatiquement aux vues dans Supabase)
```

**Avantages :** Une seule requête côté Flutter, tri naturel par `created_at`, pagination via `range`.

#### Option B — Fusion côté Flutter (plus simple)

```dart
// SupabaseService — chargerHistoriqueComplet()
final demandes = await lireDemandesParAuteur(userId);
final dons = await lireDonsParDonneur(userId);

// Fusion et tri en mémoire
final historique = [
  ...demandes.map((d) => HistoriqueEvent.fromDemande(d)),
  ...dons.map((d) => HistoriqueEvent.fromDon(d)),
]..sort((a, b) => b.date.compareTo(a.date));
```

**Inconvénient :** Deux requêtes réseau, tri en mémoire non scalable au-delà de ~1000 événements.

### Fichier Flutter à créer — `lib/screens/historique_screen.dart`

```dart
class HistoriqueScreen extends StatefulWidget {
  const HistoriqueScreen({super.key});
  // ...
}

// Modèle d'événement unifié
class HistoriqueEvent {
  final String id;
  final String type; // 'demande' ou 'don'
  final DateTime date;
  final String groupeSanguin;
  final String statut;
  final String? libelleStatut;
  
  factory HistoriqueEvent.fromDemande(DemandeSang d) => HistoriqueEvent(
    id: d.id, type: 'demande', date: d.createdAt,
    groupeSanguin: d.groupeSanguinRecherche.label,
    statut: d.statut.value,
  );
  
  factory HistoriqueEvent.fromDon(Map<String, dynamic> json) => HistoriqueEvent(
    id: json['id'], type: 'don',
    date: DateTime.parse(json['date_don'] ?? json['created_at']),
    groupeSanguin: json['groupe_sanguin'] ?? '',
    statut: json['source'] ?? '',
  );
}
```

**Point d'entrée :** Bouton "Historique" dans `profil_screen.dart` ou onglet dédié dans la navigation principale.

### Fichiers à créer / modifier
- `lib/screens/historique_screen.dart` — nouveau fichier (écran + modèle)
- `lib/services/supabase_service.dart` — méthodes `lireDemandesParAuteur()` et `lireDonsParDonneur()`
- `lib/screens/profil_screen.dart` — bouton d'accès à l'historique
- SQL (optionnel) — vue `public.historique_utilisateur`

---

## Section 10 — Audit général : sécurité, performance, RLS

### [SEC-01] 🔴 Clé de chiffrement fallback exposée dans le dépôt

**Fichier :** `lib/utils/crypto_service.dart` — lignes 34-35

```dart
static const String _fallbackKey = '[REDACTED]';
```

**Impact :** La clé AES-256 utilisée pour chiffrer les données médicales (poids, contre-indications) et les contacts est hardcodée dans le code source versionné. Tout développeur avec accès au dépôt (ou tout attaquant ayant décompilé l'APK) peut déchiffrer **toutes les données chiffrées** de tous les utilisateurs si la base est compromise.

**Niveau de risque :** 🔴 Critique — RGPD, données médicales.

**Correction :**
1. Générer une clé de 32+ caractères unique pour la production
2. Injecter via `--dart-define=SONGRE_ENCRYPT_KEY=<clé_prod>` dans le processus de build CI/CD
3. Ne jamais commiter la clé dans le dépôt
4. Supprimer la `_fallbackKey` hardcodée du code (la remplacer par une erreur explicite si la clé n'est pas fournie)

```dart
// APRÈS — sans fallback hardcodé :
static void init() {
  if (_envKey.length < 32) {
    throw StateError(
      '[CryptoService] SONGRE_ENCRYPT_KEY non fournie ou trop courte. '
      'Build avec --dart-define=SONGRE_ENCRYPT_KEY=<32+ chars>.'
    );
  }
  final keyBytes = utf8.encode(_envKey).sublist(0, 32);
  _key = enc.Key(Uint8List.fromList(keyBytes));
}
```

---

### [SEC-02] 🟠 Clé anon Supabase hardcodée dans `supabase_service.dart`

**Fichier :** `lib/services/supabase_service.dart` — lignes 26-29

```dart
const String _kAnonKeyProd = 'eyJhbGciOiJIUzI1NiIs...';
```

**Impact :** La clé anon est publique par nature (elle est destinée aux clients non authentifiés). Ce n'est **pas** une fuite critique de sécurité — Supabase est conçu pour que la clé anon soit visible. Cependant, elle est bloquée par le pre-commit hook, indiquant une politique de zéro-secret en dépôt. La présence du `_webhookSecret` hardcodé (ligne 49) est plus préoccupante.

**Fichier :** `lib/services/supabase_service.dart` — ligne 49

```dart
static const String _webhookSecret = String.fromEnvironment(
  'WEBHOOK_SECRET',
  defaultValue: 'Donnersonsangcestsauvezdesvie-songre2026burkinafaso@',
);
```

**Impact :** Le `WEBHOOK_SECRET` est un secret partagé entre Flutter et les Edge Functions. Si un attaquant connaît cette valeur, il peut appeler l'EF `mdp-modifie-auth` en mode webhook en usurpant l'identité du système de notification. **Niveau de risque modéré** — l'EF valide aussi le contenu du payload.

**Correction :** Injecter via `--dart-define=WEBHOOK_SECRET=...` sans valeur par défaut.

---

### [SEC-03] 🟡 RLS non vérifié sur `public.identites`

**Fichier :** `supabase/functions/mission-e.sql` — lignes 57-90

```sql
-- Si la table identites n'existe pas, créez-la avec : (décommenté)
-- RLS activé dans le commentaire, mais le vrai état en base est inconnu
```

La vérification dans `mission-e.sql` alerte si `identites` n'existe pas, mais ne vérifie pas si RLS est activé. Si `identites` existe sans RLS, tous les utilisateurs peuvent lire les données de suppression programmée de tous les autres comptes.

**Correction :**

```sql
ALTER TABLE public.identites ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Lecture propre identite" ON public.identites
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Modification propre identite" ON public.identites
  FOR UPDATE USING (auth.uid() = user_id);
```

---

### [PERF-01] 🟡 Requêtes N+1 potentielles dans `_chargerNotificationsBackend()`

**Fichier :** `lib/services/app_state.dart` — lignes 508-512

```dart
for (final n in nonLues) {
  SupabaseService.marquerNotificationLue(n.id).catchError((_) => false);
}
```

`marquerToutesLues()` effectue une requête HTTP par notification non lue. Pour un utilisateur avec 50 notifications, cela génère 50 requêtes `PATCH` individuelles.

**Correction — Requête bulk :**

```dart
// Nouvelle méthode dans supabase_service.dart
static Future<bool> marquerToutesNotificationsLues(String userId) async {
  final resp = await _requeteAvecRefresh(
    () => http.patch(
      Uri.parse('$_supabaseUrl/rest/v1/notifications_envoyees?user_id=eq.$userId&lu=eq.false'),
      headers: _restHeaders(withAuth: true),
      body: jsonEncode({'lu': true}),
    ).timeout(const Duration(seconds: 10)),
  );
  return resp.statusCode == 204;
}
```

---

### [PERF-02] 🟡 Absence de pagination sur `lireNotifications()`

**Fichier :** `lib/services/supabase_service.dart` (non lu directement mais inféré)

Si `lireNotifications()` charge toutes les notifications sans limite, un utilisateur avec des centaines de notifications télécharge inutilement l'ensemble à chaque connexion.

**Correction :** Ajouter `&limit=50&order=created_at.desc` dans l'URL de la requête de notifications, et implémenter la pagination sur scroll infini dans l'écran de notifications.

---

### [PERF-03] 🔵 Double écriture dans `declarerDon()` — Corrigée

**Statut :** ✅ Corrigée dans `app_state.dart` lignes 344-367. La double écriture (sauvegarderProfil + enregistrerDon) a été supprimée. Désormais : mise à jour optimiste locale uniquement, puis appel EF `don-manuel` pour la persistance.

---

### [FUNC-01] 🟠 Trigger `trg_maj_dernier_don` — Doublon potentiel avec `don-manuel`

**Fichier :** `supabase/functions/mission-e.sql` — lignes 115-169

```sql
CREATE OR REPLACE FUNCTION public.fn_maj_dernier_don_date()
-- Met à jour dernier_don_date après INSERT dans historique_dons
```

L'EF `don-manuel` fait un UPDATE explicite de `dernier_don_date`. Le trigger `trg_maj_dernier_don` fait le même UPDATE après INSERT dans `historique_dons`. Si `don-manuel` insère dans `historique_dons` ET fait un UPDATE, le trigger se déclenchera en plus → double UPDATE sur la même ligne.

**Impact :** Redondance inoffensive (idempotente car `WHERE NEW.date_don > dernier_don_date`), mais légère surcharge. À documenter comme comportement attendu ou à supprimer le trigger si `don-manuel` couvre tous les cas.

---

### [FUNC-02] 🟠 Trigger webhook `mdp-modifie-auth` Mode A sur TOUT `UPDATE auth.users`

**Fichier :** `supabase/functions/mdp-modifie-auth/index.ts` — lignes 76-112

```typescript
// Mode A : Webhook DB (x-webhook-secret)
if (payload.type !== "UPDATE" || payload.table !== "users") {
  return jsonResponse({ skipped: true }, 200, corsHeaders);
}
// Envoie la notification mdp_modifie à chaque UPDATE de auth.users
```

Le Mode A (webhook) se déclenche sur **tout** UPDATE de `auth.users`, y compris les changements d'email, de métadonnées, de `last_sign_in_at`. La notification "Votre mot de passe a été modifié" sera envoyée même si c'est l'email qui a changé, ou après chaque connexion (si Supabase met à jour `last_sign_in_at`).

**Correction :** Utiliser exclusivement le Mode B (appel explicite depuis Flutter après `changerMotDePasse()` réussi) et désactiver le webhook Mode A, ou filtrer plus finement :

```typescript
// Filtrage amélioré Mode A
const meta = updatedUser.raw_user_meta_data;
if (!meta?.password_changed_at) {
  return jsonResponse({ skipped: "no_password_change_detected" }, 200, corsHeaders);
}
```

---

### [FUNC-03] 🔵 Cron `retour-eligibilite-cron` — Vérification de déploiement

Non lu directement, mais présent dans le schéma. À vérifier dans Supabase Dashboard → Edge Functions que le cron est bien actif et que son expression cron correspond à la fréquence attendue (quotidien probable).

---

### [DATA-01] 🟡 Incohérence schéma `sante.*` vs `public.*`

**Fichier :** `supabase-schema-corrections.sql` — schéma `sante.*` (ancien)

```sql
-- Ce fichier définit des tables dans sante.* (sante.reponses_donneurs, etc.)
-- Le code Flutter utilise public.* exclusivement
```

Le fichier `supabase-schema-corrections.sql` contient des DDL pour un schéma `sante.*` qui n'est **pas utilisé** par le code Flutter (`supabase_service.dart` utilise `public.*`). Si ce script a été exécuté en base, des tables orphelines existent dans `sante.*`. Risque de confusion lors de futures migrations.

**Recommandation :** Auditer en base (`\dt sante.*`) et supprimer les tables orphelines si confirmées inutilisées.

---

### [DATA-02] 🔵 `prenom` absent des profils mais utilisé dans les templates email

**Fichier :** `supabase/functions/_shared/email.ts` — nombreux templates

```typescript
const prenom = data["prenom"] ?? "Donneur"; // Fallback si absent
```

`ProfilDonneur` dans `models.dart` ne contient pas de champ `prenom`. Les emails sont envoyés avec le fallback "Donneur" ou "Demandeur" pour tous les utilisateurs, ce qui est impersonnel.

**Recommandation :** Soit ajouter un champ `prenom` optionnel dans `profils_donneurs`, soit passer le début de l'email comme identifiant (ex: première partie avant `@`), soit accepter le fallback générique.

---

## Tableau récapitulatif — Fichiers à modifier

| Fichier | Nature du changement | Priorité |
|---------|---------------------|----------|
| `lib/services/app_state.dart` | Bug S1 : try/catch/finally dans `connecter()` | 🔴 Critique |
| `lib/screens/login_screen.dart` | Bug S1 : guard `mounted` avant `setState` | 🔴 Critique |
| `android/app/src/main/AndroidManifest.xml` | Bug S3 : `android:label="@string/app_name"` | 🔴 Critique |
| `lib/services/supabase_service.dart` | Bug S2 : `redirectTo` dans `reinitialiserMotDePasse()` | 🟠 Majeur |
| `lib/services/supabase_service.dart` | Bug S4 : `obtenirEmailCourant()` sans guard `_accessToken == null` | 🟠 Majeur |
| `supabase/functions/_shared/email.ts` | Fix S5 : `LOGO_URL` mort → Supabase Storage | 🟡 Modéré |
| `supabase/functions/reponse-donneur/index.ts` | S6 : inclure `contact_chiffre` donneur dans INSERT | 🔴 Critique |
| SQL (nouveau fichier de migration) | S6 : colonne `contact_chiffre` dans `reponses_donneurs` + vue + RLS | 🔴 Critique |
| `lib/services/supabase_service.dart` | S6 : `enregistrerReponseDonneur()` + paramètre contact | 🔴 Critique |
| `lib/screens/profil_screen.dart` | S7 : affichage email + conversion StatefulWidget | 🟡 Modéré |
| `lib/services/supabase_service.dart` | S7 : méthode `modifierEmail()` | 🟡 Modéré |
| SQL (`identites` migration) | S8 : colonne `telephone_chiffre` | 🔵 Mineur |
| `lib/screens/profil_screen.dart` | S8 : champ téléphone optionnel | 🔵 Mineur |
| `lib/screens/historique_screen.dart` | S9 : nouveau fichier écran historique | 🔵 Mineur |
| `lib/services/supabase_service.dart` | S9 : méthodes `lireDemandesParAuteur()` + `lireDonsParDonneur()` | 🔵 Mineur |
| `lib/utils/crypto_service.dart` | SEC-01 : supprimer la `_fallbackKey` hardcodée | 🔴 Critique |
| `lib/services/supabase_service.dart` | SEC-02 : supprimer `_webhookSecret` par défaut hardcodé | 🟡 Modéré |
| SQL (Supabase Dashboard) | SEC-03 : RLS sur `identites` | 🟡 Modéré |
| `lib/services/app_state.dart` | PERF-01 : requête bulk `marquerToutesLues()` | 🟡 Modéré |
| `supabase/functions/mdp-modifie-auth/index.ts` | FUNC-02 : filtrer webhook Mode A | 🟠 Majeur |

---

## Points nécessitant confirmation avant correction définitive

1. **S2 — URL de redirection configurée dans le Supabase Dashboard :** Quelle URL est actuellement dans "Authentication → URL Configuration → Redirect URLs" ? Si `songre://reset-password` est déjà là, le bug vient uniquement de l'absence de `redirectTo` dans le code Flutter.

2. **S3 — Icône :** La commande `flutter pub run flutter_launcher_icons` a-t-elle été exécutée après la configuration dans `pubspec.yaml` ? Les répertoires `android/app/src/main/res/mipmap-*/` contiennent-ils des fichiers générés par `flutter_launcher_icons` ou les icônes par défaut Flutter ?

3. **S6 — Contact du donneur :** Le donneur doit-il fournir son contact au moment de répondre à une demande (formulaire dans l'app), ou son contact est-il son numéro de téléphone de profil (`telephone_chiffre` de S8) ? La réponse détermine l'UX à implémenter.

4. **S8 — `telephone_hash` en base :** Existe-t-il vraiment une colonne `telephone_hash` dans `public.identites` (créée manuellement), ou est-elle uniquement dans l'ancien schéma `sante.*` ? Vérifier : `SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='identites';`

5. **SEC-01 — Rotation de la clé de chiffrement :** Si la `_fallbackKey` hardcodée est supprimée et remplacée par une vraie clé produite aléatoirement, toutes les données chiffrées avec l'ancienne clé (`[REDACTED]`) seront illisibles. Une migration des données en base (déchiffrement avec l'ancienne clé + rechiffrement avec la nouvelle) est nécessaire avant ce changement. Confirmer si des données chiffrées existent déjà en base.

6. **FUNC-02 — Webhook Mode A actif :** Le webhook `UPDATE auth.users → mdp-modifie-auth` est-il réellement configuré dans Supabase Dashboard (Database → Webhooks) ? Si non, Mode A est mort code et seul le Mode B (appel Flutter explicite) fonctionne.

7. **PERF — Cron `retour-eligibilite-cron` :** L'Edge Function `retour-eligibilite-cron` est-elle déployée et son cron Supabase actif ? Vérifier dans Dashboard → Edge Functions → Scheduled Functions.

---

*Fin de l'audit SONGRE — 2026-07-09*  
*Basé sur l'analyse du code source réel du dépôt `/home/user/flutter_app`*
