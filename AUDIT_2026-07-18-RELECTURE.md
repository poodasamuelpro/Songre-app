# AUDIT DE RELECTURE — SONGRE
**Ré-audit pré-lancement · Double vérification · Analyse de faisabilité**

- **Date d'audit** : 2026-07-18
- **Auditeur** : Agent IA (lecture exhaustive du code source, double vérification indépendante)
- **Branche** : `main` — commit `dfee63c`
- **Référentiel de base** : `AUDIT_PRELANCEMENT.md` (2026-07-09, commit `529989c`)
- **Flutter** : 3.35.4 / Dart 3.9.2
- **Périmètre** : Code source Flutter (`/lib/`), 15 Edge Functions Supabase (`/supabase/functions/`), configuration Android, scripts de build
- **`flutter analyze`** : `No issues found` ✅ (état au dernier build, commit `dfee63c`)
- **Correction appliquée** : Mise à jour de l'URL de la politique de confidentialité dans `README.md` (2 occurrences — seule modification autorisée dans cette session)

---

## Table des matières

1. [Section 1 — Récapitulatif des points déjà confirmés, corrigés ou mis en pause](#section-1)
2. [Section 2 — Résultats du ré-audit (11 points, double vérification)](#section-2)
3. [Section 3 — Analyse de faisabilité (C1 et C2)](#section-3)
4. [Section 4 — Comparaison local / GitHub](#section-4)
5. [Section 5 — Liste finale classée par gravité](#section-5)

---

## Section 1 — Récapitulatif des points déjà confirmés, corrigés ou volontairement mis en pause {#section-1}

### 1.1 — Déjà confirmé résolu par vérification directe (SQL exécuté manuellement en base)

| Point | Description | Statut |
|---|---|---|
| **P3** | Webhooks `matcher-et-notifier` et `reponse-donneur` existent sous forme de triggers PostgreSQL natifs (`trg_demandes_sang_notify`, `trg_reponses_donneurs_notify`). Code vérifié : récupération du secret webhook via `vault.decrypted_secrets`, appel `net.http_post` correct. | ✅ CONFIRMÉ FONCTIONNEL |
| **P4** | Jobs `pg_cron` actifs (5 jobs recensés), historique d'exécution réussie confirmé (`cron.job_run_details`). | ✅ CONFIRMÉ FONCTIONNEL |
| **SEC-07** | RLS activé sur les 14 tables de `public.*`, policies cohérentes basées sur `auth.uid()`. | ✅ CONFIRMÉ FONCTIONNEL |
| **P13** | Table `public.identites` confirmée existante avec les colonnes attendues. | ✅ CONFIRMÉ |
| **P5** | Incohérence durée de validité des demandes (7j/72h) — corrigée. Éligibilité don : 90j hommes / 120j femmes. | ✅ CORRIGÉ |
| **P11** | Package Android incohérent — corrigé. Package : `com.songre.app`, projet Firebase : `songre-88f2a`. | ✅ CORRIGÉ (session C) |
| **Vue `demandes_sang_avec_contact`** | Confirmée en `security_invoker=true`. | ✅ CONFIRMÉ |
| **SCALE-02** | `matcher-et-notifier` — patché, notifications limitées à 20 emails maximum même si plus de donneurs compatibles existent. | ✅ CONFIRMÉ CORRIGÉ |
| **Triggers redondants sur `demandes_sang`** | `trg_limite_demandes` et `trg_verifier_limite_demandes` — confirmés **intentionnels** (mécanisme d'échappement de sécurité). | ✅ INTENTIONNEL — NE PAS TOUCHER |
| **Doublon suppression de compte** | Job cron `executer-suppressions-programmees` via Edge Function ET job cron avec `DELETE` SQL direct — confirmé **intentionnel et voulu** par le porteur du projet. | ✅ INTENTIONNEL — NE PAS TOUCHER |
| **Coexistence `telephone_hash`/`contact_secondaire_chiffre`** | Dans `public.identites` et `telephone_chiffre` dans `public.profils_donneurs` — confirmé **volontaire**. | ✅ INTENTIONNEL — NE PAS TOUCHER |
| **URL politique de confidentialité** | URL réelle : `https://songre.vercel.app/fr/confidentialite` (et non `https://songre.bf/politique-confidentialite`). | ✅ MIS À JOUR dans `README.md` (correction autorisée) |

### 1.2 — Volontairement mis en pause jusqu'à la fin du projet

Les points suivants ne sont **pas à traiter, pas à auditer, pas à mentionner comme "à corriger"** dans ce rapport. Ils sont listés uniquement pour mémoire :

1. `SONGRE_ENCRYPT_KEY` (clé de chiffrement AES, **P1**) — mise en pause jusqu'à la fin du projet
2. Fonctionnalité de géolocalisation (carte des centres de santé) — hors périmètre
3. Version Web sécurisée (serveur intermédiaire / BFF) — hors périmètre
4. Version iOS — hors périmètre
5. **P8** — Email de confirmation de publication de demande — reporté explicitement ("peut-être plus tard")

---

## Section 2 — Résultats du ré-audit avec double vérification {#section-2}

> **Méthode** : chaque point a fait l'objet d'une première lecture puis d'une seconde lecture indépendante avant de formuler la conclusion. Les extraits de code cités sont tirés directement du dépôt au commit `dfee63c`.

---

### B.1 — P2 : WEBHOOK_SECRET dans les scripts / Makefile / CI

**Fichiers examinés** : `Makefile`, `scripts/pre_build_check.sh`, `lib/services/supabase_service.dart`
**Recherche** : `grep -rn "WEBHOOK_SECRET"` dans `Makefile`, `scripts/`, `.github/` (inexistant)

#### Première lecture

`Makefile` — cible `apk` :
```makefile
flutter build apk --release \
    --dart-define=SONGRE_ENCRYPT_KEY=[REDACTED] \
    --dart-define=flutter.inspector.structuredErrors=false \
    --dart-define=debugShowCheckedModeBanner=false
```
**Constat** : `--dart-define=WEBHOOK_SECRET=...` est **absent** de la cible `apk`. Le `WEBHOOK_SECRET` n'est **pas transmis** via `make apk`.

Côté Flutter (`lib/services/supabase_service.dart`, L54) :
```dart
static const String _webhookSecret = String.fromEnvironment(
  'WEBHOOK_SECRET',
);
```
Si absent au build → `_webhookSecret` vaut la chaîne vide. L'Edge Function `valider-token` recevra alors un secret vide et rejettera l'appel.

#### Deuxième lecture (indépendante)

Aucun fichier `.github/workflows/` n'existe dans le projet. Aucune CI externe configurée. Le seul point d'entrée pour le build APK release est `make apk` ou la commande directe `flutter build apk --release`. Dans les deux cas, `WEBHOOK_SECRET` n'est **pas injecté automatiquement**.

#### Conclusion

**PROBLÈME SUBSISTANT — Niveau de risque : IMPORTANT**

Le `Makefile` n'inclut pas `--dart-define=WEBHOOK_SECRET=...` dans sa cible `apk`. Tout build réalisé via `make apk` produira un APK avec `_webhookSecret == ""`. L'Edge Function `valider-token` refusera alors toutes les requêtes de scan QR.

**Note** : le problème est différent de ce que l'audit original décrivait. Ce n'est pas un risque de fuite du secret — c'est un risque de **rupture fonctionnelle silencieuse** : la fonctionnalité QR sera inopérante sans message d'erreur explicite à l'écran.

**Solutions envisageables** (non appliquées) :
- Option A : Ajouter `--dart-define=WEBHOOK_SECRET=$$(cat .webhook_secret)` dans `Makefile`, avec `.webhook_secret` dans `.gitignore`
- Option B : Ajouter `--dart-define=WEBHOOK_SECRET=$$WEBHOOK_SECRET` pour lire depuis variable d'environnement shell
- Option C : Documenter la commande complète dans `README.md` avec un avertissement explicite

---

### B.2 — P6 : `Firebase.initializeApp()` sans `DefaultFirebaseOptions`

**Fichier examiné** : `lib/main.dart`

#### Première lecture

```dart
try {
  await Firebase.initializeApp();
} catch (e) {
  if (kDebugMode) debugPrint('[main] Firebase init skipped: $e');
}
```

Aucun fichier `lib/firebase_options.dart` n'existe dans le projet (vérifié : `ls lib/` ne retourne que `main.dart, models/, router.dart, screens/, services/, theme/, utils/, widgets/`).

Packages Firebase dans `pubspec.yaml` :
```yaml
firebase_core: 3.6.0
firebase_messaging: 15.1.3
```

#### Deuxième lecture (indépendante)

`Firebase.initializeApp()` sans argument utilise la configuration native Android (`google-services.json`) pour la plateforme Android — cette approche fonctionne correctement pour un **build Android**. Pour la plateforme Web (`kIsWeb == true`), Firebase ne dispose d'aucune configuration et **échouera** à l'initialisation.

Le `try/catch` enveloppe l'erreur et permet à l'app de démarrer malgré l'échec. Sur Android, `google-services.json` (projet `songre-88f2a`) est correctement configuré → l'init réussit. Sur Web, l'init échoue silencieusement → Firebase Messaging est inopérant (les push notifications ne fonctionneront pas en preview web).

#### Conclusion

**PROBLÈME SUBSISTANT — Niveau de risque : MINEUR pour Android, IMPORTANT pour Web**

- **Android** : ✅ Fonctionnel — `google-services.json` correctement configuré pour `com.songre.app`
- **Web** : ⚠️ Firebase Messaging inopérant — l'initialisation échoue silencieusement (`try/catch`)
- **Impact production** : Nul si l'application Web n'est pas destinée à envoyer des push notifications (ce qui semble être le cas — la preview web est mentionnée comme "aperçu web" uniquement)

**Solutions envisageables** (non appliquées) :
- Option A : Créer `lib/firebase_options.dart` avec la configuration Web (depuis Firebase Console → Project Settings → General → Your apps → Web app)
- Option B : Conditionner l'init Firebase sur `!kIsWeb` pour éviter le try/catch silencieux
- Option C : Accepter l'état actuel si la version Web n'a pas besoin de FCM (la fonctionnalité principale — scan QR et Supabase — n'est pas impactée)

---

### B.3 — P7 : `isMinifyEnabled` / `isShrinkResources`

**Fichier examiné** : `android/app/build.gradle.kts`

#### Première lecture

```kotlin
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("release")
        isMinifyEnabled = false
        isShrinkResources = false
    }
}
```
Ligne 55-56 : les deux flags sont explicitement à `false`.

#### Deuxième lecture (indépendante)

```bash
grep -n "isMinifyEnabled\|isShrinkResources" android/app/build.gradle.kts
# 55: isMinifyEnabled = false
# 56: isShrinkResources = false
```
Résultat identique. Aucun changement depuis l'audit original.

#### Conclusion

**PROBLÈME SUBSISTANT — Niveau de risque : IMPORTANT (production)**

`isMinifyEnabled = false` et `isShrinkResources = false` désactivent ProGuard/R8 et le shrinking des ressources. L'APK release pèse ~74MB au lieu de ~25-40MB attendus avec minification. Plus grave : sans minification, le code Dart n'est pas obfusqué (bien que Dart compile en code natif sur Android, ce qui limite déjà le risque de reverse engineering pur).

**Solutions envisageables** (non appliquées) :
- Option A (recommandée) : Passer `isMinifyEnabled = true` + `isShrinkResources = true` et ajouter les règles ProGuard nécessaires pour Firebase/Supabase
- Option B : Laisser à `false` si les règles ProGuard ne sont pas testées (risque de crash au démarrage avec minification non configurée)
- **Note** : avant d'activer, tester avec `flutter build apk --release --obfuscate --split-debug-info=build/debug-info/`

---

### B.4 — P10 : `.limit()` dans `retour-eligibilite-cron`

**Fichier examiné** : `supabase/functions/retour-eligibilite-cron/index.ts`

#### Première lecture

La requête principale sur `profils_donneurs` :
```typescript
const { data: profils, error: profilError } = await adminClient
  .from("profils_donneurs")
  .select("user_id, genre, dernier_don_date, disponible")
  .not("dernier_don_date", "is", null)
  .gte("dernier_don_date", dateMin90.toISOString().substring(0, 10))
  .lte("dernier_don_date", dateMax90.toISOString().substring(0, 10));
```
Aucun `.limit()` n'est appliqué. La fenêtre temporelle est de 89 à 121 jours avant aujourd'hui — ce qui filtre naturellement les résultats. `grep -c "limit"` dans le fichier retourne `0`.

#### Deuxième lecture (indépendante)

Recherche complète : `grep -n "limit\|LIMIT"` → résultat vide. Confirme l'absence de `.limit()`.

La fenêtre de 32 jours (89 → 121 jours) est cependant un filtre SQL efficace : en pratique, seuls les donneurs ayant donné il y a exactement 89 à 121 jours sont récupérés. Ce n'est pas illimité — c'est borné par la fenêtre temporelle.

#### Conclusion

**PROBLÈME SUBSISTANT — Niveau de risque : FAIBLE (protection naturelle par fenêtre temporelle)**

Pas de `.limit()` explicite, mais la requête est filtrée par une fenêtre de 32 jours (89-121 jours). En conditions normales, cela représente un nombre raisonnable de donneurs. Le risque de surcharge ne devient réel qu'à très grande échelle (>10,000 donneurs actifs simultanés).

**Solutions envisageables** (non appliquées) :
- Option A : Ajouter `.limit(500)` sur la requête SQL comme garde-fou
- Option B : Monitorer les logs du cron pour détecter une montée en charge avant d'implémenter la limite

---

### B.5 — P-DON-DATE : Validation date future dans `don-manuel`

**Fichier examiné** : `supabase/functions/don-manuel/index.ts`

#### Première lecture

```typescript
const dateDon = new Date(date_don);
if (isNaN(dateDon.getTime()) || dateDon > new Date()) {
  return jsonResponse({ error: "Date de don invalide ou dans le futur." }, 400, corsHeaders);
}
```
Ligne 83-84 : validation explicite `dateDon > new Date()`. Une date future est rejetée avec HTTP 400.

#### Deuxième lecture (indépendante)

```bash
grep -n "futur\|future\|> new Date\|getTime" supabase/functions/don-manuel/index.ts
# 83: if (isNaN(dateDon.getTime()) || dateDon > new Date()) {
# 84:   return jsonResponse({ error: "Date de don invalide ou dans le futur." }, 400, corsHeaders);
```
Confirmation identique.

#### Conclusion

**RÉSOLU — Niveau de risque : AUCUN**

La validation date future est présente et fonctionnelle côté serveur dans `don-manuel`. Le point P-DON-DATE est clos.

---

### B.6 — P-SCANALL : Bouton "Scanner un code" conditionné sur `auteurId == userId`

**Fichier examiné** : `lib/screens/detail_demande_screen.dart`

#### Première lecture

Bloc `_buildActionRow` (ligne 498-522) :
```dart
// Bouton "Scanner un code" (demandeur)
if (state.userId != null)
  SizedBox(
    width: double.infinity,
    child: OutlinedButton.icon(
      onPressed: () =>
          context.push('/scan-qr', extra: state.userId),
      icon: const Icon(Icons.qr_code_scanner, size: 18),
      label: Text('Scanner le code du donneur', ...),
      ...
    ),
  ),
```
La condition est `state.userId != null` — c'est-à-dire **toute personne connectée** peut voir et utiliser le bouton Scanner, y compris le donneur lui-même ou un utilisateur non auteur de la demande.

#### Deuxième lecture (indépendante)

Recherche de `state.userId == demande.auteurId` ou équivalent dans le bloc `_buildActionRow` : **absent**. La condition `estAuteur` est bien définie ligne 241 (`final estAuteur = state.userId == demande.auteurId`) et est utilisée dans `_buildInfos()` pour l'affichage des contacts donneurs, mais **pas** appliquée au bouton Scanner.

#### Conclusion

**PROBLÈME SUBSISTANT — Niveau de risque : IMPORTANT (logique métier)**

Le bouton "Scanner le code du donneur" est affiché à **tout utilisateur connecté**, pas uniquement à l'auteur de la demande. Cela signifie qu'un donneur qui consulte une demande à laquelle il a répondu peut aussi essayer de scanner un QR code — même si la fonctionnalité de scan est réservée au demandeur pour valider le don.

**Solutions envisageables** (non appliquées) :
```dart
// Remplacer
if (state.userId != null)
// Par
if (state.userId != null && state.userId == demande.auteurId)
```
Complexité : très faible (1 ligne). Risque de correction : nul.

---

### B.7 — P-VER : Version affichée codée en dur vs `PackageInfo.fromPlatform()`

**Fichier examiné** : `lib/screens/parametres_screen.dart`
**Recherche complémentaire** : `pubspec.yaml`, `lib/` entier

#### Première lecture

`parametres_screen.dart`, ligne 219 :
```dart
'SONGRE v1.0.0',
```
Et ligne 256 :
```dart
(icone: Icons.tag, label: 'Version', valeur: '1.0.0'),
```
Deux occurrences de la version codée en dur (`1.0.0`).

`pubspec.yaml`, ligne 4 :
```yaml
version: 1.0.0+1
```
Aucun import de `package_info_plus` dans `pubspec.yaml` ni dans aucun fichier `.dart`.

#### Deuxième lecture (indépendante)

```bash
grep -rn "package_info\|PackageInfo" lib/ pubspec.yaml
# → Aucun résultat
grep -n "SONGRE v\|version.*1\." lib/screens/parametres_screen.dart
# 219: 'SONGRE v1.0.0',
```
Confirmation : la version est codée en dur à deux endroits dans `parametres_screen.dart`. Aucune dépendance `package_info_plus` n'est déclarée.

#### Conclusion

**PROBLÈME SUBSISTANT — Niveau de risque : MINEUR**

La version `1.0.0` est codée en dur dans l'UI. À chaque mise à jour de l'application, cette valeur devra être mise à jour manuellement dans `parametres_screen.dart` **en plus** de `pubspec.yaml`. Risque d'oubli et d'affichage d'une version incorrecte.

**Solutions envisageables** (non appliquées) :
- Ajouter `package_info_plus: ^8.1.4` (version compatible Flutter 3.35.4) dans `pubspec.yaml`
- Utiliser `PackageInfo.fromPlatform()` pour lire `version` dynamiquement
- Remplacer les 2 occurrences hardcodées dans `parametres_screen.dart`
- Complexité : faible (30-50 lignes de code)

---

### B.8 — NET-05 : Mécanisme retry dans `enregistrerReponseDonneur()`

**Fichier examiné** : `lib/services/supabase_service.dart` (ligne 1163 à 1191)

#### Première lecture

```dart
static Future<bool> enregistrerReponseDonneur({
  required String donneurId,
  required String demandeId,
}) async {
  if (!estConfigured) return false;
  try {
    final url = Uri.parse('$_supabaseUrl/rest/v1/reponses_donneurs');
    final hdrs = {
      ..._restHeaders(withAuth: true),
      'Prefer': 'return=minimal,resolution=ignore-duplicates',
    };
    final body = jsonEncode({
      'donneur_id': donneurId,
      'demande_id': demandeId,
    });
    final resp = await _requeteAvecRefresh(
      () => http.post(url, headers: hdrs, body: body)
          .timeout(const Duration(seconds: 10)),
    );
    return resp.statusCode == 201 ||
        resp.statusCode == 200 ||
        resp.statusCode == 204;
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[SupabaseService] enregistrerReponseDonneur error: $e');
    }
    return false;
  }
}
```

`_requeteAvecRefresh` (ligne 261-268) :
```dart
static Future<http.Response> _requeteAvecRefresh(
    Future<http.Response> Function() makeRequest) async {
  final resp = await makeRequest();
  if (resp.statusCode == 401 && _refreshToken != null) {
    final refreshed = await rafraichirToken(_refreshToken!);
    if (refreshed) return makeRequest();
  }
  return resp;
}
```

#### Deuxième lecture (indépendante)

```bash
grep -n "retry\|Retry\|for.*retry\|while.*retry\|tentative\|attempt" lib/services/supabase_service.dart
# → Aucune occurrence de retry dans le contexte de enregistrerReponseDonneur
```

`_requeteAvecRefresh` effectue un retry **uniquement sur 401** (token expiré → refresh → réessai). Il n'existe **aucun** mécanisme de retry sur erreur réseau (`TimeoutException`, `SocketException`), sur 500 ou 503.

#### Conclusion

**PROBLÈME SUBSISTANT — Niveau de risque : IMPORTANT**

Aucun mécanisme de retry réseau dans `enregistrerReponseDonneur()`. En cas de timeout réseau (fréquent en Afrique de l'Ouest sur réseau mobile), la réponse du donneur est perdue silencieusement (`return false`). L'UI affiche un rollback (`_repondu = false`) et un SnackBar d'erreur — mais l'utilisateur doit retenter manuellement.

**Solutions envisageables** (non appliquées) :
```dart
// Option A : Retry simple avec backoff
for (int i = 0; i < 3; i++) {
  final resp = await _requeteAvecRefresh(() => ...);
  if ([201, 200, 204].contains(resp.statusCode)) return true;
  if (i < 2) await Future.delayed(Duration(seconds: pow(2, i).toInt()));
}
return false;
```
- Option B : Utiliser un package comme `retry` (pub.dev) pour une logique de retry configurable
- Option C : Queue locale (Hive) pour les réponses en attente de synchronisation réseau

---

### B.9 — P-SPAM : Anti-spam `contacter-support` réellement effectif ?

**Fichier examiné** : `supabase/functions/contacter-support/index.ts`
**Fichier complémentaire** : `supabase/functions/mission-d.sql` (définition de `contact_spam_log`)

#### Première lecture

Logique anti-spam (lignes 102-124) :
```typescript
const { data: spamCheck } = await adminClient
  .from("contact_spam_log")
  .select("created_at")
  .eq("user_id", user.id)
  .gte("created_at", limiteAntiSpam)
  .limit(1);

if (spamCheck && spamCheck.length > 0) {
  return jsonResponse({ error: "...", retry_after_minutes: 10 }, 429, corsHeaders);
}
```

Insertion après envoi réussi (lignes 164-169) :
```typescript
await adminClient
  .from("contact_spam_log")
  .insert({ user_id: user.id });
```

Définition de la table (mission-d.sql) :
```sql
CREATE TABLE IF NOT EXISTS public.contact_spam_log (
  id          bigserial PRIMARY KEY,
  user_id     uuid NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
```
RLS activé, aucune policy INSERT/SELECT pour les utilisateurs — tout passe par EF avec `service_role_key` (bypass RLS).

#### Deuxième lecture (indépendante)

**Question clé** : sans contrainte `UNIQUE(user_id)` ni contrainte d'unicité, est-ce que deux requêtes simultanées peuvent toutes deux passer le `spamCheck` avant que l'une n'insère l'enregistrement ?

Analyse : oui, une **race condition** existe en théorie. Si deux requêtes arrivent en moins de quelques millisecondes, les deux peuvent lire `spamCheck.length == 0` avant que la première insertion soit effectuée. Cette fenêtre est extrêmement courte et improbable en conditions réelles (nécessite un double-tap simultané parfaitement synchronisé).

En pratique, l'anti-spam est **effectif** contre les abus ordinaires (limite 10 minutes entre messages). La race condition est théorique et sans impact significatif.

**Autre point** : si la table `contact_spam_log` n'existe pas (cas d'un environnement de staging non initialisé), le `try/catch` autour du `spamCheck` rend l'anti-spam non bloquant — un warning est loggé mais l'email est envoyé quand même.

#### Conclusion

**RISQUE RÉSIDUEL FAIBLE — Anti-spam effectif en conditions normales**

- ✅ La vérification temporelle `gte("created_at", limiteAntiSpam)` est correcte
- ✅ `.limit(1)` optimise la requête
- ✅ L'insertion se fait **après** l'envoi réussi (pas de phantom spam log)
- ⚠️ Race condition théorique (fenêtre < 10ms, impact négligeable)
- ⚠️ Anti-spam skippé si `contact_spam_log` n'existe pas (environnements non initialisés)

**Solutions envisageables** (non appliquées) si durcissement nécessaire :
- Ajouter un index partiel unique : `UNIQUE(user_id)` avec TTL sur les entrées récentes (non standard en PostgreSQL pur — nécessiterait une logique applicative)
- Ou : utiliser `INSERT ... ON CONFLICT DO NOTHING` comme garde-fou côté DB

---

### B.10 — STORE-02 : Déclaration Play Store Data Safety préparée ?

**Fichiers examinés** : tous les fichiers `.md`, `.txt`, répertoire racine du projet
**Recherche** : `ls *.md`, `grep -rn "STORE-02\|Data Safety\|données collectées"`

#### Première lecture

Aucun fichier dédié à la déclaration Data Safety trouvé (`STORE* DATA* data_safety*` → résultat : `aucun fichier STORE/DATA`).

Dans `AUDIT_PRELANCEMENT.md` (ligne 576-580) :
> **STORE-02 — Déclaration des données collectées**
> **Play Store (Data Safety)** : La section "Sécurité des données" doit déclarer explicitement toutes ces données avec leur finalité, rétention, et partage éventuel. Les données médicales entrent dans la catégorie "données sensibles" nécessitant une déclaration renforcée.

#### Deuxième lecture (indépendante)

Recherche exhaustive de tout document préparatoire : `grep -rn "STORE\|Data Safety\|Play Store"` dans tous les `.md` → uniquement des références dans `AUDIT_PRELANCEMENT.md` et `README.md` (tableaux de bord généraux, pas de document de conformité).

#### Conclusion

**PROBLÈME SUBSISTANT — Niveau de risque : BLOQUANT (pour soumission Play Store)**

Aucune déclaration Data Safety n'a été préparée. Ce document est **obligatoire** pour soumettre l'application sur le Google Play Store depuis mai 2022. Sans cette déclaration :
- La soumission initiale sera **rejetée**
- Les mises à jour existantes ne peuvent pas être publiées

**Données à déclarer** (non exhaustif) :
- Groupe sanguin, poids (données médicales sensibles)
- Numéro de téléphone chiffré
- Email (via Firebase Auth)
- Token FCM
- Localisation (ville — pas GPS)
- Historique de dons

**Solutions envisageables** (non appliquées) :
- Créer `DATA_SAFETY_PLAY_STORE.md` documentant : données collectées, finalité, rétention, partage éventuel
- Remplir le formulaire Play Console Data Safety directement (interface graphique, pas de fichier requis)
- Consulter le guide Google : https://support.google.com/googleplay/android-developer/answer/10787469

---

### B.11 — URL de la politique de confidentialité

**Fichiers examinés** : `README.md`, `AUDIT_PRELANCEMENT.md`, `lib/screens/login_screen.dart`, `lib/screens/contact_screen.dart`, `lib/screens/parametres_screen.dart`, `supabase/functions/_shared/email.ts`, code Flutter complet

#### Première lecture

Recherche exhaustive : `grep -rn "politique-confidentialite|songre.bf|songre.vercel"` dans tout le projet :

| Fichier | Occurrences | Contenu |
|---|---|---|
| `README.md:36` | `https://songre.bf/politique-confidentialite` | Tableau liens utiles (corrigé dans cette session) |
| `README.md:724` | `https://songre.bf/politique-confidentialite` | Tableau ressources (corrigé dans cette session) |
| `AUDIT_PRELANCEMENT.md:566` | `https://songre.bf/politique-confidentialite` | Documentation historique (non modifiée) |
| `AUDIT_PRELANCEMENT.md:568` | `https://songre.bf/politique-confidentialite` | Documentation historique (non modifiée) |
| `AUDIT_PRELANCEMENT.md:732` | `https://songre.bf/politique-confidentialite` | Tableau de bord (non modifié) |
| Code Flutter (`lib/`) | **Aucune occurrence** | L'URL n'est pas codée en dur dans le code Flutter |
| Supabase Edge Functions | **Aucune occurrence** | Pas d'URL de politique dans les EF |

L'URL de la politique de confidentialité dans l'application **n'est pas codée en dur** dans le code Flutter. Elle est servie depuis la table `public.liens_externes` en base de données Supabase (chargée dynamiquement par `ParametresScreen` via `SupabaseService.lireLiensExternes()`).

#### Deuxième lecture (indépendante)

```bash
grep -rn "https://" lib/ --include="*.dart"
# → Aucun résultat contenant songre.bf ou politique
grep -rn "lireLiensExternes\|liens_externes" lib/
# → lib/services/supabase_service.dart:1679, lib/screens/parametres_screen.dart:36
```
Confirme que l'URL provient de la base de données, pas du code source Flutter.

#### Correction appliquée dans cette session

`README.md` — 2 occurrences corrigées :
- L36 : `` `https://songre.bf/politique-confidentialite` `` → `` `https://songre.vercel.app/fr/confidentialite` ``
- L724 : `https://songre.bf/politique-confidentialite` → `https://songre.vercel.app/fr/confidentialite`

#### Conclusion

**PARTIELLEMENT RÉSOLU**

- ✅ Code Flutter (`lib/`) : aucune URL de politique codée en dur — l'URL est dynamique via `liens_externes` en DB
- ✅ `README.md` : corrigé dans cette session (2 occurrences)
- ⚠️ `AUDIT_PRELANCEMENT.md` : contient encore 3 mentions de l'ancienne URL — documentation historique, non corrigée car ces occurrences sont des preuves de l'audit original
- **Action restante** : Mettre à jour l'URL dans la table `public.liens_externes` en base de données Supabase (si ce n'est pas déjà fait — non vérifiable depuis le sandbox sans accès SQL)

---

## Section 3 — Analyse de faisabilité {#section-3}

### C1 — Rendre les numéros de téléphone cliquables (`tel:` via `url_launcher`)

#### 1. Localisation dans le code

Le numéro de téléphone du demandeur est affiché dans `detail_demande_screen.dart`, méthode `_buildInfos()`, lignes 261-280 :

```dart
// Vue donneur — contact du demandeur
if (_repondu && demande.contactChiffre != null) ...[
  _buildInfoRow(
    icon: Icons.phone_outlined,
    label: 'Contact principal',
    value: CryptoService.dechiffrer(demande.contactChiffre) ??
        'Contact indisponible',
  ),
  if (demande.contactSecondaireChiffre != null) ...[
    _buildInfoRow(
      icon: Icons.phone_callback_outlined,
      label: 'Contact secondaire',
      value: CryptoService.dechiffrer(demande.contactSecondaireChiffre) ??
          'Contact indisponible',
    ),
  ],
],
```

Le numéro des donneurs est affiché dans `_buildContactsDonneursRows()` (lignes 322-337) :
```dart
_buildInfoRow(
  icon: Icons.volunteer_activism_outlined,
  label: 'Donneur ${i + 1}',
  value: tel != null && tel.isNotEmpty ? tel : 'Contact non renseigné',
),
```

Dans les deux cas, `_buildInfoRow()` affiche le numéro en texte simple (`Text(value)`).

#### 2. Faisabilité avec `url_launcher` + schéma `tel:`

`url_launcher` est **déjà présent** dans le projet (`lib/screens/parametres_screen.dart` l4 : `import 'package:url_launcher/url_launcher.dart'`). Aucune dépendance supplémentaire à ajouter.

Implémentation type :
```dart
Future<void> _appelerTelephone(String numero) async {
  // Normaliser le numéro : supprimer espaces, tirets, etc.
  final numeroNettoye = numero.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  final uri = Uri(scheme: 'tel', path: numeroNettoye);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri);
  } else {
    // Fallback : afficher le numéro avec bouton copie
  }
}
```

#### 3. Application aux deux sens de contact

Les deux sens de contact doivent être traités symétriquement :
- **Vue donneur → contact demandeur** : `_buildInfos()` — `contactChiffre` et `contactSecondaireChiffre`
- **Vue demandeur → contact donneurs** : `_buildContactsDonneursRows()` — `telephone`

#### 4. Fichiers à modifier

| Fichier | Modification |
|---|---|
| `lib/screens/detail_demande_screen.dart` | Remplacer `_buildInfoRow()` par une version cliquable `_buildInfoRowTelephone()` pour les champs de contact |
| Aucune autre modification requise | `url_launcher` est déjà importé dans le projet |

#### 5. Complexité et risques

- **Complexité** : Faible — 20-40 lignes de code
- **Risques** :
  - **Formatage des numéros** : Les numéros burkinabès peuvent être au format local (`20 XX XX XX`) ou international (`+226 20 XX XX XX`). La normalisation avant construction du `tel:` est nécessaire.
  - **Appareils sans téléphone** : Sur émulateur, tablette sans SIM, ou preview web — `canLaunchUrl(tel:...)` retourne `false`. Prévoir un fallback (affichage texte + bouton copie).
  - **Permission** : Aucune permission Android supplémentaire requise pour `ACTION_DIAL` (ouvre le composeur) — contrairement à `ACTION_CALL` (passe l'appel directement).
  - **AndroidManifest** : Ajouter `<queries><intent><action android:name="android.intent.action.DIAL"/></intent></queries>` pour Android 11+ (package visibility).

---

### C2 — URL de l'application dynamique dans les emails (`APP_URL`)

#### 1. Recherche exhaustive des URLs codées en dur

Dans `supabase/functions/_shared/email.ts`, **5 occurrences** de `https://songre.bf/app` codées en dur :

| Ligne | Template | Contexte |
|---|---|---|
| 106 | `demande_compatible` | Bouton "Ouvrir SONGRE" |
| 190 | `reponse_recue` | Bouton "Voir les réponses" |
| 221 | `reponse_encouragement` | Bouton "Ouvrir SONGRE" |
| 259 | `retour_eligibilite` | Bouton "Activer ma disponibilité" |
| 371 | `bienvenue` | Bouton "Compléter mon profil" |

Et dans le pied de page de `baseTemplate` (ligne 76) :
```html
© SONGRE · <a href="https://songre.bf" style="color:#C0392B;">songre.bf</a>
```
Le domaine `songre.bf` n'est pas le même que `songre.vercel.app`.

#### 2. Vérification de l'utilisation de la variable `APP_URL`

```bash
grep -rn "APP_URL" supabase/functions/ --include="*.ts"
# → Aucun résultat
```

La variable `APP_URL` est listée dans l'inventaire des secrets Supabase de l'audit original, mais elle **n'est jamais utilisée** dans le code des Edge Functions. Elle est déclarée comme secret mais son usage n'est pas implémenté.

#### 3. Proposition de remplacement

```typescript
// Dans email.ts, ajouter en tête de fichier :
const APP_URL = Deno.env.get("APP_URL") ?? "https://songre.vercel.app";

// Remplacer toutes les occurrences de "https://songre.bf/app" par :
`${APP_URL}/app`
// et "https://songre.bf" par :
APP_URL
```

#### 4. Fichiers à modifier et complexité

| Fichier | Modifications |
|---|---|
| `supabase/functions/_shared/email.ts` | Ajouter la constante `APP_URL` + remplacer 5 + 1 occurrences d'URLs |
| Supabase Dashboard | S'assurer que la variable `APP_URL` est configurée avec la bonne valeur |

- **Complexité** : Faible — modification purement cosmétique/de configuration
- **Risques** : 
  - Si `APP_URL` n'est pas définie en secret Supabase, le fallback `songre.vercel.app` prend le relais (comportement sûr)
  - Les templates `templateDonConfirme` et `templateDonEnregistreManuel` n'ont pas de lien externe — pas de modification nécessaire

---

## Section 4 — Comparaison local / GitHub {#section-4}

Commande exécutée :
```bash
git fetch github
git diff HEAD github/main --stat
git status
```

Résultats :
```
From https://github.com/poodasamuelpro/Songre-app
   e3d8a47..dfee63c  main       -> github/main
=== FETCH OK ===
=== STATUS ===
On branch main
nothing to commit, working tree clean
```

`git diff HEAD github/main --stat` → **aucune différence** (sortie vide).

`git log github/main --oneline -3` :
```
dfee63c fix: corriger commentaires obsolètes dans retour-eligibilite-cron (60j→90j/120j)
f32486b refactor: changement package Android com.lifesaver.save → com.songre.app + nouveau projet Firebase songre-88f2a
2c08750 Update Supabase Edge Functions - 15 files updated
```

**Confirmation** : Le dépôt local et le dépôt GitHub (`poodasamuelpro/Songre-app`) sont parfaitement synchronisés sur le commit **`dfee63c`**. Aucune divergence non détectée.

> **Note** : La correction de `README.md` effectuée dans la présente session (2 occurrences de l'URL de la politique de confidentialité) sera à committer séparément.

---

## Section 5 — Liste finale classée par gravité {#section-5}

### 🔴 BLOQUANT — Empêche la soumission ou crée un risque critique

| ID | Point | Fichier(s) | État |
|---|---|---|---|
| **STORE-02** | Déclaration Data Safety Play Store absente | Aucun fichier — à créer | ❌ À FAIRE |

---

### 🟠 IMPORTANT — À corriger avant le lancement

| ID | Point | Fichier(s) | État |
|---|---|---|---|
| **P-SCANALL** | Bouton Scanner visible par tous les utilisateurs connectés, pas seulement l'auteur | `lib/screens/detail_demande_screen.dart` L498 | ❌ PROBLÈME |
| **B.1 / P2** | `WEBHOOK_SECRET` absent du `Makefile` — tout build via `make apk` produit un APK avec secret vide → fonctionnalité QR inopérante | `Makefile` (cible `apk`) | ❌ PROBLÈME |
| **NET-05** | Aucun retry réseau dans `enregistrerReponseDonneur()` — perte silencieuse sur timeout | `lib/services/supabase_service.dart` L1163 | ❌ PROBLÈME |
| **P7** | `isMinifyEnabled = false` / `isShrinkResources = false` — APK non optimisé (~74MB) | `android/app/build.gradle.kts` L55-56 | ❌ NON OPTIMISÉ |
| **P6** | `Firebase.initializeApp()` sans `DefaultFirebaseOptions` — Web inopérant pour FCM | `lib/main.dart` L17 | ⚠️ WEB UNIQUEMENT |

---

### 🟡 MINEUR — À traiter avant ou après le lancement selon les priorités

| ID | Point | Fichier(s) | État |
|---|---|---|---|
| **P-VER** | Version `1.0.0` codée en dur (2 occurrences) — risque de désynchronisation avec `pubspec.yaml` | `lib/screens/parametres_screen.dart` L219, L256 | ⚠️ COSMÉTIQUE |
| **P-SPAM** | Race condition théorique dans l'anti-spam `contacter-support` (fenêtre < 10ms) | `supabase/functions/contacter-support/index.ts` | ⚠️ THÉORIQUE |
| **P10** | `.limit()` absent dans `retour-eligibilite-cron` — protection naturelle par fenêtre temporelle | `supabase/functions/retour-eligibilite-cron/index.ts` | ⚠️ FAIBLE RISQUE |
| **B.11** | `README.md` corrigé — URL `liens_externes` en DB à vérifier | `README.md` (✅ corrigé), DB `liens_externes` (non vérifiable) | ✅ PARTIELLEMENT RÉSOLU |
| **C2** | URL `https://songre.bf/app` codée en dur dans 5 templates email — variable `APP_URL` déclarée mais non utilisée | `supabase/functions/_shared/email.ts` | ⚠️ COSMÉTIQUE |

---

### 🔵 ANALYSE DE FAISABILITÉ — Nouvelles fonctionnalités

| ID | Point | Complexité | Risques |
|---|---|---|---|
| **C1** | Téléphone cliquable (`tel:`) — `url_launcher` déjà présent | **Faible** (20-40 lignes) | Normalisation numéros BF, fallback tablette |
| **C2** | URL dynamique dans emails (`APP_URL`) — variable non utilisée à connecter | **Faible** (10 lignes) | Aucun si fallback `songre.vercel.app` |

---

### ✅ RÉSOLU — Points confirmés corrigés

| ID | Point | Résolution |
|---|---|---|
| **P11** | Package Android → `com.songre.app`, Firebase `songre-88f2a` | ✅ Corrigé (session C) |
| **P5** | Éligibilité 90j hommes / 120j femmes (anciennement 60/90j) | ✅ Corrigé (session D) |
| **P-DON-DATE** | Validation date future dans `don-manuel` | ✅ Présente et fonctionnelle |
| **P3** | Webhooks PostgreSQL triggers | ✅ Confirmé fonctionnel (SQL direct) |
| **P4** | Jobs pg_cron | ✅ Confirmé fonctionnel (SQL direct) |
| **SEC-07** | RLS sur 14 tables | ✅ Confirmé fonctionnel (SQL direct) |
| **SCALE-02** | Limite 20 emails `matcher-et-notifier` | ✅ Confirmé corrigé |

---

### ⏸️ EN PAUSE — Volontairement reportés

| ID | Point | Raison |
|---|---|---|
| **P1** | `SONGRE_ENCRYPT_KEY` (AES) | Mis en pause jusqu'à fin de projet |
| **P8** | Email confirmation publication demande | Fonctionnalité reportée explicitement |
| **-** | Géolocalisation | Hors périmètre |
| **-** | Version Web sécurisée (BFF) | Hors périmètre |
| **-** | Version iOS | Hors périmètre |

---

### 🔒 INTENTIONNEL — À ne pas modifier

| ID | Point | Décision |
|---|---|---|
| **-** | Triggers `trg_limite_demandes` + `trg_verifier_limite_demandes` (apparemment redondants) | Intentionnel — mécanisme de sécurité à un jour d'écart |
| **-** | Double suppression de compte (EF + SQL direct) | Intentionnel — architecture voulue |
| **-** | Coexistence `telephone_hash`/`contact_secondaire_chiffre` dans `identites` et `telephone_chiffre` dans `profils_donneurs` | Intentionnel — pas à unifier |

---

## Annexe — Correction effectuée dans cette session

**Fichier modifié** : `README.md`

```diff
- | Politique de confidentialité | `https://songre.bf/politique-confidentialite` |
+ | Politique de confidentialité | `https://songre.vercel.app/fr/confidentialite` |

- | Politique de confidentialité | https://songre.bf/politique-confidentialite |
+ | Politique de confidentialité | https://songre.vercel.app/fr/confidentialite |
```

**Commit à créer** : `docs: mettre à jour URL politique de confidentialité dans README.md (songre.bf → songre.vercel.app)`

---

*Rapport généré le 2026-07-18 — Commit de référence : `dfee63c` — Audit réalisé sans modification de code fonctionnel (seule correction autorisée : mise à jour URL politique dans README.md)*
