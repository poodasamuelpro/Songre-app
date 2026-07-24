# AUDIT — 5 FONCTIONNALITÉS CRITIQUES SONGRE
**Date** : 2026-07-23  
**Commit audité** : `6735ea5` — "fix: [Fix-LIFESAVER-PERMANENT] corriger régression flutter_signing_tool + FCM complet"  
**Branche** : `main`  
**Remote GitHub** : `poodasamuelpro/Songre-app`  
**Auditeur** : Lecture directe du code source — aucune affirmation sans preuve textuelle  

---

## RÉSUMÉ EXÉCUTIF

| # | Fonctionnalité | Verdict | Points à corriger |
|---|---|---|---|
| F1 | QR Code | ✅ CONFORME | Aucun |
| F2 | Notifications push | ⚠️ CONFORME AVEC RÉSERVE | `channel_id` absent du payload FCM backend |
| F3 | Notifications in-app | ⚠️ CONFORME AVEC RÉSERVE | Politique RLS `notifications_select_own` non versionnée localement |
| F4 | Écran blanc réponse demande | ✅ CONFORME | Correctif intact, non régressé |
| F5 | Email donneurs compatibles | ✅ CONFORME | Webhook DB non vérifiable depuis sandbox |
| T | Comparaison local / GitHub | ✅ IDENTIQUE | `git diff github/main HEAD` → sortie vide |

---

## FONCTIONNALITÉ 1 — QR Code (génération, affichage, scan, autorisations)

### 1.1 — Fichiers impliqués

| Fichier | Rôle |
|---|---|
| `lib/services/app_state.dart` | `genererQrToken()` — orchestration + déduplication PERF-05 |
| `lib/services/supabase_service.dart` | `lireTokenQrExistant()`, `creerToken()`, `validerToken()` — couche HTTP |
| `lib/screens/detail_demande_screen.dart` | Affichage QR côté donneur, bouton Scanner côté auteur, `_genererQr()` |
| `lib/screens/scan_qr_screen.dart` | Scanner caméra + saisie manuelle + `_valider()` |
| `lib/router.dart` | Guard `/scan-qr` (Sécurité T9) |
| `supabase/functions/valider-token/index.ts` | Chaîne complète de validation serveur (12 étapes) |
| `android/app/src/main/AndroidManifest.xml` | `uses-permission android:name="android.permission.CAMERA"` |

### 1.2 — Génération du QR code

**Écran déclencheur** : `detail_demande_screen.dart`  
**Action utilisateur** : Tap sur le bouton "Générer mon code" (ligne 604)  
**Méthode appelée** : `_genererQr(demande)` → `state.genererQrToken(demande.id)` → `SupabaseService.lireTokenQrExistant()` + `SupabaseService.creerToken()`

**Flux complet confirmé par lecture de code** :
```
[Donneur] Tap "Générer mon code"
  → _genererQr(demande)                            [detail_demande_screen.dart:825]
  → AppState.genererQrToken(demandeId)              [app_state.dart:763]
  → [PERF-05] lireTokenQrExistant(donneurId, demandeId)  [supabase_service.dart:1049]
      Query: /rest/v1/dons_qr_tokens
             ?donneur_id=eq.$donneurId
             &demande_id=eq.$demandeId
             &expires_at=gt.$now
             &used_at=is.null
             &select=token&limit=1
  → Si token existant valide → retourner immédiatement (évite un INSERT doublon)
  → Sinon : creerToken(donneurId, demandeId)       [supabase_service.dart:1084]
      POST /rest/v1/dons_qr_tokens
      Body: { donneur_id, demande_id }
      Response: { token: "<chaîne opaque>" }
  → setState({ _qrData = token, _showQr = true })   [detail_demande_screen.dart:830]
  → QrImageView(data: _qrData!)                     [detail_demande_screen.dart:753]
```

**Contenu du QR code** : Le token opaque brut (chaîne UUID ou similaire généré côté Supabase), **sans enveloppe JSON**. Preuve : `_qrData = token` est la chaîne retournée directement par `creerToken()` → `data['token'] as String`.

### 1.3 — Condition d'affichage du QR code côté donneur

**Lu dans `detail_demande_screen.dart`** :

- Le bloc QR est visible à **tout utilisateur non-auteur** de la demande (pas de condition sur `_repondu`).
- Le bouton "Générer mon code" est toujours présent dans la rangée d'actions, indépendamment de `_repondu`.
- `_showQr = false` par défaut → le QR n'est affiché **qu'après** tap sur "Générer mon code".
- Après génération : `_buildQrCode()` avec `QrImageView(data: _qrData!)` remplace le `_buildQrPlaceholder()`.

**Observation** : Le bouton "Générer mon code" n'est **pas conditionné** à `_repondu == true`. Un donneur peut générer un QR même sans avoir cliqué "Je réponds". Ce comportement est probablement intentionnel (don sur place sans réponse préalable), mais mérite confirmation fonctionnelle.

### 1.4 — Condition d'affichage et de visibilité du bouton "Scanner" — Vérification [P-SCANALL]

**Lu dans `detail_demande_screen.dart` lignes 625-646** :

```dart
// [P-SCANALL corrigé] : conditionné sur estAuteur
if (state.userId != null && state.userId == demande.auteurId)
  SizedBox(
    width: double.infinity,
    child: OutlinedButton.icon(
      onPressed: () => context.push('/scan-qr', extra: state.userId),
      icon: const Icon(Icons.qr_code_scanner, size: 18),
      label: Text('Scanner le code du donneur', ...),
    ),
  ),
```

**Verdict** : ✅ Le correctif [P-SCANALL] est **intact**. Le bouton "Scanner le code du donneur" n'est affiché que si `state.userId == demande.auteurId`. Un donneur ne voit jamais ce bouton sur une demande qu'il n'a pas créée.

### 1.5 — Écran ScanQrScreen — Permissions, flux et sécurité

**Permissions caméra** :  
- Déclarée dans `AndroidManifest.xml` : `<uses-permission android:name="android.permission.CAMERA"/>` (ligne 5).  
- `mobile_scanner` gère la demande de permission runtime automatiquement au démarrage du scanner.  
- En cas de refus : `MobileScannerController` n'accède pas à la caméra. Le comportement observé dans le code est que le widget `MobileScanner` affiche un état d'erreur ou reste vide. Il n'y a **pas de gestion explicite du refus** dans `_ScanQrScreenState` (pas de `PermissionStatus.denied` check manuel) — la gestion est déléguée à `mobile_scanner` lui-même.  
- **Point d'attention** : Si l'utilisateur refuse la permission, il n'y a pas de message explicatif dans l'UI — seulement le bouton "Manuel" qui permet le fallback.

**Guard router** (Sécurité T9, `router.dart` ligne 154-175) :
```dart
path: '/scan-qr',
redirect: (ctx, state) {
  final demandeurId = state.extra as String? ?? '';
  if (demandeurId.isEmpty) return '/home'; // BLOC HARD
  return null;
},
```
- Si `demandeurId` est vide (utilisateur non authentifié, AppState.userId null), redirection immédiate vers `/home`.
- La navigation est donc doublement protégée : côté UI (bouton visible uniquement pour l'auteur) et côté routeur (guard HARD).

**Fallback Web** : `_showManual = kIsWeb` (ligne 37) → sur Web, l'interface de saisie manuelle est affichée immédiatement, sans tentative d'accès caméra. `MobileScannerController` n'est initialisé que sur `!kIsWeb` (ligne 42-48).

**`_valider(token)` — Transmission** :
```dart
final result = await SupabaseService.validerToken(
  token: trimmed,
  demandeurId: widget.demandeurId,
);
```
Headers envoyés : `Authorization: Bearer <jwt>` + `x-webhook-secret: <WEBHOOK_SECRET>`.

### 1.6 — Chaîne complète de validation (Edge Function `valider-token`)

**Lu dans `supabase/functions/valider-token/index.ts`** — 12 étapes vérifiées :

| Étape | Action | Vérification |
|---|---|---|
| 0 | WEBHOOK_SECRET présent et valide | ✅ Obligatoire — 500 si absent, 401 si invalide |
| 1 | JWT Bearer présent | ✅ 401 si absent |
| 2 | JWT vérifié par Supabase `getUser()` | ✅ 401 si invalide/expiré |
| 3 | Parser body `{token, demandeur_id}` | ✅ 400 si malformé |
| 3b | `demandeur_id == user.id` (JWT) | ✅ 403 si divergence |
| 4 | Token trouvé dans `dons_qr_tokens` | ✅ 404 si absent |
| 5 | `used_at IS NULL` (non utilisé) | ✅ 400 avec message clair |
| 6 | `expires_at > now()` (non expiré) | ✅ 400 avec date expiration |
| 7 | `demande.auteur_id == demandeur_id` | ✅ 403 si non-auteur |
| 8 | `demande.statut == 'active'` | ✅ 400 si autre statut |
| 9 | UPDATE `used_at`, `used_by` + trigger atomique | ✅ Guard `.is("used_at", null)` anti-race |
| 10 | INSERT `historique_dons` (source='qr_valide') | ✅ Non bloquant |
| 11 | UPDATE `reponses_donneurs.statut = 'confirme'` | ✅ Non bloquant |
| 12 | 2× `notifierUtilisateur` (donneur + demandeur) | ✅ `don_confirme` + `don_confirme_demandeur` |

### 1.7 — Conclusion F1

**VERDICT : ✅ CONFORME**

Le flux QR est complet et correctement sécurisé de bout en bout. Aucun problème identifié. Points notables non-bloquants :
- Le bouton "Générer mon code" n'est pas conditionné à `_repondu == true` — comportement à confirmer fonctionnellement.
- En cas de refus de permission caméra, l'UX du fallback manuel n'est pas explicitement proposée (dépend de `mobile_scanner`).

---

## FONCTIONNALITÉ 2 — Notifications push

### 2.1 — Fichiers impliqués

| Fichier | Rôle |
|---|---|
| `lib/services/notification_service.dart` | Initialisation FCM, canal Android, handler foreground/background |
| `lib/main.dart` | `Firebase.initializeApp()` Android only, `initialiserCanal()` |
| `lib/services/app_state.dart` | `NotificationService.initialiser(userId)` à chaque connexion |
| `supabase/functions/_shared/fcm.ts` | `envoyerFcmV1()`, `getFcmTokensForUser()`, OAuth2 |
| `supabase/functions/_shared/notifier.ts` | `notifierUtilisateur()` — orchestrateur central |
| `supabase/functions/matcher-et-notifier/index.ts` | Type `demande_compatible` — envoi aux donneurs |
| `supabase/functions/reponse-donneur/index.ts` | Types `reponse_recue` + `reponse_encouragement` |
| `supabase/functions/valider-token/index.ts` | Types `don_confirme` + `don_confirme_demandeur` |
| `supabase/functions/don-manuel/index.ts` | Type `don_enregistre_manuel` |
| `supabase/functions/retour-eligibilite-cron/index.ts` | Type `retour_eligibilite` |
| `supabase/functions/mdp-modifie-auth/index.ts` | Type `mdp_modifie` |
| `supabase/functions/bienvenue-auth/index.ts` | Type `bienvenue` |
| `supabase/functions/executer-suppressions-programmees/index.ts` | Types `suppression_demandee` + `suppression_confirmee` |

### 2.2 — Liste exhaustive des types de notifications push

Lu depuis `_shared/notifier.ts` (fonction `fcmDefaults()`) et les Edge Functions :

| # | Type | Événement déclencheur | EF responsable | Destinataire |
|---|---|---|---|---|
| 1 | `demande_compatible` | Nouvelle demande publiée, groupe compatible | `matcher-et-notifier` | Donneurs compatibles et disponibles (≤ MAX_DESTINATAIRES=20) |
| 2 | `reponse_recue` | Donneur clique "Je réponds" | `reponse-donneur` | **Demandeur** de la demande |
| 3 | `reponse_encouragement` | Donneur clique "Je réponds" | `reponse-donneur` | **Donneur** lui-même |
| 4 | `don_confirme` | QR scanné et validé | `valider-token` | **Donneur** dont le token est validé |
| 5 | `don_confirme_demandeur` | QR scanné et validé | `valider-token` | **Demandeur** auteur de la demande |
| 6 | `don_enregistre_manuel` | Don déclaratif enregistré | `don-manuel` | **Donneur** déclarant |
| 7 | `retour_eligibilite` | Délai inter-don écoulé (cron) | `retour-eligibilite-cron` | **Donneur** redevenu éligible |
| 8 | `suppression_demandee` | Compte programmé pour suppression | `executer-suppressions-programmees` | **Utilisateur** concerné |
| 9 | `suppression_confirmee` | Compte supprimé (skipDbInsert=true) | `executer-suppressions-programmees` | **Utilisateur** concerné |
| 10 | `bienvenue` | Première connexion après inscription | `bienvenue-auth` | **Nouvel utilisateur** |
| 11 | `mdp_modifie` | Changement de mot de passe | `mdp-modifie-auth` | **Utilisateur** concerné |

### 2.3 — Vérification que chaque notification atteint uniquement le bon destinataire

**Lu dans `_shared/fcm.ts` lignes 157-172** :

```typescript
export async function getFcmTokensForUser(
  adminClient: any,
  userId: string,
): Promise<string[]> {
  const { data, error } = await adminClient
    .from("device_tokens")
    .select("fcm_token")
    .eq("user_id", userId);   // ← FILTRE STRICT par userId
  // ...
}
```

**Verdict** : ✅ `getFcmTokensForUser()` filtre **toujours** par `userId`. Il est **structurellement impossible** d'envoyer à tous les utilisateurs par accident via cette fonction.

Pour `matcher-et-notifier` : chaque donneur est itéré individuellement → `getFcmTokensForUser(adminClient, donneurId)` par donneur. Le plafond `MAX_DESTINATAIRES = 20` limite le nombre d'appels.

### 2.4 — Gestion du son — Canal Android

**Lu dans `notification_service.dart` lignes 12-18** :

```dart
const _androidChannel = AndroidNotificationChannel(
  _kChannelId,   // 'songre_fcm'
  _kChannelName, // 'Notifications SONGRE'
  description: _kChannelDesc,
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);
```

**Canal créé** : `initialiserCanal()` crée ce canal via `AndroidFlutterLocalNotificationsPlugin.createNotificationChannel()`.

**Notifications foreground** : affichées via `_localNotif.show()` avec `AndroidNotificationDetails(_kChannelId, ...)` → ✅ le canal `songre_fcm` est utilisé.

**🚨 PROBLÈME IDENTIFIÉ — Notifications background** :

Dans `_shared/fcm.ts`, `envoyerFcmV1()` ligne 118-128 :
```typescript
const message = {
  message: {
    token: fcmToken,
    notification: { title: titre, body: corps },
    data,
    android: { priority: "high" },  // ← MANQUE channel_id ici
    apns: { payload: { aps: { sound: "default", badge: 1 } } },
  },
};
```

Le champ `android.notification.channel_id` est **absent** du payload FCM envoyé par le backend. Sans ce champ, Android utilisera le canal **par défaut du système** (ou le premier canal créé), qui peut ne pas avoir l'importance HIGH ni le son configuré.

Le canal `songre_fcm` (importance HIGH + son) est créé côté Flutter, mais il n'est référencé dans le payload FCM que pour les notifications **foreground** (via `flutter_local_notifications`). Pour les notifications **background/terminé**, FCM doit inclure `channel_id: "songre_fcm"` dans le payload pour router vers le bon canal.

**Impact** : Les notifications reçues quand l'app est en arrière-plan ou fermée peuvent ne pas sonner ou sonner avec le son par défaut système au lieu du son configuré.

### 2.5 — Demande d'autorisation système

**Lu dans `notification_service.dart` lignes 86-99** :

```dart
static Future<void> initialiser(String userId) async {
  if (kIsWeb) return;
  // ...
  final settings = await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );
  if (settings.authorizationStatus == AuthorizationStatus.denied) {
    debugPrint('[NotificationService] Permissions refusées.');
    return;
  }
```

**Déclenchement** : `NotificationService.initialiser(userId)` est appelé :
1. Après `connecter()` réussi dans `app_state.dart`
2. Après `restaurerSession()` réussi dans `app_state.dart`

Sur **Android 13+ (API 33+)** : la boîte de dialogue système apparaît au premier appel. Sur Android < 13 : la permission est accordée automatiquement, aucune boîte de dialogue n'apparaît — ce comportement est **normal et attendu**.

En cas de refus : `return` immédiat après `debugPrint`. Aucun token FCM n'est enregistré. L'utilisateur ne recevra aucune notification push. L'app continue de fonctionner normalement (non bloquant).

### 2.6 — Conclusion F2

**VERDICT : ⚠️ CONFORME AVEC RÉSERVE**

Tout fonctionne correctement en foreground et pour le ciblage des destinataires. Réserve identifiée :

**C1 — À corriger en session dédiée** : Ajouter `notification: { channel_id: "songre_fcm" }` dans le bloc `android` de `envoyerFcmV1()` dans `_shared/fcm.ts` :
```typescript
android: {
  priority: "high",
  notification: { channel_id: "songre_fcm" }  // ← À AJOUTER
},
```

---

## FONCTIONNALITÉ 3 — Notifications in-app

### 3.1 — Fichiers impliqués

| Fichier | Rôle |
|---|---|
| `lib/screens/notifications_screen.dart` | Affichage de la liste, badge, marquage lu |
| `lib/services/supabase_service.dart` | `lireNotifications()`, `marquerNotificationLue()` |
| `lib/services/app_state.dart` | Cache `_notifications`, `notifNonLues` getter |
| `lib/models/models.dart` | `NotificationSauve.fromBase()`, `_messageDepuisType()` |
| `supabase/functions/_shared/notifier.ts` | INSERT dans `notifications_envoyees` |
| `supabase/functions/mission-e.sql` | Schéma + index RLS vérification |

### 3.2 — Source de vérité et logique client

**Lu dans `supabase_service.dart` lignes 1398-1430** :

```dart
final url = Uri.parse(
  '$_supabaseUrl/rest/v1/notifications_envoyees'
  '?user_id=eq.$userId'      // ← FILTRE STRICT par userId
  '&order=created_at.desc'
  '&limit=50',
);
```

Le filtre `user_id=eq.$userId` est appliqué **au niveau URL REST**. Le serveur Supabase ne peut retourner que les lignes matchant ce `userId`.

**Message généré côté client** :  
Lu dans `lib/models/models.dart` :
```dart
factory NotificationSauve.fromBase(Map<String, dynamic> json) {
  final typeEnum = TypeNotification.fromValue(json['type']);
  final message = _messageDepuisType(typeEnum); // génération client
}
```
La table `notifications_envoyees` stocke uniquement le `type` (enum). Le message affiché est généré côté Flutter selon le type. ✅ Conforme au choix architectural documenté.

### 3.3 — Politique RLS `notifications_select_own`

**Lu dans `supabase/functions/mission-e.sql`** :

La recherche de `notifications_select_own` dans `mission-e.sql` ne retourne **aucun résultat**. Le fichier SQL mentionne `notifications_envoyees` uniquement pour :
- Créer un index sur `(user_id, created_at DESC)` (ligne 228)
- Vérifier que RLS est actif sur la table (ligne 242)

Aucun `CREATE POLICY` n'est trouvé pour `notifications_envoyees` dans les fichiers SQL locaux.

**Analyse de la double protection** :

1. **Niveau URL REST** : Le filtre `?user_id=eq.$userId` garantit que la requête ne peut retourner que les notifications de l'utilisateur connecté, même si RLS était désactivé.
2. **Niveau RLS (non versionné localement)** : La politique devrait exister dans Supabase Dashboard. Son absence dans les fichiers SQL locaux est un **point d'attention** (non-versionning), pas un bug fonctionnel.

**Verdict** : La protection fonctionne grâce au filtre URL. Mais la politique RLS n'est pas versionnée localement.

### 3.4 — Conclusion F3

**VERDICT : ⚠️ CONFORME AVEC RÉSERVE**

La fonctionnalité est opérationnelle. Réserve :

**C2 — À corriger en session dédiée** : Vérifier l'existence de la politique `notifications_select_own` dans le Dashboard Supabase et la versionner dans un fichier SQL local (ex: `supabase/functions/mission-e.sql` ou nouveau fichier `supabase/migrations/rls_notifications.sql`).

---

## FONCTIONNALITÉ 4 — Écran blanc lors de la réponse à une demande de sang (ré-audit)

### 4.1 — Fichiers impliqués

| Fichier | Rôle |
|---|---|
| `lib/screens/detail_demande_screen.dart` | `_repondre()` — méthode auditée |

### 4.2 — Lecture complète de `_repondre()`

**Lu dans `detail_demande_screen.dart` lignes 776-818** :

```dart
Future<void> _repondre() async {
  final demande = widget.demande;
  // [1] Capturer state et messenger AVANT tout await
  final state = context.read<AppState>();
  // ignore: use_build_context_synchronously — volontaire : messenger capturé avant await
  final messenger = ScaffoldMessenger.of(context);

  // [2] Mise à jour optimiste
  setState(() => _repondu = true);

  final ok = await state.enregistrerReponseDonneur(demande.id);

  // [3] Garde !mounted
  if (!mounted) return;

  if (ok) {
    // [4] addPostFrameCallback pour éviter setState pendant reconstruction
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _chargerEtatRepondu();
    });
  } else {
    // Rollback optimiste si échec
    setState(() => _repondu = false);
  }

  // [5] SnackBar via messenger pré-capturé
  messenger.showSnackBar(SnackBar(
    content: Text(ok ? 'Réponse enregistrée...' : 'Erreur lors de l\'enregistrement...'),
    backgroundColor: ok ? SauveColors.vert : const Color(0xFFB45309),
    ...
  ));
}
```

### 4.3 — Vérification des 4 éléments du correctif

| Élément | Attendu | Trouvé dans le code | Statut |
|---|---|---|---|
| 1 | `messenger` capturé AVANT `await` | `final messenger = ScaffoldMessenger.of(context);` avant `await state.enregistrerReponseDonneur(...)` | ✅ INTACT |
| 2 | Mise à jour optimiste | `setState(() => _repondu = true);` avant `await` | ✅ INTACT |
| 3 | Garde `!mounted` | `if (!mounted) return;` après `await` | ✅ INTACT |
| 4 | `addPostFrameCallback` | `WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _chargerEtatRepondu(); });` | ✅ INTACT |

### 4.4 — Vérification régression via historique Git

Commit `6735ea5` (dernier) → modifications : `AndroidManifest.xml`, `build.gradle.kts`, `MainActivity.kt`. Aucun fichier `detail_demande_screen.dart` dans les fichiers modifiés de ce commit ni des commits récents.

```
git log --oneline -- lib/screens/detail_demande_screen.dart
```
Confirme que `_repondre()` n'a pas été touché depuis son correctif initial.

### 4.5 — Conclusion F4

**VERDICT : ✅ CONFORME**

Les 4 éléments du correctif anti-écran-blanc sont intacts et non régressés. La méthode `_repondre()` est conforme à l'implémentation cible.

---

## FONCTIONNALITÉ 5 — Email envoyé aux donneurs compatibles lors de la publication

### 5.1 — Fichiers impliqués

| Fichier | Rôle |
|---|---|
| `lib/services/app_state.dart` | `publierDemande()` → INSERT dans `demandes_sang` |
| `supabase/functions/matcher-et-notifier/index.ts` | EF principale : sélection donneurs + envoi |
| `supabase/functions/_shared/notifier.ts` | `notifierUtilisateur()` — email + FCM + DB |
| `supabase/functions/_shared/email.ts` | `templateDemandeCompatible()`, `APP_URL`, envoi SMTP |
| `lib/models/models.dart` | `estCompatibleAvec()`, `_groupesCompatibles()` |

### 5.2 — Flux complet depuis publication jusqu'à email

```
[Auteur] AppState.publierDemande()
  → SupabaseService.publierDemande(demande)
  → POST /rest/v1/demandes_sang (INSERT)
  → Supabase Dashboard Webhook déclenché sur INSERT dans demandes_sang
  → Edge Function matcher-et-notifier invoquée
  → Vérification WEBHOOK_SECRET
  → Lecture de la demande : groupe_sanguin_recherche, ville_id
  → SELECT profils_donneurs WHERE disponible=true AND ville_id=X
  → Filtre estCompatible(groupeReceveur, groupeDonneur)
       COMPATIBILITE_ABO["AB+"] = ["O-","O+","A-","A+","B-","B+","AB-","AB+"]
  → Filtre délai inter-don genre-aware (femme=120j, homme/autre=90j)
  → slice(0, MAX_DESTINATAIRES) → plafond 20 destinataires
  → Pour chaque donneur : notifierUtilisateur(donneurId, "demande_compatible", {groupe, ville})
      → email via envoyerEmailRotatif (Brevo/Resend rotation)
      → FCM via envoyerFcmV1 (token FCM de l'appareil du donneur)
      → INSERT notifications_envoyees (type="demande_compatible")
```

### 5.3 — Cohérence matrice de compatibilité Flutter ↔ Edge Function

**Edge Function** (`matcher-et-notifier/index.ts` lignes 80-90) :
```typescript
const COMPATIBILITE_ABO: Record<string, string[]> = {
  "O-":  ["O-"],
  "O+":  ["O-", "O+"],
  "A-":  ["O-", "A-"],
  "A+":  ["O-", "O+", "A-", "A+"],
  "B-":  ["O-", "B-"],
  "B+":  ["O-", "O+", "B-", "B+"],
  "AB-": ["O-", "A-", "B-", "AB-"],
  "AB+": ["O-", "O+", "A-", "A+", "B-", "B+", "AB-", "AB+"],
};
```

**Flutter** (`lib/models/models.dart`) :  
`_groupesCompatibles()` pour AB+ → `GroupeSanguin.values.toList()` (tous les groupes).

**Verdict** : ✅ Les deux matrices sont **cohérentes**. AB+ reçoit des donneurs de tous les groupes dans les deux implémentations.

### 5.4 — Limite MAX_DESTINATAIRES et APP_URL

**MAX_DESTINATAIRES** : Confirmé à 20 (ligne 78). Appliqué via `donneursCompatibles.slice(0, MAX_DESTINATAIRES)` (ligne 228). ✅ Intact.

**APP_URL** : Lu dans `_shared/email.ts` ligne 49 :
```typescript
const APP_URL = Deno.env.get("APP_URL") ?? "https://songre.vercel.app";
```
Toutes les occurrences de liens dans les templates utilisent `${APP_URL}` (lignes 82, 112, 196, 227, 265, 377). ✅ Dynamique, non codé en dur.

### 5.5 — Note sur le déclencheur

Le déclencheur est un **webhook Supabase Dashboard** sur INSERT dans `demandes_sang`, et non un trigger PostgreSQL. Il n'est pas vérifiable depuis le sandbox (non visible dans les fichiers SQL locaux). Ce point est documenté comme non-vérifiable mais cohérent avec l'architecture.

### 5.6 — Conclusion F5

**VERDICT : ✅ CONFORME**

Le flux email est complet, la matrice de compatibilité est cohérente entre Flutter et l'Edge Function, le plafond MAX_DESTINATAIRES=20 est actif, et APP_URL est dynamique. Le déclencheur webhook DB n'est pas vérifiable depuis le sandbox (limitation attendue).

---

## PARTIE TRANSVERSALE — Comparaison exhaustive local / GitHub

### Commandes exécutées

```bash
# Fetch GitHub
git fetch github
# Diff complet contenu par contenu
git diff github/main HEAD --stat
git diff github/main HEAD --name-only
```

### Résultats

**`git fetch github`** : succès (aucune erreur réseau).

**`git diff github/main HEAD --stat`** : **sortie vide**.

**`git diff github/main HEAD --name-only`** : **sortie vide**.

### Interprétation

Une sortie vide de `git diff github/main HEAD` signifie que **chaque fichier suivi par Git est identique byte pour byte** entre la version locale et `github/main`. Il n'y a aucune divergence de contenu.

### Fichiers non commités (non inclus dans le diff)

La commande `git status` révèle des fichiers modifiés non commités :

| Fichier | Statut | Nature |
|---|---|---|
| `macos/Flutter/GeneratedPluginRegistrant.swift` | Modified | Artefact de build macOS — généré automatiquement |
| `web-app/.last_build_id` | Modified | Artefact de build web — généré automatiquement |
| `web-app/assets/NOTICES` | Modified | Artefact de build |
| `web-app/flutter_bootstrap.js` | Modified | Artefact de build web |
| `web-app/flutter_service_worker.js` | Modified | Artefact de build web |
| `web-app/index.html` | Modified | Artefact de build web |
| `web-app/main.dart.js` | Modified | Artefact de build web (3.6 MB) |
| `web-app/manifest.json` | Modified | Artefact de build web |
| `AUDIT_5_FONCTIONNALITES_2026-07-23.md` | Untracked | Présent rapport d'audit |

**Analyse** : Tous les fichiers modifiés non commités sont des **artefacts de build** (générés automatiquement par `flutter build web`). Ils ne font pas partie du code source géré manuellement. Le fichier `AUDIT_5_FONCTIONNALITES_2026-07-23.md` est un fichier non tracké (non encore `git add`).

### Conclusion Transversale

**VERDICT : ✅ LOCAL ET GITHUB IDENTIQUES**

Zéro divergence sur le code source suivi par Git. La version locale et la version sur `poodasamuelpro/Songre-app` sont byte-perfect identiques au niveau du commit `6735ea5`.

---

## SYNTHÈSE DES ACTIONS REQUISES

### Corrections à planifier (session dédiée)

| ID | Priorité | Fichier | Action |
|---|---|---|---|
| C1 | Moyenne | `supabase/functions/_shared/fcm.ts` | Ajouter `notification: { channel_id: "songre_fcm" }` dans le bloc `android` de `envoyerFcmV1()` |
| C2 | Basse | Dashboard Supabase + SQL local | Vérifier existence de `notifications_select_own` RLS policy, la créer si absente, la versionner localement |

### Tâches non réalisées dans cette session (hors périmètre audit)

- Rebuild APK avec correctifs FCM : non effectué (see Pending Tasks session précédente)
- Test réel du scan QR avec deux comptes (non réalisable depuis sandbox)
- Test réel de réception email (non réalisable depuis sandbox sans accès mailbox)
- Vérification Dashboard Supabase pour RLS `notifications_select_own` (accès Dashboard non disponible)

---

## ATTESTATION D'AUDIT

Cet audit a été réalisé par **lecture directe du code source** des fichiers listés. Chaque affirmation est appuyée par des extraits de code réels avec numéros de ligne. Aucune correction n'a été appliquée durant cette session — le périmètre était strictement la lecture et la documentation.

**Fichiers lus intégralement** :
- `lib/services/notification_service.dart` (253 lignes)
- `lib/screens/scan_qr_screen.dart` (567 lignes)
- `supabase/functions/valider-token/index.ts` (329 lignes)
- `supabase/functions/_shared/fcm.ts` (196 lignes)
- `supabase/functions/_shared/notifier.ts` (285 lignes)

**Fichiers lus partiellement (sections ciblées)** :
- `lib/services/app_state.dart` (sections QR, init, FCM)
- `lib/services/supabase_service.dart` (sections QR, notifications)
- `lib/screens/detail_demande_screen.dart` (sections boutons, _repondre, _genererQr)
- `lib/router.dart` (guard /scan-qr)
- `supabase/functions/matcher-et-notifier/index.ts` (COMPATIBILITE_ABO, MAX_DESTINATAIRES, flux)
- `supabase/functions/reponse-donneur/index.ts` (bloc notifications)
- `supabase/functions/_shared/email.ts` (APP_URL, templateDemandeCompatible)
- `supabase/functions/mission-e.sql` (recherche RLS notifications)
- `android/app/src/main/AndroidManifest.xml` (permissions)

**Commit de référence** : `6735ea5`  
**Date** : 2026-07-23
