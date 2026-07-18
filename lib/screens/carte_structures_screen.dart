// =====================================================================
// ÉCRAN — Carte des structures sanitaires (Mission E)
//
// Bascule dynamique Option A / Option B lue depuis app_config Supabase.
//
// Option B (défaut, mode_carte = 'externe') :
//   Ouvre l'app Maps native via url_launcher (schéma geo:) avec fallback
//   URL Google Maps. Aucune dépendance de localisation.
//
// Option A (mode_carte = 'integree') :
//   Carte flutter_map intégrée avec :
//   - Si consentement géoloc accordé  : position réelle (marqueur bleu),
//     structures autour, + structure liée à la demande en cours (si fournie)
//   - Si consentement géoloc refusé   : carte centrée sur la ville du profil,
//     structures de cette ville uniquement
//   - Gestion complète des états de permission (granted/denied/
//     permanentlyDenied/serviceDisabled)
//   - Aucun calcul ni texte de distance — proximité visuelle uniquement
//   - Design cohérent avec SauveColors + google_fonts
// =====================================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';
import '../theme/sauve_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Coordonnées par défaut : Ouagadougou (capitale, utilisée si aucune ville
// du profil n'est géolocalisée dans la base de données).
// ─────────────────────────────────────────────────────────────────────────────
const _kDefautLat = 12.3647;
const _kDefautLon = -1.5337;
const _kZoomVille = 13.0;
const _kZoomPosition = 14.5;

// ─────────────────────────────────────────────────────────────────────────────
// Widget principal
// ─────────────────────────────────────────────────────────────────────────────
class CarteStructuresScreen extends StatefulWidget {
  /// Structure liée à la demande de sang en cours (passée via GoRouter extra).
  /// Null si l'écran est ouvert sans contexte de demande.
  final StructureSanitaire? structureContexte;

  const CarteStructuresScreen({
    super.key,
    this.structureContexte,
  });

  @override
  State<CarteStructuresScreen> createState() => _CarteStructuresScreenState();
}

class _CarteStructuresScreenState extends State<CarteStructuresScreen> {
  // ── État de chargement global ─────────────────────────────────────────────
  bool _chargement = true;
  String? _erreur;

  // ── Mode carte (lu depuis app_config) ─────────────────────────────────────
  String _modeCarte = 'externe'; // 'externe' | 'integree'

  // ── Données Option A ───────────────────────────────────────────────────────
  List<StructureSanitaire> _structures = [];
  LatLng? _positionUtilisateur;
  LatLng _centreInitial = const LatLng(_kDefautLat, _kDefautLon);
  double _zoomInitial = _kZoomVille;

  // ── Permission localisation ───────────────────────────────────────────────
  bool _geolocAccorde = false;
  bool _geolocRefusDef = false;   // permanentlyDenied
  bool _serviceDesactive = false;

  // ── Contrôleur carte ──────────────────────────────────────────────────────
  final MapController _mapController = MapController();

  // ── Structure sélectionnée (tap sur marqueur) ────────────────────────────
  StructureSanitaire? _structureSelectionnee;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialiser());
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Initialisation principale
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _initialiser() async {
    try {
      // 1. Lire le mode carte depuis app_config (timeout silencieux → défaut)
      final mode = await SupabaseService.lireConfigCarte();
      if (!mounted) return;
      setState(() => _modeCarte = mode);

      if (mode == 'externe') {
        // Option B : on ouvre directement Maps externe, rien d'autre à charger
        setState(() => _chargement = false);
        _ouvrirMapsExterne();
        return;
      }

      // Option A : initialisation de la carte intégrée
      await _initialiserOptionA();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erreur = 'Impossible de charger la carte. Vérifiez votre connexion.';
        _chargement = false;
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Initialisation Option A (carte intégrée)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _initialiserOptionA() async {
    final appState = context.read<AppState>();
    final profil = appState.profil;

    // 2. Vérifier l'état de permission géolocalisation
    await _verifierPermission();
    if (!mounted) return;

    if (_geolocAccorde && !_serviceDesactive) {
      // Permission accordée → position réelle
      await _chargerPositionReelle();
    } else {
      // Permission refusée ou service désactivé → centrer sur ville du profil
      await _centrerSurVilleProfil(profil);
    }
    if (!mounted) return;

    // 3. Charger les structures sanitaires
    await _chargerStructures(profil);
    if (!mounted) return;

    setState(() => _chargement = false);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Vérification état permission géolocalisation
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _verifierPermission() async {
    try {
      final serviceActif = await Geolocator.isLocationServiceEnabled();
      if (!serviceActif) {
        setState(() => _serviceDesactive = true);
        return;
      }
      final permission = await Geolocator.checkPermission();
      switch (permission) {
        case LocationPermission.always:
        case LocationPermission.whileInUse:
          setState(() => _geolocAccorde = true);
        case LocationPermission.denied:
          // Pas de demande intrusive ici : l'utilisateur a déjà pu refuser
          // dans le formulaire de profil. On tente une demande silencieuse
          // uniquement si le consentement avait été accordé dans le profil.
          final aConsenti = await _lireConsentementGeoloc();
          if (aConsenti) {
            final rep = await Geolocator.requestPermission();
            if (rep == LocationPermission.whileInUse ||
                rep == LocationPermission.always) {
              setState(() => _geolocAccorde = true);
            }
          }
        case LocationPermission.deniedForever:
          setState(() => _geolocRefusDef = true);
        case LocationPermission.unableToDetermine:
          break;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Carte] _verifierPermission error: $e');
    }
  }

  /// Lit le consentement géoloc depuis Supabase pour décider si on peut
  /// demander la permission (sans insister si non consenti).
  Future<bool> _lireConsentementGeoloc() async {
    try {
      final appState = context.read<AppState>();
      final userId = appState.userId;
      if (userId == null) return false;
      final data = await SupabaseService.lireConsentement(userId);
      return data?['consentement_geoloc'] as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Récupération position réelle
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _chargerPositionReelle() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) return;
      setState(() {
        _positionUtilisateur = LatLng(pos.latitude, pos.longitude);
        _centreInitial = _positionUtilisateur!;
        _zoomInitial = _kZoomPosition;
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[Carte] _chargerPositionReelle error: $e');
      // Erreur silencieuse → on tombera en fallback ville du profil
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Centrage sur la ville du profil (fallback)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _centrerSurVilleProfil(ProfilDonneur? profil) async {
    if (profil == null) return;
    try {
      // Chercher la ville dans la liste déjà chargée par AppState
      final appState = context.read<AppState>();
      Ville? ville;
      try {
        ville = appState.villes.firstWhere((v) => v.id == profil.villeId);
      } catch (_) {
        ville = null;
      }
      if (ville == null || !ville.estGeolocalise) {
        // Charger depuis DB si pas en cache ou sans coordonnées
        final villes = await SupabaseService.lireVilles();
        if (!mounted) return;
        try {
          ville = villes.firstWhere(
            (v) => v.id == profil.villeId && v.estGeolocalise,
          );
        } catch (_) {
          ville = null;
        }
      }
      if (ville != null && ville.estGeolocalise && mounted) {
        setState(() {
          _centreInitial = LatLng(ville!.latitude!, ville.longitude!);
          _zoomInitial = _kZoomVille;
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Carte] _centrerSurVilleProfil error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Chargement des structures sanitaires
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _chargerStructures(ProfilDonneur? profil) async {
    try {
      final int? villeId = _geolocAccorde ? null : profil?.villeId;
      final structures = await SupabaseService.lireStructuresSanitaires(
        villeId: villeId,
      );
      if (!mounted) return;

      // S'assurer que la structure contextuelle est incluse même si hors ville
      final Set<int> ids = structures.map((s) => s.id).toSet();
      final List<StructureSanitaire> liste = List.from(structures);
      if (widget.structureContexte != null &&
          widget.structureContexte!.estGeolocalise &&
          !ids.contains(widget.structureContexte!.id)) {
        liste.add(widget.structureContexte!);
      }

      setState(() => _structures = liste);
    } catch (e) {
      if (kDebugMode) debugPrint('[Carte] _chargerStructures error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Option B : ouvrir l'app Maps native via url_launcher
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _ouvrirMapsExterne() async {
    final structure = widget.structureContexte;

    // Si on a une structure avec coordonnées, centrer dessus
    // Sinon, centrer sur Ouagadougou par défaut
    final double lat = structure?.latitude ?? _kDefautLat;
    final double lon = structure?.longitude ?? _kDefautLon;
    final String label = structure?.nom ?? 'Structures sanitaires';
    final String labelEncode = Uri.encodeComponent(label);

    // Tentative 1 : schéma geo: (Google Maps, OsmAnd, Here Maps, etc.)
    final geoUri = Uri.parse('geo:$lat,$lon?q=$lat,$lon($labelEncode)');
    bool ouvert = false;
    try {
      if (await canLaunchUrl(geoUri)) {
        ouvert = await launchUrl(geoUri);
      }
    } catch (_) {}

    // Tentative 2 : fallback URL Google Maps (navigateur ou app Google Maps)
    if (!ouvert) {
      final mapsUrl = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lon',
      );
      try {
        await launchUrl(mapsUrl, mode: LaunchMode.externalApplication);
      } catch (_) {
        if (mounted) _afficherErreurMapsExterne();
      }
    }
  }

  void _afficherErreurMapsExterne() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Impossible d\'ouvrir l\'application de cartes.',
          style: GoogleFonts.inter(fontSize: 13),
        ),
        backgroundColor: SauveColors.rouge,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build principal
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SauveColors.creme,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildContenu()),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.pop(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: SauveColors.carte,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: SauveColors.grisClair),
              ),
              child: const Icon(
                Icons.arrow_back,
                size: 18,
                color: SauveColors.encre,
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: Text(
                'Structures sanitaires',
                style: GoogleFonts.archivo(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: SauveColors.encre,
                ),
              ),
            ),
          ),
          // Bouton de recentrage (visible uniquement en mode intégré avec position)
          if (_modeCarte == 'integree' && _positionUtilisateur != null)
            GestureDetector(
              onTap: _recentrer,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: SauveColors.carte,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: SauveColors.grisClair),
                ),
                child: const Icon(
                  Icons.my_location,
                  size: 18,
                  color: SauveColors.encre,
                ),
              ),
            )
          else
            const SizedBox(width: 36),
        ],
      ),
    );
  }

  void _recentrer() {
    if (_positionUtilisateur != null) {
      _mapController.move(_positionUtilisateur!, _kZoomPosition);
    }
  }

  Widget _buildContenu() {
    if (_chargement) return _buildChargement();
    if (_erreur != null) return _buildErreur(_erreur!);

    // Option B : pendant le chargement initial, l'app Maps externe est ouverte.
    // On affiche un écran informatif pendant l'attente.
    if (_modeCarte == 'externe') return _buildOptionBEcranInfo();

    // Option A : carte intégrée
    return _buildOptionA();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Option B — Écran informatif pendant ouverture Maps externe
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildOptionBEcranInfo() {
    final structure = widget.structureContexte;
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: SauveColors.rouge.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.map_outlined,
              size: 36,
              color: SauveColors.rouge,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            structure != null
                ? 'Localisation de la structure'
                : 'Structures sanitaires',
            style: GoogleFonts.archivo(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: SauveColors.encre,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          if (structure != null) ...[
            Text(
              structure.nom,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: SauveColors.encre,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
          ],
          Text(
            'L\'application de cartes s\'est ouverte pour vous montrer '
            '${structure != null ? 'cette structure' : 'les structures sanitaires'}.',
            style: GoogleFonts.inter(
              fontSize: 13.5,
              color: SauveColors.gris,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _ouvrirMapsExterne,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(
                'Ouvrir à nouveau',
                style: GoogleFonts.archivo(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: SauveColors.rouge,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Option A — Carte intégrée flutter_map
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildOptionA() {
    final structuresGeoloc =
        _structures.where((s) => s.estGeolocalise).toList();

    return Stack(
      children: [
        // ── Carte principale ────────────────────────────────────────────────
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _centreInitial,
            initialZoom: _zoomInitial,
            minZoom: 5,
            maxZoom: 18,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
            ),
          ),
          children: [
            // Tuiles OpenStreetMap (pas de clé API)
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.songre.app',
              maxZoom: 19,
            ),
            // Marqueurs structures sanitaires
            MarkerLayer(
              markers: [
                // Marqueurs des structures géolocalisées
                ...structuresGeoloc.map((s) => _buildMarqueurStructure(s)),
                // Marqueur position utilisateur (point bleu)
                if (_positionUtilisateur != null)
                  _buildMarqueurPosition(_positionUtilisateur!),
              ],
            ),
          ],
        ),

        // ── Bandeau d'état permission (si problème géoloc) ─────────────────
        if (!_geolocAccorde && !_chargement)
          _buildBandeauPermission(),

        // ── Fiche structure sélectionnée (tap sur marqueur) ────────────────
        if (_structureSelectionnee != null)
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: _buildFicheStructure(_structureSelectionnee!),
          ),

        // ── Message si aucune structure géolocalisée ───────────────────────
        if (structuresGeoloc.isEmpty && !_chargement)
          _buildMessageAucuneStructure(),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Marqueur structure sanitaire
  // ─────────────────────────────────────────────────────────────────────────
  Marker _buildMarqueurStructure(StructureSanitaire structure) {
    final estContexte = widget.structureContexte?.id == structure.id;
    final estSelectionnee = _structureSelectionnee?.id == structure.id;

    return Marker(
      point: LatLng(structure.latitude!, structure.longitude!),
      width: 40,
      height: 46,
      child: GestureDetector(
        onTap: () => setState(() {
          _structureSelectionnee =
              estSelectionnee ? null : structure;
        }),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: estContexte
                    ? SauveColors.rouge
                    : estSelectionnee
                        ? SauveColors.encre
                        : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: estContexte
                      ? SauveColors.rouge
                      : SauveColors.encre.withValues(alpha: 0.4),
                  width: estContexte ? 2.5 : 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                Icons.local_hospital,
                size: 18,
                color: estContexte || estSelectionnee
                    ? Colors.white
                    : SauveColors.rouge,
              ),
            ),
            // Pointe du marqueur
            Container(
              width: 2,
              height: 6,
              color: estContexte
                  ? SauveColors.rouge
                  : SauveColors.encre.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Marqueur position utilisateur (point bleu classique)
  // ─────────────────────────────────────────────────────────────────────────
  Marker _buildMarqueurPosition(LatLng position) {
    return Marker(
      point: position,
      width: 24,
      height: 24,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: const Color(0xFF2563EB),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2563EB).withValues(alpha: 0.35),
              blurRadius: 8,
              spreadRadius: 2,
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Fiche structure sélectionnée (bottom sheet inline)
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildFicheStructure(StructureSanitaire structure) {
    final estContexte = widget.structureContexte?.id == structure.id;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: estContexte
                  ? SauveColors.rouge.withValues(alpha: 0.1)
                  : SauveColors.creme,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.local_hospital,
              color: estContexte ? SauveColors.rouge : SauveColors.encre,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  structure.nom,
                  style: GoogleFonts.archivo(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: SauveColors.encre,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (structure.type != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    structure.type!,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: SauveColors.gris,
                    ),
                  ),
                ],
                if (estContexte) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: SauveColors.rouge.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Structure de la demande',
                      style: GoogleFonts.inter(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: SauveColors.rouge,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _structureSelectionnee = null),
            child: const Icon(
              Icons.close,
              size: 18,
              color: SauveColors.gris,
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Bandeau d'état permission géolocalisation
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildBandeauPermission() {
    String message;
    IconData icone;

    if (_geolocRefusDef) {
      message =
          'Accès à la localisation refusé. Activez-le dans les paramètres '
          'de l\'application pour voir votre position.';
      icone = Icons.location_off_outlined;
    } else if (_serviceDesactive) {
      message =
          'Le service de localisation est désactivé sur votre appareil.';
      icone = Icons.gps_off_outlined;
    } else {
      message = 'Carte centrée sur votre ville de profil.';
      icone = Icons.location_city_outlined;
    }

    return Positioned(
      top: 8,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: SauveColors.encre.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icone, size: 16, color: Colors.white.withValues(alpha: 0.8)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: Colors.white,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Message aucune structure géolocalisée
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildMessageAucuneStructure() {
    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline,
              size: 20,
              color: SauveColors.gris,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Aucune structure sanitaire géolocalisée disponible dans cette zone.',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: SauveColors.gris,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // États génériques : chargement / erreur
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildChargement() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: SauveColors.rouge,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Chargement de la carte…',
            style: GoogleFonts.inter(
              fontSize: 14,
              color: SauveColors.gris,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErreur(String message) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 52,
            color: SauveColors.gris.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 20),
          Text(
            message,
            style: GoogleFonts.inter(
              fontSize: 14,
              color: SauveColors.gris,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _chargement = true;
                _erreur = null;
              });
              _initialiser();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: SauveColors.rouge,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              'Réessayer',
              style: GoogleFonts.archivo(
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
