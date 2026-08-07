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

class PatrickMessengerApp extends StatefulWidget {
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
  State<PatrickMessengerApp> createState() => _PatrickMessengerAppState();
}

class _PatrickMessengerAppState extends State<PatrickMessengerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A car-reply path (Android Auto's headless isolate, or on iOS the
    // CarPlay Intents Extension process) can advance a room's outbound
    // Megolm session on disk while this app is backgrounded. The main
    // Client's KeyManager caches that session in memory and won't know it
    // was superseded, so drop the cache on resume to force a fresh load
    // from the database before this app sends anything else.
    if (state == AppLifecycleState.resumed) {
      widget.client.encryption?.keyManager.clearOutboundGroupSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final config = widget.config;
    final themeController = widget.themeController;
    final textScaleController = widget.textScaleController;
    final notificationController = widget.notificationController;
    final notificationService = widget.notificationService;
    final conversationMuteController = widget.conversationMuteController;
    final liamChatterVisibility = widget.liamChatterVisibility;
    final archives = widget.archives;
    final searchIndex = widget.searchIndex;
    final readReceiptController = widget.readReceiptController;
    final receiptService = widget.receiptService;
    final incomingShares = widget.incomingShares;
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
    final generated = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    // Keep Material's secondary and tertiary component families in the same
    // LiamBlue palette. Generated accent families can otherwise introduce
    // unrelated warm colors into tonal buttons, dialogs, and selections.
    final colorScheme = generated.copyWith(
      secondary: generated.primary,
      onSecondary: generated.onPrimary,
      secondaryContainer: generated.primaryContainer,
      onSecondaryContainer: generated.onPrimaryContainer,
      tertiary: generated.primary,
      onTertiary: generated.onPrimary,
      tertiaryContainer: generated.primaryContainer,
      onTertiaryContainer: generated.onPrimaryContainer,
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
