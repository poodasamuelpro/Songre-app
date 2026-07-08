import 'dart:convert';
import 'dart:math';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';

// =====================================================================
// SERVICE DE CHIFFREMENT — AES-256-CBC (C4)
// Conforme à la section 7.2 du cahier des charges :
// "Chiffrement applicatif supplémentaire (AES-256) sur les champs sensibles"
//
// PRODUCTION : la clé DOIT être injectée via dart-define :
//   --dart-define=SONGRE_ENCRYPT_KEY=<minimum_32_caracteres>
//
// Aucune clé de fallback n'existe dans ce fichier. L'absence de clé
// provoque une StateError immédiate, en debug comme en release.
// Ceci garantit qu'un build sans clé échoue explicitement plutôt
// que de chiffrer silencieusement avec une clé connue.
//
// Format du chiffré : base64(IV_16B) + ":" + base64(ciphertext)
// IV généré aléatoirement par opération (pas de réutilisation).
// =====================================================================
class CryptoService {
  CryptoService._();

  // Clé injectée uniquement par --dart-define=SONGRE_ENCRYPT_KEY=...
  // Aucune valeur par défaut — vide signifie "non configuré".
  static const String _envKey =
      String.fromEnvironment('SONGRE_ENCRYPT_KEY', defaultValue: '');

  static enc.Key? _key;

  static void init() {
    if (_envKey.isNotEmpty && _envKey.length >= 32) {
      final keyBytes = utf8.encode(_envKey).sublist(0, 32);
      _key = enc.Key(Uint8List.fromList(keyBytes));
    } else {
      // ✋ Aucune clé de fallback. En l'absence de --dart-define=SONGRE_ENCRYPT_KEY,
      // l'application refuse de démarrer pour protéger les données médicales.
      // Pour le développement local, créez un fichier `.env.local` (ignoré par Git)
      // et passez la clé via : flutter run --dart-define=SONGRE_ENCRYPT_KEY=<votre_cle_dev>
      throw StateError(
        '[SONGRE] ERREUR CRITIQUE : Clé de chiffrement absente.\n'
        'Lancez l\'app avec : --dart-define=SONGRE_ENCRYPT_KEY=<32_chars_minimum>\n'
        'Exemple dev : flutter run --dart-define=SONGRE_ENCRYPT_KEY=SongreDevLocal2026_ChangeMe',
      );
    }
  }

  /// Chiffre une valeur String → base64(IV):base64(ciphertext) AES-256-CBC
  /// Retourne null si la valeur est null ou vide.
  static String? chiffrer(String? valeur) {
    if (valeur == null || valeur.isEmpty) return null;
    _ensureInit();
    try {
      final ivBytes = _generateRandomBytes(16);
      final iv = enc.IV(ivBytes);
      final encrypter = enc.Encrypter(enc.AES(_key!, mode: enc.AESMode.cbc));
      final encrypted = encrypter.encrypt(valeur, iv: iv);
      final ivB64 = base64Encode(ivBytes);
      return '$ivB64:${encrypted.base64}';
    } catch (e) {
      if (kDebugMode) debugPrint('[CryptoService] Erreur chiffrement: $e');
      return null;
    }
  }

  /// Déchiffre un champ base64(IV):base64(ciphertext) → String clair
  /// Retourne null si la valeur est null, vide, ou mal formée.
  static String? dechiffrer(String? valeurChiffree) {
    if (valeurChiffree == null || valeurChiffree.isEmpty) return null;
    _ensureInit();
    try {
      final parts = valeurChiffree.split(':');
      if (parts.length != 2) return null;
      final ivBytes = base64Decode(parts[0]);
      final iv = enc.IV(Uint8List.fromList(ivBytes));
      final encrypter = enc.Encrypter(enc.AES(_key!, mode: enc.AESMode.cbc));
      return encrypter.decrypt64(parts[1], iv: iv);
    } catch (e) {
      if (kDebugMode) debugPrint('[CryptoService] Erreur déchiffrement: $e');
      return null;
    }
  }

  /// Chiffre une liste de chaînes (ex : contre-indications médicales)
  static String? chiffrerListe(List<String>? valeurs) {
    if (valeurs == null || valeurs.isEmpty) return null;
    return chiffrer(jsonEncode(valeurs));
  }

  /// Déchiffre une liste de chaînes
  static List<String> dechiffrerListe(String? valeurChiffree) {
    final json = dechiffrer(valeurChiffree);
    if (json == null) return [];
    try {
      return List<String>.from(jsonDecode(json) as List);
    } catch (_) {
      return [];
    }
  }

  static void _ensureInit() {
    if (_key == null) init();
  }

  static Uint8List _generateRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
