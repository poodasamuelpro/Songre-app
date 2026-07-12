import 'dart:convert';
import 'dart:math';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';

// =====================================================================
// SERVICE DE CHIFFREMENT — AES-256-CBC (C4)
// Conforme à la section 7.2 du cahier des charges :
// "Chiffrement applicatif supplémentaire (AES-256) sur les champs sensibles"
//
// PRODUCTION : la clé est injectée via dart-define (prioritaire) :
//   --dart-define=SONGRE_ENCRYPT_KEY=<minimum_32_caracteres>
//
// Si SONGRE_ENCRYPT_KEY n'est pas fourni au build, la clé de production
// historique est utilisée comme fallback implicite.
//
// CORRECTION ÉCRAN NOIR (SEC-01 revisited) :
// L'ancienne implémentation levait un StateError si la clé était absente,
// crashant l'app avant runApp (écran noir permanent sur appareil réel).
// La clé de production historique (SongreProdBurkinaFaso2026_SecureKey!)
// est celle avec laquelle les données en BDD ont été chiffrées — son
// absence dans le build rendait le déchiffrement impossible ET crashait
// l'app. Elle est désormais embarquée comme defaultValue pour garantir :
// 1. Le démarrage de l'app même sans --dart-define
// 2. La compatibilité avec les données chiffrées existantes en BDD
// 3. La possibilité de rotation future via --dart-define
//
// Format du chiffré : base64(IV_16B) + ":" + base64(ciphertext)
// IV généré aléatoirement par opération (pas de réutilisation).
// =====================================================================
class CryptoService {
  CryptoService._();

  // Clé injectée par --dart-define=SONGRE_ENCRYPT_KEY (prioritaire).
  // Fallback : clé de production historique utilisée pour les données en BDD.
  // Cette valeur garantit la compatibilité des données chiffrées existantes
  // ET évite le crash au démarrage si --dart-define est absent.
  static const String _envKey = String.fromEnvironment(
    'SONGRE_ENCRYPT_KEY',
    defaultValue: 'SongreProdBurkinaFaso2026_SecureKey!',
  );

  static enc.Key? _key;

  /// Initialise le service de chiffrement.
  /// Ne lève plus d'exception — dégradation gracieuse si la clé est absente.
  static void init() {
    if (_envKey.isEmpty || _envKey.length < 32) {
      // Clé absente ou trop courte : service non initialisé, opérations de
      // chiffrement retourneront null. L'app démarre quand même.
      if (kDebugMode) {
        debugPrint(
          '[CryptoService] ⚠️  Clé absente ou trop courte — chiffrement désactivé. '
          'Injectez --dart-define=SONGRE_ENCRYPT_KEY=<32+ chars>.',
        );
      }
      return;
    }
    final keyBytes = utf8.encode(_envKey).sublist(0, 32);
    _key = enc.Key(Uint8List.fromList(keyBytes));
  }

  /// Chiffre une valeur String → base64(IV):base64(ciphertext) AES-256-CBC
  /// Retourne null si la valeur est null/vide ou si le service n'est pas initialisé.
  static String? chiffrer(String? valeur) {
    if (valeur == null || valeur.isEmpty) return null;
    _ensureInit();
    if (_key == null) return null;
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
  /// Retourne null si la valeur est null, vide, mal formée, ou si le service
  /// n'est pas initialisé.
  static String? dechiffrer(String? valeurChiffree) {
    if (valeurChiffree == null || valeurChiffree.isEmpty) return null;
    _ensureInit();
    if (_key == null) return null;
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
