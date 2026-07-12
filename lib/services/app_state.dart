import 'dart:async'; // unawaited()
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../utils/secure_storage_service.dart';
import '../utils/crypto_service.dart';
import '../services/supabase_service.dart';
import '../services/notification_service.dart'; // [P7] Token FCM

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
  String? _emailCourant; // Mémorisé à la connexion — évite un appel réseau dans ChangePasswordScreen (S4)
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
  List<DemandeSang> _demandes = [];           // Demandes filtrées par ville (accueil + compatibilité)
  List<DemandeSang> _toutesLesDemandes = [];  // Toutes les demandes actives (onglet Demandes)
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
  /// Email de l'utilisateur connecté, mémorisé à la connexion.
  /// Null si non encore connecté. Utilisé par ChangePasswordScreen pour
  /// éviter un appel réseau redondant à obtenirEmailCourant() (correction S4).
  String? get emailCourant => _emailCourant;
  List<DemandeSang> get demandes => _demandes;
  /// Toutes les demandes actives, toutes villes confondues — pour l'onglet "Demandes".
  List<DemandeSang> get toutesLesDemandes => _toutesLesDemandes;
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
        // [P7] Ré-enregistrer le token FCM à chaque restauration de session
        // (le token peut avoir été renouvelé par Firebase depuis la dernière connexion).
        unawaited(NotificationService.initialiser(_userId!));
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
      // On mémorise l'userId pour que sauvegarderProfil() puisse écrire en DB.
      // On NE met PAS _isAuthenticated=true ici — c'est sauvegarderProfil()
      // qui le fera après création du profil, évitant que GoRouter redirige
      // vers /completer-profil AVANT que l'utilisateur ait soumis le formulaire.
      _userId = result.userId;
      await SecureStorageService.sauvegarderSession(
        userId: _userId!,
        accessToken: result.accessToken!,
        refreshToken: SupabaseService.refreshTokenCourant ?? '',
        authType: 'email',
      );
      // NE PAS appeler notifyListeners() ici — on n'est pas encore authentifié
      // du point de vue de l'application (le profil n'est pas encore créé).
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
    _emailCourant = email; // Mémorisé ici — évite un appel réseau dans ChangePasswordScreen (S4)
    await SecureStorageService.sauvegarderSession(
      userId: _userId!,
      accessToken: result.accessToken!,
      refreshToken: SupabaseService.refreshTokenCourant ?? '',
      authType: 'email',
    );
    _isAuthenticated = true;

    // Charger les référentiels + données métier.
    // Le bloc try/finally garantit que _setLoading(false) est TOUJOURS appelé,
    // même si _chargerVilles() ou _loadDemandes() lèvent une exception réseau.
    // Sans ce garde, une exception non capturée laisse le spinner figé (S1-A).
    try {
      await _chargerVilles();
      final profilCharge = await _loadProfilAvecFallback();
      await _loadDemandes();
      await _chargerNotificationsBackend();
      // [P7] Enregistrer le token FCM pour les notifications push.
      // Non bloquant : une exception ici ne doit pas empêcher la connexion.
      // Ignoré sur Web (kIsWeb guard interne à NotificationService).
      unawaited(NotificationService.initialiser(_userId!));
      _recalculerCompatibilite();
      // Si le profil n'a pu être chargé ni depuis le backend ni depuis le cache,
      // remonter un avertissement — la session est valide, mais l'utilisateur
      // doit compléter son profil ou vérifier sa connexion.
      if (!profilCharge && _profil == null) {
        _authError =
            'Connecté, mais impossible de charger votre profil. '
            'Vérifiez votre connexion et réessayez.';
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AppState] connecter() — chargement post-auth: $e');
      }
      // En cas d'exception non anticipée, remonter l'erreur si le profil est absent.
      if (_profil == null) {
        _authError =
            'Connecté, mais impossible de charger votre profil. '
            'Vérifiez votre connexion et réessayez.';
      }
      // On ne déconnecte pas l'utilisateur : la session est valide.
      // Les données manquantes seront rechargées au prochain rafraîchissement.
    } finally {
      _setLoading(false);
    }
    return true;
  }

  // =====================================================================
  // DÉCONNEXION — Invalide le JWT côté Supabase + purge locale
  // =====================================================================
  Future<void> seDeconnecter() async {
    // Activer le loading pendant la déconnexion pour bloquer les redirects
    // GoRouter intermédiaires (isLoading guard dans router.dart).
    // Sans ce guard, un notifyListeners() background (ex: _rafraichirDonneesBackground)
    // peut évaluer le redirect avec isAuth=true + profil=null → boucle /completer-profil.
    _setLoading(true);
    await SupabaseService.deconnecter();
    await _purgerSessionLocale();
    // _purgerSessionLocale() appelle notifyListeners() en fin avec isAuth=false,
    // profil=null, isLoading=false (via _setLoading(false) dans finally non nécessaire
    // car _purgerSessionLocale réinitialise tout directement).
  }

  Future<void> _purgerSessionLocale() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in _toutesLesClesCache) {
      await prefs.remove(key);
    }
    await SecureStorageService.supprimerSession();

    _userId = null;
    _emailCourant = null; // Effacer l'email mémorisé à la déconnexion (S4)
    _profil = null;
    _isAuthenticated = false;
    _isLoading = false; // Libérer le guard de transition (déconnexion + init)
    _suppressionProgrammee = false;
    _dateSuppression = null;
    _demandes = [];
    _toutesLesDemandes = [];
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

    // [Fix #3] Après inscription, _userId est défini mais _isAuthenticated=false.
    // On finalise l'authentification ici, une fois le profil prêt.
    // Fallback : si userId vient de SupabaseService (ex: connexion directe).
    if (_userId == null && SupabaseService.currentUserId != null) {
      _userId = SupabaseService.currentUserId;
    }
    // Marquer comme authentifié maintenant que le profil est créé
    if (_userId != null) {
      _isAuthenticated = true;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyProfil, jsonEncode(profil.toJson()));
    await SupabaseService.creerOuMettreAJourProfil(profil);
    notifyListeners(); // GoRouter voit isAuth=true + hasProfil=true → redirige vers /home
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
    // ── Correction 2.8.2 (audit 2026-07-09) : suppression de la double-écriture.
    // Ancienne version : sauvegarderProfil(updated) + enregistrerDon().
    // Les deux écrivaient dernier_don_date en base → double PATCH.
    // Correction : mise à jour optimiste locale uniquement, puis appel EF don-manuel
    // qui gère seul la mise à jour DB (profils_donneurs + historique_dons + notif).
    final updated = _profil!.copyWith(dernierDonDate: dateDon);
    // Mise à jour locale optimiste (UI immédiate, sans PATCH réseau)
    _profil = updated;
    notifyListeners();
    // Appel EF — écrit dernier_don_date, insère historique_dons, envoie notif
    await SupabaseService.enregistrerDon(
      donneurId: _userId!,
      dateDon: dateDon,
      source: SourceDon.declaratif,
    );
    _ajouterNotificationLocale(NotificationSauve(
      id: _genId(),
      type: TypeNotification.donEnregistreManuel,
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

  /// Actualise la liste complète des demandes (toutes villes) pour l'onglet "Demandes".
  /// N'affecte pas [_demandes] (demandes par ville pour l'accueil + compatibilité).
  Future<void> actualiserToutesLesDemandes() async {
    if (!SupabaseService.estConfigured) return;
    try {
      final toutes = await SupabaseService.lireToutesDemandesActives(
        villesMap: _villesMap,
      );
      _toutesLesDemandes = toutes;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AppState] actualiserToutesLesDemandes: $e');
      }
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

  /// Marque une notification comme lue (optimiste + backend).
  /// Met à jour le cache local immédiatement, puis persiste en base.
  Future<void> marquerNotificationLue(String notifId) async {
    // Mise à jour optimiste locale
    final idx = _notifications.indexWhere((n) => n.id == notifId);
    if (idx == -1) return;
    final notif = _notifications[idx];
    if (notif.lue) return; // déjà lue, rien à faire

    // Remplacer par une version marquée lue (modèle immutable)
    _notifications[idx] = NotificationSauve(
      id: notif.id,
      type: notif.type,
      message: notif.message,
      createdAt: notif.createdAt,
      lue: true,
      demandeId: notif.demandeId,
    );
    await _sauvegarderNotifications();
    notifyListeners();

    // Persistance backend (fire-and-forget — non bloquant)
    if (_userId != null && SupabaseService.estConfigured) {
      SupabaseService.marquerNotificationLue(notifId).catchError((_) => false);
    }
  }

  /// Marque toutes les notifications non lues comme lues.
  Future<void> marquerToutesLues() async {
    final nonLues = _notifications.where((n) => !n.lue).toList();
    if (nonLues.isEmpty) return;

    // Mise à jour optimiste locale
    _notifications = _notifications.map((n) {
      if (n.lue) return n;
      return NotificationSauve(
        id: n.id,
        type: n.type,
        message: n.message,
        createdAt: n.createdAt,
        lue: true,
        demandeId: n.demandeId,
      );
    }).toList();
    await _sauvegarderNotifications();
    notifyListeners();

    // Backend : une requête par notification (fire-and-forget)
    if (_userId != null && SupabaseService.estConfigured) {
      for (final n in nonLues) {
        SupabaseService.marquerNotificationLue(n.id).catchError((_) => false);
      }
    }
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

  /// Charge le profil en essayant d'abord le backend (source de vérité),
  /// avec 2 tentatives (retry après 1 s en cas d'erreur réseau passagère),
  /// puis fallback sur le cache local.
  ///
  /// Retourne `true` si un profil a pu être chargé (backend ou cache),
  /// `false` si aucune source n'a fourni de données.
  Future<bool> _loadProfilAvecFallback() async {
    // 1. Essayer le backend (source de vérité) — 2 tentatives max
    if (_userId != null && SupabaseService.estConfigured) {
      for (int tentative = 0; tentative < 2; tentative++) {
        try {
          final profilBackend = await SupabaseService.lireProfil(
            _userId!,
            villesMap: _villesMap,
          );
          if (profilBackend != null) {
            _profil = profilBackend;
            // Mettre à jour le cache local avec les données backend fraîches
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_keyProfil, jsonEncode(profilBackend.toJson()));
            return true;
          }
          // Profil confirmé absent côté serveur (utilisateur nouveau) — inutile de réessayer
          break;
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[AppState] _loadProfilAvecFallback() tentative ${tentative + 1}/2 : $e');
          }
          if (tentative == 0) {
            // Première tentative échouée → attendre 1 s avant le retry
            await Future.delayed(const Duration(seconds: 1));
            continue;
          }
          // Deuxième tentative échouée → sortir et tenter le cache
        }
      }
    }
    // 2. Fallback sur le cache local
    await _loadProfil();
    return _profil != null;
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
