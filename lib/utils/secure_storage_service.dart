import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =====================================================================
// STOCKAGE SÉCURISÉ — Session utilisateur SONGRE
//
// Android : Android Keystore (AES_GCM_NoPadding)  ✅ Production-ready
// iOS     : Keychain (first_unlock_this_device)    ✅ Production-ready
//
// ⚠️  WEB : SharedPreferences (localStorage) — NON SÉCURISÉ
//     Les tokens JWT sont lisibles par tout script JavaScript de la page
//     (attaque XSS) et visibles dans les DevTools du navigateur.
//
//     DÉCISION : la version Web est strictement réservée aux démonstrations
//     et à l'accueil non-authentifié. Elle ne doit PAS être déployée en
//     production avec de vraies données médicales tant que les cookies
//     HttpOnly ne sont pas implémentés via un relais serveur dédié.
//
//     Un avertissement visuel est affiché dans l'app sur kIsWeb
//     dès la tentative d'authentification (voir WebSecurityBanner).
// =====================================================================
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

  static const String _keyUserId       = 'songre_secure_user_id';
  static const String _keyAccessToken  = 'songre_secure_access_token';
  static const String _keyRefreshToken = 'songre_secure_refresh_token';
  static const String _keyAuthType     = 'songre_secure_auth_type';

  // ---- Web : avertissement de sécurité ----

  /// Retourne true si la plateforme courante ne supporte pas un stockage
  /// sécurisé des tokens. Utiliser pour afficher WebSecurityBanner.
  static bool get estPlatformeNonSecurisee => kIsWeb;

  // ---- Écriture ----

  static Future<void> sauvegarderSession({
    required String userId,
    required String accessToken,
    required String refreshToken,
    String authType = 'email',
  }) async {
    if (kIsWeb) {
      // ⚠️ Web — stockage dégradé dans localStorage (non sécurisé pour prod)
      // Acceptable uniquement en mode démonstration.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyUserId, userId);
      await prefs.setString(_keyAccessToken, accessToken);
      await prefs.setString(_keyRefreshToken, refreshToken);
      await prefs.setString(_keyAuthType, authType);
      return;
    }
    await _storage.write(key: _keyUserId, value: userId);
    await _storage.write(key: _keyAccessToken, value: accessToken);
    await _storage.write(key: _keyRefreshToken, value: refreshToken);
    await _storage.write(key: _keyAuthType, value: authType);
  }

  static Future<void> mettreAJourTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAccessToken, accessToken);
      await prefs.setString(_keyRefreshToken, refreshToken);
      return;
    }
    await _storage.write(key: _keyAccessToken, value: accessToken);
    await _storage.write(key: _keyRefreshToken, value: refreshToken);
  }

  // ---- Lecture ----

  static Future<String?> lireUserId() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyUserId);
    }
    return _storage.read(key: _keyUserId);
  }

  static Future<String?> lireAccessToken() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyAccessToken);
    }
    return _storage.read(key: _keyAccessToken);
  }

  static Future<String?> lireRefreshToken() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyRefreshToken);
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

  /// Supprime TOUTES les données de session.
  /// Chaque clé est supprimée dans son propre try/catch : une PlatformException
  /// sur une clé (ex: Android Keystore verrouillé ou corrompu) ne bloque pas
  /// la suppression des autres et ne remonte jamais d'exception bloquante.
  static Future<void> supprimerSession() async {
    if (kIsWeb) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_keyUserId);
        await prefs.remove(_keyAccessToken);
        await prefs.remove(_keyRefreshToken);
        await prefs.remove(_keyAuthType);
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
        // Ne pas laisser une clé en erreur bloquer la suppression des autres.
      }
    }
  }

  static Future<bool> sessionExiste() async {
    final id = await lireUserId();
    final token = await lireAccessToken();
    return id != null && id.isNotEmpty && token != null && token.isNotEmpty;
  }
}
