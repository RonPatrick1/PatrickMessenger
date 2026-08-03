import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'archive/archive_repository.dart';
import 'config/app_config.dart';
import 'matrix/matrix_client_factory.dart';
import 'notifications/android_background_message_handler.dart';
import 'notifications/android_push_service.dart';
import 'notifications/conversation_mute_controller.dart';
import 'notifications/ios_push_service.dart';
import 'notifications/liam_chatter_visibility.dart';
import 'notifications/message_notification_service.dart';
import 'notifications/notification_preferences.dart';
import 'notifications/push_classification_service.dart';
import 'receipts/message_receipt_service.dart';
import 'receipts/read_receipt_preferences.dart';
import 'search/search_index_service.dart';
import 'search/shared_search_service.dart';
import 'sharing/incoming_share_controller.dart';
import 'settings/text_scale_preference.dart';
import 'settings/theme_preference.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    await windowManager.ensureInitialized();
  }
  if (defaultTargetPlatform == TargetPlatform.linux) {
    fvp.registerWith(
      options: {
        'platforms': ['linux'],
      },
    );
  } else {
    MediaKit.ensureInitialized();
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }
  await _start();
}

// A stuck native crypto initialization (see MatrixClientFactory) or any
// other startup step that hangs instead of throwing would otherwise leave
// the app on a permanently blank white screen with no feedback. A timeout
// turns that into a recoverable error screen with a retry button instead.
Future<void> _start() async {
  try {
    await _startup().timeout(const Duration(seconds: 20));
  } catch (error) {
    runApp(StartupFailureApp(message: error.toString(), onRetry: _start));
  }
}

Future<void> _startup() async {
  final config = AppConfig.fromEnvironment();
  config.validate();
  final themeController = await ThemePreferenceController.load();
  final textScaleController = await TextScalePreferenceController.load();
  final notificationController = await NotificationPreferenceController.load();
  final conversationMuteController = await ConversationMuteController.load();
  final liamChatterVisibility = await LiamChatterVisibilityController.load();
  final readReceiptController = await ReadReceiptPreferenceController.load();
  final client = await MatrixClientFactory.create(
    homeserver: config.homeserver,
  );
  await conversationMuteController.connect(client);
  await liamChatterVisibility.connect(client, config.liamUserId);
  await readReceiptController.connect(client);
  final pushClassificationService = PushClassificationService(client);
  await pushClassificationService.initialize();
  final archives = ArchiveRepository(client);
  final sharedSearch = SharedSearchService(
    client: client,
    searchUserId: config.searchUserId,
  );
  await sharedSearch.initialize();
  final searchIndex = SearchIndexService(
    client: client,
    archives: archives,
    sharedSearch: sharedSearch,
  );
  await searchIndex.initialize();
  final receiptService = MessageReceiptService(client, readReceiptController);
  await receiptService.initialize();
  final incomingShares = IncomingShareController();
  await incomingShares.initialize();
  final notificationService = MessageNotificationService(
    client,
    notificationController,
    conversationMuteController,
    liamChatterVisibility,
    config.liamUserId,
  );
  await notificationService.initialize();
  final iosPushService = IosPushService(
    client: client,
    preferences: notificationController,
    gateway: Uri.parse(config.pushGatewayUrl),
    appId: config.iosPushAppId,
  );
  await iosPushService.initialize();
  final androidPushService = AndroidPushService(
    client: client,
    preferences: notificationController,
    config: config,
  );
  await androidPushService.initialize();
  runApp(
    PatrickMessengerApp(
      client: client,
      config: config,
      themeController: themeController,
      textScaleController: textScaleController,
      notificationController: notificationController,
      notificationService: notificationService,
      conversationMuteController: conversationMuteController,
      liamChatterVisibility: liamChatterVisibility,
      archives: archives,
      searchIndex: searchIndex,
      readReceiptController: readReceiptController,
      receiptService: receiptService,
      incomingShares: incomingShares,
    ),
  );
}
