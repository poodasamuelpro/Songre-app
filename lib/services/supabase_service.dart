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
//   SAUVE_ENCRYPT_KEY=<32 chars minimum>
//
// Authentification : Email / Mot de passe via Supabase Auth
// Token : JWT signé retourné par /auth/v1/token?grant_type=password
// Schémas PostgreSQL : identite.* et sante.*
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
        // Persister immédiatement les tokens raffraîchis
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
  // PROFIL DONNEUR — Création et modification (schéma sante.*)
  // =====================================================================
  static Future<bool> creerOuMettreAJourProfil(ProfilDonneur profil) async {
    if (!estConfigured) {
      if (kDebugMode) debugPrint('[SupabaseService] Pas de backend configuré');
      return false;
    }

    final poidsChiffre = CryptoService.chiffrer(profil.poids.toString());
    final ciChiffre = CryptoService.chiffrerListe(profil.contreIndications);

    final hdrs = {
      ..._restHeaders(withAuth: true),
      'Prefer': 'return=minimal,resolution=merge-duplicates',
    };
    final body = jsonEncode({
      'user_id': profil.userId,
      'groupe_sanguin': profil.groupeSanguin.label,
      'poids_chiffre': poidsChiffre,
      'genre': profil.genre.value,
      'ville': profil.ville,
      'quartier': profil.quartier,
      'contre_indications_chiffre': ciChiffre,
      'dernier_don_date':
          profil.dernierDonDate?.toIso8601String().substring(0, 10),
      'disponible': profil.disponible,
    });
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
      if (kDebugMode)
        debugPrint('[SupabaseService] creerOuMettreAJourProfil error: $e');
      return false;
    }
  }

  // =====================================================================
  // DEMANDES DE SANG — Lecture et création
  // =====================================================================
  static Future<List<DemandeSang>> lireDemandesActives(String ville) async {
    if (!estConfigured) return [];

    try {
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/demandes_sang'
        '?ville=eq.${Uri.encodeComponent(ville)}'
        '&statut=eq.active'
        '&expires_at=gt.${DateTime.now().toUtc().toIso8601String()}'
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
            .map((e) => DemandeSang.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      if (kDebugMode)
        debugPrint('[SupabaseService] lireDemandesActives error: $e');
      return [];
    }
  }

  static Future<CreationDemandeResult> creerDemande({
    required String userId,
    required GroupeSanguin groupeSanguin,
    required String ville,
    required String structureSanitaire,
    required String contactPrincipal,
    String? contactSecondaire,
  }) async {
    if (!estConfigured) {
      return const CreationDemandeResult(
        success: false,
        error: 'Backend non configuré. Impossible de publier.',
      );
    }

    // Anti-spam : max 3 demandes actives
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
    final body = jsonEncode({
      'auteur_id': userId,
      'groupe_sanguin_recherche': groupeSanguin.label,
      'ville': ville,
      'structure_sanitaire': structureSanitaire,
      'contact_chiffre': contactChiffre,
      'contact_secondaire_chiffre': contactSecondaireChiffre,
      'statut': 'active',
    });

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
      return CreationDemandeResult(
        success: false,
        error: 'Erreur lors de la publication (${resp.statusCode})',
      );
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
  /// Retourne le token opaque si trouvé, null sinon.
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
      if (kDebugMode) debugPrint('[SupabaseService] lireTokenQrExistant error: $e');
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
      if (kDebugMode)
        debugPrint('[SupabaseService] mettreAJourDisponibilite error: $e');
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
      if (kDebugMode)
        debugPrint('[SupabaseService] enregistrerDon error: $e');
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
      if (kDebugMode)
        debugPrint('[SupabaseService] enregistrerReponseDonneur error: $e');
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
      if (kDebugMode)
        debugPrint('[SupabaseService] programmerSuppression error: $e');
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
      if (kDebugMode)
        debugPrint('[SupabaseService] annulerSuppression error: $e');
      return false;
    }
  }

  // =====================================================================
  // RÉPONSE — Vérification côté serveur (vue demandes_sang_avec_contact)
  // =====================================================================

  /// [1.5] Interroge la vue demandes_sang_avec_contact pour savoir si
  /// l'utilisateur authentifié a déjà répondu à la demande donnée.
  /// Retourne le champ `a_repondu` (booléen) calculé par le serveur.
  /// Jamais déduit côté client : la vérité vient de la base.
  static Future<bool> verifierReponduDemande(String demandeId) async {
    if (!estConfigured || _accessToken == null) return false;
    try {
      // Interroger la vue avec filtre sur l'id — sélectionner uniquement a_repondu
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
      // En cas d'erreur réseau : retourner false (côté sécuritaire — pas d'accès)
      return false;
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] verifierReponduDemande error: $e');
      return false;
    }
  }

  // =====================================================================
  // HELPERS PRIVÉS
  // =====================================================================
  static Future<int> _compterDemandesActives(String userId) async {
    try {
      final resp = await http.get(
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
      ).timeout(const Duration(seconds: 5));

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

// ---- DTOs résultats ----

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

  const CreationDemandeResult(
      {required this.success, this.demande, this.error});
}

class QrTokenResult {
  final bool success;
  final String? tokenOpaque;
  final String? error;

  const QrTokenResult(
      {required this.success, this.tokenOpaque, this.error});
}

class ValidationResult {
  final bool success;
  final String? donneurId;
  final String? error;

  const ValidationResult(
      {required this.success, this.donneurId, this.error});
}
