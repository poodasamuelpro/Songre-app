import 'dart:async';
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
//
// [Fix-FCM-LEAK] Correction fuite mémoire onTokenRefresh :
// La subscription était recréée à chaque appel de initialiser().
// Désormais : subscription singleton gérée via _tokenRefreshSub.
// =====================================================================

/// Gestionnaire de tokens FCM + notifications locales.
class NotificationService {
  NotificationService._();

  // [Fix-FCM-LEAK] Subscription singleton — évite les doublons si
  // initialiser() est appelé plusieurs fois (reconnexion, restauration session).
  static StreamSubscription<String>? _tokenRefreshSub;

  // [Fix-FCM-FOREGROUND] Subscription singleton pour les messages foreground
  static StreamSubscription<RemoteMessage>? _foregroundSub;

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
  ///
  /// [Fix-FCM-LEAK] : annule les subscriptions précédentes avant d'en créer
  /// de nouvelles — évite les doublons si appelé plusieurs fois par session.
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
        debugPrint('[NotificationService] Permissions refusées.');
        return;
      }

      // Obtenir le token FCM
      final token = await messaging.getToken();
      if (token == null || token.isEmpty) {
        debugPrint('[NotificationService] Token FCM null ou vide.');
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
      // [Fix-FCM-UPSERT] : l'URL cible maintenant ?on_conflict=fcm_token
      // (correction dans supabase_service.dart — plus de 409)
      final ok = await SupabaseService.enregistrerFcmToken(
        userId: userId,
        fcmToken: token,
        plateforme: plateforme,
      );

      debugPrint(
        '[NotificationService] Token FCM ${ok ? "enregistré ✅" : "ERREUR ❌"}: '
        '${token.length > 20 ? token.substring(0, 20) : token}...',
      );

      // [Fix-FCM-LEAK] Annuler la subscription précédente avant de recréer
      // (évite les doublons si initialiser() est appelé à chaque reconnexion)
      await _tokenRefreshSub?.cancel();
      _tokenRefreshSub = messaging.onTokenRefresh.listen((newToken) async {
        debugPrint('[NotificationService] Token FCM renouvelé — mise à jour.');
        await SupabaseService.enregistrerFcmToken(
          userId: userId,
          fcmToken: newToken,
          plateforme: plateforme,
        );
      });

      // [Fix-FCM-BACKGROUND] Configurer la réception des messages en arrière-plan
      // DOIT être appelé avant d'écouter onMessage (ordre Firebase requis)
      FirebaseMessaging.onBackgroundMessage(
          _firebaseMessagingBackgroundHandler);

      // [Fix-FCM-FOREGROUND] Annuler l'ancienne subscription avant recréation
      await _foregroundSub?.cancel();
      _foregroundSub = FirebaseMessaging.onMessage.listen(
        (RemoteMessage message) => _afficherNotificationForeground(message),
      );

      // [Fix-FCM-CLICK] Gérer le tap sur notification quand l'app est en background
      // (notification cliquée → app ouverte)
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint(
          '[NotificationService] Notification cliquée (background): '
          '${message.notification?.title}',
        );
        // TODO: router vers l'écran approprié selon message.data['type']
      });

      // Vérifier si l'app a été ouverte via une notification (app fermée)
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        debugPrint(
          '[NotificationService] App ouverte depuis notification (terminée): '
          '${initialMessage.notification?.title}',
        );
        // TODO: router vers l'écran approprié selon initialMessage.data['type']
      }

    } catch (e) {
      // Non bloquant — la connexion principale n'est pas affectée
      debugPrint('[NotificationService] Erreur initialisation: $e');
    }
  }

  /// Affiche une bannière locale pour les messages reçus en premier plan.
  /// FCM est silencieux en foreground sur Android — on doit afficher manuellement.
  static void _afficherNotificationForeground(RemoteMessage message) {
    final notif = message.notification;

    // [Fix-FCM-DATA-ONLY] Gérer les messages data-only (sans notification payload)
    // Ces messages arrivent silencieusement — on crée une notification locale
    // depuis les données si le champ 'titre' ou 'body' est présent dans data.
    final titre = notif?.title ?? message.data['titre'] as String?;
    final corps = notif?.body  ?? message.data['body']  as String?;

    if (titre == null && corps == null) {
      // Message data-only sans contenu affichable — ignorer silencieusement
      debugPrint(
        '[NotificationService] Message data-only reçu (foreground): '
        'type=${message.data["type"]}',
      );
      return;
    }

    _localNotif.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      titre ?? 'SONGRE',
      corps,
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
  }

  /// Libère les ressources — appeler lors de la déconnexion.
  static Future<void> disposer() async {
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
    await _foregroundSub?.cancel();
    _foregroundSub = null;
  }
}

/// Handler de messages FCM en arrière-plan.
/// DOIT être une fonction top-level (pas de méthode de classe).
/// Exécutée dans un isolate séparé — NE PAS accéder à l'UI ici.
///
/// [Fix-FCM-BACKGROUND-DATA] : gère maintenant les messages data-only
/// (sans notification payload) qui arrivent quand l'app est en arrière-plan.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Firebase est déjà initialisé par le système dans ce contexte.
  // NE PAS appeler Firebase.initializeApp() ici — doublon = crash.

  final notif = message.notification;
  final titre = notif?.title ?? message.data['titre'] as String?;
  final corps = notif?.body  ?? message.data['body']  as String?;
  final type  = message.data['type'] as String? ?? 'inconnu';

  debugPrint(
    '[FCM Background] type=$type | '
    'titre="${titre ?? "(data-only)"}" | '
    'corps="${corps ?? "(aucun)"}"',
  );

  // Les messages data-only en arrière-plan doivent être affichés manuellement
  // via flutter_local_notifications SI l'app est en arrière-plan (pas terminée).
  // Quand l'app est TERMINÉE, FCM affiche automatiquement la notification système
  // si le payload contient un objet `notification`. Pour les messages data-only
  // avec app terminée, une Edge Function doit envoyer le payload `notification`.
}
