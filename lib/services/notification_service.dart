import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'supabase_service.dart';

// Canal Android — importance HIGH + son
const _kChannelId   = 'songre_fcm';
const _kChannelName = 'Notifications SONGRE';
const _kChannelDesc = 'Alertes dons, réponses et rappels SONGRE';

const _androidChannel = AndroidNotificationChannel(
  _kChannelId, _kChannelName,
  description: _kChannelDesc,
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

final _localNotif = FlutterLocalNotificationsPlugin();

// =====================================================================
// NOTIFICATION SERVICE — Gestion des tokens FCM pour SONGRE
//
// Ce service enregistre le token FCM de l'appareil dans
// public.device_tokens (jamais dans public.identites — le schéma réel
// n'a pas de colonne fcm_token dans identites).
//
// Configuration requise AVANT d'utiliser ce service :
//   1. Créer un projet Firebase sur https://console.firebase.google.com/
//   2. Ajouter une app Android avec le package : com.songre.app
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

/// Gestionnaire de tokens FCM + notifications locales.
class NotificationService {
  NotificationService._();

  /// Initialise le canal Android (son + importance HIGH).
  /// Appeler UNE FOIS dans main(), après Firebase.initializeApp().
  static Future<void> initialiserCanal() async {
    if (kIsWeb) return;
    try {
      await _localNotif
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_androidChannel);
      const init = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _localNotif.initialize(init);
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationService] initialiserCanal: $e');
    }
  }

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
      // → afficher une bannière locale avec son (FCM est silencieux en foreground)
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final notif = message.notification;
        if (notif == null) return;
        _localNotif.show(
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
          notif.title ?? 'SONGRE',
          notif.body,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _kChannelId, _kChannelName,
              channelDescription: _kChannelDesc,
              importance: Importance.high,
              priority: Priority.high,
              playSound: true,
              enableVibration: true,
              icon: '@mipmap/ic_launcher',
            ),
          ),
        );
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
