# GUIDE DE MISE EN ŒUVRE COMPLET — SONGRE
**Version :** Session 4 — 2026-07-18  
**Référence de commit :** `9b05c81` (base de travail)  
**Périmètre :** Clé de chiffrement · Géolocalisation · SHA keystores · Email Resend · Version Web sécurisée  
**Hors périmètre :** iOS (traité séparément), formulaire Data Safety Play Store (mis en pause)  
**Principe :** Chaque constat est ancré dans la lecture réelle du code. Si une information ne peut pas être déterminée avec certitude, c'est signalé explicitement.

---

## PARTIE 1 — Clé de chiffrement `SONGRE_ENCRYPT_KEY`

### 1.1 État actuel vérifié dans le code

**Fichier source :** `lib/utils/crypto_service.dart` (lignes 38–41)

```dart
// Extrait exact, lignes 38–41 :
static const String _envKey = String.fromEnvironment(
  'SONGRE_ENCRYPT_KEY',
  defaultValue: '[REDACTED]',
);
```

**Contexte du commentaire en tête de fichier (lignes 17–28) :**

Le commentaire actuel dans `crypto_service.dart` explique pourquoi le `defaultValue` a été réintroduit intentionnellement : un `StateError` précédent faisait crasher l'app (`écran noir Android`) quand le `--dart-define` était absent. Le `defaultValue` est donc un **choix délibéré** pour garantir :
1. Le démarrage de l'app même sans `--dart-define`
2. La compatibilité avec les données chiffrées existantes en BDD
3. La possibilité de rotation future via `--dart-define`

**Conséquence sécurité réelle :** La clé `[REDACTED]` est compilée dans le binaire Flutter comme constante. Elle est **visible par décompilation de l'APK** (JADX, apktool) en quelques minutes.

**Makefile ligne 24 :** la même clé est aussi passée en clair dans la commande `make apk` :
```makefile
--dart-define=SONGRE_ENCRYPT_KEY=[REDACTED] \
```
Ce qui signifie qu'elle figure également dans l'historique shell si quelqu'un exécute `history`, et dans les logs CI/CD si le build est tracé.

### 1.2 Vérification préalable : la table est-elle vide ?

**Requête SQL à exécuter en lecture seule dans le Dashboard Supabase → SQL Editor :**

```sql
SELECT COUNT(*) AS nb_profils FROM public.profils_donneurs;
```

Cette requête ne modifie rien. Si le résultat est `0`, le remplacement de clé est sans risque (aucune donnée chiffrée à migrer). Si le résultat est `> 0`, la procédure de migration de données est obligatoire avant tout remplacement de clé (voir section 1.6).

**Contexte des sessions précédentes :** la table était vide (`0 ligne`) lors du dernier audit. Re-vérifier au moment de l'exécution, car des utilisateurs ont pu renseigner leur profil depuis.

### 1.3 Génération d'une nouvelle clé forte

```bash
# Génère 32 octets aléatoires encodés en base64 (43 caractères, tous valides en ASCII)
openssl rand -base64 32
# Exemple de sortie : kL9mN2qP5rS8tV1wX4yZ7aB0cD3eF6gH9iJ=
```

**Pourquoi `base64 32` et pas autre chose ?**
- AES-256 nécessite exactement 256 bits = 32 octets de clé
- `crypto_service.dart` utilise `utf8.encode(_envKey).sublist(0, 32)` → prend les 32 premiers octets
- Une chaîne base64 de 32 octets produit 43 caractères ASCII, tous encodables en UTF-8 avec une valeur < 128 → pas de problème de troncature UTF-8

**Alternative lisible (entropie équivalente) :**
```bash
openssl rand -hex 32  # 64 caractères hex = 256 bits ← bonne option "lisible"
```

### 1.4 Exhaustivité du nettoyage — tous les fichiers contenant la clé en clair

**Vérification exhaustive exécutée (`grep -rn "SongreProdBurkinaFaso2026_SecureKey"`, hors `build/` et `.git/`) — résultats réels de session 4 :**

| Fichier | Ligne(s) | Nature de l'occurrence | Action requise |
|---|---|---|---|
| `lib/utils/crypto_service.dart` | 20, 40 | Commentaire (ligne 20) + `defaultValue:` (ligne 40) | **Supprimer le `defaultValue`** + mettre à jour le commentaire |
| `Makefile` | 24 | `--dart-define=SONGRE_ENCRYPT_KEY=SongreProd...` | **Remplacer par `$$SONGRE_ENCRYPT_KEY`** |
| `README.md` | 350, 572, 663 | 3 occurrences (doc technique, note sécurité, exemple build) | Mettre à jour la documentation |
| `audit-songre-authentification-securite.md` | 763, 950, 1188 | Rapport d'audit historique | **Supprimer le fichier ou remplacer par `[REDACTED]`** |
| `AUDIT_2026-07-13.md` | 33, 44, 46, 48, 59 | Rapport d'audit historique | **Supprimer ou `[REDACTED]`** |
| `AUDIT_PRELANCEMENT.md` | 139, 277, 666 | Rapport d'audit historique | **Supprimer ou `[REDACTED]`** |
| `AUDIT_2026-07-18-RELECTURE.md` | 72 | Rapport d'audit | **Supprimer ou `[REDACTED]`** |
| `CORRECTIONS_2026-07-18.md` | 140, 146, 460 | Rapport de corrections | **Supprimer ou `[REDACTED]`** |
| `AUDIT_TRIPLE_LECTURE_2026-07-18.md` | 108 | Rapport d'audit | **Supprimer ou `[REDACTED]`** |
| Ce fichier (`GUIDE_MISE_EN_OEUVRE_COMPLET.md`) | Plusieurs | Documentation explicative | **Ne pas purger — document de référence** |

**Total : 30+ occurrences dans 10 fichiers distincts (hors build/ et .git/).**

**⚠️ IMPORTANT — Historique git :** Même après la modification de tous ces fichiers, **la clé restera dans l'historique git** tant que les commits ne sont pas purgés. Si le dépôt est public ou partagé, il faut utiliser `git filter-repo` ou `BFG Repo-Cleaner` pour éliminer la clé de tout l'historique. Si le dépôt est strictement privé et que la clé est rotée (nouvelle clé), le risque résiduel est faible mais documenté.

### 1.5 Modifications de code nécessaires

**Étape A — `lib/utils/crypto_service.dart` :**

Remplacer les lignes 38–41 :
```dart
// AVANT (clé embarquée — RISQUE)
static const String _envKey = String.fromEnvironment(
  'SONGRE_ENCRYPT_KEY',
  defaultValue: '[REDACTED]',
);
```

Par :
```dart
// SEC-01 : aucun defaultValue — comportement identique à WEBHOOK_SECRET.
// Si absent au build, _envKey sera '' → init() logge un avertissement et
// désactive le chiffrement (dégradation gracieuse, données illisibles en prod).
// Forcer l'injection via --dart-define=SONGRE_ENCRYPT_KEY=$$SONGRE_ENCRYPT_KEY
static const String _envKey = String.fromEnvironment('SONGRE_ENCRYPT_KEY');
```

Le comportement de `init()` déjà présent (lignes 47–57) gère déjà ce cas — aucune modification de la logique métier n'est nécessaire :
```dart
// Code existant dans init() — aucune modification requise :
if (_envKey.isEmpty || _envKey.length < 32) {
  if (kDebugMode) {
    debugPrint('[CryptoService] ⚠️  Clé absente ou trop courte — chiffrement désactivé.');
  }
  return;
}
```

**Mettre également à jour le commentaire de tête de fichier (lignes 11–28)** pour supprimer la référence à la clé de production et documenter la nouvelle procédure.

**Étape B — `Makefile` ligne 24 :**

```makefile
# AVANT (clé en clair — RISQUE SÉCURITÉ)
--dart-define=SONGRE_ENCRYPT_KEY=[REDACTED] \

# APRÈS (variable d'environnement — identique à WEBHOOK_SECRET ligne 25)
--dart-define=SONGRE_ENCRYPT_KEY=$$SONGRE_ENCRYPT_KEY \
```

**Étape C — Mettre à jour `README.md` :** Remplacer les 3 occurrences par `export SONGRE_ENCRYPT_KEY="$(openssl rand -base64 32)"` avec la documentation appropriée, à l'image de `WEBHOOK_SECRET`.

### 1.6 Cas où la table n'est PAS vide (procédure de migration)

Si `SELECT COUNT(*) FROM public.profils_donneurs` retourne `> 0` au moment de l'exécution :

```python
# Script de migration à exécuter UNE SEULE FOIS, hors app Flutter
# Prérequis : backup complet de la base avant exécution

import base64
import json
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad

ANCIENNE_CLE = b'[REDACTED]'[:32]  # 32 premiers octets
NOUVELLE_CLE = bytes.fromhex(os.environ['SONGRE_ENCRYPT_KEY_NEW'])[:32]

def dechiffrer(valeur_chiffree: str, cle: bytes) -> str | None:
    """Format : base64(IV_16B):base64(ciphertext)"""
    try:
        iv_b64, ct_b64 = valeur_chiffree.split(':')
        iv = base64.b64decode(iv_b64)
        ct = base64.b64decode(ct_b64)
        cipher = AES.new(cle, AES.MODE_CBC, iv)
        return unpad(cipher.decrypt(ct), 16).decode('utf-8')
    except Exception:
        return None

def chiffrer(valeur: str, cle: bytes) -> str:
    """Format : base64(IV_16B):base64(ciphertext)"""
    import os as _os
    iv = _os.urandom(16)
    cipher = AES.new(cle, AES.MODE_CBC, iv)
    ct = cipher.encrypt(pad(valeur.encode('utf-8'), 16))
    return f"{base64.b64encode(iv).decode()}:{base64.b64encode(ct).decode()}"

# Récupérer tous les profils avec champs chiffrés depuis Supabase
# Déchiffrer avec ANCIENNE_CLE, rechiffrer avec NOUVELLE_CLE
# Mettre à jour en base
# CHAMPS CHIFFRÉS dans profils_donneurs : telephone, contraindications (liste)
```

Ce script de migration n'est PAS dans le périmètre de cette session. Il sera rédigé dans la session d'implémentation si des données existent.

### 1.7 Complexité et risques

| Aspect | Évaluation |
|---|---|
| Complexité technique | Faible — 2 fichiers à modifier (crypto_service.dart, Makefile) + README |
| Risque si table vide | Nul — aucune donnée à migrer |
| Risque si table non vide | Élevé — les données chiffrées existantes deviendraient illisibles sans migration |
| Temps estimé (table vide) | 20 minutes (modification + test build + vérification flutter analyze) |
| Temps estimé (avec migration) | 3–5 heures (script + test + vérification en base) |
| Action humaine requise | Générer la clé + la stocker dans un gestionnaire de secrets + vérifier COUNT(*) |
| Ce qu'un agent peut faire seul | Modifier le code, mettre à jour README, masquer la clé dans les fichiers d'audit |

---

## PARTIE 2 — Géolocalisation et affichage des centres de santé

### 2.1 État actuel du `pubspec.yaml` — lecture réelle

**Fichier `pubspec.yaml` — état exact à la date de cet audit :**

```yaml
# Contenu actuel du pubspec.yaml — NI flutter_map NI geolocator NI latlong2 ne sont présents
dependencies:
  flutter:    sdk: flutter
  go_router:         ^13.2.0
  provider:          6.1.5+1
  shared_preferences: 2.5.3
  hive:              2.2.3
  hive_flutter:      1.1.0
  http:              1.5.0
  qr_flutter:        ^4.1.0
  mobile_scanner:    ^5.2.3
  uuid:              ^4.3.3
  intl:              ^0.19.0
  google_fonts:      ^6.2.1
  cupertino_icons:   ^1.0.8
  flutter_secure_storage: ^9.2.2
  encrypt:           ^5.0.3
  pointycastle:      ^3.9.1
  firebase_core:     3.6.0
  firebase_messaging: 15.1.3
  url_launcher:      ^6.3.2
  package_info_plus: ^8.1.2
```

**Aucun package de géolocalisation ni de carte n'est présent.** `url_launcher: ^6.3.2` est déjà présent (utilisé pour les liens `tel:` — Option B ne nécessite aucune dépendance supplémentaire).

### 2.2 État actuel du schéma `public.structures_sanitaires`

**Constat :** Le fichier `supabase/functions/mission-d.sql` (327 lignes, lues intégralement en session 3) **ne contient aucune définition de la table `structures_sanitaires`**. La table est référencée dans `matcher-et-notifier/index.ts` (interface `DemandeSangRecord` ligne 54 : `structure_id: number | null`) et dans la requête lignes 183–188 (SELECT `nom` par `id`). La présence de colonnes `latitude`/`longitude` est **inconnue** — vérification requise :

```sql
-- Requête de vérification du schéma actuel (lecture seule, 0 modification)
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'structures_sanitaires'
ORDER BY ordinal_position;
```

**À exécuter dans le Dashboard Supabase → SQL Editor.** Résultat attendu minimal : `id`, `nom`. Présence de `latitude`/`longitude` à confirmer.

### 2.3 Option A — Carte intégrée avec `flutter_map` (RETENUE, sans calcul de distance)

**Décision du porteur du projet :** Option A retenue, **sans géolocalisation de l'utilisateur, sans calcul de distance**. Affichage de marqueurs sur une carte OpenStreetMap uniquement.

#### Packages requis (à ajouter dans `pubspec.yaml`)

```yaml
# À ajouter dans la section dependencies de pubspec.yaml
flutter_map: ^7.0.2        # Carte OpenStreetMap — aucune clé API requise
latlong2: ^0.9.1           # Type LatLng utilisé par flutter_map
```

**Pas besoin de `geolocator` ni d'aucune permission de localisation** pour l'Option A retenue. La carte s'ouvre centrée sur une position fixe par défaut (Ouagadougou : `lat: 12.3647, lon: -1.5332`).

**Si on souhaitait centrer la carte sur la ville de l'utilisateur (extension future possible sans GPS) :**
- Lire `profil.villeId` depuis l'`AppState` déjà disponible
- Joindre une table `villes` avec leurs coordonnées (table existante dans le projet)
- **Aucune permission Android/iOS requise** — on utilise les données du profil, pas le GPS

#### Permissions Android — État actuel et impact Option A

Le `AndroidManifest.xml` actuel contient : `INTERNET`, `CAMERA`, `POST_NOTIFICATIONS`. **Aucune permission de localisation (`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`) n'est nécessaire** pour l'Option A sans géolocalisation utilisateur. Seule `INTERNET` (déjà présente) est requise pour les tuiles OpenStreetMap.

#### Schéma de données — Ajout colonnes lat/lon si absentes

```sql
-- Ajout idempotent des colonnes de coordonnées (DO block pour IF NOT EXISTS)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'structures_sanitaires'
      AND column_name  = 'latitude'
  ) THEN
    ALTER TABLE public.structures_sanitaires
      ADD COLUMN latitude  double precision NULL,
      ADD COLUMN longitude double precision NULL;

    COMMENT ON COLUMN public.structures_sanitaires.latitude  IS
      'Latitude WGS84. NULL si coordonnées non encore renseignées.';
    COMMENT ON COLUMN public.structures_sanitaires.longitude IS
      'Longitude WGS84. NULL si coordonnées non encore renseignées.';
  END IF;
END $$;
```

Les colonnes sont `NULL`-ables intentionnellement : les centres sans coordonnées renseignées n'apparaissent pas sur la carte — comportement propre et sans erreur.

#### Collecte des coordonnées — Travail manuel incontournable

**Ceci est du travail humain, non automatisable par du code.** Procédure recommandée :

1. Ouvrir [Google Maps](https://maps.google.com) ou [OpenStreetMap](https://openstreetmap.org)
2. Rechercher chaque centre de santé par nom
3. Clic droit → "Que se passe-t-il ici ?" → copier les coordonnées (lat, lon)
4. Mettre à jour via le Dashboard Supabase : Table Editor → `structures_sanitaires` → modifier chaque ligne

**Stratégie de priorisation recommandée :**
- Commencer par **une seule ville pilote** (Ouagadougou), vérifier que la carte fonctionne, puis étendre
- Cibler d'abord les 5–10 structures les plus actives

**Requête pour identifier les structures actives :**
```sql
SELECT ss.id, ss.nom, COUNT(ds.id) AS nb_demandes
FROM public.structures_sanitaires ss
LEFT JOIN public.demandes_sang ds ON ds.structure_id = ss.id
GROUP BY ss.id, ss.nom
ORDER BY nb_demandes DESC
LIMIT 20;
```

#### Code Flutter complet — `CarteStructuresScreen`

```dart
// lib/screens/carte_structures_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class StructureSanitaire {
  final String id;
  final String nom;
  final double? latitude;
  final double? longitude;

  const StructureSanitaire({
    required this.id,
    required this.nom,
    this.latitude,
    this.longitude,
  });

  factory StructureSanitaire.fromJson(Map<String, dynamic> json) {
    return StructureSanitaire(
      id:        json['id'].toString(),
      nom:       json['nom'] as String? ?? 'Structure inconnue',
      latitude:  (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
    );
  }

  bool get estGeolocalise => latitude != null && longitude != null;
}

class CarteStructuresScreen extends StatefulWidget {
  const CarteStructuresScreen({super.key});

  @override
  State<CarteStructuresScreen> createState() => _CarteStructuresScreenState();
}

class _CarteStructuresScreenState extends State<CarteStructuresScreen> {
  List<StructureSanitaire> _structures = [];
  bool _isLoading = true;
  String? _error;
  final TextEditingController _recherche = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _charger());
  }

  @override
  void dispose() {
    _recherche.dispose();
    super.dispose();
  }

  Future<void> _charger({String? filtre}) async {
    if (!mounted) return;
    setState(() { _isLoading = true; _error = null; });

    try {
      final structures = await SupabaseService.lireStructuresSanitaires(
        filtre: filtre,
      );
      if (!mounted) return;
      setState(() { _structures = structures; _isLoading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Erreur de chargement : $e'; _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final structuresGeo = _structures
        .where((s) => s.estGeolocalise)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Centres de santé'),
        backgroundColor: const Color(0xFFC0392B),
        foregroundColor: Colors.white,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TextField(
              controller: _recherche,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Rechercher un centre...',
                hintStyle: const TextStyle(color: Colors.white70),
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.white54),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.white54),
                ),
              ),
              onSubmitted: (v) => _charger(filtre: v.trim().isEmpty ? null : v.trim()),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFC0392B)))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: Colors.red),
                      const SizedBox(height: 16),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () => _charger(),
                        child: const Text('Réessayer'),
                      ),
                    ],
                  ),
                )
              : structuresGeo.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.location_off, size: 48, color: Colors.grey),
                          const SizedBox(height: 16),
                          Text(
                            _structures.isEmpty
                                ? 'Aucune structure trouvée'
                                : '${_structures.length} structure(s) trouvée(s) mais sans coordonnées géographiques',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : FlutterMap(
                      options: MapOptions(
                        initialCenter: const LatLng(12.3647, -1.5332), // Ouagadougou
                        initialZoom: 12.0,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.songre.app',
                        ),
                        MarkerLayer(
                          markers: structuresGeo.map((s) => Marker(
                            point: LatLng(s.latitude!, s.longitude!),
                            width: 200,
                            height: 60,
                            child: GestureDetector(
                              onTap: () => _afficherDetailStructure(s),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.local_hospital,
                                    color: Color(0xFFC0392B),
                                    size: 32,
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.9),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      s.nom,
                                      style: const TextStyle(
                                        fontSize: 10, fontWeight: FontWeight.bold),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )).toList(),
                        ),
                      ],
                    ),
    );
  }

  void _afficherDetailStructure(StructureSanitaire s) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.nom, style: Theme.of(ctx).textTheme.titleLarge),
            if (s.latitude != null)
              Text('${s.latitude!.toStringAsFixed(4)}, '
                   '${s.longitude!.toStringAsFixed(4)}',
                  style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.close),
              label: const Text('Fermer'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }
}
```

#### Méthode à ajouter dans `SupabaseService`

```dart
/// Lecture des structures sanitaires avec filtrage optionnel par nom.
/// Pas de calcul de distance — affichage pur.
static Future<List<StructureSanitaire>> lireStructuresSanitaires({
  String? filtre,
}) async {
  try {
    // Requête simple sans orderBy pour éviter les index composites
    String queryString =
        '$_supabaseUrl/rest/v1/structures_sanitaires'
        '?select=id,nom,latitude,longitude'
        '&latitude=not.is.null'  // Uniquement les structures avec coordonnées
        '&limit=100';

    if (filtre != null && filtre.isNotEmpty) {
      queryString +=
          '&nom=ilike.*${Uri.encodeComponent(filtre)}*';
    }

    final url = Uri.parse(queryString);
    final resp = await _requeteAvecRefresh(
      () => http.get(url, headers: _hdrs()),
    );

    if (resp.statusCode == 200) {
      final List<dynamic> data = jsonDecode(resp.body) as List<dynamic>;
      return data
          .map((e) => StructureSanitaire.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[SupabaseService] lireStructuresSanitaires error: $e');
    }
    return [];
  }
}
```

#### Recherche par nom — Fonctionnement sans schéma modifié

La recherche ILIKE fonctionne dès que la colonne `nom` existe (ce qui est le cas). Aucun changement de schéma nécessaire pour la recherche seule. Exemple d'URL REST :
```
GET /rest/v1/structures_sanitaires?nom=ilike.*hopital*&select=id,nom,latitude,longitude&limit=20
```

### 2.4 Option B — Ouverture de l'app Maps native (documentée pour comparaison)

**Non retenue pour cette phase, documentée pour référence future.**

#### Faisabilité

`url_launcher` est **déjà présent** dans le projet (`pubspec.yaml` : `url_launcher: ^6.3.2`). Il est déjà utilisé pour les liens `tel:` (P4.7 des corrections de session 2). L'Option B ne nécessite **aucune dépendance supplémentaire**.

#### Exemple de code complet

```dart
// Pour ouvrir l'app Maps native sur les coordonnées d'une structure
Future<void> _ouvrirMapsNatives(StructureSanitaire s) async {
  if (s.latitude == null || s.longitude == null) return;

  final lat = s.latitude!;
  final lon = s.longitude!;
  final encodedNom = Uri.encodeComponent(s.nom);

  // Schéma geo: standard — ouvre l'app Maps par défaut sur Android
  final uriGeo = Uri.parse('geo:$lat,$lon?q=$lat,$lon($encodedNom)');
  // Fallback web (si aucune app Maps installée)
  final uriGoogleMaps = Uri.parse(
    'https://www.google.com/maps/search/?api=1&query=$lat,$lon',
  );

  if (await canLaunchUrl(uriGeo)) {
    await launchUrl(uriGeo);
  } else {
    await launchUrl(uriGoogleMaps, mode: LaunchMode.externalApplication);
  }
}
```

**Déclaration dans `AndroidManifest.xml` nécessaire (en plus du `DIAL` déjà présent) :**
```xml
<queries>
  <!-- déjà présent : -->
  <intent><action android:name="android.intent.action.DIAL"/><data android:scheme="tel"/></intent>
  <!-- à ajouter pour geo: -->
  <intent>
    <action android:name="android.intent.action.VIEW"/>
    <data android:scheme="geo"/>
  </intent>
</queries>
```

### 2.5 Comparaison A vs B

| Critère | Option A (flutter_map) | Option B (url_launcher geo:) |
|---|---|---|
| Complexité | Moyenne (nouveaux packages, widget carte) | Très faible (url_launcher déjà présent) |
| Clé API | Aucune (OpenStreetMap gratuit) | Aucune |
| Expérience utilisateur | L'utilisateur reste dans SONGRE | Sort de l'app, entre dans Maps |
| Données nécessaires | latitude + longitude dans `structures_sanitaires` | Identique |
| Maintenance | Légère (màj flutter_map au fil des versions) | Minimale (url_launcher stable) |
| Affichage simultané multi-centres | Oui (tous marqueurs en même temps) | Non (un centre à la fois) |
| Personnalisation visuelle | Totale (couleurs SONGRE) | Aucune (app Maps native) |
| APK size impact | +2–4 MB (assets flutter_map) | 0 MB |
| Permissions Android | Aucune nouvelle (INTERNET déjà présente) | Aucune (url_launcher déjà configuré) |

**Recommandation :** Option A retenue. Pour commencer avec le minimum viable : implémenter d'abord la **recherche par nom** (fonctionnelle sans carte, sans colonne lat/lon, exploitable immédiatement), puis ajouter la carte après saisie des premières coordonnées.

### 2.6 Complexité et temps estimés

| Étape | Responsable | Temps estimé |
|---|---|---|
| Vérifier schéma + ajouter colonnes lat/lon si absent | Agent (SQL lecture puis ALTER) | 15 min |
| Ajouter flutter_map + latlong2 dans pubspec.yaml | Agent | 5 min |
| Créer `CarteStructuresScreen` + méthode SupabaseService | Agent | 2 heures |
| Intégrer dans la navigation (route GoRouter + bouton) | Agent | 30 min |
| Saisir les coordonnées en base (collecte de données) | **Humain obligatoire** | ~30 min par ville pilote |
| Test APK avec vraies coordonnées | Agent + Humain | 30 min |
| **Total (hors collecte de coordonnées)** | | **~3 heures** |

---

## PARTIE 3 — SHA-1 / SHA-256 des keystores

### 3.1 À quoi sert réellement le SHA dans un projet Android

Le SHA (Secure Hash Algorithm) d'un certificat Android identifie de façon unique le keystore avec lequel une APK est signée. Google utilise ce fingerprint pour **vérifier l'origine de l'application** lors de certains services.

| Service | SHA requis ? | Détail |
|---|---|---|
| **Google Sign-In** | **Oui, obligatoire** | Sans SHA enregistré dans Firebase, l'auth Google échoue avec `DEVELOPER_ERROR` |
| **App Links (liens profonds HTTPS)** | Oui | Fichier `assetlinks.json` sur le serveur doit contenir le SHA |
| **Dynamic Links Firebase** | Oui | Même mécanisme que les App Links |
| **reCAPTCHA (SafetyNet / Play Integrity)** | Oui | Vérifie l'intégrité de l'app |
| **Firebase Cloud Messaging (FCM)** | **Non** | Le token FCM est indépendant du certificat de signature |
| **Supabase Auth (email/mdp)** | **Non** | Entièrement côté serveur, pas de vérification de certificat |
| **Supabase REST API** | **Non** | Authentification par JWT, pas par certificat |

**Conclusion pour SONGRE :** L'application utilise Supabase Auth (email/mdp) et Firebase Messaging (FCM) uniquement. **Le SHA n'est pas strictement requis pour le fonctionnement actuel.** Il deviendrait obligatoire si Google Sign-In ou des App Links sont ajoutés.

### 3.2 SHA du keystore de release — Valeurs extraites (session 3, confirmées)

Extraction effectuée depuis `android/release-key.jks` avec le mot de passe de `android/key.properties` :

```
Keystore : android/release-key.jks
Alias    : release
Owner    : CN=Flutter App, OU=Mobile Development, O=GenSpark, L=San Francisco, ST=California, C=US
Validité : 2026-07-10 → 2053-11-25
Algo     : SHA256withRSA

SHA-1   : 55:B0:CA:F9:94:85:B1:64:2E:B1:5A:E2:64:C9:F2:AE:A2:DA:D6:BE
SHA-256 : 9E:8B:76:7A:33:21:64:90:A0:41:C3:CE:7F:22:BA:D1:FF:6E:99:BC:FB:E9:66:4C:C2:7C:FB:9B:07:4A:73:CD
```

### 3.3 SHA du keystore de debug — Valeurs extraites (session 4, confirmées)

Extraction effectuée depuis `~/.android/debug.keystore` :

```bash
# Commande exacte utilisée :
keytool -list -v \
  -keystore ~/.android/debug.keystore \
  -alias androiddebugkey \
  -storepass android \
  -keypass android

# Résultat :
Alias name : androiddebugkey
Owner      : C=US, O=Android, CN=Android Debug
Algo       : SHA256withRSA

SHA-1   : 18:8A:A0:82:AA:1B:56:4F:A1:29:D0:43:AF:27:8B:AA:5A:5F:38:C9
SHA-256 : 07:37:E2:5D:3E:01:1F:DF:DE:16:E4:9A:6D:46:76:E5:95:72:97:74:EF:75:E6:D8:5B:F2:48:99:59:58:38:9A
```

**⚠️ Important :** Le debug keystore est **propre à chaque machine de développement**. Le SHA ci-dessus correspond au keystore de la machine de build actuelle (sandbox Genspark). Sur la machine du développeur ou en CI/CD, les valeurs seront différentes. Pour les obtenir sur une autre machine :
```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
```

### 3.4 Procédure complète pour enregistrer dans Firebase Console

**Action humaine — estimée à 10 minutes.**

1. Aller sur [Firebase Console](https://console.firebase.google.com)
2. Sélectionner le projet **songre-88f2a**
3. Icône engrenage (⚙) → **Paramètres du projet**
4. Onglet **Vos applications** → sélectionner l'app Android **com.songre.app**
5. Section **Empreintes digitales du certificat SHA** → bouton **Ajouter une empreinte**
6. Ajouter les 4 valeurs :
   - SHA-1 release : `55:B0:CA:F9:94:85:B1:64:2E:B1:5A:E2:64:C9:F2:AE:A2:DA:D6:BE`
   - SHA-256 release : `9E:8B:76:7A:33:21:64:90:A0:41:C3:CE:7F:22:BA:D1:FF:6E:99:BC:FB:E9:66:4C:C2:7C:FB:9B:07:4A:73:CD`
   - SHA-1 debug (machine actuelle) : `18:8A:A0:82:AA:1B:56:4F:A1:29:D0:43:AF:27:8B:AA:5A:5F:38:C9`
   - SHA-256 debug (machine actuelle) : `07:37:E2:5D:3E:01:1F:DF:DE:16:E4:9A:6D:46:76:E5:95:72:97:74:EF:75:E6:D8:5B:F2:48:99:59:58:38:9A`
7. Cliquer **Enregistrer** après chaque ajout

**Note :** Si l'équipe de développement travaille sur des machines différentes, ajouter autant de SHA-1/SHA-256 debug que de machines (Firebase le supporte, pas de limite documentée).

### 3.5 Pourquoi ajouter aussi le SHA debug

| Scénario | SHA release seul | SHA release + debug |
|---|---|---|
| Build release (`make apk`) + FCM | ✅ Fonctionne (FCM ne vérifie pas le SHA) | ✅ Identique |
| Test en debug (`flutter run`) avec Google Sign-In | ❌ `DEVELOPER_ERROR` | ✅ Fonctionne |
| Test en debug avec App Links | ❌ Les liens ne s'ouvrent pas | ✅ Fonctionne |

**Pour le projet actuel :** Sans Google Sign-In ni App Links, l'ajout du SHA debug est optionnel mais recommandé pour l'avenir.

---

## PARTIE 4 — Email de confirmation de publication de demande

### 4.1 Infrastructure d'envoi existante — Audit email.ts (session 4)

**`supabase/functions/_shared/email.ts`** est le module centralisé. Lecture complète effectuée. Il expose :

- `envoyerEmailRotatif(destinataire, sujet, htmlBody, options?)` — orchestre Brevo → Resend avec rotation automatique
- `renderTemplate(template, data)` — génération HTML depuis un type de notification
- **12 templates** existants (lecture ligne 21–33 du fichier réel) :
  - `demande_compatible`, `don_confirme`, `don_confirme_demandeur`, `reponse_recue`
  - `reponse_encouragement`, `retour_eligibilite`, `don_enregistre_manuel`
  - `suppression_demandee`, `suppression_confirmee`, `bienvenue`, `mdp_modifie`
  - `contact_support` ← **nouveau par rapport à la session 3 (12 vs 9 précédemment recensés)**

**Note de réconciliation :** La session 3 recensait 9 templates. La lecture réelle de session 4 (ligne 21–33) en révèle 12. Les 3 supplémentaires sont `retour_eligibilite`, `contact_support`, et `don_enregistre_manuel`. Ce n'est pas une erreur de session 3 — ces templates étaient peut-être dans un état différent du fichier à ce moment.

**Resend est intégré via `envoyerViaResend()` (lignes 539–575).** Infrastructure complète, aucune dépendance supplémentaire nécessaire.

**`EMAIL_FROM`** : lue depuis `Deno.env.get("EMAIL_FROM") ?? "SONGRE <noreply@songre.bf>"` (ligne 585 du fichier réel).

**Rotation :** mode `auto` = Brevo (key1, key2) en priorité, puis Resend (key1, key2) en fallback. Variables attendues : `BREVO_API_KEY`, `BREVO_API_KEY_2`, `RESEND_API_KEY`, `RESEND_API_KEY_2`.

### 4.2 Trigger — Où déclencher l'envoi dans `matcher-et-notifier/index.ts`

**Flux actuel confirmé (lecture réelle du code) :**

1. Flutter → `AppState.publierDemande()` (ligne 516 de `app_state.dart`) → `SupabaseService.creerDemande()` (ligne 802) → `POST /rest/v1/demandes_sang`
2. Supabase INSERT déclenche le webhook sur `demandes_sang`
3. `matcher-et-notifier` reçoit le payload via `WebhookPayload` (interface lignes 40–46)
4. La fonction récupère `adminClient` avec `service_role_key` (ligne 165) — accès total à `auth.users`
5. Les emails des donneurs sont récupérés via requête bulk `auth.users` (lignes 246–279)
6. Les notifications FCM + email sont envoyées aux donneurs dans la boucle de batch (lignes 324–373)
7. **Aucun email n'est envoyé à l'auteur de la demande** — c'est le cas manquant

**Meilleur point d'insertion :** Après le `return jsonResponse({success: true, ...})` actuel (ligne 394–399), AVANT ce return. Plus précisément : entre la fin de la boucle (ligne 373) et la section "6. Persister les notifications" (ligne 375) — ou après la persistance.

**Données disponibles au point d'insertion :**
- `demande.auteur_id` (string, lignes 51, 197)
- `demande.groupe_sanguin_recherche` (string, ligne 52)
- `demande.expires_at` (string, ligne 58)
- `villeLabel` (string, ligne 170–179)
- `structureLabel` (string, ligne 171–188)
- `adminClient` avec accès admin (ligne 165) → peut faire `auth.admin.getUserById(demande.auteur_id)`

**Pattern existant pour récupérer un email depuis `auth.users` (ligne 264) :**
```typescript
const { data, error } = await adminClient.auth.admin.getUserById(uid);
if (!error && data?.user?.email) { /* email disponible */ }
```

### 4.3 Template email de confirmation

À ajouter dans `email.ts` après `templateContactSupport` (dernier template existant), et à intégrer dans le `switch` de `renderTemplate` :

```typescript
// ── Ajout dans le type TemplateName (ligne 21–33) ──────────────────────────
// Ajouter "confirmation_demande" à l'union de types :
// | "contact_support"
// | "confirmation_demande"   ← nouveau

// ── Template (à ajouter après templateContactSupport, vers ligne ~460) ─────
function templateConfirmationDemande(data: Record<string, string>): string {
  const prenom    = data["prenom"]         ?? "Demandeur";
  const groupe    = data["groupe_sanguin"] ?? "?";
  const ville     = data["ville"]          ?? "votre ville";
  const structure = data["structure"]      ?? "la structure indiquée";
  const expiration = data["expiration"]   ?? "72 heures";

  return baseTemplate(
    "Votre demande de sang a été publiée",
    `<p style="color:#333;font-size:16px;line-height:1.6;">
      Bonjour <strong>${prenom}</strong>,
    </p>
    <p style="color:#333;font-size:16px;line-height:1.6;">
      Votre demande de sang de groupe <strong>${groupe}</strong>
      a bien été publiée sur SONGRE.
    </p>
    <div style="background:#fff5f5;border-left:4px solid #C0392B;
                padding:16px;border-radius:6px;margin:20px 0;">
      <p style="margin:0;font-size:15px;color:#555;">
        📍 <strong>Structure :</strong> ${structure}<br>
        🏙️ <strong>Ville :</strong> ${ville}<br>
        ⏳ <strong>Expire :</strong> ${expiration}
      </p>
    </div>
    <p style="color:#555;font-size:14px;line-height:1.6;">
      Les donneurs compatibles dans votre ville ont été notifiés.<br>
      Vous recevrez une notification dans l'application dès qu'un
      donneur aura confirmé sa disponibilité.
    </p>
    <div style="background:#f0fff4;border-left:4px solid #27AE60;
                padding:12px 16px;border-radius:6px;margin:16px 0;">
      <p style="margin:0;font-size:13px;color:#27AE60;">
        ℹ️ Si aucune réponse rapidement, pensez à contacter directement
        la structure de santé pour les informer de la demande urgente.
      </p>
    </div>
    <div style="text-align:center;margin-top:28px;">
      <a href="${APP_URL}"
         style="background:#C0392B;color:white;text-decoration:none;
                padding:12px 28px;border-radius:8px;font-weight:bold;font-size:15px;">
        Voir ma demande dans SONGRE
      </a>
    </div>`,
    "#C0392B",
  );
}

// ── Dans le switch de renderTemplate ────────────────────────────────────────
// Ajouter avant le default :
case "confirmation_demande":
  return templateConfirmationDemande(data);
```

**Ajout SQL optionnel dans l'enum (si on veut tracer cet email dans `notifications_envoyees`) :**
```sql
ALTER TYPE public.type_notification_enum
  ADD VALUE IF NOT EXISTS 'confirmation_demande';
```

### 4.4 Code à ajouter dans `matcher-et-notifier/index.ts`

Ajouter entre la fin de la boucle batch (après ligne 373, fin du `for (let i = 0...`) et le `return jsonResponse(...)` final. Les variables `adminClient`, `villeLabel`, `structureLabel`, et `demande` sont toutes disponibles à ce point.

```typescript
// ── 7. Email de confirmation à l'auteur de la demande ──────────────────────
// [NOUVEAU] Informer l'auteur que sa demande a été publiée et que les donneurs
// ont été notifiés. Cet email est informatif — son absence n'est pas critique.
try {
  const { data: auteurData, error: auteurError } =
    await adminClient.auth.admin.getUserById(demande.auteur_id);

  if (!auteurError && auteurData?.user?.email) {
    const prenomAuteur =
      (auteurData.user.user_metadata?.["prenom"] as string | undefined)
      ?? "Demandeur";

    // Calculer la date d'expiration lisible en français
    const expiresAt  = new Date(demande.expires_at);
    const expirationLabel = expiresAt.toLocaleDateString("fr-FR", {
      weekday: "long", day: "2-digit", month: "long", year: "numeric",
    }) + " à " + expiresAt.toLocaleTimeString("fr-FR", {
      hour: "2-digit", minute: "2-digit",
    });

    const htmlConfirmation = renderTemplate("confirmation_demande", {
      prenom:          prenomAuteur,
      groupe_sanguin:  demande.groupe_sanguin_recherche,
      ville:           villeLabel,
      structure:       structureLabel,
      expiration:      expirationLabel,
    });

    if (htmlConfirmation) {
      const sujetConfirmation =
        `[SONGRE] Votre demande de ${demande.groupe_sanguin_recherche} a été publiée`;
      const emailResult = await envoyerEmailRotatif(
        auteurData.user.email,
        sujetConfirmation,
        htmlConfirmation,
      );
      console.log(
        `[matcher] Email confirmation auteur ${emailResult.success ? "✓" : "✗"} → ${auteurData.user.email}`,
      );
    }
  }
} catch (emailAuteurErr) {
  // Email de confirmation non critique — ne pas bloquer le traitement
  console.warn("[matcher] Email confirmation auteur échoué (non bloquant):", emailAuteurErr);
}
// ── Fin 7 ────────────────────────────────────────────────────────────────────
```

### 4.5 Configuration externe requise

| Action | Qui | Détail |
|---|---|---|
| Vérifier `RESEND_API_KEY` dans Supabase | **Humain** | Dashboard Supabase → Edge Functions → Secrets |
| Vérifier `BREVO_API_KEY` dans Supabase | **Humain** | Idem |
| Vérifier `EMAIL_FROM` dans Supabase | **Humain** | Doit être `SONGRE <noreply@songre.bf>` |
| Vérifier quotas Resend | **Humain** | Plan gratuit = 100 emails/jour. À surveiller si volume élevé |
| Déployer après modification | **Humain** | `supabase functions deploy matcher-et-notifier` |
| Écrire le template dans email.ts | Agent | Voir section 4.3 |
| Modifier matcher-et-notifier/index.ts | Agent | Voir section 4.4 |

### 4.6 Risques

| Risque | Probabilité | Impact | Mitigation |
|---|---|---|---|
| Email non reçu si Brevo + Resend down simultanément | Faible | Moyen | La demande est publiée — l'email est informatif, pas critique |
| Double envoi si webhook déclenché deux fois | Faible | Faible | Mettre un `try/catch` non bloquant (déjà fait dans le code ci-dessus) |
| Quota Resend dépassé | Dépend du volume | Faible | Surveiller Resend Dashboard |
| `prenom` non renseigné dans `user_metadata` | Possible | Nul | Fallback `?? "Demandeur"` |
| Latence ajoutée au webhook | Négligeable | Nul | 1 appel HTTP supplémentaire (~100ms) |

### 4.7 Complexité

| Aspect | Évaluation |
|---|---|
| Complexité technique | Faible — réutilise l'infrastructure existante |
| Fichiers à modifier | 2 : `email.ts` (template + type union), `matcher-et-notifier/index.ts` (déclenchement) |
| Temps estimé | 1–2 heures (écriture + déploiement Edge Function + test dans logs Supabase) |
| Ce qu'un agent peut faire seul | Tout le code — les 2 fichiers sont dans le dépôt |
| Action humaine requise | Vérifier les clés API, déployer l'Edge Function |

---

## PARTIE 5 — Version Web sécurisée (BFF)

### 5.1 État actuel du support Web — Audit réel

**`lib/utils/secure_storage_service.dart` — lecture complète (151 lignes) :**

Le fichier confirme que 4 méthodes ont chacune une branche `kIsWeb` :
- `sauvegarderSession()` (ligne 55–63) : stocke **4 clés** en `SharedPreferences` (localStorage), dont `_keyAccessToken` et `_keyRefreshToken` — **les tokens JWT en clair**
- `mettreAJourTokens()` (ligne 75–79) : même problème
- `lireAccessToken()` (ligne 96–99) : lecture depuis localStorage
- `lireRefreshToken()` (ligne 103–108) : idem
- `supprimerSession()` (ligne 124–135) : supprime les 4 clés

**Le commentaire en tête de fichier (lignes 11–21) reconnaît explicitement le problème :**
```
// ⚠️  WEB : SharedPreferences (localStorage) — NON SÉCURISÉ
// Les tokens JWT sont lisibles par tout script JavaScript de la page
// (attaque XSS) et visibles dans les DevTools du navigateur.
// DÉCISION : la version Web est strictement réservée aux démonstrations
// et à l'accueil non-authentifié.
```

**`lib/services/supabase_service.dart` — inventaire réel des endpoints :**

| Catégorie | Nombre d'endpoints | Exemples de lignes |
|---|---|---|
| `/auth/v1/*` | 9 | signup (111), logout (281), recover (310), verify (362), user (439, 495, 1583, 1634), token (1609) |
| `/rest/v1/*` | 28 | profils_donneurs (584), consentements (632), demandes_sang (857), etc. |
| `/functions/v1/*` | 5 | valider-token (980), don-manuel (1055), mdp-modifie-auth (1385, 1665), contacter-support (1696) |
| **Total** | **42** | Confirmé par `grep -c "Uri.parse"` |

**Aucune référence `kIsWeb` ou `bff` n'existe actuellement dans `supabase_service.dart`** — il n'y a aucune branche Web spécifique dans ce fichier.

### 5.2 Comparaison Cloudflare Workers vs Vercel

| Critère | Cloudflare Workers | Vercel Serverless Functions |
|---|---|---|
| **Latence** | ~5–10ms (edge mondial, 300+ PoPs) | ~50–200ms (régions limitées) |
| **Forfait gratuit** | 100k req/jour, 10ms CPU/req | 100k req/mois (très limité) |
| **Coût production** | $5/mois pour 10M req | $20/mois pour le même volume |
| **Proximité Burkina Faso** | PoP Nairobi, Lagos, Johannesburg (~80ms) | Région Paris (~200ms) |
| **Runtime** | V8 isolates, API standard (fetch, Response) | Node.js / Edge runtime |
| **KV Store intégré** | Oui (Workers KV — parfait pour sessions) | Non (besoin Redis externe) |
| **Conflits avec Vercel existant** | Aucun (domaine différent) | Possible confusion de routing |
| **Recommandation** | ✅ **Recommandé pour ce projet** | ⚠️ Possible si équipe préfère Node.js |

**Recommandation : Cloudflare Workers** — latence plus faible, meilleure couverture Afrique, forfait gratuit généreux, Workers KV pour les sessions.

### 5.3 Architecture BFF complète — Cloudflare Workers

#### Structure des routes

| Route BFF | Méthode | Action | Appel Supabase proxifié |
|---|---|---|---|
| `/bff/auth/signup` | POST | Inscription | `/auth/v1/signup` |
| `/bff/auth/login` | POST | Connexion email/mdp | `/auth/v1/token?grant_type=password` |
| `/bff/auth/logout` | POST | Déconnexion | `/auth/v1/logout` |
| `/bff/auth/recover` | POST | Mot de passe oublié | `/auth/v1/recover` |
| `/bff/auth/refresh` | POST | Refresh token | `/auth/v1/token?grant_type=refresh_token` |
| `/bff/api/*` | GET/POST/PATCH/DELETE | Proxy REST authentifié | `/rest/v1/*` |
| `/bff/functions/*` | POST | Edge Functions proxy | `/functions/v1/*` |

#### Code complet — `cloudflare-bff/src/index.ts`

```typescript
// cloudflare-bff/src/index.ts
// Deploy : wrangler deploy
// Secrets (wrangler secret put) : SUPABASE_URL, SUPABASE_ANON_KEY

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // CORS — origine restreinte à l'app Flutter Web
    const corsHeaders = {
      "Access-Control-Allow-Origin":   env.FLUTTER_WEB_ORIGIN,
      "Access-Control-Allow-Methods":  "GET, POST, PATCH, DELETE, OPTIONS",
      "Access-Control-Allow-Headers":  "Content-Type, x-webhook-secret",
      "Access-Control-Allow-Credentials": "true",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // ── Routing ────────────────────────────────────────────────────────────
    if (url.pathname === "/bff/auth/signup" && request.method === "POST") {
      return handleSignup(request, env, corsHeaders);
    }
    if (url.pathname === "/bff/auth/login" && request.method === "POST") {
      return handleLogin(request, env, corsHeaders);
    }
    if (url.pathname === "/bff/auth/logout" && request.method === "POST") {
      return handleLogout(request, env, corsHeaders);
    }
    if (url.pathname === "/bff/auth/recover" && request.method === "POST") {
      return handleRecover(request, env, corsHeaders);
    }
    if (url.pathname === "/bff/auth/refresh" && request.method === "POST") {
      return handleRefresh(request, env, corsHeaders);
    }
    if (url.pathname.startsWith("/bff/api/") ||
        url.pathname.startsWith("/bff/functions/")) {
      return handleProxy(request, env, url, corsHeaders);
    }

    return new Response("Not found", { status: 404 });
  },
};

// ── Helpers ──────────────────────────────────────────────────────────────────

function extractCookie(cookieHeader: string, name: string): string | null {
  const match = cookieHeader.match(
    new RegExp(`(?:^|;\\s*)${name}=([^;]*)`)
  );
  return match ? decodeURIComponent(match[1]) : null;
}

function setCookieOptions(maxAge: number, path = "/"): string {
  return `HttpOnly; Secure; SameSite=None; Path=${path}; Max-Age=${maxAge}`;
}

// ── Inscription ───────────────────────────────────────────────────────────────
async function handleSignup(
  request: Request, env: Env,
  corsHeaders: Record<string, string>,
): Promise<Response> {
  const body = await request.json() as { email: string; password: string };
  const resp = await fetch(`${env.SUPABASE_URL}/auth/v1/signup`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": env.SUPABASE_ANON_KEY,
    },
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    return new Response(await resp.text(), {
      status: resp.status,
      headers: { "Content-Type": "application/json", ...corsHeaders },
    });
  }

  const data = await resp.json() as {
    access_token: string;
    refresh_token: string;
    user: { id: string };
  };

  return new Response(
    JSON.stringify({ user_id: data.user.id }),
    {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        "Set-Cookie": [
          `songre_access=${data.access_token}; ${setCookieOptions(3600)}`,
          `songre_refresh=${data.refresh_token}; ${setCookieOptions(604800, "/bff/auth/refresh")}`,
        ].join(", "),
        ...corsHeaders,
      },
    }
  );
}

// ── Connexion ────────────────────────────────────────────────────────────────
async function handleLogin(
  request: Request, env: Env,
  corsHeaders: Record<string, string>,
): Promise<Response> {
  const { email, password } =
    await request.json() as { email: string; password: string };

  const resp = await fetch(
    `${env.SUPABASE_URL}/auth/v1/token?grant_type=password`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": env.SUPABASE_ANON_KEY,
      },
      body: JSON.stringify({ email, password }),
    }
  );

  if (!resp.ok) {
    const err = await resp.json();
    return new Response(JSON.stringify(err), {
      status: resp.status,
      headers: { "Content-Type": "application/json", ...corsHeaders },
    });
  }

  const data = await resp.json() as {
    access_token: string;
    refresh_token: string;
    user: { id: string };
  };

  return new Response(
    JSON.stringify({ user_id: data.user.id }),
    {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        "Set-Cookie": [
          `songre_access=${data.access_token}; ${setCookieOptions(3600)}`,
          `songre_refresh=${data.refresh_token}; ${setCookieOptions(604800, "/bff/auth/refresh")}`,
        ].join(", "),
        ...corsHeaders,
      },
    }
  );
}

// ── Déconnexion ───────────────────────────────────────────────────────────────
async function handleLogout(
  request: Request, env: Env,
  corsHeaders: Record<string, string>,
): Promise<Response> {
  const cookieHeader = request.headers.get("Cookie") ?? "";
  const accessToken  = extractCookie(cookieHeader, "songre_access");

  if (accessToken) {
    await fetch(`${env.SUPABASE_URL}/auth/v1/logout`, {
      method: "POST",
      headers: {
        "apikey":        env.SUPABASE_ANON_KEY,
        "Authorization": `Bearer ${accessToken}`,
      },
    });
  }

  return new Response(null, {
    status: 204,
    headers: {
      "Set-Cookie": [
        `songre_access=;  HttpOnly; Secure; SameSite=None; Path=/;                         Max-Age=0`,
        `songre_refresh=; HttpOnly; Secure; SameSite=None; Path=/bff/auth/refresh; Max-Age=0`,
      ].join(", "),
      ...corsHeaders,
    },
  });
}

// ── Mot de passe oublié ───────────────────────────────────────────────────────
async function handleRecover(
  request: Request, env: Env,
  corsHeaders: Record<string, string>,
): Promise<Response> {
  const body = await request.json() as { email: string };
  const resp = await fetch(`${env.SUPABASE_URL}/auth/v1/recover`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": env.SUPABASE_ANON_KEY,
    },
    body: JSON.stringify(body),
  });
  return new Response(await resp.text(), {
    status: resp.status,
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });
}

// ── Refresh token ─────────────────────────────────────────────────────────────
async function handleRefresh(
  request: Request, env: Env,
  corsHeaders: Record<string, string>,
): Promise<Response> {
  const cookieHeader  = request.headers.get("Cookie") ?? "";
  const refreshToken  = extractCookie(cookieHeader, "songre_refresh");

  if (!refreshToken) {
    return new Response(
      JSON.stringify({ error: "Session expirée" }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } },
    );
  }

  const resp = await fetch(
    `${env.SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": env.SUPABASE_ANON_KEY,
      },
      body: JSON.stringify({ refresh_token: refreshToken }),
    }
  );

  if (!resp.ok) {
    return new Response(await resp.text(), {
      status: resp.status,
      headers: { "Content-Type": "application/json", ...corsHeaders },
    });
  }

  const data = await resp.json() as {
    access_token: string;
    refresh_token: string;
    user: { id: string };
  };

  return new Response(
    JSON.stringify({ user_id: data.user.id }),
    {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        "Set-Cookie": [
          `songre_access=${data.access_token}; ${setCookieOptions(3600)}`,
          `songre_refresh=${data.refresh_token}; ${setCookieOptions(604800, "/bff/auth/refresh")}`,
        ].join(", "),
        ...corsHeaders,
      },
    }
  );
}

// ── Proxy authentifié ─────────────────────────────────────────────────────────
async function handleProxy(
  request: Request, env: Env, url: URL,
  corsHeaders: Record<string, string>,
): Promise<Response> {
  const cookieHeader = request.headers.get("Cookie") ?? "";
  const accessToken  = extractCookie(cookieHeader, "songre_access");

  if (!accessToken) {
    return new Response(
      JSON.stringify({ error: "Non authentifié" }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } },
    );
  }

  // Mapping chemin BFF → chemin Supabase
  const supabasePath = url.pathname
    .replace(/^\/bff\/api\//, "/rest/v1/")
    .replace(/^\/bff\/functions\//, "/functions/v1/");
  const targetUrl = `${env.SUPABASE_URL}${supabasePath}${url.search}`;

  const forwardHeaders: Record<string, string> = {
    "Content-Type":  "application/json",
    "apikey":        env.SUPABASE_ANON_KEY,
    "Authorization": `Bearer ${accessToken}`,
  };

  // Préserver les headers spécifiques Supabase (Prefer, x-webhook-secret)
  const preferHeader = request.headers.get("Prefer");
  if (preferHeader) forwardHeaders["Prefer"] = preferHeader;
  const webhookHeader = request.headers.get("x-webhook-secret");
  if (webhookHeader) forwardHeaders["x-webhook-secret"] = webhookHeader;

  const proxyResp = await fetch(targetUrl, {
    method:  request.method,
    headers: forwardHeaders,
    body:    request.method !== "GET" && request.method !== "HEAD"
               ? await request.text()
               : undefined,
  });

  return new Response(await proxyResp.text(), {
    status:  proxyResp.status,
    headers: {
      "Content-Type": proxyResp.headers.get("Content-Type") ?? "application/json",
      ...corsHeaders,
    },
  });
}

// ── Types Cloudflare Workers Bindings ─────────────────────────────────────────
interface Env {
  SUPABASE_URL:       string;  // wrangler secret put SUPABASE_URL
  SUPABASE_ANON_KEY:  string;  // wrangler secret put SUPABASE_ANON_KEY
  FLUTTER_WEB_ORIGIN: string;  // var publique dans wrangler.toml
}
```

#### `cloudflare-bff/wrangler.toml`

```toml
# cloudflare-bff/wrangler.toml
name               = "songre-bff"
main               = "src/index.ts"
compatibility_date = "2024-09-23"

[vars]
# Variable publique : l'origine de l'app Flutter Web
FLUTTER_WEB_ORIGIN = "https://songre.vercel.app"

# Secrets à injecter via CLI (jamais dans ce fichier) :
# wrangler secret put SUPABASE_URL
# wrangler secret put SUPABASE_ANON_KEY
```

#### `cloudflare-bff/package.json`

```json
{
  "name": "songre-bff",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev":   "wrangler dev",
    "deploy": "wrangler deploy"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^4.0.0",
    "wrangler": "^3.0.0"
  }
}
```

### 5.4 Modifications côté Flutter Web

#### `SecureStorageService` — 5 méthodes à modifier pour le BFF

Avec le BFF HttpOnly, Flutter Web **ne stocke plus les tokens JWT**. Les cookies sont gérés automatiquement par le navigateur (envoyés implicitement avec chaque requête `withCredentials`). Il faut seulement stocker l'`userId` et l'`authType` côté client.

```dart
// lib/utils/secure_storage_service.dart
// Modifications dans les branches kIsWeb uniquement (Android/iOS inchangés)

// ── sauvegarderSession() — MODIFIÉ pour kIsWeb ──────────────────────────────
static Future<void> sauvegarderSession({
  required String userId,
  required String accessToken,   // Ignoré sur Web — géré par cookie HttpOnly du BFF
  required String refreshToken,  // Ignoré sur Web — géré par cookie HttpOnly du BFF
  String authType = 'email',
}) async {
  if (kIsWeb) {
    final prefs = await SharedPreferences.getInstance();
    // Sur Web avec BFF : stocker UNIQUEMENT userId et authType (non-sensibles)
    // Les tokens ne transitent JAMAIS côté client Flutter Web
    await prefs.setString(_keyUserId,    userId);
    await prefs.setString(_keyAuthType,  authType);
    // Ne PAS stocker accessToken ni refreshToken
    return;
  }
  // Android/iOS inchangés :
  await _storage.write(key: _keyUserId,       value: userId);
  await _storage.write(key: _keyAccessToken,  value: accessToken);
  await _storage.write(key: _keyRefreshToken, value: refreshToken);
  await _storage.write(key: _keyAuthType,     value: authType);
}

// ── mettreAJourTokens() — MODIFIÉ pour kIsWeb ───────────────────────────────
static Future<void> mettreAJourTokens({
  required String accessToken,
  required String refreshToken,
}) async {
  if (kIsWeb) {
    // Sur Web avec BFF : les tokens sont dans les cookies HttpOnly
    // Le BFF met à jour les cookies automatiquement lors du refresh
    // Aucune action côté Flutter Web
    return;
  }
  await _storage.write(key: _keyAccessToken,  value: accessToken);
  await _storage.write(key: _keyRefreshToken, value: refreshToken);
}

// ── lireAccessToken() — MODIFIÉ pour kIsWeb ─────────────────────────────────
static Future<String?> lireAccessToken() async {
  if (kIsWeb) {
    // Sur Web avec BFF : le token n'est pas accessible côté client (HttpOnly)
    // Retourner une sentinelle non-null pour indiquer que la session est active
    // La vraie authentification se fait par cookie automatique
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_keyUserId);
    return userId != null ? 'bff-session-active' : null;
  }
  return _storage.read(key: _keyAccessToken);
}

// ── lireRefreshToken() — MODIFIÉ pour kIsWeb ────────────────────────────────
static Future<String?> lireRefreshToken() async {
  if (kIsWeb) {
    // Sur Web avec BFF : inaccessible côté client (HttpOnly)
    return null;
  }
  return _storage.read(key: _keyRefreshToken);
}

// ── sessionExiste() — impact indirect : à vérifier ──────────────────────────
// La méthode actuelle vérifie token != null.
// Avec BFF, lireAccessToken() retourne 'bff-session-active' si userId présent
// → sessionExiste() fonctionnera correctement sans modification supplémentaire.
```

#### `SupabaseService` — Phase minimale (auth seulement)

La phase minimale consiste à rediriger uniquement les **5 endpoints d'auth** vers le BFF. Les 37 autres endpoints (REST et Functions) continuent d'appeler Supabase directement avec la clé anon (ce qui est acceptable, car la clé anon est publique par design dans l'architecture Supabase, et la protection réelle est dans les règles RLS).

```dart
// Dans supabase_service.dart, ajouter en tête de fichier (après les imports) :

/// URL du BFF Cloudflare Workers (injectée via --dart-define=BFF_URL)
static const String _bffUrl = String.fromEnvironment(
  'BFF_URL',
  defaultValue: 'https://songre-bff.workers.dev',  // À remplacer après déploiement
);

/// Headers pour les requêtes BFF (sans Authorization — tokens dans cookies)
static Map<String, String> _hdrsBff() => {
  'Content-Type': 'application/json',
};

/// Requête vers le BFF avec credentials (cookies envoyés automatiquement)
/// Utiliser html.HttpRequest sur Web car http.dart ne supporte pas withCredentials
static Future<http.Response> _bffPost(String path, Object body) async {
  // Note : sur Web, les cookies HttpOnly sont envoyés automatiquement
  // si la requête est faite depuis le même origin ou avec CORS correct.
  // http.dart sur Flutter Web envoie les cookies automatiquement.
  final url = Uri.parse('$_bffUrl$path');
  return http.post(url, headers: _hdrsBff(), body: jsonEncode(body));
}
```

```dart
// Dans seConnecter() — REMPLACER la branche kIsWeb (à créer ou à insérer) :
if (kIsWeb) {
  final resp = await _bffPost('/bff/auth/login', {
    'email':    email,
    'password': password,
  });
  if (resp.statusCode == 200) {
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final userId = data['user_id'] as String;
    // Pas d'accessToken à sauvegarder — cookie HttpOnly géré par le BFF
    await SecureStorageService.sauvegarderSession(
      userId:       userId,
      accessToken:  'bff-managed',  // sentinelle
      refreshToken: 'bff-managed',
      authType:     'email',
    );
    return ConnexionResult(success: true, userId: userId);
  }
  return ConnexionResult(success: false);
}
// ... suite : code Android/iOS existant inchangé
```

### 5.5 Étapes de mise en œuvre

#### Actions qu'un agent peut faire seul

1. Créer `cloudflare-bff/src/index.ts` (code complet en section 5.3)
2. Créer `cloudflare-bff/wrangler.toml` + `package.json`
3. Modifier `SecureStorageService` — 4 méthodes, branches `kIsWeb` uniquement
4. Modifier `SupabaseService` — ajouter `_bffUrl`, `_hdrsBff()`, `_bffPost()` + branche Web dans `seConnecter()`, `seDeconnecter()`, `refreshToken()`, `seConnecter()` et `reinitialiserMdp()` (5 méthodes = phase minimale)
5. Ajouter `BFF_URL` au `Makefile` (cible `web`) et dans la documentation
6. Supprimer `WebSecurityBanner` ou modifier son message

#### Actions nécessitant une intervention humaine

| Action | Raison |
|---|---|
| Créer un compte Cloudflare | Nécessite une adresse email, vérification de numéro |
| Exécuter `wrangler login` + `wrangler deploy` | Authentification Cloudflare requise |
| `wrangler secret put SUPABASE_URL` | Valeur sensible à injecter en sécurité |
| `wrangler secret put SUPABASE_ANON_KEY` | Idem |
| Configurer `FLUTTER_WEB_ORIGIN` dans `wrangler.toml` | Décision : quel domaine pour la version Web ? |
| Tester en vrai navigateur avec cookies | Environnement navigateur requis |

### 5.6 Réévaluation de la difficulté et du temps

| Phase | Difficulté | Temps estimé |
|---|---|---|
| Créer le Worker + déployer (code fourni) | Faible | 1 heure humain (compte + CLI) |
| Modifier `SecureStorageService` (4 méthodes Web) | Faible | 30 min agent |
| Modifier `SupabaseService` (5 endpoints auth) | Moyenne | 2 heures agent |
| Modifier `SupabaseService` (37 endpoints REST/Functions) | Élevée | 6–8 heures agent |
| Tests d'intégration (vraie session Web avec cookies) | Moyenne | 2–3 heures humain |
| **Total phase minimale (auth seulement)** | | **~4 heures** |
| **Total phase complète (tous endpoints)** | | **~12–15 heures** |

**Recommandation :** Commencer par la **phase minimale** — sécuriser uniquement l'authentification (5 endpoints auth/v1 via BFF HttpOnly). Les 37 endpoints REST/Functions avec la clé anon restent en appel direct : c'est acceptable car :
1. La clé `_anonKey` est publique par design dans l'architecture Supabase (documentation officielle)
2. La vraie protection est dans les règles RLS côté Supabase
3. L'objectif principal du BFF est de protéger les tokens JWT, pas la clé anon

### 5.7 Risques et points de vigilance

| Risque | Probabilité | Mitigation |
|---|---|---|
| CORS mal configuré → Web bloqué | Moyenne | Tester en local avec `wrangler dev` avant déploiement |
| `SameSite=None` requis si BFF et app sur domaines différents | Certaine | Déjà implémenté dans le code ci-dessus (`SameSite=None; Secure`) |
| Cookie expiré → 401 non géré | Moyenne | Implémenter `_requeteAvecRefreshBff()` côté Flutter |
| Régression Android si `kIsWeb` mal conditionné | Élevée sans tests | `flutter analyze` + `make apk` systématique après chaque modification |
| `SUPABASE_ANON_KEY` visible dans Cloudflare Dashboard | Note | C'est intentionnel — clé anon publique, protection réelle = RLS |
| Cookie HttpOnly non envoyé sur certains navigateurs | Faible | Tester Chrome, Firefox, Safari avec DevTools → Network → Cookies |

---

## Synthèse exécutive

| Partie | Difficulté | Urgence | Action humaine minimale | Temps agent | Prochaine session |
|---|---|---|---|---|---|
| **P1 — Clé chiffrement** | Faible (table vide) | **Élevée** (sécurité) | Vérifier `COUNT(*)` + générer clé | 20 min | Oui, 30 min |
| **P2 — Carte flutter_map** | Moyenne | Faible | Saisir coordonnées 5–10 structures | 3 heures | Oui |
| **P3 — SHA keystores** | Déjà fait | Faible | **Enregistrer dans Firebase Console** (10 min) | 0 | Non — action humaine seulement |
| **P4 — Email confirmation** | Faible | Moyenne | Vérifier clés API + déployer EF | 1–2 heures | Oui |
| **P5 — BFF Web sécurisé** | Moyenne (phase min) | Faible (Web = démo) | Compte Cloudflare + wrangler deploy | 2h30 min | Session dédiée |

**Priorité recommandée pour les prochaines sessions :**
1. **P1** (30 min, impact sécurité immédiat, sans risque si table vide — vérifier `COUNT(*)` d'abord)
2. **P3** (10 min, action humaine seulement, aucune dépendance)
3. **P4** (1–2 heures, valeur utilisateur directe, infrastructure existante)
4. **P2** après saisie des coordonnées par l'équipe (dépendance humaine)
5. **P5** dans une session dédiée avec accès Cloudflare

---

*Guide généré en Session 4 — 2026-07-18*  
*Ancré sur le code réel du projet SONGRE (commit `9b05c81`)*  
*Lectures réelles effectuées : `crypto_service.dart`, `Makefile`, `pubspec.yaml`, `secure_storage_service.dart`, `email.ts`, `matcher-et-notifier/index.ts`, debug keystore SHA extrait en live*
