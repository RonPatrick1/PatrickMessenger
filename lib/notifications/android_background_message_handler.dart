import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';

import '../config/app_config.dart';
import '../matrix/display_names.dart';
import '../matrix/matrix_client_factory.dart';
import '../screens/chat/message_interactions.dart';
import 'android_push_service.dart';
import 'conversation_mute_controller.dart';
import 'liam_chatter_visibility.dart';
import 'message_notification_service.dart' show notificationPreview;
import 'notification_preferences.dart';

/// Handles an FCM data message while this app has no running process (or is
/// merely backgrounded), reconnecting to the already logged-in session,
/// decrypting the one referenced event, and showing a local notification —
/// mirroring MessageNotificationService's live-app behavior for the one case
/// it can't cover on its own. Android runs this in its own isolate/engine
/// specifically for this callback (a fresh process if the app was fully
/// killed), so it must be entirely self-contained: no shared state with the
/// main app isolate, and it must independently initialize Firebase and
/// reconstruct its own Matrix client. `getEventByPushNotification` is
/// matrix-dart-sdk's own purpose-built API for exactly this: it explicitly
/// documents being safe to run from a second, lightweight client instance in
/// parallel with a main client using the same local database.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();

  final data = message.data;
  if (data['room_id'] == null || data['event_id'] == null) return;

  Client? client;
  try {
    final config = AppConfig.fromEnvironment();
    if (!config.hasAndroidFirebaseConfig) return;
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: config.androidFirebaseApiKey,
          appId: config.androidFirebaseAppId,
          messagingSenderId: config.androidFirebaseMessagingSenderId,
          projectId: config.androidFirebaseProjectId,
        ),
      );
    }

    final preferences = await NotificationPreferenceController.load();
    if (!preferences.enabled) return;

    final roomId = data['room_id'] as String;
    final muteController = await ConversationMuteController.load();
    if (muteController.isMuted(roomId)) return;

    final liamChatterVisibility = await LiamChatterVisibilityController.load();

    client = await MatrixClientFactory.create(homeserver: config.homeserver);
    if (!client.isLogged()) return;

    final event = await client.getEventByPushNotification(
      PushNotification.fromJson(data),
      returnNullIfSeen: !preferences.notifyIfReadElsewhere,
    );
    if (event == null) return;

    if (liamChatterVisibility.isHidden(roomId) &&
        isLiamChatterEvent(event, liamUserId: config.liamUserId)) {
      return;
    }

    final room = event.room;
    final sender = readableMatrixUserName(event.senderFromMemoryOrFallback);
    final roomName = readableMatrixRoomName(room);
    final title = !preferences.showPreviews
        ? 'Patrick Messenger'
        : room.isDirectChat
        ? sender
        : '$sender in $roomName';
    final body = !preferences.showPreviews
        ? 'New encrypted message'
        : notificationPreview(event);

    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
    );
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final channelId = preferences.soundEnabled
        ? AndroidPushService.soundChannelId
        : AndroidPushService.silentChannelId;
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        channelId,
        preferences.soundEnabled ? 'Messages with sound' : 'Silent messages',
        description: preferences.soundEnabled
            ? 'New encrypted messages with the default sound'
            : 'New encrypted messages without sound',
        importance: Importance.high,
        playSound: preferences.soundEnabled,
        enableVibration: true,
      ),
    );

    await plugin.show(
      id: event.eventId.hashCode & 0x7fffffff,
      title: title,
      body: body,
      payload: roomId,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          preferences.soundEnabled ? 'Messages with sound' : 'Silent messages',
          channelDescription: preferences.soundEnabled
              ? 'New encrypted messages with the default sound'
              : 'New encrypted messages without sound',
          importance: Importance.high,
          priority: Priority.high,
          playSound: preferences.soundEnabled,
          enableVibration: true,
          category: AndroidNotificationCategory.message,
        ),
      ),
    );
  } catch (error, stackTrace) {
    debugPrint('Android background push handling failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  } finally {
    // Sqflite returns one process-wide connection for this database path. A
    // background Firebase engine can therefore share the native connection
    // with the foreground Matrix client even though each uses a separate Dart
    // isolate. Closing it here leaves the foreground sync loop permanently
    // failing with DatabaseException(database_closed 7). The operating system
    // will release the connection when the app process exits.
    await client?.dispose(closeDatabase: false);
  }
}
