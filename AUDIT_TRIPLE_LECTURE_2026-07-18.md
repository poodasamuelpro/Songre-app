# RAPPORT D'AUDIT TRIPLE LECTURE — SONGRE
**Date :** 2026-07-18  
**Session :** Audit session 3 — vérification rigoreuse des correctifs de session 2  
**Méthodologie :** Triple lecture indépendante + analyse croisée + vérification structurelle  
**Auditeur :** Ingénieur senior — lecture manuelle de chaque fichier, aucune présupposition  
**Résultat global :** ✅ **TOUS LES POINTS CONFORMES — AUCUN CORRECTIF COMPLÉMENTAIRE REQUIS**

---

## Environnement de vérification

| Item | Valeur |
|---|---|
| Commit audité | `824383a` (correctifs) + `dfd7b6f` (rapport session 2) |
| Commit de référence (avant session 2) | `bf68bcc` |
| Branch | `main` |
| `flutter analyze` au démarrage | `No issues found! (ran in 12.2s)` ✅ |
| Working tree | Propre — aucune modification non committée |
| APK rebuild session 3 | `build/app/outputs/flutter-apk/app-release.apk` — 72.6 MB ✅ |

---

## Point 1 — Bug écran blanc après « Je réponds »

**Fichiers lus :** `lib/screens/detail_demande_screen.dart` (intégralité, 850 lignes), `lib/services/app_state.dart` (méthodes `enregistrerReponseDonneur`, `_ajouterNotificationLocale`), `lib/router.dart` (complet)

### Première lecture
`_repondre()` (lignes 741–786) :
- `context.read<AppState>()` capturé ligne 746 — **avant** tout `await` ✓
- `ScaffoldMessenger.of(context)` capturé ligne 748 — **avant** tout `await` ✓  
- `setState(() => _repondu = true)` effectué avant `await` (mise à jour optimiste) ✓
- `if (!mounted) return;` présent ligne 755 après l'`await` ✓
- `WidgetsBinding.instance.addPostFrameCallback(...)` utilisé pour différer `_chargerEtatRepondu()` ✓
- `messenger.showSnackBar(...)` utilise le messenger pré-capturé ✓

`_chargerContactsDonneurs()` (lignes 68–79) :
- `if (!mounted) return;` **en première ligne** (ligne 69) ✓
- Second `if (!mounted) return;` après `await` (ligne 74) ✓

### Deuxième lecture (indépendante)
Relecture ciblée sur la séquence temporelle des captures vs awaits :
- Ordre confirmé : read/watch → capture → setState optimiste → await → !mounted → callback ✓
- Aucune inversion détectée

### Troisième lecture (croisée avec app_state.dart + router.dart)
- `enregistrerReponseDonneur()` dans `app_state.dart` appelle `_ajouterNotificationLocale()` → `notifyListeners()` ✓ (cause racine identifiée)
- `refreshListenable: appState` dans `router.dart` ligne 72 → GoRouter réévalue redirect lors de `notifyListeners()` ✓
- La redirect ne peut pas mener hors de `/demande/:id` pour un utilisateur auth + profil → `return null` ✓
- Accès à `state.userId` après `await` dans `_chargerEtatRepondu()` (ligne 61) : **safe** — `state` est une référence locale capturée avant l'`await`, pas un accès à `context` ✓

### Verdict
✅ **CONFORME** — Correctif correctement appliqué, cause racine adressée, aucun cas limite non couvert.

---

## Point 2 — Visibilité bouton « Scanner un code »

**Fichiers lus :** `lib/screens/detail_demande_screen.dart` (`_buildActionRow`), `lib/router.dart` (route `/scan-qr` avec redirect)

### Première lecture
Condition ligne 629 :
```dart
if (state.userId != null && state.userId == demande.auteurId)
```
- `state` obtenu via `context.watch<AppState>()` ligne 569 — reconstruit à chaque changement ✓
- Double vérification : non-null ET égalité à `auteurId` ✓

### Deuxième lecture
- Vérification que `state` dans `_buildActionRow` est bien `context.watch` (pas `context.read`) → ✓ rebuild déclenché si userId change
- Bouton "Je réponds" et "Générer mon code" restent sans condition → choix de design intentionnel, non un bug

### Troisième lecture
- Route `/scan-qr` dans `router.dart` a un redirect hard qui bloque si `demandeurId.isEmpty` — protection supplémentaire en profondeur ✓
- Aucun autre endroit dans l'app n'affiche ce bouton Scanner

### Verdict
✅ **CONFORME** — Condition correctement implantée, aucune duplication, protection double (UI + router).

---

## Point 3 — Logique affichage demandes (accueil filtré / global)

**Fichiers lus :** `lib/screens/home_screen.dart`, `lib/screens/demandes_screen.dart`, `lib/services/app_state.dart` (getters)

### Première lecture
- `home_screen.dart` ligne 20 : `state.demandes` (getter filtré par ville) ✓
- `demandes_screen.dart` ligne 41 : `state.toutesLesDemandes` (toutes villes) ✓

### Deuxième lecture
- `app_state.dart` : deux variables distinctes `_demandes` et `_toutesLesDemandes` ✓
- `actualiserDemandes()` vs `actualiserToutesLesDemandes()` : appels distincts dans les deux écrans ✓

### Troisième lecture croisée
- `git diff bf68bcc 824383a -- lib/services/app_state.dart` → diff vide : `app_state.dart` **non modifié** en session 2 → zéro risque de régression ✓

### Verdict
✅ **CONFORME** — Logique d'affichage intacte, aucune régression.

---

## Point 4 — WEBHOOK_SECRET dans Makefile + README

**Fichiers lus :** `Makefile`, `README.md`, `lib/services/supabase_service.dart`

### Première lecture (Makefile)
```makefile
flutter build apk --release \
    --dart-define=SONGRE_ENCRYPT_KEY=[REDACTED] \
    --dart-define=WEBHOOK_SECRET=$$WEBHOOK_SECRET \
    ...
```
`$$WEBHOOK_SECRET` : syntaxe Makefile correcte pour passer la variable d'environnement ✓

### Deuxième lecture (README)
- Ligne 631 : tableau documentant `WEBHOOK_SECRET` avec description complète ✓
- Ligne 641 : avertissement explicite si variable vide → QR rejeté en production ✓
- Ligne 643 : consigne de sécurité (ne jamais hardcoder) ✓

### Troisième lecture (code Flutter)
```dart
static const String _webhookSecret = String.fromEnvironment('WEBHOOK_SECRET');
```
- Ligne 987 : `if (_webhookSecret.isNotEmpty) 'x-webhook-secret': _webhookSecret,` → usage défensif ✓

### Verdict
✅ **CONFORME** — Chaîne complète : env var → Makefile → dart-define → `String.fromEnvironment` → usage conditionnel.

---

## Point 5 — Retry réseau dans `enregistrerReponseDonneur()`

**Fichiers lus :** `lib/services/supabase_service.dart` (lignes 1164–1244), `lib/services/app_state.dart` (appel)

### Première lecture
- 3 tentatives maximum avec délais `[0, 1000, 2000]` ms ✓
- Retry uniquement sur exception réseau (catch), pas sur erreur HTTP ✓
- Header `Prefer: return=minimal,resolution=ignore-duplicates` défini avant la boucle → présent sur toutes les tentatives ✓
- `return false` immédiat sur HTTP error (pas de retry pour 4xx/5xx) ✓

### Deuxième lecture
Vérification logique de la boucle :
- Tentative 0 : délai 0ms → catch → pas last (0 < 2) → continue ✓
- Tentative 1 : délai 1000ms → catch → pas last (1 < 2) → continue ✓
- Tentative 2 : délai 2000ms → catch → last (2 == 2) → return false ✓
- `return false` final ligne 1243 : requis par Dart (inatteignable mais necessaire pour le type) ✓

### Troisième lecture (cohérence avec _repondre())
- Délai maximal théorique : 0s + 10s(to) + 1s + 10s(to) + 2s + 10s(to) ≈ 33s en cas de 3 timeouts consécutifs
- `_repondre()` affiche le SnackBar **après** le retour de `enregistrerReponseDonneur()` → l'utilisateur voit le résultat final ✓
- Pas de race condition possible : `_repondre()` est `async`, le bouton est `_repondu=true` pendant l'attente ✓

### Verdict
✅ **CONFORME** — Retry logique correcte, anti-duplicate préservé, cohérence avec appelant garantie.

---

## Point 6 — Minification Android (ProGuard/R8)

**Fichiers lus :** `android/app/build.gradle.kts`, `android/app/proguard-rules.pro`

### Première lecture (build.gradle.kts)
```kotlin
release {
    signingConfig = signingConfigs.getByName("release")
    isMinifyEnabled = true
    isShrinkResources = true
    proguardFiles(
        getDefaultProguardFile("proguard-android-optimize.txt"),
        "proguard-rules.pro"
    )
}
```
✓ Activé correctement

### Deuxième lecture (proguard-rules.pro)
Règles présentes pour :
- `io.flutter.**` — Flutter engine ✓
- `com.google.firebase.**` + `com.google.android.gms.**` — Firebase ✓
- `com.it_nomads.fluttersecurestorage.**` — flutter_secure_storage ✓
- `com.google.mlkit.**` + `com.google.android.gms.vision.**` — mobile_scanner ML Kit ✓
- `kotlin.**` — stdlib ✓
- `io.flutter.plugins.urllauncher.**` — url_launcher ✓
- `androidx.**` — support library ✓
- `-keepattributes Signature,Exceptions,SourceFile,LineNumberTable` ✓

### Troisième lecture (test build réel)
- APK rebuild session 3 : ✅ succès complet (`72.6 MB`)
- Session 2 APK avait déjà buildé avec succès (`70 MB`)
- Aucune erreur ProGuard/R8 dans les logs de build

### Verdict
✅ **CONFORME** — Minification activée, règles complètes, build réel confirmé deux fois.

---

## Point 7 — `Firebase.initializeApp()` conditionné sur `!kIsWeb`

**Fichiers lus :** `lib/main.dart` (complet, 110 lignes)

### Première lecture
```dart
if (!kIsWeb) {
  try {
    await Firebase.initializeApp();
  } catch (e) {
    if (kDebugMode) debugPrint('[main] Firebase init skipped: $e');
  }
}
```
✓ Condition correcte, try/catch protège le démarrage

### Deuxième lecture
- `kIsWeb = true` sur Web → `!kIsWeb = false` → bloc ignoré sur Web ✓
- `kIsWeb = false` sur Android → `!kIsWeb = true` → Firebase initialisé sur Android ✓
- Condition non inversée, logique claire ✓

### Troisième lecture
- Aucune autre initialisation Firebase dans les autres fichiers de `lib/` ✓
- `SauveApp` est `StatefulWidget` (correction anti-écran-noir préservée) ✓
- Builder de `MaterialApp.router` gère `child == null` avec `safeChild` ✓

### Verdict
✅ **CONFORME** — Condition correcte, démarrage Android préservé, Web non impacté.

---

## Point 8 — Version dynamique via `package_info_plus`

**Fichiers lus :** `lib/screens/parametres_screen.dart`, `pubspec.yaml`

### Première lecture
```dart
import 'package:package_info_plus/package_info_plus.dart';
String? _version;

Future<void> _chargerVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    if (mounted) { setState(() => _version = info.version); }
  } catch (e) {
    if (kDebugMode) debugPrint('[ParametresScreen] erreur chargement version: $e');
  }
}
```
- `mounted` check avant `setState` ✓
- Erreur non-fatale (app continue) ✓
- Fallback : `_version ?? '—'` si null ✓

### Deuxième lecture
- `initState` : `await _chargerVersion()` avant `_chargerLiens()` ✓ (awaited intentionnel pour avoir la version avant le rendu)
- 2 occurrences de `_version` dans le build : `'SONGRE v${_version ?? '—'}'` et `valeur: _version ?? '—'` ✓
- Aucune occurrence résiduelle de `'1.0.0'` hardcodé dans cet écran ✓

### Troisième lecture
- `pubspec.yaml` ligne 4 : `version: 1.0.0+1` → `PackageInfo.version` retournera `'1.0.0'` ✓
- `package_info_plus: ^8.1.2` dans `pubspec.yaml` ligne 58 ✓

### Verdict
✅ **CONFORME** — Version dynamique correctement implantée, deux points d'affichage mis à jour, fallback sûr.

---

## Point 9 — URLs dynamiques dans `supabase/functions/_shared/email.ts`

**Fichiers lus :** `supabase/functions/_shared/email.ts` (complet), scan de tous les `.ts` dans `supabase/functions/`

### Première lecture
```typescript
const APP_URL = Deno.env.get("APP_URL") ?? "https://songre.vercel.app";
```
Occurrences vérifiées :
- Ligne 82 : `href="${APP_URL}"` (footer) ✓
- Lignes 112, 196, 227, 265, 377 : `href="${APP_URL}"` (5 boutons) ✓
**Total : 6 remplacements** ✓

### Deuxième lecture
Occurrences résiduelles de `songre.bf` dans `email.ts` :
- Ligne 82 : texte affiché `songre.bf` (nom de marque) — lien pointe vers `${APP_URL}` ✓ intentionnel
- Ligne 585 : `noreply@songre.bf` (adresse email expéditeur) — hors périmètre P4.6, documenté ✓

### Troisième lecture (scan transversal)
- `supabase/functions/_shared/cors.ts` : `"https://songre.bf"` = liste blanche CORS origin ✓ intentionnel
- `supabase/functions/mission-d.sql` : URLs de liens légaux hardcodées en base ✓ hors périmètre
- **Aucune occurrence non traitée de `songre.bf/app` dans les fichiers de fonctions actifs** ✓

### Verdict
✅ **CONFORME** — 6 remplacements effectués, 2 occurrences résiduelles légitimes et documentées.

---

## Point 10 — Liens téléphoniques `tel:` + intégrité `AndroidManifest.xml`

**Fichiers lus :** `lib/screens/detail_demande_screen.dart` (`_buildContactRow`, `_appelerTelephone`, `_normaliserTelephone`), `android/app/src/main/AndroidManifest.xml`

### Première lecture (AndroidManifest)
Structure `<queries>` :
```xml
<queries>
    <intent>
        <action android:name="android.intent.action.PROCESS_TEXT"/>
        <data android:mimeType="text/plain"/>
    </intent>
    <!-- [4.7] DIAL intent pour Android 11+ -->
    <intent>
        <action android:name="android.intent.action.DIAL"/>
        <data android:scheme="tel"/>
    </intent>
</queries>
```
- `PROCESS_TEXT` existant préservé ✓
- `DIAL` ajouté ✓
- `intent-filter` principal (MAIN/LAUNCHER) intact ✓
- Permissions `INTERNET`, `CAMERA`, `POST_NOTIFICATIONS` intactes ✓

### Deuxième lecture (code Dart)
`_buildContactRow()` :
- `hasPhone = telephone != null && telephone.isNotEmpty && telephone != 'Contact indisponible'` ✓
- Fallback si `!hasPhone` : `telephone ?? 'Non renseigné'` ✓
- Note : quand `CryptoService.dechiffrer()` retourne `null`, on passe `'Contact indisponible'` → affiché comme "Non renseigné" (inconsistance d'affichage mineure connue, documentée en session 2, non bloquante)

`_appelerTelephone()` :
- `canLaunchUrl(uri)` vérifié avant `launchUrl(uri)` ✓
- Fallback sur copie presse-papier si dialer absent ✓
- `ctx.mounted` check avant SnackBar ✓

### Troisième lecture (deux directions)
Direction 1 (donneur → contact demandeur) : `demande.contactChiffre` → `CryptoService.dechiffrer()` → `_buildContactRow` ✓
Direction 2 (demandeur → contacts donneurs) : `_contactsDonneurs[i]['telephone']` → `_buildContactRow` ✓
Les deux directions utilisent la même implémentation ✓

### Verdict
✅ **CONFORME** — Intent `DIAL` déclaré, deux directions opérationnelles, fallback clipboard fonctionnel.

---

## Recherche transversale

### Fichiers modifiés en session 2 (13 fichiers)

| Fichier | Raison de la modification | Hors périmètre ? |
|---|---|---|
| `Makefile` | P4.1 : `WEBHOOK_SECRET` dans cible `apk` | Non ✓ |
| `README.md` | P4.1 : documentation variables env | Non ✓ |
| `android/app/build.gradle.kts` | P4.3 : `isMinifyEnabled=true` | Non ✓ |
| `android/app/proguard-rules.pro` | P4.3 : nouveau fichier ProGuard | Non ✓ |
| `android/app/src/main/AndroidManifest.xml` | P4.7 : DIAL intent | Non ✓ |
| `lib/main.dart` | P4.4 : Firebase `!kIsWeb` | Non ✓ |
| `lib/screens/detail_demande_screen.dart` | P1+P2+P4.7 | Non ✓ |
| `lib/screens/parametres_screen.dart` | P4.5 : version dynamique | Non ✓ |
| `lib/services/supabase_service.dart` | P4.2 : retry réseau | Non ✓ |
| `macos/Flutter/GeneratedPluginRegistrant.swift` | Auto-généré par `flutter pub get` (package_info_plus) | Attendu ✓ |
| `pubspec.lock` | Auto-mis à jour par `flutter pub get` | Attendu ✓ |
| `pubspec.yaml` | P4.5 : `package_info_plus: ^8.1.2` | Non ✓ |
| `supabase/functions/_shared/email.ts` | P4.6 : APP_URL | Non ✓ |

**Conclusion :** Aucune modification hors périmètre. Les 2 fichiers auto-générés (`GeneratedPluginRegistrant.swift`, `pubspec.lock`) sont des effets normaux de `flutter pub get` après ajout d'un package.

### Fichiers critiques non modifiés — diff vérifié
```
git diff bf68bcc 824383a -- lib/screens/login_screen.dart \
    lib/screens/reset_password_screen.dart \
    lib/screens/profil_screen.dart \
    lib/screens/notifications_screen.dart \
    lib/screens/nouvelle_demande_screen.dart \
    lib/screens/home_screen.dart \
    lib/screens/demandes_screen.dart \
    lib/router.dart \
    lib/services/app_state.dart
→ 0 lignes (aucune modification)
```
✅ **Zéro modification sur 9 fichiers critiques.**

---

## Vérification de non-régression globale

| Fonctionnalité | Fichier principal | Modifié en session 2 | Statut |
|---|---|---|---|
| Connexion email/mdp | `login_screen.dart` | Non | ✅ Intact |
| Inscription + création profil | `login_screen.dart` | Non | ✅ Intact |
| Réinitialisation mdp par OTP | `reset_password_screen.dart` | Non | ✅ Intact |
| Consentements | `login_screen.dart` | Non | ✅ Intact |
| Notifications | `notifications_screen.dart` | Non | ✅ Intact |
| Calcul d'éligibilité | `profil_screen.dart` + `app_state.dart` | Non | ✅ Intact |
| Liste demandes accueil (ville) | `home_screen.dart` | Non | ✅ Intact |
| Liste demandes toutes villes | `demandes_screen.dart` | Non | ✅ Intact |
| Création demande | `nouvelle_demande_screen.dart` | Non | ✅ Intact |
| Profil + suppression compte | `profil_screen.dart` | Non | ✅ Intact |
| Navigation GoRouter | `router.dart` | Non | ✅ Intact |
| AppState (état global) | `app_state.dart` | Non | ✅ Intact |

---

## Livraison finale

### Rebuild propre session 3

```
make clean-android        → ✅ Cache Android nettoyé
flutter analyze           → ✅ No issues found! (ran in 4.0s)
make apk (WEBHOOK_SECRET=SongreWebhookSecret2026!)
  → pre_build_check.sh   → ✅ android:label correct : "@string/app_name"
  → pre_build_check.sh   → ✅ app_name dans strings.xml : "Songre"
  → flutter build apk    → ✅ Built build/app/outputs/flutter-apk/app-release.apk (72.6MB)
```

### Vérification APK (aapt dump badging)

```
package: name='com.songre.app' versionCode='1' versionName='1.0.0'
application-label:'Songre'
uses-permission: INTERNET ✓
uses-permission: CAMERA ✓
uses-permission: POST_NOTIFICATIONS ✓
```

### Correctifs complémentaires de session 3
**Aucun.** Tous les 10 points d'audit étaient conformes dès la première vérification. Aucun fichier n'a été modifié lors de cette session.

### État Git final
- Commit de tête : `dfd7b6f` (rapport session 2)
- Working tree : propre
- Aucun nouveau commit à pousser

---

## Résumé exécutif

| Point | Description | Résultat |
|---|---|---|
| P1 | Bug écran blanc après « Je réponds » | ✅ CONFORME |
| P2 | Visibilité bouton Scanner (auteurId uniquement) | ✅ CONFORME |
| P3 | Logique affichage demandes (accueil/global) | ✅ CONFORME |
| P4 | WEBHOOK_SECRET Makefile + README | ✅ CONFORME |
| P5 | Retry réseau + no-duplicate | ✅ CONFORME |
| P6 | ProGuard/R8 minification + build réel | ✅ CONFORME |
| P7 | Firebase `!kIsWeb` condition | ✅ CONFORME |
| P8 | Version dynamique `package_info_plus` | ✅ CONFORME |
| P9 | APP_URL dans email.ts (6 occurrences) | ✅ CONFORME |
| P10 | Tel: links + AndroidManifest DIAL intent | ✅ CONFORME |
| Transversal | Aucune modification hors périmètre | ✅ AUCUNE |
| Non-régression | 9 fichiers critiques non modifiés | ✅ CONFIRMÉE |
| Build | APK release `com.songre.app` label `Songre` | ✅ 72.6 MB |

**Score : 10/10 points conformes, 0 correctif complémentaire, 0 régression détectée.**

---

### Observation documentée (non bloquante)

**Inconsistance d'affichage mineure dans `_buildContactRow`** : quand `CryptoService.dechiffrer()` échoue et retourne `null`, le code passe `'Contact indisponible'` comme valeur de `telephone`. Dans `_buildContactRow`, la condition `telephone != 'Contact indisponible'` force `hasPhone = false`, ce qui affiche `telephone ?? 'Non renseigné'` → donc "Contact indisponible" est bien affiché dans le `else`, mais sans l'icône de verrouillage et avec le style "Non renseigné". Comportement non idéal mais non bloquant pour l'utilisateur. Documenté en session 2 comme connue.

---

*Rapport généré par audit triple lecture — Session 3 — 2026-07-18*
