import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import '../utils/crypto_service.dart';
import '../utils/secure_storage_service.dart';

// =====================================================================
// SERVICE SUPABASE — Production SONGRE
//
// Les clés de production sont embarquées directement (fallback hardcodé).
// Elles peuvent aussi être surchargées via --dart-define au build.
//
// Authentification : Email / Mot de passe via Supabase Auth
// Token : JWT signé retourné par /auth/v1/token?grant_type=password
// Schéma PostgreSQL : public.* (schéma réel — PAS sante.* ni identite.*)
//
// IMPORTANT : La Service Role Key n'appartient JAMAIS à ce fichier.
//             Elle est injectée exclusivement dans les Edge Functions
//             via les secrets Supabase Dashboard.
// =====================================================================

// Clés de production SONGRE (embarquées pour garantir le fonctionnement APK)
const String _kSupabaseUrlProd =
    'https://ptomqwucvveuflfnyczo.supabase.co';
const String _kAnonKeyProd =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
    '.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB0b21xd3VjdnZldWZsZm55Y3pvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM0NjE4MDEsImV4cCI6MjA5OTAzNzgwMX0'
    '.5ATdPSNn5YxNKWyOu08NA4fj-hQYypF5StdN3z4-Efg';

class SupabaseService {
  SupabaseService._();

  // dart-define a la priorité ; sinon on utilise les constantes de production
  static const String _supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: _kSupabaseUrlProd,
  );
  static const String _anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: _kAnonKeyProd,
  );

  /// Secret partagé requis par l'Edge Function valider-token (étape 0).
  /// Injecté exclusivement via --dart-define=WEBHOOK_SECRET=...
  /// Aucune valeur ne doit jamais apparaître en clair dans ce fichier
  /// ni dans l'historique Git.
  /// Si ce secret a déjà été exposé, il doit être régénéré côté Supabase
  /// Vault avant tout déploiement (voir documentation interne).
  // SEC-02 : valeur par défaut hardcodée supprimée.
  // Si absent au build, la chaîne sera vide et l'EF valider-token rejettera
  // la requête (échec explicite, pas de secret connu publiquement).
  static const String _webhookSecret = String.fromEnvironment(
    'WEBHOOK_SECRET',
  );

  /// JWT retourné par Supabase Auth — sert de Bearer token
  static String? _accessToken;
  static String? _refreshToken;
  static String? _currentUserId;

  static bool get estConfigured =>
      _supabaseUrl.isNotEmpty && _anonKey.isNotEmpty;

  /// URL et clé anon exposées pour les écrans qui appellent Supabase directement
  /// (ex : ResetPasswordScreen — évite la duplication des clés)
  static String get supabaseUrl => _supabaseUrl;
  static String get anonKey => _anonKey;

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

      final rawMsg = (data['error_description'] as String? ??
              data['msg'] as String? ??
              data['error'] as String? ??
              '')
          .toLowerCase();

      // Traduire les erreurs d'inscription les plus fréquentes en français
      final String finalMsg;
      if (resp.statusCode == 500 && rawMsg.contains('database error')) {
        finalMsg = 'Inscription temporairement indisponible. Merci de réessayer dans quelques minutes ou de contacter le support.';
      } else if (rawMsg.contains('user already registered') ||
          rawMsg.contains('already_registered') ||
          rawMsg.contains('email already')) {
        finalMsg = 'Cette adresse email est déjà associée à un compte. Utilisez "Se connecter" ou "Mot de passe oublié".';
      } else if (rawMsg.contains('password') && rawMsg.contains('weak')) {
        finalMsg = 'Mot de passe trop faible. Utilisez au moins 8 caractères avec des lettres et chiffres.';
      } else if (rawMsg.contains('invalid email') || resp.statusCode == 422) {
        finalMsg = 'L\'adresse email saisie est invalide. Vérifiez le format (ex : nom@domaine.com).';
      } else if (rawMsg.contains('rate limit') || resp.statusCode == 429) {
        finalMsg = 'Trop de tentatives. Patientez quelques minutes avant de réessayer.';
      } else if (rawMsg.isNotEmpty) {
        finalMsg = 'Inscription impossible : $rawMsg';
      } else {
        finalMsg = 'Erreur lors de l\'inscription (${resp.statusCode}). Réessayez.';
      }
      return AuthResult(success: false, error: finalMsg);
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

      final rawMsg = (data['error_description'] as String? ??
              data['msg'] as String? ??
              data['error'] as String? ??
              '')
          .toLowerCase();
      final msg = _traduireErreurConnexion(rawMsg, resp.statusCode);
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

  /// Envoie un email de réinitialisation de mot de passe via Supabase Auth.
  /// Retourne true si l'email a été envoyé, false sinon.
  /// L'email arrive avec un lien magique qui redirige vers l'app.
  static Future<ResetPasswordResult> envoyerEmailReinitialisation(
      String email) async {
    if (!estConfigured) {
      return const ResetPasswordResult(
        success: false,
        error: 'Backend non configuré.',
      );
    }
    try {
      final resp = await http.post(
        Uri.parse('$_supabaseUrl/auth/v1/recover'),
        headers: _headers(),
        body: jsonEncode({'email': email}),
      ).timeout(const Duration(seconds: 15));

      // Supabase retourne 200 même si l'email n'existe pas (sécurité)
      if (resp.statusCode == 200) {
        return const ResetPasswordResult(success: true);
      }

      String errMsg = 'Erreur lors de l\'envoi (${resp.statusCode})';
      try {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        errMsg = data['error_description'] as String? ??
            data['msg'] as String? ??
            errMsg;
      } catch (_) {}
      return ResetPasswordResult(success: false, error: errMsg);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] envoyerEmailReinitialisation error: $e');
      }
      return const ResetPasswordResult(
        success: false,
        error: 'Connexion impossible. Vérifiez votre réseau.',
      );
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

  /// Enregistre le consentement de l'utilisateur dans public.consentements.
  ///
  /// Cette table est distincte de profils_donneurs — elle stocke les
  /// consentements légaux (données de santé, géolocalisation, version politique).
  /// Utilise UPSERT (merge-duplicates) pour gérer les ré-inscriptions.
  ///
  /// [userId]            : UUID de l'utilisateur
  /// [consentementSante] : case "J'accepte le traitement de mes données de santé" cochée
  /// [consentementGeoloc]: case géolocalisation (false par défaut si non demandé)
  /// [versionPolitique]  : version de la politique de confidentialité en vigueur
  static Future<bool> enregistrerConsentement({
    required String userId,
    required bool consentementSante,
    bool consentementGeoloc = false,
    String versionPolitique = '1.0',
  }) async {
    if (!estConfigured) return false;

    final hdrs = {
      ..._restHeaders(withAuth: true),
      'Prefer': 'return=minimal,resolution=merge-duplicates',
    };
    final body = jsonEncode({
      'user_id': userId,
      'consentement_sante': consentementSante,
      'consentement_geoloc': consentementGeoloc,
      'consentement_date': DateTime.now().toUtc().toIso8601String(),
      'version_politique': versionPolitique,
    });

    try {
      final url = Uri.parse('$_supabaseUrl/rest/v1/consentements');
      final resp = await _requeteAvecRefresh(
        () => http.post(url, headers: hdrs, body: body)
            .timeout(const Duration(seconds: 10)),
      );
      final ok = resp.statusCode == 201 ||
          resp.statusCode == 200 ||
          resp.statusCode == 204;
      if (kDebugMode) {
        debugPrint('[SupabaseService] enregistrerConsentement: ${ok ? "OK" : "ERREUR ${resp.statusCode}"}');
      }
      return ok;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] enregistrerConsentement error: $e');
      }
      return false;
    }
  }

  /// Lit le consentement d'un utilisateur depuis public.consentements.
  /// Retourne une Map avec les champs du consentement, ou null si absent.
  static Future<Map<String, dynamic>?> lireConsentement(String userId) async {
    if (!estConfigured) return null;
    try {
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/consentements'
        '?user_id=eq.$userId'
        '&limit=1',
      );
      final hdrs = _restHeaders(withAuth: true);
      final resp = await _requeteAvecRefresh(
        () => http.get(url, headers: hdrs).timeout(const Duration(seconds: 10)),
      );
      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        if (list.isNotEmpty) return list.first as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] lireConsentement error: $e');
      }
      return null;
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

  /// Charge TOUTES les demandes actives, toutes villes confondues.
  /// Utilisée par la page "Demandes" (onglet navigation) qui doit afficher
  /// l'ensemble des demandes sans filtre géographique.
  /// Distinct de [lireDemandesActives] qui filtre par ville (accueil + compatibilité).
  static Future<List<DemandeSang>> lireToutesDemandesActives({
    Map<int, String>? villesMap,
    Map<int, String>? structuresMap,
  }) async {
    if (!estConfigured) return [];

    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/demandes_sang'
        '?statut=eq.active'
        '&expires_at=gt.$now'
        '&order=created_at.desc'
        '&limit=100',
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
        debugPrint('[SupabaseService] lireToutesDemandesActives error: $e');
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
      // ── Correction S-04 (audit 2026-07-09) ──────────────────────────────
      // L'Edge Function valider-token exige le header x-webhook-secret à
      // l'étape 0. Sans ce header, l'EF retourne 401. On l'ajoute ici.
      // La valeur est injectée via --dart-define=WEBHOOK_SECRET=...
      final hdrs = {
        ..._headers(withAuth: true),
        if (_webhookSecret.isNotEmpty) 'x-webhook-secret': _webhookSecret,
      };
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
      // Case 4 — Mission D : les dons déclaratifs passent par l'EF don-manuel
      // qui met à jour profil_donneurs.dernier_don_date, insère dans historique_dons
      // ET envoie la notification don_enregistre_manuel.
      if (source == SourceDon.declaratif && _accessToken != null) {
        final efUrl =
            Uri.parse('$_supabaseUrl/functions/v1/don-manuel');
        final efBody = jsonEncode({
          'date_don': dateDon.toIso8601String().substring(0, 10),
          if (demandeId != null) 'demande_id': demandeId,
        });
        final efResp = await _requeteAvecRefresh(
          () => http
              .post(efUrl, headers: _headers(withAuth: true), body: efBody)
              .timeout(const Duration(seconds: 12)),
        );
        return efResp.statusCode == 200;
      }

      // Fallback pour les autres sources (qr_confirme, etc.) : insertion directe
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
      final ok = resp.statusCode == 204 || resp.statusCode == 200;

      // Case 6 — Notification suppression_demandee (fire-and-forget)
      if (ok) {
        _declencherNotificationSuppressionDemandee();
      }

      return ok;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SupabaseService] programmerSuppression error: $e');
      }
      return false;
    }
  }

  /// Fire-and-forget : appelle l'EF mdp-modifie-auth avec action=suppression_demandee
  /// pour déclencher l'email + notification in-app (type suppression_demandee).
  static void _declencherNotificationSuppressionDemandee() {
    if (!estConfigured || _accessToken == null) return;
    http
        .post(
          Uri.parse('$_supabaseUrl/functions/v1/mdp-modifie-auth'),
          headers: _headers(withAuth: true),
          body: jsonEncode({'action': 'suppression_demandee'}),
        )
        .timeout(const Duration(seconds: 8))
        .catchError((e) {
      if (kDebugMode) {
        debugPrint(
            '[SupabaseService] _declencherNotificationSuppressionDemandee: $e');
      }
      return http.Response('', 500);
    });
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

  /// Traduit les messages d'erreur Supabase Auth en français clair et précis.
  ///
  /// Supabase retourne des messages en anglais via error_description/msg.
  /// Cette fonction les mappe vers des messages français chirurgicaux,
  /// distinguant explicitement email incorrect vs mot de passe incorrect.
  ///
  /// Codes HTTP pertinents :
  ///   400 : identifiants invalides (mauvais email OU mauvais mot de passe)
  ///   422 : données mal formatées (email invalide côté serveur)
  ///   429 : trop de tentatives
  static String _traduireErreurConnexion(String rawMsg, int statusCode) {
    // ── Trop de tentatives ──────────────────────────────────────────────
    if (statusCode == 429 || rawMsg.contains('rate limit') || rawMsg.contains('too many')) {
      return 'Trop de tentatives de connexion. Patientez quelques minutes avant de réessayer.';
    }

    // ── Email non confirmé ──────────────────────────────────────────────
    if (rawMsg.contains('email not confirmed') || rawMsg.contains('email_not_confirmed')) {
      return 'Votre adresse email n\'a pas encore été confirmée. Vérifiez votre boîte mail.';
    }

    // ── Compte désactivé / supprimé ─────────────────────────────────────
    if (rawMsg.contains('user not found') || rawMsg.contains('user_not_found')) {
      return 'Aucun compte n\'existe avec cette adresse email. Vérifiez votre email ou créez un compte.';
    }

    // ── Mot de passe incorrect (Supabase distingue parfois) ─────────────
    if (rawMsg.contains('invalid password') || rawMsg.contains('wrong password') ||
        rawMsg.contains('incorrect password')) {
      return 'Mot de passe incorrect. Vérifiez votre mot de passe ou utilisez "Mot de passe oublié".';
    }

    // ── Identifiants invalides (message générique Supabase le plus courant) ─
    // "Invalid login credentials" signifie que l'email existe mais le mot
    // de passe est faux, OU que l'email n'existe pas du tout.
    // Supabase ne distingue pas les deux pour des raisons de sécurité.
    if (rawMsg.contains('invalid login credentials') ||
        rawMsg.contains('invalid_credentials') ||
        rawMsg.contains('invalid credentials')) {
      return 'Email ou mot de passe incorrect. '
          'Vérifiez l\'adresse email saisie et votre mot de passe.';
    }

    // ── Email invalide (format incorrect côté serveur) ───────────────────
    if (statusCode == 422 || rawMsg.contains('invalid email') ||
        rawMsg.contains('email_invalid') || rawMsg.contains('unable to validate email')) {
      return 'L\'adresse email saisie est invalide. Vérifiez le format (ex : nom@domaine.com).';
    }

    // ── Réseau / serveur ─────────────────────────────────────────────────
    if (rawMsg.contains('network') || rawMsg.contains('connection') || statusCode >= 500) {
      return 'Connexion impossible. Vérifiez votre accès à internet et réessayez.';
    }

    // ── Message par défaut (erreur inconnue) ─────────────────────────────
    if (rawMsg.isNotEmpty) {
      // Retourner le message brut si on ne sait pas le traduire
      return 'Connexion impossible : $rawMsg';
    }
    return 'Email ou mot de passe incorrect. Vérifiez vos identifiants.';
  }

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
        // ── Correction S-08 (audit 2026-07-09) ──────────────────────────────
        // Ancienne version : list.length — fragile car dépend de la pagination
        // (Supabase retourne max 1000 résultats par défaut).
        // Correction : utiliser le header Content-Range retourné par
        // Prefer: count=exact, qui contient le total réel indépendamment
        // de la pagination. Format : "0-N/TOTAL" ou "*/TOTAL".
        final contentRange = resp.headers['content-range'] ?? '';
        if (contentRange.isNotEmpty) {
          final parts = contentRange.split('/');
          if (parts.length == 2) {
            return int.tryParse(parts[1]) ?? 0;
          }
        }
        // Fallback sur list.length si Content-Range absent
        final list = jsonDecode(resp.body) as List;
        return list.length;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }

  // =====================================================================
  // MOT DE PASSE — Changement + Réinitialisation (D6 — Mission D)
  // =====================================================================

  /// Retourne l'email de l'utilisateur authentifié courant
  /// via GET /auth/v1/user (utilise le JWT en mémoire).
  static Future<String?> obtenirEmailCourant() async {
    if (!estConfigured || _accessToken == null) return null;
    try {
      final resp = await _requeteAvecRefresh(
        () => http
            .get(
              Uri.parse('$_supabaseUrl/auth/v1/user'),
              headers: _headers(withAuth: true),
            )
            .timeout(const Duration(seconds: 8)),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return data['email'] as String?;
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] obtenirEmailCourant: $e');
      return null;
    }
  }

  /// Vérifie l'ancien mot de passe en ré-authentifiant l'utilisateur.
  /// Retourne true si les identifiants sont valides.
  static Future<bool> verifierMotDePasse({
    required String email,
    required String motDePasse,
  }) async {
    if (!estConfigured) return false;
    try {
      final resp = await http
          .post(
            Uri.parse('$_supabaseUrl/auth/v1/token?grant_type=password'),
            headers: _headers(),
            body: jsonEncode({'email': email, 'password': motDePasse}),
          )
          .timeout(const Duration(seconds: 10));
      return resp.statusCode == 200;
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] verifierMotDePasse: $e');
      return false;
    }
  }

  /// Change le mot de passe de l'utilisateur authentifié.
  /// Appelle PUT /auth/v1/user avec { password: nouveauMotDePasse }.
  static Future<AuthResult> changerMotDePasse({
    required String nouveauMotDePasse,
  }) async {
    if (!estConfigured || _accessToken == null) {
      return const AuthResult(
          success: false, error: 'Session invalide. Reconnectez-vous.');
    }
    try {
      final resp = await _requeteAvecRefresh(
        () => http
            .put(
              Uri.parse('$_supabaseUrl/auth/v1/user'),
              headers: _headers(withAuth: true),
              body: jsonEncode({'password': nouveauMotDePasse}),
            )
            .timeout(const Duration(seconds: 10)),
      );

      if (resp.statusCode == 200) {
        return const AuthResult(success: true);
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final msg = data['message'] as String? ??
          data['msg'] as String? ??
          'Erreur lors du changement de mot de passe (${resp.statusCode}).';
      return AuthResult(success: false, error: msg);
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] changerMotDePasse: $e');
      return const AuthResult(
          success: false, error: 'Erreur réseau. Veuillez réessayer.');
    }
  }

  /// Envoie un email de réinitialisation de mot de passe.
  /// Appelle POST /auth/v1/recover.
  static Future<bool> reinitialiserMotDePasse({required String email}) async {
    if (!estConfigured) return false;
    try {
      final resp = await http
          .post(
            Uri.parse('$_supabaseUrl/auth/v1/recover'),
            headers: _headers(),
            body: jsonEncode({
            'email': email,
            // Deep link qui s'ouvre dans l'app pour afficher ResetPasswordScreen.
            // Doit être enregistré dans Supabase Dashboard →
            // Authentication → URL Configuration → Redirect URLs.
            'redirectTo': 'songre://reset-password',
          }),
          )
          .timeout(const Duration(seconds: 10));
      // 200 = email envoyé, 204 = même résultat sans body
      return resp.statusCode == 200 || resp.statusCode == 204;
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] reinitialiserMotDePasse: $e');
      return false;
    }
  }

  /// Déclenche la notification mdp_modifie via l'EF mdp-modifie-auth.
  /// Appelé en fire-and-forget après un changement de mot de passe réussi.
  static Future<void> declencherNotificationMdpModifie() async {
    if (!estConfigured || _accessToken == null) return;
    try {
      await http
          .post(
            Uri.parse('$_supabaseUrl/functions/v1/mdp-modifie-auth'),
            headers: _headers(withAuth: true),
            body: jsonEncode({'action': 'mdp_modifie'}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      // Fire-and-forget : on ne propage pas l'erreur
      if (kDebugMode) {
        debugPrint('[SupabaseService] declencherNotificationMdpModifie: $e');
      }
    }
  }

  // =====================================================================
  // CONTACT SUPPORT — Envoi de message (D8 — Mission D)
  // =====================================================================

  /// Envoie un message au support via l'EF contacter-support.
  /// Anti-spam côté serveur (fenêtre 10 min).
  static Future<ContactResult> envoyerMessageSupport({
    required String objet,
    required String message,
  }) async {
    if (!estConfigured || _accessToken == null) {
      return const ContactResult(
          success: false, error: 'Session invalide. Reconnectez-vous.');
    }
    try {
      final resp = await _requeteAvecRefresh(
        () => http
            .post(
              Uri.parse('$_supabaseUrl/functions/v1/contacter-support'),
              headers: _headers(withAuth: true),
              body: jsonEncode({'objet': objet, 'message': message}),
            )
            .timeout(const Duration(seconds: 12)),
      );

      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      if (resp.statusCode == 200) {
        return const ContactResult(success: true);
      }

      // 429 = anti-spam déclenché
      if (resp.statusCode == 429) {
        return ContactResult(
          success: false,
          error: data['error'] as String? ??
              'Vous avez déjà envoyé un message récemment. Attendez 10 minutes.',
        );
      }

      final msg = data['error'] as String? ??
          'Erreur lors de l\'envoi (${resp.statusCode}).';
      return ContactResult(success: false, error: msg);
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] envoyerMessageSupport: $e');
      return const ContactResult(
          success: false, error: 'Erreur réseau. Veuillez réessayer.');
    }
  }

  // =====================================================================
  // LIENS EXTERNES — Table dynamique (D9 — Mission D)
  // =====================================================================

  /// Charge les liens externes actifs depuis public.liens_externes,
  /// triés par ordre_affichage.
  static Future<List<LienExterne>> lireLiensExternes() async {
    if (!estConfigured) return [];
    try {
      final url = Uri.parse(
        '$_supabaseUrl/rest/v1/liens_externes'
        '?actif=eq.true'
        '&order=ordre_affichage.asc',
      );
      final resp = await _requeteAvecRefresh(
        () => http
            .get(url, headers: _restHeaders(withAuth: false))
            .timeout(const Duration(seconds: 8)),
      );
      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        return list
            .map((e) => LienExterne.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] lireLiensExternes: $e');
      return [];
    }
  }

  // =====================================================================
  // HISTORIQUE — Dons effectués + Demandes publiées (S5)
  // =====================================================================
  static Future<HistoriquePageResult> lireHistoriqueUtilisateur({
    required String userId,
    int page = 0,
    int pageSize = 25,
  }) async {
    if (!estConfigured || _accessToken == null) {
      return const HistoriquePageResult(dons: [], demandes: [], aUnePageSuivante: false);
    }
    final offset = page * pageSize;
    final limitePlusUn = pageSize + 1;
    try {
      final urlDons = Uri.parse(
        '$_supabaseUrl/rest/v1/historique_dons'
        '?donneur_id=eq.$userId'
        '&select=id,date_don,source,demande_id,created_at'
        '&order=date_don.desc,created_at.desc'
        '&limit=$limitePlusUn'
        '&offset=$offset',
      );
      final respDons = await _requeteAvecRefresh(
        () => http.get(urlDons, headers: _restHeaders(withAuth: true)).timeout(const Duration(seconds: 10)),
      );
      final urlDemandes = Uri.parse(
        '$_supabaseUrl/rest/v1/demandes_sang'
        '?auteur_id=eq.$userId'
        '&select=id,groupe_sanguin_recherche,statut,created_at,expires_at,ville_nom'
        '&order=created_at.desc'
        '&limit=$limitePlusUn'
        '&offset=$offset',
      );
      final respDemandes = await _requeteAvecRefresh(
        () => http.get(urlDemandes, headers: _restHeaders(withAuth: true)).timeout(const Duration(seconds: 10)),
      );
      List<HistoriqueDon> dons = [];
      List<HistoriqueDemande> demandes = [];
      bool aUnePageSuivante = false;
      if (respDons.statusCode == 200) {
        final list = jsonDecode(respDons.body) as List;
        if (list.length > pageSize) { aUnePageSuivante = true; list.removeLast(); }
        dons = list.map((e) => HistoriqueDon.fromJson(e as Map<String, dynamic>)).toList();
      }
      if (respDemandes.statusCode == 200) {
        final list = jsonDecode(respDemandes.body) as List;
        if (list.length > pageSize) { aUnePageSuivante = true; list.removeLast(); }
        demandes = list.map((e) => HistoriqueDemande.fromJson(e as Map<String, dynamic>)).toList();
      }
      return HistoriquePageResult(dons: dons, demandes: demandes, aUnePageSuivante: aUnePageSuivante);
    } catch (e) {
      if (kDebugMode) debugPrint('[SupabaseService] lireHistoriqueUtilisateur error: $e');
      return const HistoriquePageResult(dons: [], demandes: [], aUnePageSuivante: false);
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

// =====================================================================
// MODÈLE — LienExterne (D9 — Mission D)
// =====================================================================

class LienExterne {
  final int id;
  final String cle;
  final String libelle;
  final String url;
  final String? icone;
  final int ordreAffichage;

  const LienExterne({
    required this.id,
    required this.cle,
    required this.libelle,
    required this.url,
    this.icone,
    required this.ordreAffichage,
  });

  factory LienExterne.fromJson(Map<String, dynamic> json) {
    return LienExterne(
      id: json['id'] as int? ?? 0,
      cle: json['cle'] as String? ?? '',
      libelle: json['libelle'] as String? ?? '',
      url: json['url'] as String? ?? '',
      icone: json['icone'] as String?,
      ordreAffichage: json['ordre_affichage'] as int? ?? 0,
    );
  }
}

// =====================================================================
// MODÈLE — ContactResult (D8 — Mission D)
// =====================================================================

class ContactResult {
  final bool success;
  final String? error;

  const ContactResult({required this.success, this.error});
}

// =====================================================================
// MODÈLE — ResetPasswordResult (Mot de passe oublié)
// =====================================================================

class ResetPasswordResult {
  final bool success;
  final String? error;

  const ResetPasswordResult({required this.success, this.error});
}

// =====================================================================
// MODÈLES — Historique (S5)
// =====================================================================

/// Résultat paginé d'une page de l'historique.
class HistoriquePageResult {
  final List<HistoriqueDon> dons;
  final List<HistoriqueDemande> demandes;
  final bool aUnePageSuivante;

  const HistoriquePageResult({
    required this.dons,
    required this.demandes,
    required this.aUnePageSuivante,
  });
}

/// Un don enregistré depuis public.historique_dons.
class HistoriqueDon {
  final String id;
  final DateTime dateDon;
  final String source; // 'qr_valide' | 'declaratif'
  final String? demandeId;
  final DateTime? createdAt;

  const HistoriqueDon({
    required this.id,
    required this.dateDon,
    required this.source,
    this.demandeId,
    this.createdAt,
  });

  factory HistoriqueDon.fromJson(Map<String, dynamic> json) => HistoriqueDon(
        id: json['id'] as String,
        dateDon: DateTime.parse(json['date_don'] as String),
        source: json['source'] as String? ?? 'declaratif',
        demandeId: json['demande_id'] as String?,
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'] as String)
            : null,
      );

  bool get estQrValide => source == 'qr_valide';
}

/// Une demande publiée depuis public.demandes_sang (auteur = l'utilisateur).
class HistoriqueDemande {
  final String id;
  final String groupeSanguinRecherche;
  final String statut;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String? villeNom;

  const HistoriqueDemande({
    required this.id,
    required this.groupeSanguinRecherche,
    required this.statut,
    required this.createdAt,
    required this.expiresAt,
    this.villeNom,
  });

  factory HistoriqueDemande.fromJson(Map<String, dynamic> json) =>
      HistoriqueDemande(
        id: json['id'] as String,
        groupeSanguinRecherche:
            json['groupe_sanguin_recherche'] as String? ?? '',
        statut: json['statut'] as String? ?? 'active',
        createdAt: DateTime.parse(json['created_at'] as String),
        expiresAt: DateTime.parse(json['expires_at'] as String),
        villeNom: json['ville_nom'] as String?,
      );

  bool get estActive => statut == 'active' && DateTime.now().isBefore(expiresAt);

  String get statutLabel {
    switch (statut) {
      case 'active':
        return estActive ? 'Active' : 'Expirée';
      case 'en_cours':
        return 'En cours';
      case 'satisfaite':
        return 'Satisfaite';
      case 'expiree':
        return 'Expirée';
      case 'annulee':
        return 'Annulée';
      default:
        return statut;
    }
  }
}
