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
// Données : backend Supabase uniquement (plus de mode démo forcé)
// =====================================================================
class AppState extends ChangeNotifier {
  // Clés SharedPreferences (données non-sensibles)
  static const String _keyProfil        = 'songre_profil';
  static const String _keyDemandes      = 'songre_demandes';
  static const String _keyNotifications = 'songre_notifications';

  static const List<String> _toutesLesClesCache = [
    _keyProfil,
    _keyDemandes,
    _keyNotifications,
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

  // ---- Données ----
  List<DemandeSang> _demandes = [];
  List<NotificationSauve> _notifications = [];

  // ---- [PERF-01] Cache de compatibilité pré-calculé ----
  // Mis à jour chaque fois que _demandes ou _profil change.
  // Évite de recalculer estCompatibleAvec() dans chaque build() de widget.
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

  /// [PERF-01] Liste des demandes compatibles avec le profil courant.
  /// Pré-calculée — jamais recalculée dans un build() de widget.
  List<DemandeSang> get demandesCompatibles => _demandesCompatibles;

  /// [PERF-01] Recalcule la liste des demandes compatibles.
  /// Appelé après chaque mise à jour de _demandes ou _profil.
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
  // 1. Restaurer JWT (bloquant — nécessaire pour les headers)
  // 2. Charger cache local IMMÉDIATEMENT + notifier l'UI
  // 3. Rafraîchir en arrière-plan depuis le backend (non-bloquant)
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
        await _loadProfil();
        await _loadDemandesDepuisCache();
        await _loadNotifications();
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
    if (_profil == null || !SupabaseService.estConfigured) return;
    try {
      final demandesBackend =
          await SupabaseService.lireDemandesActives(_profil!.ville);
      if (demandesBackend.isNotEmpty) {
        _demandes = demandesBackend;
        _recalculerCompatibilite();
        await _sauvegarderDemandes();
        notifyListeners(); // ← second rendu avec données fraîches
      }
    } catch (_) {
      // Non bloquant — le cache est déjà affiché
    }
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
      // Retourner true mais sans session active (email à confirmer)
      return true;
    }

    if (result.userId != null && result.accessToken != null) {
      _userId = result.userId;
      await SecureStorageService.sauvegarderSession(
        userId: _userId!,
        accessToken: result.accessToken!,
        // [1.3] Persister le vrai refresh_token — peut être absent si email
        // confirmation est requise (session=null), on stocke '' dans ce cas.
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
      // [1.3] Persister le vrai refresh_token reçu de Supabase Auth
      refreshToken: SupabaseService.refreshTokenCourant ?? '',
      authType: 'email',
    );
    _isAuthenticated = true;
    await _loadProfil();
    await _loadDemandes();
    await _loadNotifications();
    _recalculerCompatibilite(); // [PERF-01]

    _setLoading(false);
    return true;
  }

  // =====================================================================
  // DÉCONNEXION — Invalide le JWT côté Supabase + purge locale
  // =====================================================================
  Future<void> seDeconnecter() async {
    await SupabaseService.deconnecter(); // POST /auth/v1/logout
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
    _ajouterNotification(NotificationSauve(
      id: _genId(),
      type: TypeNotification.donConfirme,
      message: 'Votre don a été enregistré. Merci pour votre générosité.',
      createdAt: DateTime.now(),
    ));
  }

  // =====================================================================
  // DEMANDES
  // =====================================================================
  Future<CreationDemandeResult> publierDemande({
    required GroupeSanguin groupeSanguin,
    required String ville,
    required String structureSanitaire,
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
      ville: ville,
      structureSanitaire: structureSanitaire,
      contactPrincipal: contactPrincipal,
      contactSecondaire: contactSecondaire,
    );

    if (result.success && result.demande != null) {
      _demandes.insert(0, result.demande!);
      await _sauvegarderDemandes();
      _ajouterNotification(NotificationSauve(
        id: _genId(),
        type: TypeNotification.demandeCompatible,
        message:
            'Votre demande de sang ${groupeSanguin.label} a été publiée à $ville.',
        createdAt: DateTime.now(),
      ));
      notifyListeners();
    }
    return result;
  }

  /// Charge les demandes depuis le backend — fallback cache local uniquement
  Future<void> actualiserDemandes() async {
    if (_profil == null) return;
    final demandesBackend =
        await SupabaseService.lireDemandesActives(_profil!.ville);
    if (demandesBackend.isNotEmpty) {
      _demandes = demandesBackend;
      await _sauvegarderDemandes();
      notifyListeners();
    }
    // Pas de fallback démo en production
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
      _ajouterNotification(NotificationSauve(
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
  /// [PERF-05] Vérifie d'abord si un token QR valide (non expiré, non
  /// utilisé) existe déjà pour le couple donneur+demande. Évite la
  /// multiplication de tokens orphelins en base.
  Future<String?> genererQrToken(String demandeId) async {
    if (_userId == null) return null;

    // Chercher un token existant valide — évite de créer des doublons
    final tokenExistant = await SupabaseService.lireTokenQrExistant(
      donneurId: _userId!,
      demandeId: demandeId,
    );
    if (tokenExistant != null) return tokenExistant;

    // Créer un nouveau token uniquement si aucun valide n'existe
    final result = await SupabaseService.creerToken(_userId!, demandeId);
    if (result.success) return result.tokenOpaque;
    return null;
  }

  // =====================================================================
  // SUPPRESSION DE COMPTE J+5
  // =====================================================================
  Future<bool> programmerSuppression() async {
    if (_userId == null) return false;
    final ok =
        await SupabaseService.programmerSuppression(_userId!);
    if (ok) {
      _suppressionProgrammee = true;
      _dateSuppression =
          DateTime.now().add(const Duration(days: 5));
      notifyListeners();
    }
    return ok;
  }

  Future<bool> annulerSuppression() async {
    if (_userId == null) return false;
    final ok =
        await SupabaseService.annulerSuppression(_userId!);
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

  void _ajouterNotification(NotificationSauve notif) {
    _notifications.insert(0, notif);
    _sauvegarderNotifications();
    notifyListeners();
  }

  String _genId() =>
      DateTime.now().millisecondsSinceEpoch.toString();

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
    // Tenter d'abord le backend
    if (_profil != null && SupabaseService.estConfigured) {
      final demandesBackend =
          await SupabaseService.lireDemandesActives(_profil!.ville);
      if (demandesBackend.isNotEmpty) {
        _demandes = demandesBackend;
        _recalculerCompatibilite(); // [PERF-01]
        await _sauvegarderDemandes();
        return;
      }
    }
    await _loadDemandesDepuisCache();
  }

  /// [PERF-03] Charge uniquement depuis le cache local (sans appel réseau).
  /// Utilisé par init() pour un affichage immédiat, avant le rafraîchissement
  /// arrière-plan.
  Future<void> _loadDemandesDepuisCache() async {
    // Fallback : cache local
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyDemandes) ??
        prefs.getString('sauve_demandes'); // migration
    if (json != null) {
      try {
        final list = jsonDecode(json) as List;
        _demandes = list
            .map((e) => DemandeSang.fromJson(e as Map<String, dynamic>))
            .where((d) => d.estActive)
            .toList();
        _recalculerCompatibilite(); // [PERF-01]
      } catch (_) {
        _demandes = [];
      }
    }
  }

  Future<void> _loadNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyNotifications) ??
        prefs.getString('sauve_notifications'); // migration
    if (json != null) {
      try {
        final list = jsonDecode(json) as List;
        _notifications = list
            .map((e) => NotificationSauve(
                  id: e['id'] as String,
                  type: TypeNotification.values[e['type'] as int],
                  message: e['message'] as String,
                  createdAt: DateTime.parse(e['created_at'] as String),
                  lue: e['lue'] as bool? ?? false,
                ))
            .toList();
        if (_notifications.isNotEmpty) return;
      } catch (_) {
        // fallthrough
      }
    }
    // Pas de données démo en production
  }

  Future<void> _sauvegarderDemandes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyDemandes,
      jsonEncode(_demandes.map((d) => d.toJson()).toList()),
    );
  }

  Future<void> _sauvegarderNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _notifications
        .map((n) => {
              'id': n.id,
              'type': n.type.index,
              'message': n.message,
              'created_at': n.createdAt.toIso8601String(),
              'lue': n.lue,
            })
        .toList();
    await prefs.setString(_keyNotifications, jsonEncode(list));
  }
}
