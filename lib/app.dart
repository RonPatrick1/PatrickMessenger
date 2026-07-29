import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'config/app_config.dart';
import 'archive/archive_repository.dart';
import 'notifications/conversation_mute_controller.dart';
import 'notifications/liam_chatter_visibility.dart';
import 'notifications/message_notification_service.dart';
import 'notifications/notification_preferences.dart';
import 'receipts/message_receipt_service.dart';
import 'receipts/read_receipt_preferences.dart';
import 'search/search_index_service.dart';
import 'sharing/incoming_share_controller.dart';
import 'screens/login_screen.dart';
import 'screens/rooms_screen.dart';
import 'settings/text_scale_preference.dart';
import 'settings/theme_preference.dart';

class PatrickMessengerApp extends StatelessWidget {
  final Client client;
  final AppConfig config;
  final ThemePreferenceController themeController;
  final TextScalePreferenceController textScaleController;
  final NotificationPreferenceController notificationController;
  final MessageNotificationService notificationService;
  final ConversationMuteController conversationMuteController;
  final LiamChatterVisibilityController liamChatterVisibility;
  final ArchiveRepository archives;
  final SearchIndexService searchIndex;
  final ReadReceiptPreferenceController readReceiptController;
  final MessageReceiptService receiptService;
  final IncomingShareController incomingShares;

  const PatrickMessengerApp({
    required this.client,
    required this.config,
    required this.themeController,
    required this.textScaleController,
    required this.notificationController,
    required this.notificationService,
    required this.conversationMuteController,
    required this.liamChatterVisibility,
    required this.archives,
    required this.searchIndex,
    required this.readReceiptController,
    required this.receiptService,
    required this.incomingShares,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeController,
      builder: (context, _) => ListenableBuilder(
        listenable: textScaleController,
        builder: (context, _) => MaterialApp(
          title: 'Patrick Messenger',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: themeController.themeMode,
          builder: (context, child) {
            final media = MediaQuery.of(context);
            final systemScale = media.textScaler.scale(100) / 100;
            final combinedScale = (systemScale * textScaleController.scale)
                .clamp(0.8, 3.0)
                .toDouble();
            return MediaQuery(
              data: media.copyWith(
                textScaler: TextScaler.linear(combinedScale),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: StreamBuilder<LoginState>(
            stream: client.onLoginStateChanged.stream,
            initialData: client.onLoginStateChanged.value,
            builder: (context, _) {
              return client.isLogged()
                  ? RoomsScreen(
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
                    )
                  : LoginScreen(
                      client: client,
                      config: config,
                      themeController: themeController,
                    );
            },
          ),
        ),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) {
    // A restrained steel blue derived from Liam's blue/cyan icon palette.
    const seed = Color(0xFF2D6192);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      scaffoldBackgroundColor: colorScheme.surface,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    );
  }
}

class StartupFailureApp extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const StartupFailureApp({
    required this.message,
    required this.onRetry,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Patrick Messenger',
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 54),
                    const SizedBox(height: 20),
                    Text(
                      'Patrick Messenger could not start',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(message, textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: onRetry,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
