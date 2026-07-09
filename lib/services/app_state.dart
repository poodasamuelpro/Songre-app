import 'dart:async'; // unawaited()
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../utils/secure_storage_service.dart';
import '../utils/crypto_service.dart';
import '../services/supabase_service.dart';

// =====================================================================
// APP STATE — SONGRE Production
// Authentification : Email / Mot de passe via Supabase Auth
// Tokens : JWT réel (access_token + refresh_token)
// Schéma : public.* (synchronisé avec l'audit 2026-07-08)
// =====================================================================
class AppState extends ChangeNotifier {
  // Clés SharedPreferences (données non-sensibles)
  static const String _keyProfil        = 'songre_profil';
  static const String _keyDemandes      = 'songre_demandes';
  static const String _keyNotifications = 'songre_notifications';
  static const String _keyVilles        = 'songre_villes';

  static const List<String> _toutesLesClesCache = [
    _keyProfil,
    _keyDemandes,
    _keyNotifications,
    _keyVilles,
    // Legacy keys (migration)
    'sauve_profil',
    'sauve_demandes',
    'sauve_notifications',
    'sauve_dons_declares',
  ];

  // ---- État utilisateur ----
  String? _userId;
  ProfilDonneur? _profil;
  bool _isLoading = false;
  bool _isAuthenticated = false;
  bool _suppressionProgrammee = false;
  DateTime? _dateSuppression;
  String? _authError;

  // ---- Référentiels (public.villes + public.structures_sanitaires) ----
  List<Ville> _villes = [];
  /// Map id → nom pour résolution rapide
  Map<int, String> _villesMap = {};

  // ---- Données ----
  List<DemandeSang> _demandes = [];
  List<NotificationSauve> _notifications = [];

  // ---- [PERF-01] Cache de compatibilité pré-calculé ----
  List<DemandeSang> _demandesCompatibles = [];

  // Getters
  String? get userId => _userId;
  ProfilDonneur? get profil => _profil;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _isAuthenticated;
  bool get suppressionProgrammee => _suppressionProgrammee;
  DateTime? get dateSuppression => _dateSuppression;
  String? get authError => _authError;
  List<DemandeSang> get demandes => _demandes;
  List<NotificationSauve> get notifications => _notifications;
  int get notifNonLues => _notifications.where((n) => !n.lue).length;
  List<Ville> get villes => _villes;
  Map<int, String> get villesMap => _villesMap;

  /// [PERF-01] Liste des demandes compatibles avec le profil courant.
  List<DemandeSang> get demandesCompatibles => _demandesCompatibles;

  void _recalculerCompatibilite() {
    if (_profil == null) {
      _demandesCompatibles = [];
      return;
    }
    _demandesCompatibles = _demandes
        .where((d) => d.estActive && d.estCompatibleAvec(_profil!))
        .toList();
  }

  // =====================================================================
  // INITIALISATION — [PERF-03] Stale-while-revalidate
  // =====================================================================
  Future<void> init() async {
    _setLoading(true);
    CryptoService.init();

    final userId       = await SecureStorageService.lireUserId();
    final accessToken  = await SecureStorageService.lireAccessToken();
    final refreshToken = await SecureStorageService.lireRefreshToken();

    if (userId != null && accessToken != null && refreshToken != null) {
      final ok = await SupabaseService.restaurerSession(
        accessToken: accessToken,
        refreshToken: refreshToken,
        userId: userId,
      );

      if (ok) {
        _userId = userId;
        _isAuthenticated = true;

        // [PERF-03] Phase 1 : cache local → affichage immédiat
        await _loadVillesDepuisCache();
        await _loadProfil();
        await _loadDemandesDepuisCache();
        await _loadNotificationsDepuisCache();
        _recalculerCompatibilite();
        _setLoading(false); // ← l'UI s'affiche ici avec les données cachées

        // [PERF-03] Phase 2 : rafraîchissement arrière-plan (non-bloquant)
        unawaited(_rafraichirDonneesBackground());
        return;
      } else {
        await _purgerSessionLocale();
      }
    }
    _setLoading(false);
  }

  /// [PERF-03] Rafraîchissement arrière-plan après affichage du cache.
  Future<void> _rafraichirDonneesBackground() async {
    if (!SupabaseService.estConfigured) return;
    try {
      // Rafraîchir les villes si besoin
      if (_villes.isEmpty) {
        await _chargerVilles();
      }

      // Rafraîchir les demandes si on a un profil avec une ville connue
      if (_profil != null && _profil!.villeId > 0) {
        final demandesBackend = await SupabaseService.lireDemandesActives(
          _profil!.villeId,
          villesMap: _villesMap,
        );
        if (demandesBackend.isNotEmpty) {
          _demandes = demandesBackend;
          _recalculerCompatibilite();
          await _sauvegarderDemandes();
          notifyListeners();
        }
      }

      // Rafraîchir les notifications depuis le backend (source de vérité)
      if (_userId != null) {
        await _chargerNotificationsBackend();
      }
    } catch (_) {
      // Non bloquant — le cache est déjà affiché
    }
  }

  // =====================================================================
  // VILLES — Chargement et cache
  // =====================================================================

  Future<void> _chargerVilles() async {
    final villes = await SupabaseService.lireVilles();
    if (villes.isNotEmpty) {
      _villes = villes;
      _villesMap = {for (final v in villes) v.id: v.nom};
      await _sauvegarderVillesCache();
    }
  }

  Future<void> _loadVillesDepuisCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_keyVilles);
      if (json != null) {
        final list = jsonDecode(json) as List;
        _villes = list
            .map((e) => Ville.fromJson(e as Map<String, dynamic>))
            .toList();
        _villesMap = {for (final v in _villes) v.id: v.nom};
      }
    } catch (_) {
      _villes = [];
      _villesMap = {};
    }
  }

  Future<void> _sauvegarderVillesCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _keyVilles,
        jsonEncode(_villes.map((v) => v.toJson()).toList()),
      );
    } catch (_) {}
  }

  // =====================================================================
  // INSCRIPTION — Email + Mot de passe
  // =====================================================================
  Future<bool> inscrire({
    required String email,
    required String motDePasse,
  }) async {
    _authError = null;
    _setLoading(true);

    final result = await SupabaseService.inscrire(
      email: email,
      motDePasse: motDePasse,
    );

    if (!result.success) {
      _authError = result.error;
      _setLoading(false);
      return false;
    }

    if (result.needsEmailConfirmation) {
      _authError = null;
      _setLoading(false);
      return true;
    }

    if (result.userId != null && result.accessToken != null) {
      _userId = result.userId;
      await SecureStorageService.sauvegarderSession(
        userId: _userId!,
        accessToken: result.accessToken!,
        refreshToken: SupabaseService.refreshTokenCourant ?? '',
        authType: 'email',
      );
      _isAuthenticated = true;
    }

    _setLoading(false);
    return true;
  }

  // =====================================================================
  // CONNEXION — Email + Mot de passe → JWT réel
  // =====================================================================
  Future<bool> connecter({
    required String email,
    required String motDePasse,
  }) async {
    _authError = null;
    _setLoading(true);

    final result = await SupabaseService.connecter(
      email: email,
      motDePasse: motDePasse,
    );

    if (!result.success) {
      _authError = result.error;
      _setLoading(false);
      return false;
    }

    _userId = result.userId;
    await SecureStorageService.sauvegarderSession(
      userId: _userId!,
      accessToken: result.accessToken!,
      refreshToken: SupabaseService.refreshTokenCourant ?? '',
      authType: 'email',
    );
    _isAuthenticated = true;

    // Charger les référentiels + données métier
    await _chargerVilles();
    await _loadProfil();
    await _loadDemandes();
    // Notifications depuis le backend (source de vérité)
    await _chargerNotificationsBackend();
    _recalculerCompatibilite();

    _setLoading(false);
    return true;
  }

  // =====================================================================
  // DÉCONNEXION — Invalide le JWT côté Supabase + purge locale
  // =====================================================================
  Future<void> seDeconnecter() async {
    await SupabaseService.deconnecter();
    await _purgerSessionLocale();
  }

  Future<void> _purgerSessionLocale() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in _toutesLesClesCache) {
      await prefs.remove(key);
    }
    await SecureStorageService.supprimerSession();

    _userId = null;
    _profil = null;
    _isAuthenticated = false;
    _suppressionProgrammee = false;
    _dateSuppression = null;
    _demandes = [];
    _notifications = [];
    _villes = [];
    _villesMap = {};
    _authError = null;
    notifyListeners();
  }

  // =====================================================================
  // PROFIL
  // =====================================================================
  Future<void> sauvegarderProfil(ProfilDonneur profil) async {
    _profil = profil;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyProfil, jsonEncode(profil.toJson()));
    await SupabaseService.creerOuMettreAJourProfil(profil);
    notifyListeners();
  }

  Future<void> toggleDisponibilite() async {
    if (_profil == null || _userId == null) return;
    final updated = _profil!.copyWith(disponible: !_profil!.disponible);
    await SupabaseService.mettreAJourDisponibilite(
        _userId!, updated.disponible);
    await sauvegarderProfil(updated);
  }

  Future<void> declarerDon(DateTime dateDon) async {
    if (_profil == null || _userId == null) return;
    final updated = _profil!.copyWith(dernierDonDate: dateDon);
    await sauvegarderProfil(updated);
    await SupabaseService.enregistrerDon(
      donneurId: _userId!,
      dateDon: dateDon,
      source: SourceDon.declaratif,
    );
    _ajouterNotificationLocale(NotificationSauve(
      id: _genId(),
      type: TypeNotification.donConfirme,
      message: 'Votre don a été enregistré. Merci pour votre générosité.',
      createdAt: DateTime.now(),
    ));
  }

  // =====================================================================
  // DEMANDES
  // =====================================================================

  /// Publie une nouvelle demande de sang.
  /// Accepte les IDs entiers (ville_id, structure_id) depuis le schéma réel.
  Future<CreationDemandeResult> publierDemande({
    required GroupeSanguin groupeSanguin,
    required int? villeId,
    required int? structureId,
    String? villeLibre,
    String? structureLibre,
    required String contactPrincipal,
    String? contactSecondaire,
  }) async {
    if (_userId == null) {
      return const CreationDemandeResult(
          success: false, error: 'Non authentifié.');
    }

    final result = await SupabaseService.creerDemande(
      userId: _userId!,
      groupeSanguin: groupeSanguin,
      villeId: villeId,
      structureId: structureId,
      villeLibre: villeLibre,
      structureLibre: structureLibre,
      contactPrincipal: contactPrincipal,
      contactSecondaire: contactSecondaire,
    );

    if (result.success && result.demande != null) {
      _demandes.insert(0, result.demande!);
      await _sauvegarderDemandes();
      final villeAffichage = villeId != null
          ? (_villesMap[villeId] ?? villeLibre ?? '')
          : (villeLibre ?? '');
      _ajouterNotificationLocale(NotificationSauve(
        id: _genId(),
        type: TypeNotification.demandeCompatible,
        message:
            'Votre demande de sang ${groupeSanguin.label} a été publiée'
            '${villeAffichage.isNotEmpty ? " à $villeAffichage" : ""}.',
        createdAt: DateTime.now(),
      ));
      notifyListeners();
    }
    return result;
  }

  /// Actualise les demandes depuis le backend.
  Future<void> actualiserDemandes() async {
    if (_profil == null) return;
    if (_profil!.villeId <= 0) return;
    final demandesBackend = await SupabaseService.lireDemandesActives(
      _profil!.villeId,
      villesMap: _villesMap,
    );
    if (demandesBackend.isNotEmpty) {
      _demandes = demandesBackend;
      _recalculerCompatibilite();
      await _sauvegarderDemandes();
      notifyListeners();
    }
  }

  // =====================================================================
  // NOTIFICATIONS — Source de vérité : public.notifications_envoyees
  // =====================================================================

  /// Charge les notifications depuis le backend (source de vérité).
  /// Met à jour le cache local après chaque chargement réussi.
  Future<void> _chargerNotificationsBackend() async {
    if (_userId == null || !SupabaseService.estConfigured) return;
    try {
      final notifs = await SupabaseService.lireNotifications(_userId!);
      if (notifs.isNotEmpty) {
        _notifications = notifs;
        await _sauvegarderNotifications();
        notifyListeners();
      }
    } catch (_) {
      // Non bloquant — fallback cache déjà chargé
    }
  }

  /// Actualise l'onglet notifications depuis le backend.
  Future<void> actualiserNotifications() async {
    await _chargerNotificationsBackend();
  }

  // =====================================================================
  // RÉPONSE DONNEUR — Persistée en base
  // =====================================================================
  Future<bool> enregistrerReponseDonneur(String demandeId) async {
    if (_userId == null) return false;
    final ok = await SupabaseService.enregistrerReponseDonneur(
      donneurId: _userId!,
      demandeId: demandeId,
    );
    if (ok) {
      _ajouterNotificationLocale(NotificationSauve(
        id: _genId(),
        type: TypeNotification.demandeCompatible,
        message: 'Votre réponse a été enregistrée. Rendez-vous sur place.',
        createdAt: DateTime.now(),
      ));
    }
    return ok;
  }

  // =====================================================================
  // QR TOKEN — [PERF-05] Déduplication avant création
  // =====================================================================
  Future<String?> genererQrToken(String demandeId) async {
    if (_userId == null) return null;

    final tokenExistant = await SupabaseService.lireTokenQrExistant(
      donneurId: _userId!,
      demandeId: demandeId,
    );
    if (tokenExistant != null) return tokenExistant;

    final result = await SupabaseService.creerToken(_userId!, demandeId);
    if (result.success) return result.tokenOpaque;
    return null;
  }

  // =====================================================================
  // SUPPRESSION DE COMPTE J+5
  // =====================================================================
  Future<bool> programmerSuppression() async {
    if (_userId == null) return false;
    final ok = await SupabaseService.programmerSuppression(_userId!);
    if (ok) {
      _suppressionProgrammee = true;
      _dateSuppression = DateTime.now().add(const Duration(days: 5));
      notifyListeners();
    }
    return ok;
  }

  Future<bool> annulerSuppression() async {
    if (_userId == null) return false;
    final ok = await SupabaseService.annulerSuppression(_userId!);
    if (ok) {
      _suppressionProgrammee = false;
      _dateSuppression = null;
      notifyListeners();
    }
    return ok;
  }

  // =====================================================================
  // MÉTHODES PRIVÉES
  // =====================================================================
  void _setLoading(bool val) {
    _isLoading = val;
    notifyListeners();
  }

  /// Ajoute une notification locale (actions client-side) sans appel réseau.
  void _ajouterNotificationLocale(NotificationSauve notif) {
    _notifications.insert(0, notif);
    _sauvegarderNotifications();
    notifyListeners();
  }

  String _genId() => DateTime.now().millisecondsSinceEpoch.toString();

  Future<void> _loadProfil() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyProfil) ??
        prefs.getString('sauve_profil'); // migration
    if (json != null) {
      try {
        _profil =
            ProfilDonneur.fromJson(jsonDecode(json) as Map<String, dynamic>);
      } catch (_) {
        _profil = null;
      }
    }
  }

  Future<void> _loadDemandes() async {
    if (_profil != null &&
        _profil!.villeId > 0 &&
        SupabaseService.estConfigured) {
      final demandesBackend = await SupabaseService.lireDemandesActives(
        _profil!.villeId,
        villesMap: _villesMap,
      );
      if (demandesBackend.isNotEmpty) {
        _demandes = demandesBackend;
        _recalculerCompatibilite();
        await _sauvegarderDemandes();
        return;
      }
    }
    await _loadDemandesDepuisCache();
  }

  /// [PERF-03] Charge uniquement depuis le cache local.
  Future<void> _loadDemandesDepuisCache() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyDemandes) ??
        prefs.getString('sauve_demandes'); // migration
    if (json != null) {
      try {
        final list = jsonDecode(json) as List;
        _demandes = list
            .map((e) => DemandeSang.fromJson(
                  e as Map<String, dynamic>,
                  villesMap: _villesMap,
                ))
            .where((d) => d.estActive)
            .toList();
        _recalculerCompatibilite();
      } catch (_) {
        _demandes = [];
      }
    }
  }

  /// Charge les notifications depuis le cache local (fallback hors-ligne).
  /// La source de vérité est _chargerNotificationsBackend().
  Future<void> _loadNotificationsDepuisCache() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyNotifications) ??
        prefs.getString('sauve_notifications'); // migration
    if (json != null) {
      try {
        final list = jsonDecode(json) as List;
        _notifications = list
            .map((e) => NotificationSauve.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _notifications = [];
      }
    }
  }

  Future<void> _sauvegarderDemandes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _keyDemandes,
        jsonEncode(_demandes.map((d) => d.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _sauvegarderNotifications() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _keyNotifications,
        jsonEncode(_notifications.map((n) => n.toJson()).toList()),
      );
    } catch (_) {}
  }
}
