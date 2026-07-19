import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =====================================================================
// STOCKAGE SÉCURISÉ — Session utilisateur SONGRE
//
// Android : Android Keystore (AES_GCM_NoPadding)  ✅ Production-ready
// iOS     : Keychain (first_unlock_this_device)    ✅ Production-ready
//
// ✅ WEB (BFF MODE) : Tokens stockés côté serveur (Cloudflare KV /
//     Upstash Redis) dans des cookies HttpOnly.
//     Le navigateur NE peut PAS lire les tokens via JavaScript.
//     Seul le userId (identifiant non-sensible) est dans SharedPreferences
//     pour permettre l'affichage du profil sans requête réseau.
//
//     CSRF : le BFF pose un cookie bff_csrf (non-HttpOnly) que l'app
//     lit et envoie dans l'en-tête X-CSRF-Token sur les requêtes mutantes.
// =====================================================================

// ── Constante BFF_URL (injectée via --dart-define=BFF_URL=...) ───────────
// Valeur par défaut vide → en mode natif Android/iOS, BFF_URL n'est jamais
// utilisée (les appels directs Supabase restent actifs).
// En mode Web, doit être défini à l'URL du BFF déployé.
const String kBffUrl = String.fromEnvironment('BFF_URL', defaultValue: '');

/// Retourne true si le mode BFF est actif :
///   - plateforme Web
///   - ET BFF_URL non vide
bool get estBffActif => kIsWeb && kBffUrl.isNotEmpty;

class SecureStorageService {
  SecureStorageService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // Clés de stockage
  static const String _keyUserId       = 'songre_secure_user_id';
  static const String _keyAccessToken  = 'songre_secure_access_token';
  static const String _keyRefreshToken = 'songre_secure_refresh_token';
  static const String _keyAuthType     = 'songre_secure_auth_type';

  // ── API publique — état de sécurité ──────────────────────────────────

  /// [Legacy] Retourne true si la plateforme utilise un stockage non sécurisé.
  /// Avec le BFF actif, la Web n'est plus non sécurisée.
  static bool get estPlatformeNonSecurisee => kIsWeb && !estBffActif;

  // ── Écriture ─────────────────────────────────────────────────────────

  /// Sauvegarde la session utilisateur.
  ///
  /// Mode BFF (Web + BFF_URL défini) :
  ///   - Stocke UNIQUEMENT le userId dans SharedPreferences
  ///   - Les tokens sont gérés côté BFF via cookie HttpOnly
  ///   - ne jamais stocker accessToken/refreshToken côté client Web
  ///
  /// Mode natif (Android/iOS) :
  ///   - Stocke les 4 clés dans Android Keystore / iOS Keychain
  ///
  /// Mode Web sans BFF (déprécié, fallback dégradé) :
  ///   - Stocke uniquement userId dans SharedPreferences
  ///   - N'écrit PAS les tokens en localStorage (suppression du risque XSS)
  static Future<void> sauvegarderSession({
    required String userId,
    required String accessToken,
    required String refreshToken,
    String authType = 'email',
  }) async {
    if (kIsWeb) {
      // Web (BFF ou non) : stocker UNIQUEMENT userId (non sensible)
      // Les tokens restent côté BFF (cookie HttpOnly) ou ne sont pas stockés.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyUserId, userId);
      // Note : authType stocké pour l'affichage uniquement (non sensible)
      await prefs.setString(_keyAuthType, authType);
      // NE PAS écrire _keyAccessToken ni _keyRefreshToken
      return;
    }
    // Android / iOS : stockage sécurisé complet
    await _storage.write(key: _keyUserId, value: userId);
    await _storage.write(key: _keyAccessToken, value: accessToken);
    await _storage.write(key: _keyRefreshToken, value: refreshToken);
    await _storage.write(key: _keyAuthType, value: authType);
  }

  /// Met à jour les tokens après un rafraîchissement JWT.
  ///
  /// Mode BFF Web : no-op côté client — le BFF met à jour Redis directement.
  /// Mode natif : met à jour Android Keystore / Keychain.
  static Future<void> mettreAJourTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    if (kIsWeb) {
      // En mode BFF, le refresh est géré côté BFF (/bff/auth/refresh).
      // Rien à faire côté client — le cookie HttpOnly est mis à jour
      // automatiquement par le BFF dans sa réponse Set-Cookie.
      return;
    }
    await _storage.write(key: _keyAccessToken, value: accessToken);
    await _storage.write(key: _keyRefreshToken, value: refreshToken);
  }

  // ── Lecture ──────────────────────────────────────────────────────────

  static Future<String?> lireUserId() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyUserId);
    }
    return _storage.read(key: _keyUserId);
  }

  /// En mode BFF Web, les tokens ne sont PAS lisibles côté client.
  /// Ce getter retourne null sur Web — le BFF les gère via cookie HttpOnly.
  /// Utilisé uniquement sur Android/iOS.
  static Future<String?> lireAccessToken() async {
    if (kIsWeb) {
      // BFF mode : token dans cookie HttpOnly → non accessible depuis JS/Dart
      // Retourner null indique que l'app doit passer par le BFF pour les requêtes
      return null;
    }
    return _storage.read(key: _keyAccessToken);
  }

  /// Même principe que lireAccessToken — null sur Web (BFF mode).
  static Future<String?> lireRefreshToken() async {
    if (kIsWeb) {
      return null;
    }
    return _storage.read(key: _keyRefreshToken);
  }

  static Future<String?> lireAuthType() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyAuthType);
    }
    return _storage.read(key: _keyAuthType);
  }

  /// Supprime TOUTES les données de session locales.
  ///
  /// Web : efface userId et authType de SharedPreferences.
  ///       Les cookies HttpOnly sont effacés par le BFF lors du logout
  ///       (réponse du BFF avec Set-Cookie: Max-Age=0).
  ///
  /// Natif : supprime toutes les clés du Keystore/Keychain.
  static Future<void> supprimerSession() async {
    if (kIsWeb) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_keyUserId);
        await prefs.remove(_keyAuthType);
        // Pas de remove pour _keyAccessToken/_keyRefreshToken
        // car ils ne sont jamais écrits en Web BFF mode
      } catch (e) {
        if (kDebugMode) debugPrint('[SecureStorageService] supprimerSession (web) error: $e');
      }
      return;
    }
    for (final key in [_keyUserId, _keyAccessToken, _keyRefreshToken, _keyAuthType]) {
      try {
        await _storage.delete(key: key);
      } catch (e) {
        if (kDebugMode) debugPrint('[SecureStorageService] delete($key) error: $e');
      }
    }
  }

  /// Vérifie si une session est active.
  ///
  /// Web BFF : vérifie uniquement la présence du userId en SharedPreferences.
  ///           Le cookie HttpOnly n'est pas lisible depuis Dart/JS —
  ///           la vraie validation de session passe par une requête au BFF.
  ///
  /// Natif : vérifie la présence du userId ET du token dans le Keystore.
  static Future<bool> sessionExiste() async {
    final id = await lireUserId();
    if (kIsWeb) {
      // Web : on ne peut pas vérifier le token côté client (HttpOnly cookie)
      // L'existence du userId est un indicateur suffisant pour l'UI.
      // La validation réelle se fait via la première requête BFF.
      return id != null && id.isNotEmpty;
    }
    final token = await lireAccessToken();
    return id != null && id.isNotEmpty && token != null && token.isNotEmpty;
  }
}
