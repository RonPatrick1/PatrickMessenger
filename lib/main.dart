import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'archive/archive_repository.dart';
import 'config/app_config.dart';
import 'matrix/matrix_client_factory.dart';
import 'notifications/android_message_connection_service.dart';
import 'notifications/ios_push_service.dart';
import 'notifications/liam_chatter_visibility.dart';
import 'notifications/message_notification_service.dart';
import 'notifications/notification_preferences.dart';
import 'notifications/push_classification_service.dart';
import 'receipts/message_receipt_service.dart';
import 'receipts/read_receipt_preferences.dart';
import 'search/search_index_service.dart';
import 'search/shared_search_service.dart';
import 'settings/text_scale_preference.dart';
import 'settings/theme_preference.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AndroidMessageConnectionService.initializeCommunicationPort();
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
  final liamChatterVisibility = await LiamChatterVisibilityController.load();
  final readReceiptController = await ReadReceiptPreferenceController.load();
  final client = await MatrixClientFactory.create(
    homeserver: config.homeserver,
  );
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
  final notificationService = MessageNotificationService(
    client,
    notificationController,
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
  final androidMessageConnection = AndroidMessageConnectionService(client);
  runApp(
    PatrickMessengerApp(
      client: client,
      config: config,
      themeController: themeController,
      textScaleController: textScaleController,
      notificationController: notificationController,
      notificationService: notificationService,
      liamChatterVisibility: liamChatterVisibility,
      archives: archives,
      searchIndex: searchIndex,
      readReceiptController: readReceiptController,
      receiptService: receiptService,
    ),
  );
  unawaited(androidMessageConnection.initialize());
}
