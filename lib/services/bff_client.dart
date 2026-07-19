// lib/services/bff_client.dart
// Client BFF pour Flutter Web — EXCLUSIVEMENT conditionné kIsWeb
//
// Ce fichier est importé par supabase_service.dart mais ses méthodes
// ne sont appelées que si estBffActif == true (kIsWeb && BFF_URL non vide).
// Le code Android/iOS ne passe JAMAIS par ce client.
//
// Architecture :
//   Flutter Web → BffClient → BFF (Cloudflare ou Vercel)
//                                     ↓
//                             Cookie HttpOnly ← Supabase Auth
//                                     ↓
//                              KV / Redis (tokens)
//
// Note sur le cookie : le navigateur envoie automatiquement le cookie
// HttpOnly dans chaque requête (credentials: 'include' implicite via
// http.Client sur Web). Dart web utilise le même mécanisme XHR
// que le navigateur → les cookies sont automatiquement inclus.
//
// Note sur le CSRF : le BFF pose un cookie bff_csrf (non-HttpOnly).
// Ce client le lit depuis document.cookie et l'envoie dans X-CSRF-Token.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_service.dart';
import 'supabase_service.dart' show AuthResult, ResetPasswordResult;

import 'bff_cookie_web.dart'
    if (dart.library.io) 'bff_cookie_stub.dart';

class BffClient {
  BffClient._();

  /// URL du BFF injectée via --dart-define=BFF_URL=https://bff.songre.bf
  static String get _bffUrl => kBffUrl;

  // ── Headers communs pour toutes les requêtes BFF ──────────────────────

  static Map<String, String> _headers({bool withCsrf = false}) {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (withCsrf) {
      final csrfToken = readCsrfCookie();
      if (csrfToken != null && csrfToken.isNotEmpty) {
        h['X-CSRF-Token'] = csrfToken;
      }
    }
    return h;
  }

  // ── Authentification ──────────────────────────────────────────────────

  /// Inscription via BFF → /bff/auth/signup
  static Future<AuthResult> inscrire({
    required String email,
    required String motDePasse,
  }) async {
    try {
      final resp = await http.post(
        Uri.parse('$_bffUrl/bff/auth/signup'),
        headers: _headers(),
        body: jsonEncode({'email': email, 'password': motDePasse}),
      ).timeout(const Duration(seconds: 20));

      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      if (data['ok'] == true) {
        final userId = data['userId'] as String?;
        final needsConfirm = data['needsEmailConfirmation'] as bool? ?? false;

        if (userId != null) {
          // Session immédiate — stocker userId (non sensible)
          await SecureStorageService.sauvegarderSession(
            userId: userId,
            accessToken: '', // Non utilisé en BFF mode
            refreshToken: '', // Non utilisé en BFF mode
            authType: 'email',
          );
        }

        return AuthResult(
          success: true,
          userId: userId,
          needsEmailConfirmation: needsConfirm,
        );
      }

      return AuthResult(
        success: false,
        error: data['error'] as String? ?? 'Erreur d\'inscription',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[BffClient] inscrire error: $e');
      return const AuthResult(
        success: false,
        error: 'Connexion au service impossible. Vérifiez votre réseau.',
      );
    }
  }

  /// Connexion via BFF → /bff/auth/login
  static Future<AuthResult> connecter({
    required String email,
    required String motDePasse,
  }) async {
    try {
      final resp = await http.post(
        Uri.parse('$_bffUrl/bff/auth/login'),
        headers: _headers(),
        body: jsonEncode({'email': email, 'password': motDePasse}),
      ).timeout(const Duration(seconds: 20));

      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      if (data['ok'] == true) {
        final userId = data['userId'] as String?;

        if (userId != null) {
          // Stocker uniquement userId (tokens dans cookie HttpOnly côté BFF)
          await SecureStorageService.sauvegarderSession(
            userId: userId,
            accessToken: '', // Non utilisé en BFF mode
            refreshToken: '', // Non utilisé en BFF mode
            authType: 'email',
          );
        }

        return AuthResult(
          success: true,
          userId: userId,
          accessToken: null, // Jamais transmis au client en BFF mode
        );
      }

      final error = data['error'] as String? ?? 'Erreur de connexion';
      return AuthResult(success: false, error: error);
    } catch (e) {
      if (kDebugMode) debugPrint('[BffClient] connecter error: $e');
      return const AuthResult(
        success: false,
        error: 'Connexion au service impossible. Vérifiez votre réseau.',
      );
    }
  }

  /// Rafraîchissement du token via BFF → /bff/auth/refresh
  /// Le BFF détient le refresh_token — le client n'a pas besoin de le fournir.
  static Future<bool> rafraichirToken() async {
    try {
      final resp = await http.post(
        Uri.parse('$_bffUrl/bff/auth/refresh'),
        headers: _headers(withCsrf: true),
      ).timeout(const Duration(seconds: 15));

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return data['ok'] == true;
    } catch (e) {
      if (kDebugMode) debugPrint('[BffClient] rafraichirToken error: $e');
      return false;
    }
  }

  /// Déconnexion via BFF → /bff/auth/logout
  /// Le BFF invalide la session KV + efface les cookies.
  static Future<void> deconnecter() async {
    try {
      await http.post(
        Uri.parse('$_bffUrl/bff/auth/logout'),
        headers: _headers(withCsrf: true),
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      if (kDebugMode) debugPrint('[BffClient] deconnecter error: $e');
      // Non bloquant — on efface la session locale de toute façon
    }
    // Effacer les données locales (userId dans SharedPreferences)
    await SecureStorageService.supprimerSession();
  }

  /// Envoi email de réinitialisation via BFF → /bff/auth/recover
  static Future<ResetPasswordResult> envoyerEmailReinitialisation(
    String email,
  ) async {
    try {
      final resp = await http.post(
        Uri.parse('$_bffUrl/bff/auth/recover'),
        headers: _headers(),
        body: jsonEncode({'email': email}),
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 429) {
        return const ResetPasswordResult(
          success: false,
          error: 'Trop de demandes. Patientez quelques minutes.',
        );
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      if (data['ok'] == true) {
        return const ResetPasswordResult(success: true);
      }

      return ResetPasswordResult(
        success: false,
        error: data['error'] as String? ?? 'Erreur lors de l\'envoi',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[BffClient] recover error: $e');
      return const ResetPasswordResult(
        success: false,
        error: 'Connexion au service impossible. Vérifiez votre réseau.',
      );
    }
  }

  // ── Proxy vers Supabase (données) ─────────────────────────────────────
  // Ces méthodes permettent aux autres services d'utiliser le BFF comme
  // proxy authentifié pour les requêtes de données (REST + Edge Functions).

  /// Requête GET vers Supabase REST via BFF
  static Future<http.Response> get(
    String path, {
    Map<String, String>? extraHeaders,
  }) async {
    final headers = _headers()..addAll(extraHeaders ?? {});
    return http.get(
      Uri.parse('$_bffUrl/bff/api/$path'),
      headers: headers,
    ).timeout(const Duration(seconds: 30));
  }

  /// Requête POST vers Supabase REST via BFF (avec CSRF)
  static Future<http.Response> post(
    String path,
    Object body, {
    Map<String, String>? extraHeaders,
  }) async {
    final headers = _headers(withCsrf: true)..addAll(extraHeaders ?? {});
    return http.post(
      Uri.parse('$_bffUrl/bff/api/$path'),
      headers: headers,
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 30));
  }

  /// Requête PATCH vers Supabase REST via BFF (avec CSRF)
  static Future<http.Response> patch(
    String path,
    Object body, {
    Map<String, String>? extraHeaders,
  }) async {
    final headers = _headers(withCsrf: true)..addAll(extraHeaders ?? {});
    return http.patch(
      Uri.parse('$_bffUrl/bff/api/$path'),
      headers: headers,
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 30));
  }

  /// Requête DELETE vers Supabase REST via BFF (avec CSRF)
  static Future<http.Response> delete(
    String path, {
    Map<String, String>? extraHeaders,
  }) async {
    final headers = _headers(withCsrf: true)..addAll(extraHeaders ?? {});
    return http.delete(
      Uri.parse('$_bffUrl/bff/api/$path'),
      headers: headers,
    ).timeout(const Duration(seconds: 30));
  }

  /// Appel Edge Function via BFF
  static Future<http.Response> callFunction(
    String functionName,
    Object body, {
    Map<String, String>? extraHeaders,
  }) async {
    final headers = _headers(withCsrf: true)..addAll(extraHeaders ?? {});
    return http.post(
      Uri.parse('$_bffUrl/bff/functions/$functionName'),
      headers: headers,
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 30));
  }
}
