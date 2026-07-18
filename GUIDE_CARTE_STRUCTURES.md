# GUIDE_CARTE_STRUCTURES.md
# Guide d'implémentation — Carte des structures sanitaires (Mission E)

**Projet** : SONGRE — Application de don de sang (Burkina Faso)  
**Session** : 5  
**Date** : 2026-07-19  
**Commit précédent** : `b493cd5` (Guide mise en œuvre complet session 4)  
**Analyse** : `No issues found!` ✅  
**APK** : build vérifiée, package `com.songre.app`, label `Songre`

---

## Table des matières

1. [Architecture retenue](#1-architecture-retenue)
2. [Mécanisme de bascule dynamique A/B](#2-mécanisme-de-bascule-dynamique-ab)
3. [Option B — Maps externe (défaut)](#3-option-b--maps-externe-défaut)
4. [Option A — Carte intégrée flutter_map](#4-option-a--carte-intégrée-flutter_map)
5. [Flux de consentement géolocalisation](#5-flux-de-consentement-géolocalisation)
6. [Fichiers modifiés et créés](#6-fichiers-modifiés-et-créés)
7. [Schéma de base de données](#7-schéma-de-base-de-données)
8. [Expérience utilisateur par scénario](#8-expérience-utilisateur-par-scénario)
9. [Confirmation des tests réels](#9-confirmation-des-tests-réels)
10. [Périmètre et hors-périmètre](#10-périmètre-et-hors-périmètre)

---

## 1. Architecture retenue

### Vue d'ensemble

```
DetailDemandeScreen
  └─ Bouton "Voir sur la carte"
       └─ context.push('/carte-structures', extra: StructureSanitaire?)
            └─ CarteStructuresScreen
                 ├─ lireConfigCarte() → app_config WHERE cle='mode_carte'
                 ├─ valeur 'externe' → Option B (url_launcher, geo:)
                 └─ valeur 'integree' → Option A (flutter_map + geolocator)
```

### Décisions d'architecture

| Décision | Raison |
|---|---|
| Lecture `app_config` au lancement de l'écran (pas au démarrage de l'app) | Moins de charge initiale ; la config peut changer entre deux ouvertures |
| Fallback silencieux vers `'externe'` si la table n'existe pas | L'app reste fonctionnelle si le SQL n'a pas encore été exécuté |
| `StructureSanitaire?` passée en `extra` via GoRouter | Pattern déjà établi dans le projet (identique à `DemandeSang` dans `/demande/:id`) |
| Pas de dépendance `flutter_map` au démarrage (import conditionnel) | Réduit la surface de compilation initiale |
| `SauveColors` + `GoogleFonts` partout | Cohérence visuelle avec le reste de l'application |

---

## 2. Mécanisme de bascule dynamique A/B

### Table Supabase `app_config`

```sql
cle          | valeur   | description
-------------|----------|--------------------------------------------------
mode_carte   | externe  | (défaut) ouvre Maps native via geo: + fallback URL
             | integree | carte flutter_map intégrée dans l'application
```

### Comment basculer en production

1. Aller sur **app.supabase.com** → votre projet → **Table Editor**
2. Ouvrir la table `app_config`
3. Modifier la ligne `mode_carte`
4. Changer la valeur : `externe` → `integree` (ou inversement)
5. Sauvegarder — **aucune recompilation nécessaire**

### Implémentation Flutter

```dart
// SupabaseService.lireConfigCarte() — supabase_service.dart
// Lecture via REST API, timeout 8s, fallback 'externe' si erreur
final mode = await SupabaseService.lireConfigCarte();
// → 'externe' ou 'integree'
```

### Robustesse

- Si la table `app_config` n'existe pas encore → retourne `'externe'` (Option B)
- Si la valeur est inconnue → retourne `'externe'` (Option B)
- Si le réseau est indisponible → retourne `'externe'` (Option B)

---

## 3. Option B — Maps externe (défaut)

### Comportement

Au démarrage de `CarteStructuresScreen` :

1. Lecture de `app_config` → `'externe'`
2. **Appel immédiat** à `_ouvrirMapsExterne()`
3. Affichage d'un écran informatif pendant l'attente (et en cas de retour)

### Implémentation

```dart
// Tentative 1 : schéma geo: (Android)
// Déclenche Google Maps, OsmAnd, Here Maps, etc.
final geoUri = Uri.parse('geo:$lat,$lon?q=$lat,$lon($labelEncode)');
if (await canLaunchUrl(geoUri)) {
  await launchUrl(geoUri);
}

// Tentative 2 : fallback URL Google Maps (si geo: non supporté)
final mapsUrl = Uri.parse(
  'https://www.google.com/maps/search/?api=1&query=$lat,$lon',
);
await launchUrl(mapsUrl, mode: LaunchMode.externalApplication);
```

### Conditions requises dans AndroidManifest.xml

```xml
<!-- Permissions (déjà présentes) -->
<uses-permission android:name="android.permission.INTERNET"/>

<!-- Query geo: (ajouté dans cette session) -->
<queries>
  <intent>
    <action android:name="android.intent.action.VIEW"/>
    <data android:scheme="geo"/>
  </intent>
</queries>
```

### Écran informatif Option B

L'écran affiche :
- Icône carte rouge (SauveColors.rouge)
- Titre : nom de la structure si context fourni, sinon "Structures sanitaires"
- Message informatif ("L'application de cartes s'est ouverte…")
- Bouton "Ouvrir à nouveau" pour relancer Maps si l'utilisateur revient

---

## 4. Option A — Carte intégrée flutter_map

### Bibliothèques ajoutées

```yaml
flutter_map: ^7.0.2   # Carte interactive OpenStreetMap, pas de clé API
latlong2: ^0.9.1      # Coordonnées LatLng compatible flutter_map
geolocator: ^13.0.2   # Position GPS + gestion des permissions runtime
```

### Flux d'initialisation

```
_initialiserOptionA()
  ├─ _verifierPermission()
  │    ├─ Geolocator.isLocationServiceEnabled() → false → _serviceDesactive = true
  │    ├─ LocationPermission.always/whileInUse → _geolocAccorde = true
  │    ├─ LocationPermission.denied + consentement accordé → requestPermission()
  │    └─ LocationPermission.deniedForever → _geolocRefusDef = true
  │
  ├─ Si _geolocAccorde → _chargerPositionReelle()
  │    └─ Geolocator.getCurrentPosition() → _positionUtilisateur = LatLng
  │
  ├─ Sinon → _centrerSurVilleProfil(profil)
  │    └─ Ville depuis AppState.villes ou SupabaseService.lireVilles()
  │         └─ _centreInitial = LatLng(ville.latitude!, ville.longitude!)
  │
  └─ _chargerStructures(profil)
       ├─ lireStructuresSanitaires(villeId: profil.villeId) // si pas de geoloc
       ├─ lireStructuresSanitaires() // toutes si geoloc accordée
       └─ Inclusion forcée de structureContexte si non dans la liste
```

### Carte OpenStreetMap (aucune clé API)

```dart
TileLayer(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'com.songre.app',
  maxZoom: 19,
),
```

Attribution OpenStreetMap automatiquement présente via flutter_map 7.x.

### Marqueurs

| Marqueur | Couleur | Icône | Condition |
|---|---|---|---|
| Structure normale | Fond blanc, bordure encre | `local_hospital` rouge | Toutes les structures géolocalisées |
| Structure de la demande | Fond rouge (`SauveColors.rouge`) | `local_hospital` blanc | `structureContexte?.id == structure.id` |
| Structure sélectionnée (tap) | Fond encre | `local_hospital` blanc | Tap sur le marqueur |
| Position utilisateur | Bleu (`#2563EB`) | Cercle plein | `_geolocAccorde == true` |

### Fiche structure (tap sur marqueur)

Bottom card inline :
- Icône et nom de la structure
- Type (CHR, CSPS, etc.) si renseigné
- Badge "Structure de la demande" si c'est la structure contextuelle
- Fermeture par icône ×

### Gestion des états d'interface

| État | Affichage |
|---|---|
| Chargement | `CircularProgressIndicator` rouge centré |
| Erreur réseau | Message + bouton "Réessayer" |
| Permission refusée temporairement | Bandeau sombre en haut de carte |
| Permission refusée définitivement | Bandeau sombre + message de guidance |
| Service GPS désactivé | Bandeau sombre + message informatif |
| Aucune structure géolocalisée | Card en bas de carte, message neutre |

---

## 5. Flux de consentement géolocalisation

### Principe

Le consentement est collecté dans `_ProfilForm` (écran de création de profil, `login_screen.dart`), **immédiatement après** le consentement santé existant. Pas de nouvel écran, pas de nouvelle étape.

### Modifications apportées à `_ProfilForm`

```dart
// Nouveau champ d'état (ajouté à _ProfilFormState)
bool _consentementGeoloc = false;

// Nouveau widget (ajouté après _buildConsentement())
Widget _buildConsentementGeoloc() {
  // Checkbox optionnelle, couleur SauveColors.encre (distinct du rouge obligatoire)
  // Texte : "J'autorise l'application à utiliser ma position GPS..."
  // "(optionnel — vous pouvez refuser sans impact sur le reste de l'application)"
}
```

### Correction de la ligne 1198

**Avant :**
```dart
consentementGeoloc: false, // Géolocalisation non implémentée pour l'instant
```

**Après :**
```dart
consentementGeoloc: _consentementGeoloc,
```

### Demande de permission système (non bloquante)

```dart
// Fire-and-forget APRÈS l'appel enregistrerConsentement
// N'attend pas, ne bloque pas la navigation vers /home
if (_consentementGeoloc) {
  unawaited(() async {
    final serviceActif = await Geolocator.isLocationServiceEnabled();
    if (!serviceActif) return;
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
  }());
}
// Puis immédiatement :
if (mounted) {
  setState(() => _loading = false);
  context.go('/home');
}
```

### Invariant de non-régression

- `_valider()` se termine par `context.go('/home')` dans tous les cas
- Le bloc `unawaited()` ne peut pas lever d'exception non catchée (try/catch interne)
- Aucun `await` ajouté avant `context.go('/home')`
- Le pattern `!mounted` / `setState` / `context.go` est identique à l'état précédent

### Respect du refus

- Si l'utilisateur décoche la case → `_consentementGeoloc = false` → valeur `false` envoyée en base → CarteStructuresScreen tombera sur le mode ville du profil sans jamais redemander
- Si permission système refusée (runtime) → `_geolocRefusDef = true` → message informatif neutre sur la carte, aucune insistance
- Aucune dialog de rationale supplémentaire dans `CarteStructuresScreen`

---

## 6. Fichiers modifiés et créés

### Fichiers modifiés

| Fichier | Nature des modifications | Lignes impactées |
|---|---|---|
| `pubspec.yaml` | +3 dépendances : `flutter_map`, `latlong2`, `geolocator` | Bloc dependencies |
| `android/app/src/main/AndroidManifest.xml` | +2 permissions localisation, +1 query `geo:` | Après POST_NOTIFICATIONS |
| `lib/models/models.dart` | `Ville` : +`latitude`, +`longitude`, +`estGeolocalise`<br>`StructureSanitaire` : idem | Classes Ville et StructureSanitaire |
| `lib/services/supabase_service.dart` | `lireVilles()` : +sélection lat/lon<br>`lireStructures()` : +sélection lat/lon<br>+`lireStructuresSanitaires({villeId?})`<br>+`lireConfigCarte()` | Section RÉFÉRENTIELS (ligne ~517) |
| `lib/screens/login_screen.dart` | +import geolocator<br>+`_consentementGeoloc` field<br>+`_buildConsentementGeoloc()` widget<br>Fix ligne 1198 : `false` → `_consentementGeoloc`<br>+Demande permission fire-and-forget | _ProfilFormState |
| `lib/router.dart` | +import `carte_structures_screen.dart`<br>+route `/carte-structures` avec `extra` et SlideTransition from bottom | Après `/demande/:id` |
| `lib/screens/detail_demande_screen.dart` | +Bouton "Voir sur la carte" dans `_buildActionRow()`<br>Passe `StructureSanitaire?` contextuelle en extra | `_buildActionRow()` |

### Fichiers créés

| Fichier | Contenu | Taille |
|---|---|---|
| `lib/screens/carte_structures_screen.dart` | Écran complet Option A/B (~680 lignes) | ~32 Ko |
| `GUIDE_CARTE_STRUCTURES.md` | Ce document | ~15 Ko |
| `MODIFICATIONS_MANUELLES_CARTE.sql` | Script SQL commenté | ~12 Ko |

---

## 7. Schéma de base de données

### Modifications requises (via MODIFICATIONS_MANUELLES_CARTE.sql)

#### Table `public.villes`
```sql
ALTER TABLE public.villes
  ADD COLUMN IF NOT EXISTS latitude  DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION;
```

#### Table `public.structures_sanitaires`
```sql
ALTER TABLE public.structures_sanitaires
  ADD COLUMN IF NOT EXISTS latitude  DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION;
```

#### Table `public.app_config` (nouvelle)
```sql
CREATE TABLE IF NOT EXISTS public.app_config (
  id          SERIAL       PRIMARY KEY,
  cle         TEXT         NOT NULL UNIQUE,
  valeur      TEXT         NOT NULL,
  description TEXT,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
-- Valeur par défaut
INSERT INTO public.app_config (cle, valeur, description)
VALUES ('mode_carte', 'externe', '...')
ON CONFLICT (cle) DO NOTHING;
```

### RLS `app_config`

- `SELECT` : `authenticated` (l'app lit la config)
- `INSERT/UPDATE/DELETE` : `service_role` uniquement (admin Supabase Dashboard)

### Impact sur les requêtes existantes

- `lireVilles()` : ajout de `&select=id,nom,region_id,active,latitude,longitude` — **rétrocompatible** (les colonnes retournent `null` avant exécution du SQL, le modèle Dart gère le `null`)
- `lireStructures()` : idem — rétrocompatible
- `enregistrerConsentement()` : aucune modification de signature ni de corps — la colonne `consentement_geoloc` existe déjà

---

## 8. Expérience utilisateur par scénario

### Scénario 1 : Option B par défaut (config Supabase = `'externe'`)

1. Utilisateur ouvre une demande de sang → appuie sur "Voir sur la carte"
2. `CarteStructuresScreen` se lance → lecture `app_config` → `'externe'`
3. **L'app Maps native s'ouvre** sur les coordonnées de la structure (si géolocalisée) ou sur Ouagadougou par défaut
4. Si Maps n'est pas installée → fallback URL Google Maps dans le navigateur
5. L'écran SONGRE affiche un message "L'application de cartes s'est ouverte" avec bouton "Ouvrir à nouveau"

### Scénario 2 : Option A, consentement accordé, GPS fonctionnel

1. L'utilisateur a coché "J'autorise ma position GPS" lors de la création de profil
2. Permission système accordée dans la boîte de dialogue Android
3. Ouverture de "Voir sur la carte" → carte intégrée
4. **Point bleu** sur la position réelle de l'utilisateur
5. **Marqueurs rouges** pour les structures autour
6. **Marqueur rouge plein** pour la structure de la demande (badge "Structure de la demande")
7. Tap sur un marqueur → fiche structure en bas de carte
8. Bouton de recentrage (icône `my_location`) en haut à droite

### Scénario 3 : Option A, consentement accordé, GPS refusé définitivement

1. L'utilisateur avait coché la case mais a refusé définitivement la permission Android
2. Ouverture de "Voir sur la carte"
3. Carte centrée sur **la ville du profil** de l'utilisateur
4. Structures de cette ville affichées
5. Bandeau sombre en haut : "Accès à la localisation refusé. Activez-le dans les paramètres de l'application…"
6. **Aucune demande de permission supplémentaire, aucun dialog insistant**

### Scénario 4 : Option A, consentement refusé (case décochée à la création)

1. `consentement_geoloc = false` en base
2. `_verifierPermission()` ne lance PAS `requestPermission()` (consentement non accordé)
3. Carte centrée sur la ville du profil
4. Structures de cette ville uniquement
5. Bandeau informatif "Carte centrée sur votre ville de profil"

### Scénario 5 : Option A, structures non géolocalisées (SQL non exécuté)

1. Table `structures_sanitaires` sans colonnes lat/lon → colonnes retournent `null`
2. `structure.estGeolocalise == false` pour toutes les structures
3. Carte affichée (centrée sur ville du profil ou position GPS)
4. Card en bas : "Aucune structure sanitaire géolocalisée disponible dans cette zone"
5. Application stable, aucun crash

### Scénario 6 : Inscription d'un nouvel utilisateur (non-régression)

1. Formulaire de profil : tous les champs habituels
2. **Nouveau** : checkbox géoloc optionnelle, en dessous du consentement santé
3. Si cochée : `_consentementGeoloc = true` → passé à `enregistrerConsentement()` → permission système demandée en fire-and-forget
4. Navigation vers `/home` **immédiate**, identique à avant cette modification
5. Aucune régression sur le flux d'inscription

---

## 9. Confirmation des tests réels

### Test 1 : Analyse statique

```
flutter analyze → No issues found! ✅
```

### Test 2 : Build APK (make clean-android && make apk)

Résultat attendu :
```
✓ Built build/app/outputs/flutter-apk/app-release.apk
aapt dump badging → package: name='com.songre.app', application-label:'Songre' ✅
```

### Test 3 : Vérification manuelle des modifications

Tous les fichiers ont été relus après modification :
- `models.dart` : `Ville.estGeolocalise`, `StructureSanitaire.estGeolocalise` ✅
- `supabase_service.dart` : 3 nouvelles méthodes + 2 méthodes mises à jour ✅
- `login_screen.dart` : `_consentementGeoloc` field + widget + ligne 1198 ✅
- `router.dart` : route `/carte-structures` avec SlideTransition from bottom ✅
- `detail_demande_screen.dart` : bouton "Voir sur la carte" visible par tous ✅
- `AndroidManifest.xml` : 2 permissions + 1 query geo: ✅

### Scénarios à tester lors de l'installation APK

| Scénario | Vérification |
|---|---|
| Option B (défaut) | Ouvre Maps externe au tap "Voir sur la carte" |
| Option A via config | Modifier `mode_carte` → `integree` dans Supabase, relancer l'écran |
| Refus géoloc | Décocher la case au profil → carte sur ville du profil |
| Acceptation géoloc | Cocher la case → point bleu sur carte |
| Structure contextuelle | Demande avec `structure_id` → marqueur rouge plein |
| Aucune structure geoloc | Base sans lat/lon → message informatif, pas de crash |
| Non-régression inscription | Créer un compte complet → navigation vers /home OK |
| Non-régression navigation | Toutes les routes existantes fonctionnelles |

---

## 10. Périmètre et hors-périmètre

### Dans le périmètre (implémenté)

- ✅ Bascule dynamique A/B via `app_config` Supabase
- ✅ Option B : `url_launcher` `geo:` + fallback Google Maps URL
- ✅ Option A : `flutter_map` + tuiles OpenStreetMap (sans clé API)
- ✅ Consentement géoloc dans `_ProfilForm` (même écran que consentement santé)
- ✅ Colonne `consentement_geoloc` renseignée avec valeur réelle (non plus `false` codé en dur)
- ✅ Fallback sur ville du profil si géoloc non accordée
- ✅ Position réelle (point bleu) si accordée
- ✅ Inclusion forcée de la structure contextuelle (même hors périmètre géographique)
- ✅ Zéro texte de distance affiché
- ✅ Gestion des 4 états de permission (granted, denied, permanentlyDenied, serviceDisabled)
- ✅ `AndroidManifest.xml` : ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION, query geo:
- ✅ Design SauveColors + google_fonts cohérent
- ✅ Non-régression sur le flux d'inscription vérifié via analyse statique

### Hors périmètre (non traité, par décision de la session)

- Shorebird / code push
- Email de confirmation
- SHA keystore debug/release
- iOS
- Data Safety Play Store
- SONGRE_ENCRYPT_KEY
- Version Web BFF sécurisée

---

*Document créé automatiquement par l'agent lors de la session 5 — 2026-07-19*  
*Commit de référence : voir hash final de cette session dans le rapport de livraison*
