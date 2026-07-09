import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'supabase_service.dart';

// =====================================================================
// NOTIFICATION SERVICE — Gestion des tokens FCM pour SONGRE
//
// Ce service enregistre le token FCM de l'appareil dans
// public.device_tokens (jamais dans public.identites — le schéma réel
// n'a pas de colonne fcm_token dans identites).
//
// Configuration requise AVANT d'utiliser ce service :
//   1. Créer un projet Firebase sur https://console.firebase.google.com/
//   2. Ajouter une app Android avec le package : com.lifesaver.save
//   3. Télécharger google-services.json → android/app/google-services.json
//   4. Activer Cloud Messaging dans Firebase Console
//   5. Pour la génération du service account JSON (utilisé dans les
//      Edge Functions) : Project Settings → Service accounts → Generate key
//
// Sur iOS : il faut aussi télécharger GoogleService-Info.plist
// et configurer le certificat APNs dans Firebase Console.
//
// IMPORTANT : Le Service Account JSON reste EXCLUSIVEMENT dans les
// Edge Functions Supabase. Il ne doit jamais apparaître dans ce code.
// =====================================================================

/// Gestionnaire de tokens FCM.
/// Doit être initialisé après une connexion réussie.
class NotificationService {
  NotificationService._();

  /// Initialise FCM et enregistre le token dans public.device_tokens.
  /// Appeler après chaque connexion (connecter() ou restaurerSession()).
  static Future<void> initialiser(String userId) async {
    // FCM non disponible sur Web — skip silencieusement
    if (kIsWeb) return;

    try {
      final messaging = FirebaseMessaging.instance;

      // Demander la permission (iOS + Android 13+)
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        if (kDebugMode) {
          debugPrint('[NotificationService] Permissions refusées.');
        }
        return;
      }

      // Obtenir le token FCM
      final token = await messaging.getToken();
      if (token == null || token.isEmpty) {
        if (kDebugMode) {
          debugPrint('[NotificationService] Token FCM null ou vide.');
        }
        return;
      }

      // Déterminer la plateforme
      String? plateforme;
      if (defaultTargetPlatform == TargetPlatform.android) {
        plateforme = 'android';
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        plateforme = 'ios';
      }

      // Enregistrer dans public.device_tokens
      final ok = await SupabaseService.enregistrerFcmToken(
        userId: userId,
        fcmToken: token,
        plateforme: plateforme,
      );

      if (kDebugMode) {
        debugPrint(
          '[NotificationService] Token FCM ${ok ? "enregistré" : "ERREUR"}: '
          '${token.substring(0, 20)}...',
        );
      }

      // Écouter les rotations de token (token invalidé par Firebase)
      messaging.onTokenRefresh.listen((newToken) async {
        if (kDebugMode) {
          debugPrint('[NotificationService] Token FCM renouvelé.');
        }
        await SupabaseService.enregistrerFcmToken(
          userId: userId,
          fcmToken: newToken,
          plateforme: plateforme,
        );
      });

      // Configurer la réception des messages en arrière-plan
      FirebaseMessaging.onBackgroundMessage(
          _firebaseMessagingBackgroundHandler);

      // Configurer la réception des messages en premier plan
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        if (kDebugMode) {
          debugPrint(
            '[NotificationService] Message reçu en premier plan: '
            '${message.notification?.title}',
          );
        }
        // L'UI se met à jour via _chargerNotificationsBackend() au prochain
        // actualiserNotifications() ou retour de l'app en premier plan.
      });
    } catch (e) {
      // Non bloquant — la connexion principale n'est pas affectée
      if (kDebugMode) {
        debugPrint('[NotificationService] Erreur initialisation: $e');
      }
    }
  }
}

/// Handler de messages FCM en arrière-plan.
/// DOIT être une fonction top-level (pas de méthode de classe).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Pas besoin d'initialiser Firebase ici — déjà fait dans main.dart
  if (kDebugMode) {
    debugPrint(
      '[FCM Background] Notification reçue: ${message.notification?.title}',
    );
  }
}
