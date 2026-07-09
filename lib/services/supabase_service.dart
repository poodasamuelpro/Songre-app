import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import '../utils/crypto_service.dart';
import '../utils/secure_storage_service.dart';

// =====================================================================
// SERVICE SUPABASE — Production SONGRE
//
// Configuration via --dart-define :
//   SUPABASE_URL=https://ptomqwucvveuflfnyczo.supabase.co
//   SUPABASE_ANON_KEY=eyJ...
//   SONGRE_ENCRYPT_KEY=<32 chars minimum>
//
// Authentification : Email / Mot de passe via Supabase Auth
// Token : JWT signé retourné par /auth/v1/token?grant_type=password
// Schéma PostgreSQL : public.* (schéma réel — PAS sante.* ni identite.*)
//
// IMPORTANT : La Service Role Key n'appartient JAMAIS à ce fichier.
//             Elle est injectée exclusivement dans les Edge Functions
//             via les secrets Supabase Dashboard.
// =====================================================================
class SupabaseService {
  SupabaseService._();

  static const String _supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const String _anonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  /// JWT retourné par Supabase Auth — sert de Bearer token
  static String? _accessToken;
  static String? _refreshToken;
  static String? _currentUserId;

  static bool get estConfigured =>
      _supabaseUrl.isNotEmpty && _anonKey.isNotEmpty;

  static String? get currentUserId => _currentUserId;

  /// Expose le refresh token courant (lecture seule) pour persistance
  static String? get refreshTokenCourant => _refreshToken;

  // ---- Headers communs ----
  static Map<String, String> _headers({bool withAuth = false}) {
    final h = {
      'Content-Type': 'application/json',
      'apikey': _anonKey,
    };
    if (withAuth && _accessToken != null) {
      h['Authorization'] = 'Bearer $_accessToken';
    }
    return h;
  }

  static Map<String, String> _restHeaders({bool withAuth = true}) {
    return {
      ..._headers(withAuth: withAuth),
      'Prefer': 'return=representation',
    };
  }

  // =====================================================================
  // AUTHENTIFICATION — Email / Mot de passe (Supabase Auth V2)
  // =====================================================================

  /// Inscription avec email + mot de passe
  static Future<AuthResult> inscrire({
    required String email,
    required String motDePasse,
  }) async {
    if (!estConfigured) {
      return const AuthResult(
        success: false,
        error: 'Backend non configuré. Contactez l\'administrateur.',
      );
    }
    try {
      final resp = await http.post(
        Uri.parse('$_supabaseUrl/auth/v1/signup'),
        headers: _headers(),
        body: jsonEncode({
          'email': email,
          'password': motDePasse,
        }),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      if (resp.statusCode == 200) {
        final session = data['session'] as Map<String, dynamic>?;
        if (session != null) {
          _accessToken = session['access_token'] as String?;
          _refreshToken = session['refresh_token'] as String?;
          final user = data['user'] as Map<String, dynamic>?;
          _currentUserId = user?['id'] as String?;
          return AuthResult(
            success: true,
            userId: _currentUserId,
            accessToken: _accessToken,
          );
        }
        // Email confirmation required
        return const AuthResult(
          success: true,
          userId: null,
          needsEmailConfirmation: true,
        );
      }

      final msg = data['error_description'] as String? ??
          data['msg'] as String? ??
          'Erreur lors de l\'inscription (${resp.statusCode})';
      return AuthResult(success: false, error: msg);
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] inscrire error: $e');
      return const AuthResult(
          success: false, error: 'Connexion impossible. Vérifiez votre réseau.');
    }
  }

  /// Connexion avec email + mot de passe → JWT réel
  static Future<AuthResult> connecter({
    required String email,
    required String motDePasse,
  }) async {
    if (!estConfigured) {
      return const AuthResult(
        success: false,
        error: 'Backend non configuré. Contactez l\'administrateur.',
      );
    }
    try {
      final resp = await http.post(
        Uri.parse(
            '$_supabaseUrl/auth/v1/token?grant_type=password'),
        headers: _headers(),
        body: jsonEncode({
          'email': email,
          'password': motDePasse,
        }),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      if (resp.statusCode == 200) {
        _accessToken = data['access_token'] as String?;
        _refreshToken = data['refresh_token'] as String?;
        final user = data['user'] as Map<String, dynamic>?;
        _currentUserId = user?['id'] as String?;
        return AuthResult(
          success: true,
          userId: _currentUserId,
          accessToken: _accessToken,
        );
      }

      final msg = data['error_description'] as String? ??
          data['msg'] as String? ??
          'Email ou mot de passe incorrect.';
      return AuthResult(success: false, error: msg);
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] connecter error: $e');
      return const AuthResult(
          success: false, error: 'Connexion impossible. Vérifiez votre réseau.');
    }
  }

  /// Rafraîchissement du JWT avec le refresh_token.
  /// [1.3] Persiste automatiquement les nouveaux tokens dans SecureStorage.
  static Future<bool> rafraichirToken(String refreshToken) async {
    if (!estConfigured) return false;
    try {
      final resp = await http.post(
        Uri.parse(
            '$_supabaseUrl/auth/v1/token?grant_type=refresh_token'),
        headers: _headers(),
        body: jsonEncode({'refresh_token': refreshToken}),
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _accessToken = data['access_token'] as String?;
        _refreshToken = data['refresh_token'] as String?;
        final user = data['user'] as Map<String, dynamic>?;
        _currentUserId = user?['id'] as String?;
        // Persister immédiatement les tokens rafraîchis
        if (_accessToken != null && _refreshToken != null) {
          await SecureStorageService.mettreAJourTokens(
            accessToken: _accessToken!,
            refreshToken: _refreshToken!,
          );
        }
        return true;
      }
      return false;
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] rafraichirToken error: $e');
      return false;
    }
  }

  /// [1.3] Intercepteur 401 — réessaie la requête après rafraîchissement
  /// automatique si la réponse est 401 (JWT expiré).
  static Future<http.Response> _requeteAvecRefresh(
      Future<http.Response> Function() makeRequest) async {
    final resp = await makeRequest();
    if (resp.statusCode == 401 && _refreshToken != null) {
      final refreshed = await rafraichirToken(_refreshToken!);
      if (refreshed) return makeRequest();
    }
    return resp;
  }

  /// Déconnexion — invalide la session côté serveur (POST /auth/v1/logout)
  static Future<void> deconnecter() async {
    if (!estConfigured || _accessToken == null) {
      _accessToken = null;
      _refreshToken = null;
      _currentUserId = null;
      return;
    }
    try {
      await http.post(
        Uri.parse('$_supabaseUrl/auth/v1/logout'),
        headers: _headers(withAuth: true),
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] deconnecter error: $e');
    } finally {
      _accessToken = null;
      _refreshToken = null;
      _currentUserId = null;
    }
  }

  /// Restaure une session existante depuis les tokens sauvegardés
  static Future<bool> restaurerSession({
    required String accessToken,
    required String refreshToken,
    required String userId,
  }) async {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _currentUserId = userId;

    // Valider le JWT en tentant un appel léger
    if (!estConfigured) return true; // confiance locale si pas de réseau
    try {
      final resp = await http.get(
        Uri.parse('$_supabaseUrl/auth/v1/user'),
        headers: _headers(withAuth: true),
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) return true;

      // JWT expiré → tenter refresh
      if (resp.statusCode == 401) {
        return rafraichirToken(refreshToken);
      }
      return false;
    } catch (_) {
      // Pas de réseau — on garde la session locale
      return true;
    }
  }

  // =====================================================================
  // RÉFÉRENTIELS — Villes et structures sanitaires (public.*)
  // =====================================================================

  /// Charge la liste des villes actives depuis public.villes
  static Future<List<Ville>> lireVilles() async {
    if (!estConfigured) return [];
    try {
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/villes'
        '?active=eq.true'
        '&order=nom.asc',
      );
      final resp = await _requeteAvecRefresh(
        () => http.get(url, headers: _restHeaders(withAuth: true))
            .timeout(const Duration(seconds: 10)),
      );
      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        return list.map((e) => Ville.fromJson(e as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] lireVilles error: $e');
      return [];
    }
  }

  /// Charge les structures sanitaires actives d'une ville donnée
  static Future<List<StructureSanitaire>> lireStructures(int villeId) async {
    if (!estConfigured) return [];
    try {
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/structures_sanitaires'
        '?ville_id=eq.$villeId'
        '&active=eq.true'
        '&order=nom.asc',
      );
      final resp = await _requeteAvecRefresh(
        () => http.get(url, headers: _restHeaders(withAuth: true))
            .timeout(const Duration(seconds: 10)),
      );
      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        return list
            .map((e) => StructureSanitaire.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] lireStructures error: $e');
      return [];
    }
  }

  // =====================================================================
  // PROFIL DONNEUR — Création et modification (schéma public.*)
  // =====================================================================
  static Future<bool> creerOuMettreAJourProfil(ProfilDonneur profil) async {
    if (!estConfigured) {
      if (kDebugMode) debugPrint('[SupabaseService] Pas de backend configuré');
      return false;
    }

    final hdrs = {
      ..._restHeaders(withAuth: true),
      'Prefer': 'return=minimal,resolution=merge-duplicates',
    };
    // Utiliser toJsonPourBase() qui chiffre poids + CI et envoie ville_id (int)
    final body = jsonEncode(profil.toJsonPourBase());

    try {
      final url = Uri.parse('$_supabaseUrl/rest/v1/profils_donneurs');
      final resp = await _requeteAvecRefresh(
        () => http.post(url, headers: hdrs, body: body)
            .timeout(const Duration(seconds: 10)),
      );

      return resp.statusCode == 201 ||
          resp.statusCode == 200 ||
          resp.statusCode == 204;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] creerOuMettreAJourProfil error: $e');
      }
      return false;
    }
  }

  /// Charge le profil depuis le backend, déchiffre poids + CI.
  /// Nécessite la map des villes pour résoudre ville_nom.
  static Future<ProfilDonneur?> lireProfil(
    String userId, {
    Map<int, String>? villesMap,
  }) async {
    if (!estConfigured) return null;
    try {
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/profils_donneurs'
        '?user_id=eq.$userId'
        '&limit=1',
      );
      final resp = await _requeteAvecRefresh(
        () => http.get(url, headers: _restHeaders(withAuth: true))
            .timeout(const Duration(seconds: 10)),
      );
      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        if (list.isEmpty) return null;
        final json = list[0] as Map<String, dynamic>;
        final villeId = json['ville_id'] as int? ?? 0;
        final villeNom = villesMap?[villeId] ?? '';
        return ProfilDonneur.fromBase(json, villeNom: villeNom);
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] lireProfil error: $e');
      return null;
    }
  }

  // =====================================================================
  // DEMANDES DE SANG — Lecture et création (schéma public.*)
  // =====================================================================

  /// Charge les demandes actives pour une ville (filtre par ville_id).
  static Future<List<DemandeSang>> lireDemandesActives(
    int villeId, {
    Map<int, String>? villesMap,
    Map<int, String>? structuresMap,
  }) async {
    if (!estConfigured) return [];

    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/demandes_sang'
        '?ville_id=eq.$villeId'
        '&statut=eq.active'
        '&expires_at=gt.$now'
        '&order=created_at.desc'
        '&limit=50',
      );
      final hdrs = _restHeaders(withAuth: true);
      final resp = await _requeteAvecRefresh(
        () => http.get(url, headers: hdrs).timeout(const Duration(seconds: 10)),
      );

      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        return list
            .map((e) => DemandeSang.fromJson(
                  e as Map<String, dynamic>,
                  villesMap: villesMap,
                  structuresMap: structuresMap,
                ))
            .toList();
      }
      return [];
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] lireDemandesActives error: $e');
      }
      return [];
    }
  }

  /// Crée une nouvelle demande de sang.
  /// Reçoit les IDs entiers (ville_id, structure_id) — jamais des chaînes.
  static Future<CreationDemandeResult> creerDemande({
    required String userId,
    required GroupeSanguin groupeSanguin,
    required int? villeId,
    required int? structureId,
    String? villeLibre,
    String? structureLibre,
    required String contactPrincipal,
    String? contactSecondaire,
  }) async {
    if (!estConfigured) {
      return const CreationDemandeResult(
        success: false,
        error: 'Backend non configuré. Impossible de publier.',
      );
    }

    // Anti-spam : max 3 demandes actives — PROTÉGÉ par _requeteAvecRefresh
    final count = await _compterDemandesActives(userId);
    if (count >= 3) {
      return const CreationDemandeResult(
        success: false,
        error:
            'Vous avez déjà 3 demandes actives. Attendez qu\'elles expirent ou annulez-en une.',
      );
    }

    final contactChiffre = CryptoService.chiffrer(contactPrincipal);
    final contactSecondaireChiffre =
        CryptoService.chiffrer(contactSecondaire);

    // Construire le body selon les contraintes de la base :
    // chk_ville_renseignee  : ville_id IS NOT NULL OR ville_libre IS NOT NULL
    // chk_structure_renseignee : structure_id IS NOT NULL OR structure_libre IS NOT NULL
    final Map<String, dynamic> bodyMap = {
      'auteur_id': userId,
      'groupe_sanguin_recherche': groupeSanguin.label,
      'contact_chiffre': contactChiffre,
      'contact_secondaire_chiffre': contactSecondaireChiffre,
      'statut': 'active',
    };
    if (villeId != null) {
      bodyMap['ville_id'] = villeId;
    } else {
      bodyMap['ville_libre'] = villeLibre;
    }
    if (structureId != null) {
      bodyMap['structure_id'] = structureId;
    } else {
      bodyMap['structure_libre'] = structureLibre;
    }

    final body = jsonEncode(bodyMap);

    try {
      final url = Uri.parse('$_supabaseUrl/rest/v1/demandes_sang');
      final hdrs = _restHeaders(withAuth: true);
      final resp = await _requeteAvecRefresh(
        () => http.post(url, headers: hdrs, body: body)
            .timeout(const Duration(seconds: 10)),
      );

      if (resp.statusCode == 201) {
        final data = jsonDecode(resp.body);
        final demandeData = data is List ? data[0] : data;
        return CreationDemandeResult(
          success: true,
          demande: DemandeSang.fromJson(demandeData as Map<String, dynamic>),
        );
      }
      // Lire le message d'erreur Supabase si disponible
      String errMsg =
          'Erreur lors de la publication (${resp.statusCode})';
      try {
        final errData =
            jsonDecode(resp.body) as Map<String, dynamic>;
        errMsg = errData['message'] as String? ??
            errData['error'] as String? ??
            errMsg;
      } catch (_) {}
      return CreationDemandeResult(success: false, error: errMsg);
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] creerDemande error: $e');
      return const CreationDemandeResult(
        success: false,
        error: 'Impossible de publier. Vérifiez votre connexion.',
      );
    }
  }

  // =====================================================================
  // TOKEN QR — Création et validation
  // =====================================================================

  /// [PERF-05] Vérifie si un token QR valide (non expiré, non utilisé)
  /// existe déjà pour ce donneur + demande.
  static Future<String?> lireTokenQrExistant({
    required String donneurId,
    required String demandeId,
  }) async {
    if (!estConfigured) return null;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/dons_qr_tokens'
        '?donneur_id=eq.$donneurId'
        '&demande_id=eq.$demandeId'
        '&expires_at=gt.$now'
        '&used_at=is.null'
        '&select=token'
        '&limit=1',
      );
      final resp = await _requeteAvecRefresh(
        () => http.get(url, headers: _restHeaders(withAuth: true))
            .timeout(const Duration(seconds: 8)),
      );
      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        if (list.isNotEmpty) {
          return list[0]['token'] as String?;
        }
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] lireTokenQrExistant error: $e');
      }
      return null;
    }
  }

  static Future<QrTokenResult> creerToken(
      String donneurId, String demandeId) async {
    if (!estConfigured) {
      return const QrTokenResult(
        success: false,
        error: 'Backend non configuré. Génération QR impossible.',
      );
    }

    try {
      final url = Uri.parse('$_supabaseUrl/rest/v1/dons_qr_tokens');
      final hdrs = _restHeaders(withAuth: true);
      final body = jsonEncode({
        'donneur_id': donneurId,
        'demande_id': demandeId,
      });
      final resp = await _requeteAvecRefresh(
        () => http.post(url, headers: hdrs, body: body)
            .timeout(const Duration(seconds: 10)),
      );

      if (resp.statusCode == 201) {
        final data = jsonDecode(resp.body);
        final token = data is List ? data[0]['token'] : data['token'];
        return QrTokenResult(success: true, tokenOpaque: token as String);
      }
      return const QrTokenResult(
          success: false, error: 'Impossible de générer le code.');
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] creerToken error: $e');
      return const QrTokenResult(
          success: false, error: 'Erreur réseau lors de la génération.');
    }
  }

  static Future<ValidationResult> validerToken({
    required String token,
    required String demandeurId,
  }) async {
    if (!estConfigured) {
      return const ValidationResult(
        success: false,
        error: 'Backend non configuré.',
      );
    }

    try {
      final url = Uri.parse('$_supabaseUrl/functions/v1/valider-token');
      final hdrs = _headers(withAuth: true);
      final body = jsonEncode({
        'token': token,
        'demandeur_id': demandeurId,
      });
      final resp = await _requeteAvecRefresh(
        () => http.post(url, headers: hdrs, body: body)
            .timeout(const Duration(seconds: 10)),
      );

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200) {
        return ValidationResult(
            success: true,
            donneurId: data['donneur_id'] as String?);
      }
      return ValidationResult(
        success: false,
        error: data['error'] as String? ?? 'Code invalide ou expiré.',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] validerToken error: $e');
      return const ValidationResult(
          success: false, error: 'Erreur réseau lors de la validation.');
    }
  }

  // =====================================================================
  // DISPONIBILITÉ
  // =====================================================================
  static Future<bool> mettreAJourDisponibilite(
      String userId, bool disponible) async {
    if (!estConfigured) return false;
    try {
      final url = Uri.parse(
          '$_supabaseUrl/rest/v1/profils_donneurs?user_id=eq.$userId');
      final hdrs = _restHeaders(withAuth: true);
      final body = jsonEncode({'disponible': disponible});
      final resp = await _requeteAvecRefresh(
        () => http.patch(url, headers: hdrs, body: body)
            .timeout(const Duration(seconds: 10)),
      );
      return resp.statusCode == 204 || resp.statusCode == 200;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] mettreAJourDisponibilite error: $e');
      }
      return false;
    }
  }

  // =====================================================================
  // HISTORIQUE DONS
  // =====================================================================
  static Future<bool> enregistrerDon({
    required String donneurId,
    required DateTime dateDon,
    required SourceDon source,
    String? demandeId,
  }) async {
    if (!estConfigured) return false;
    try {
      final url = Uri.parse('$_supabaseUrl/rest/v1/historique_dons');
      final hdrs = _restHeaders(withAuth: true);
      final body = jsonEncode({
        'donneur_id': donneurId,
        'demande_id': demandeId,
        'date_don': dateDon.toIso8601String().substring(0, 10),
        'source': source.value,
      });
      final resp = await _requeteAvecRefresh(
        () => http.post(url, headers: hdrs, body: body)
            .timeout(const Duration(seconds: 10)),
      );
      return resp.statusCode == 201;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] enregistrerDon error: $e');
      }
      return false;
    }
  }

  // =====================================================================
  // RÉPONSE DONNEUR — Persistance en base
  // =====================================================================
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

  // =====================================================================
  // NOTIFICATIONS — Lecture depuis public.notifications_envoyees
  // =====================================================================

  /// Charge les 50 dernières notifications de l'utilisateur depuis le backend.
  /// Source de vérité : public.notifications_envoyees.
  static Future<List<NotificationSauve>> lireNotifications(
      String userId) async {
    if (!estConfigured || _accessToken == null) return [];
    try {
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/notifications_envoyees'
        '?user_id=eq.$userId'
        '&order=created_at.desc'
        '&limit=50',
      );
      final resp = await _requeteAvecRefresh(
        () => http.get(url, headers: _restHeaders(withAuth: true))
            .timeout(const Duration(seconds: 10)),
      );
      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        return list
            .map((e) =>
                NotificationSauve.fromBase(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] lireNotifications error: $e');
      }
      return [];
    }
  }

  /// Marque une notification comme lue dans public.notifications_envoyees.
  static Future<bool> marquerNotificationLue(String notifId) async {
    if (!estConfigured || _accessToken == null) return false;
    try {
      final url = Uri.parse(
          '$_supabaseUrl/rest/v1/notifications_envoyees?id=eq.$notifId');
      final hdrs = {
        ..._restHeaders(withAuth: true),
        'Prefer': 'return=minimal',
      };
      final body = jsonEncode({'lu': true});
      final resp = await _requeteAvecRefresh(
        () => http.patch(url, headers: hdrs, body: body)
            .timeout(const Duration(seconds: 8)),
      );
      return resp.statusCode == 204 || resp.statusCode == 200;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] marquerNotificationLue error: $e');
      }
      return false;
    }
  }

  // =====================================================================
  // DEVICE TOKENS FCM — public.device_tokens
  // =====================================================================

  /// Enregistre (ou met à jour) le token FCM de l'appareil courant.
  /// Utilise upsert sur fcm_token (unique) pour éviter les doublons.
  static Future<bool> enregistrerFcmToken({
    required String userId,
    required String fcmToken,
    String? plateforme,
  }) async {
    if (!estConfigured || _accessToken == null) return false;
    try {
      final url = Uri.parse('$_supabaseUrl/rest/v1/device_tokens');
      final hdrs = {
        ..._restHeaders(withAuth: true),
        'Prefer': 'return=minimal,resolution=merge-duplicates',
      };
      final body = jsonEncode({
        'user_id': userId,
        'fcm_token': fcmToken,
        'plateforme': plateforme,
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
        debugPrint('[SupabaseService] enregistrerFcmToken error: $e');
      }
      return false;
    }
  }

  // =====================================================================
  // SUPPRESSION DE COMPTE J+5
  // =====================================================================
  static Future<bool> programmerSuppression(String userId) async {
    if (!estConfigured) return false;
    final dateExecution = DateTime.now().add(const Duration(days: 5));
    try {
      final url = Uri.parse(
          '$_supabaseUrl/rest/v1/identites?user_id=eq.$userId');
      final hdrs = _restHeaders(withAuth: true);
      final body = jsonEncode({
        'suppression_programmee_le':
            dateExecution.toUtc().toIso8601String(),
        'compte_actif': false,
      });
      final resp = await _requeteAvecRefresh(
        () => http.patch(url, headers: hdrs, body: body)
            .timeout(const Duration(seconds: 10)),
      );
      return resp.statusCode == 204 || resp.statusCode == 200;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] programmerSuppression error: $e');
      }
      return false;
    }
  }

  static Future<bool> annulerSuppression(String userId) async {
    if (!estConfigured) return false;
    try {
      final url = Uri.parse(
          '$_supabaseUrl/rest/v1/identites?user_id=eq.$userId');
      final hdrs = _restHeaders(withAuth: true);
      final body = jsonEncode({
        'suppression_programmee_le': null,
        'compte_actif': true,
      });
      final resp = await _requeteAvecRefresh(
        () => http.patch(url, headers: hdrs, body: body)
            .timeout(const Duration(seconds: 10)),
      );
      return resp.statusCode == 204 || resp.statusCode == 200;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] annulerSuppression error: $e');
      }
      return false;
    }
  }

  // =====================================================================
  // RÉPONSE — Vérification côté serveur (vue demandes_sang_avec_contact)
  // =====================================================================

  /// [1.5] Interroge la vue demandes_sang_avec_contact pour savoir si
  /// l'utilisateur authentifié a déjà répondu à la demande donnée.
  static Future<bool> verifierReponduDemande(String demandeId) async {
    if (!estConfigured || _accessToken == null) return false;
    try {
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/demandes_sang_avec_contact'
        '?id=eq.$demandeId'
        '&select=a_repondu',
      );
      final hdrs = {
        ..._restHeaders(withAuth: true),
        'Accept': 'application/json',
      };
      final resp = await _requeteAvecRefresh(
        () => http.get(url, headers: hdrs).timeout(const Duration(seconds: 8)),
      );

      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        if (list.isNotEmpty) {
          return list[0]['a_repondu'] as bool? ?? false;
        }
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] verifierReponduDemande error: $e');
      }
      return false;
    }
  }

  // =====================================================================
  // HELPERS PRIVÉS
  // =====================================================================

  /// Compte les demandes actives de l'utilisateur — PROTÉGÉ par
  /// _requeteAvecRefresh() (§5 audit : anti-spam non contournable par
  /// expiration de token).
  static Future<int> _compterDemandesActives(String userId) async {
    if (_accessToken == null) return 0;
    try {
      final resp = await _requeteAvecRefresh(
        () => http.get(
          Uri.parse(
            '$_supabaseUrl/rest/v1/demandes_sang'
            '?auteur_id=eq.$userId'
            '&statut=eq.active'
            '&expires_at=gt.${DateTime.now().toUtc().toIso8601String()}'
            '&select=id',
          ),
          headers: {
            ..._restHeaders(withAuth: true),
            'Prefer': 'count=exact',
          },
        ).timeout(const Duration(seconds: 5)),
      );

      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        return list.length;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }
}

// =====================================================================
// TYPES DE RÉSULTATS
// =====================================================================

class AuthResult {
  final bool success;
  final String? userId;
  final String? accessToken;
  final String? error;
  final bool needsEmailConfirmation;

  const AuthResult({
    required this.success,
    this.userId,
    this.accessToken,
    this.error,
    this.needsEmailConfirmation = false,
  });
}

class CreationDemandeResult {
  final bool success;
  final DemandeSang? demande;
  final String? error;

  const CreationDemandeResult({
    required this.success,
    this.demande,
    this.error,
  });
}

class QrTokenResult {
  final bool success;
  final String? tokenOpaque;
  final String? error;

  const QrTokenResult({
    required this.success,
    this.tokenOpaque,
    this.error,
  });
}

class ValidationResult {
  final bool success;
  final String? donneurId;
  final String? error;

  const ValidationResult({
    required this.success,
    this.donneurId,
    this.error,
  });
}
