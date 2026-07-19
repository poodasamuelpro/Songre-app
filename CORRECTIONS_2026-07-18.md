# RAPPORT DE CORRECTIONS — SONGRE · 2026-07-18

**Commit de référence :** `824383a`  
**Build APK :** `build/app/outputs/flutter-apk/app-release.apk` · 70 MB · `com.songre.app` · label `Songre`  
**`flutter analyze` :** Zéro issue  
**GitHub :** https://github.com/poodasamuelpro/Songre-app · `bf68bcc..824383a` pushé sur `main`  
**Date :** 2026-07-18

---

## Tableau de bord — Statut de toutes les corrections

| ID | Titre | Fichier(s) | Statut |
|---|---|---|---|
| P1 | Bug écran blanc après « Je réponds » | `detail_demande_screen.dart` | ✅ CORRIGÉ |
| P2 | Bouton Scanner restreint à l'auteur | `detail_demande_screen.dart` | ✅ CORRIGÉ |
| P3 | Logique affichage demandes (home vs global) | `home_screen.dart`, `demandes_screen.dart` | ✅ CONFIRMÉ CORRECT (lecture seule) |
| 4.1 | WEBHOOK_SECRET dans Makefile + README | `Makefile`, `README.md` | ✅ CORRIGÉ |
| 4.2 | Retry réseau dans `enregistrerReponseDonneur()` | `supabase_service.dart` | ✅ CORRIGÉ |
| 4.3 | ProGuard + activation minification | `build.gradle.kts`, `proguard-rules.pro` (nouveau) | ✅ CORRIGÉ |
| 4.4 | `Firebase.initializeApp()` conditionné `!kIsWeb` | `main.dart` | ✅ CORRIGÉ |
| 4.5 | Version dynamique via `package_info_plus` | `pubspec.yaml`, `parametres_screen.dart` | ✅ CORRIGÉ |
| 4.6 | `APP_URL` env var dans `email.ts` | `supabase/functions/_shared/email.ts` | ✅ CORRIGÉ |
| 4.7 | Liens `tel:` cliquables + DIAL queries | `detail_demande_screen.dart`, `AndroidManifest.xml` | ✅ CORRIGÉ |

---

## PARTIE 1 — Bug écran blanc après « Je réponds »

### Fichier modifié
`lib/screens/detail_demande_screen.dart`

### Cause racine identifiée
Chaîne async à 3 niveaux déclenchant un écran blanc :
1. `_repondre()` → `state.enregistrerReponseDonneur()` → `_ajouterNotificationLocale()` → **`notifyListeners()`**
2. `notifyListeners()` déclenche GoRouter (`refreshListenable: appState`) → reconstruit l'arbre de widgets
3. `_chargerContactsDonneurs()` appelait `setState()` **sans** vérification `!mounted` préalable → crash
4. `ScaffoldMessenger.of(context)` utilisé **après** les `await` → contexte potentiellement invalide

### Corrections appliquées

**`_repondre()` — avant :**
```dart
// ❌ context.read<AppState>() après un await (contexte potentiellement reconstruit)
// ❌ await _chargerEtatRepondu() direct (setState pendant reconstruction GoRouter)
// ❌ ScaffoldMessenger.of(context) après les awaits
```

**`_repondre()` — après :**
```dart
Future<void> _repondre() async {
  final demande = widget.demande;
  // ✅ Capture AVANT tout await
  final state = context.read<AppState>();
  // ignore: use_build_context_synchronously — volontaire : capturé avant await
  final messenger = ScaffoldMessenger.of(context);

  setState(() => _repondu = true);  // mise à jour optimiste

  final ok = await state.enregistrerReponseDonneur(demande.id);

  if (!mounted) return;  // ✅ Guard après await

  if (ok) {
    // ✅ addPostFrameCallback évite setState pendant reconstruction GoRouter
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _chargerEtatRepondu();
    });
  } else {
    setState(() => _repondu = false);  // rollback optimiste
  }

  // ✅ messenger capturé avant await — toujours valide
  messenger.showSnackBar(SnackBar(...));
}
```

**`_chargerContactsDonneurs()` — avant :**
```dart
Future<void> _chargerContactsDonneurs() async {
  setState(() => _contactsDonneursLoading = true);  // ❌ sans !mounted
```

**`_chargerContactsDonneurs()` — après :**
```dart
Future<void> _chargerContactsDonneurs() async {
  if (!mounted) return;  // ✅ check AVANT setState
  setState(() => _contactsDonneursLoading = true);
  ...
  if (!mounted) return;
  setState(() { ... });
}
```

---

## PARTIE 2 — Bouton Scanner restreint à l'auteur de la demande

### Fichier modifié
`lib/screens/detail_demande_screen.dart` — méthode `_buildActionRow()`

### Problème
Le bouton « Scanner le code du donneur » était affiché à **tout utilisateur connecté**, y compris aux donneurs. Cette action (scanner le QR du donneur pour confirmer un don) est réservée exclusivement à l'auteur de la demande.

### Correction

```dart
// ❌ Avant — visible par tous les connectés
if (state.userId != null)

// ✅ Après — visible uniquement par l'auteur
if (state.userId != null && state.userId == demande.auteurId)
```

---

## PARTIE 3 — Logique d'affichage des demandes (vérification lecture seule)

### Fichiers lus (aucune modification)
- `lib/screens/home_screen.dart`
- `lib/screens/demandes_screen.dart`

### Résultat
- **Accueil (`home_screen.dart`)** : utilise `state.demandes` → données filtrées par ville du profil via `actualiserDemandes()` ✅
- **Toutes demandes (`demandes_screen.dart`)** : utilise `state.toutesLesDemandes` → toutes villes via `actualiserToutesLesDemandes()` ✅
- Logique correcte, aucune modification nécessaire.

---

## PARTIE 4.1 — WEBHOOK_SECRET dans Makefile + documentation README

### Fichiers modifiés
`Makefile`, `README.md`

### Makefile — ajout `--dart-define=WEBHOOK_SECRET=$$WEBHOOK_SECRET`

```makefile
# Avant
flutter build apk --release \
    --dart-define=SONGRE_ENCRYPT_KEY=[REDACTED] \
    --dart-define=flutter.inspector.structuredErrors=false \
    --dart-define=debugShowCheckedModeBanner=false

# Après
flutter build apk --release \
    --dart-define=SONGRE_ENCRYPT_KEY=[REDACTED] \
    --dart-define=WEBHOOK_SECRET=$$WEBHOOK_SECRET \     # ← AJOUTÉ
    --dart-define=flutter.inspector.structuredErrors=false \
    --dart-define=debugShowCheckedModeBanner=false
```

> **Note syntaxe Makefile :** `$$WEBHOOK_SECRET` = un seul `$` passé au shell (Makefile échappe `$` en `$$`).

### README.md — nouvelle section
Ajout de la section **"Variables d'environnement requises avant tout build release"** avec tableau, exemple `export WEBHOOK_SECRET=...`, notes de sécurité.

### Comment utiliser
```bash
export WEBHOOK_SECRET="votre_secret_supabase"
make apk
```

---

## PARTIE 4.2 — Retry réseau dans `enregistrerReponseDonneur()`

### Fichier modifié
`lib/services/supabase_service.dart`

### Problème
`_requeteAvecRefresh()` ne retentait que sur HTTP 401 (refresh token). Les erreurs réseau (`TimeoutException`, `SocketException`) échouaient définitivement sans retry.

### Solution : 3 tentatives avec backoff exponentiel

```dart
const int maxTentatives = 3;
const List<int> delaisMs = [0, 1000, 2000];  // 0ms, 1s, 2s

for (int tentative = 0; tentative < maxTentatives; tentative++) {
  if (delaisMs[tentative] > 0) {
    await Future.delayed(Duration(milliseconds: delaisMs[tentative]));
  }
  try {
    final resp = await _requeteAvecRefresh(
      () => http.post(url, headers: hdrs, body: body)
          .timeout(const Duration(seconds: 10)),
    );
    if (resp.statusCode == 201 || resp.statusCode == 200 || resp.statusCode == 204) {
      return true;  // succès — stop immédiat
    }
    return false;  // erreur HTTP — pas de retry (serveur a répondu)
  } catch (e) {
    if (tentative == maxTentatives - 1) return false;  // dernière tentative
    // sinon : retry avec délai
  }
}
```

**Comportement :**
- Erreur réseau (timeout, socket) → retry après 1s puis 2s → max 3 tentatives
- Réponse HTTP (200/201/204/4xx/5xx) → retour immédiat sans retry
- `_requeteAvecRefresh()` continue de gérer le refresh JWT (401) de façon indépendante

---

## PARTIE 4.3 — ProGuard + activation minification Android

### Fichiers modifiés/créés
- `android/app/build.gradle.kts` — `isMinifyEnabled = true`, `isShrinkResources = true`
- `android/app/proguard-rules.pro` — **NOUVEAU fichier** (créé)

### `build.gradle.kts` — avant/après

```kotlin
// Avant
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("release")
        isMinifyEnabled = false
        isShrinkResources = false
    }
}

// Après
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("release")
        isMinifyEnabled = true
        isShrinkResources = true
        proguardFiles(
            getDefaultProguardFile("proguard-android-optimize.txt"),
            "proguard-rules.pro"
        )
    }
}
```

### `proguard-rules.pro` — règles couvertes

| Bibliothèque | Règle | Raison |
|---|---|---|
| Flutter Engine | `-keep class io.flutter.**` | Runtime Flutter obligatoire |
| Firebase | `-keep class com.google.firebase.**` | Reflection Firebase |
| Google Play Services | `-keep class com.google.android.gms.**` | Dépendance Firebase |
| flutter_secure_storage | `-keep class com.it_nomads.fluttersecurestorage.**` | Accès Keystore Android |
| mobile_scanner / ML Kit | `-keep class com.google.mlkit.**` | Bibliothèques de scan QR |
| Kotlin stdlib | `-keep class kotlin.**` | Utilisé par plugins |
| url_launcher | `-keep class io.flutter.plugins.urllauncher.**` | Intent Android |
| Android standard | Activity, Service, BroadcastReceiver | Composants Android |

---

## PARTIE 4.4 — `Firebase.initializeApp()` conditionné sur `!kIsWeb`

### Fichier modifié
`lib/main.dart`

### Problème
Sur la version Web, `Firebase.initializeApp()` échouait silencieusement (pas de `google-services Web`, pas de `firebase_options.dart`). L'exception était capturée par le `try/catch` mais générait du bruit inutile.

### Correction

```dart
// Avant
try {
  await Firebase.initializeApp();
} catch (e) {
  if (kDebugMode) debugPrint('[main] Firebase init skipped: $e');
}

// Après
if (!kIsWeb) {  // ← AJOUTÉ
  try {
    await Firebase.initializeApp();
  } catch (e) {
    if (kDebugMode) debugPrint('[main] Firebase init skipped: $e');
  }
}
```

`kIsWeb` est déjà importé via `package:flutter/foundation.dart` — aucun import supplémentaire requis.

---

## PARTIE 4.5 — Version dynamique via `package_info_plus`

### Fichiers modifiés
`pubspec.yaml`, `lib/screens/parametres_screen.dart`

### `pubspec.yaml`
```yaml
# Ajouté
package_info_plus: ^8.1.2
```

### `parametres_screen.dart` — 4 modifications

**1. Import ajouté :**
```dart
import 'package:package_info_plus/package_info_plus.dart';
```

**2. Champ d'état ajouté :**
```dart
String? _version;  // null jusqu'au chargement asynchrone
```

**3. Méthode `_chargerVersion()` ajoutée + `initState` mis à jour :**
```dart
Future<void> _chargerVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = info.version);
  } catch (e) {
    // _version reste null → affiche '—'
  }
}

@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await _chargerVersion();  // awaité (rapide)
    _chargerLiens();          // puis chargement des liens
  });
}
```

**4. Deux occurrences hardcodées remplacées :**
```dart
// Avant
'SONGRE v1.0.0'
valeur: '1.0.0'

// Après
'SONGRE v${_version ?? '—'}'
valeur: _version ?? '—'
```

---

## PARTIE 4.6 — `APP_URL` env var dans `email.ts`

### Fichier modifié
`supabase/functions/_shared/email.ts`

### Problème
6 URLs `https://songre.bf` hardcodées dans les templates email : 5 dans les boutons CTA des templates et 1 dans le footer copyright.

### Correction

**Constante ajoutée (après `LOGO_URL`) :**
```typescript
const APP_URL = Deno.env.get("APP_URL") ?? "https://songre.vercel.app";
```

**Remplacement :**
| Ligne origine | Avant | Après |
|---|---|---|
| 76 | `href="https://songre.bf"` (footer) | `href="${APP_URL}"` |
| 106 | `href="https://songre.bf/app"` (demande_compatible) | `href="${APP_URL}"` |
| 190 | `href="https://songre.bf/app"` (don_confirme) | `href="${APP_URL}"` |
| 221 | `href="https://songre.bf/app"` (don_confirme_demandeur) | `href="${APP_URL}"` |
| 259 | `href="https://songre.bf/app"` (reponse_recue) | `href="${APP_URL}"` |
| 371 | `href="https://songre.bf/app"` (retour_eligibilite) | `href="${APP_URL}"` |

**Non touché :** ligne 585 `noreply@songre.bf` (adresse expéditeur — hors périmètre).

### Action requise côté Supabase
Dans **Dashboard Supabase → Project Settings → Edge Functions → Environment Variables**, ajouter :
```
APP_URL = https://songre.vercel.app
```
(ou `https://songre.bf/app` si le domaine est actif)

---

## PARTIE 4.7 — Numéros `tel:` cliquables + DIAL queries

### Fichiers modifiés
`lib/screens/detail_demande_screen.dart`, `android/app/src/main/AndroidManifest.xml`

### `detail_demande_screen.dart` — nouvelles méthodes

**Imports ajoutés :**
```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';    // Clipboard
import 'package:url_launcher/url_launcher.dart';  // launchUrl, canLaunchUrl
```

**`_normaliserTelephone()` — nettoyage du numéro :**
```dart
String _normaliserTelephone(String tel) {
  return tel.replaceAll(RegExp(r'[\s\-.()/]'), '');
}
```

**`_appelerTelephone()` — lancement du dialer avec fallback :**
```dart
Future<void> _appelerTelephone(BuildContext ctx, String tel) async {
  final normalise = _normaliserTelephone(tel);
  final uri = Uri.parse('tel:$normalise');
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri);
  } else {
    // Fallback : copie dans le presse-papier + SnackBar
    await Clipboard.setData(ClipboardData(text: normalise));
    ScaffoldMessenger.of(ctx).showSnackBar(...);
  }
}
```

**`_buildContactRow()` — widget de contact cliquable :**
- Bordure verte si numéro disponible, grise sinon
- Numéro en vert souligné + icône `Icons.call`
- Un tap → `_appelerTelephone()`
- Si numéro null/vide → texte « Non renseigné » (non cliquable)

**Points de contact mis à jour :**

| Direction | Champs | Widget utilisé |
|---|---|---|
| Donneur → voit contact demandeur | `contactChiffre`, `contactSecondaireChiffre` | `_buildContactRow()` |
| Auteur → voit contacts donneurs | `_contactsDonneurs[i]['telephone']` | `_buildContactRow()` |

### `AndroidManifest.xml` — intent `DIAL` ajouté

```xml
<queries>
    <!-- PROCESS_TEXT — existant -->
    <intent>
        <action android:name="android.intent.action.PROCESS_TEXT"/>
        <data android:mimeType="text/plain"/>
    </intent>
    <!-- [4.7] DIAL — requis Android 11+ pour canLaunchUrl('tel:') -->
    <intent>
        <action android:name="android.intent.action.DIAL"/>
        <data android:scheme="tel"/>
    </intent>
</queries>
```

Sans cette déclaration, `canLaunchUrl(Uri.parse('tel:...'))` retourne `false` sur Android 11+ (API 30+), ce qui forcerait systématiquement le fallback clipboard même sur un appareil avec dialer.

---

## Résultats des vérifications finales

### `flutter analyze`
```
Analyzing flutter_app...
No issues found! (ran in 5.8s)
```
✅ **Zéro issue**

### Build APK
```
flutter build apk --release \
  --dart-define=SONGRE_ENCRYPT_KEY=[REDACTED] \
  --dart-define=WEBHOOK_SECRET=*** \
  ...

✓ Built build/app/outputs/flutter-apk/app-release.apk (70 MB)
```
✅ **Build réussi** · 70 MB · durée ~295s

### Vérification `aapt dump badging`
```
package: name='com.songre.app' versionCode='1' versionName='1.0.0'
application-label:'Songre'
```
✅ **`com.songre.app`** ✅ **label `Songre`**

### Git
```
[main 824383a] fix+feat: corrections audit 2026-07-18 — P1 écran blanc, P2 scanner, P4.1-P4.7
13 files changed, 439 insertions(+), 52 deletions(-)
create mode 100644 android/app/proguard-rules.pro

To https://github.com/poodasamuelpro/Songre-app.git
   bf68bcc..824383a  main -> main
```
✅ **Committé et pushé** sur `github/main`

---

## Ledger complet des fichiers modifiés

| Fichier | Type | Modifications |
|---|---|---|
| `lib/screens/detail_demande_screen.dart` | modifié | P1 (_repondre + _chargerContactsDonneurs), P2 (scanner condition), P4.7 (tel: links, imports, _buildContactRow) |
| `Makefile` | modifié | 4.1 : ajout `--dart-define=WEBHOOK_SECRET=$$WEBHOOK_SECRET` |
| `README.md` | modifié | 4.1 : section variables requises avant build |
| `lib/services/supabase_service.dart` | modifié | 4.2 : retry 3 tentatives avec backoff |
| `android/app/build.gradle.kts` | modifié | 4.3 : `isMinifyEnabled=true`, `isShrinkResources=true`, `proguardFiles` |
| `android/app/proguard-rules.pro` | **créé** | 4.3 : règles ProGuard/R8 pour toutes les dépendances |
| `lib/main.dart` | modifié | 4.4 : `if (!kIsWeb)` autour de `Firebase.initializeApp()` |
| `pubspec.yaml` | modifié | 4.5 : ajout `package_info_plus: ^8.1.2` |
| `lib/screens/parametres_screen.dart` | modifié | 4.5 : import, `_version`, `_chargerVersion()`, 2 occurrences dynamiques |
| `supabase/functions/_shared/email.ts` | modifié | 4.6 : constante `APP_URL`, 6 URLs remplacées |
| `android/app/src/main/AndroidManifest.xml` | modifié | 4.7 : `<queries>` DIAL intent |

**Fichiers non modifiés (vérifiés par lecture) :**
- `lib/services/app_state.dart` — logique `enregistrerReponseDonneur()` correcte, pas de changement
- `lib/router.dart` — `refreshListenable: appState` compris, pas de changement
- `lib/screens/home_screen.dart` — `state.demandes` (ville-filtré) correct
- `lib/screens/demandes_screen.dart` — `state.toutesLesDemandes` (toutes villes) correct

---

## Actions requises côté déploiement (hors code)

| Action | Priorité | Détail |
|---|---|---|
| Configurer `APP_URL` dans Supabase | **Haute** | Dashboard → Edge Functions → Environment Variables → `APP_URL = https://songre.vercel.app` |
| Déployer les Edge Functions | Moyenne | `supabase functions deploy` pour `email.ts` mis à jour |
| Tester `tel:` sur APK réel | Haute | Vérifier que le dialer s'ouvre sur Android physique |
| Play Store — Sécurité des données | **BLOQUANT** | Formulaire Data Safety à compléter avant publication (B.10 audit) |

---

*Rapport généré le 2026-07-18 · Commit `824383a` · `flutter analyze: 0 issues` · APK `com.songre.app` label `Songre` · 70 MB*
