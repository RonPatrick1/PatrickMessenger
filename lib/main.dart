import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'config/app_config.dart';
import 'matrix/matrix_client_factory.dart';
import 'notifications/android_message_connection_service.dart';
import 'notifications/ios_push_service.dart';
import 'notifications/liam_chatter_visibility.dart';
import 'notifications/message_notification_service.dart';
import 'notifications/notification_preferences.dart';
import 'settings/text_scale_preference.dart';
import 'settings/theme_preference.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AndroidMessageConnectionService.initializeCommunicationPort();

  final config = AppConfig.fromEnvironment();
  try {
    config.validate();
    final themeController = await ThemePreferenceController.load();
    final textScaleController = await TextScalePreferenceController.load();
    final notificationController =
        await NotificationPreferenceController.load();
    final liamChatterVisibility = await LiamChatterVisibilityController.load();
    final client = await MatrixClientFactory.create();
    final notificationService = MessageNotificationService(
      client,
      notificationController,
      liamChatterVisibility,
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
      ),
    );
    unawaited(androidMessageConnection.initialize());
  } catch (error) {
    runApp(StartupFailureApp(message: error.toString()));
  }
}
