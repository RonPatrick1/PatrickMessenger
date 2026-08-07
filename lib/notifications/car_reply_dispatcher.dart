import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:matrix/matrix.dart';

import '../config/app_config.dart';
import '../matrix/matrix_client_factory.dart';
import '../matrix/matrix_message_sender.dart';

/// Headless entrypoint `CarReplyService` (native Kotlin) launches in a
/// fresh Flutter engine whenever a driver replies to an Android Auto
/// messaging notification and the app isn't already running. Mirrors
/// `android_background_message_handler.dart`'s reconnect pattern: no shared
/// state with the main app isolate, independently reconstructs a Matrix
/// client against the already logged-in session's local database. Sends go
/// through `MatrixMessageSender.guarded` — the same choke point the
/// foreground compose flow uses — so this can never race the main app's
/// outbound Megolm session.
@pragma('vm:entry-point')
Future<void> carReplyDispatcher() async {
  WidgetsFlutterBinding.ensureInitialized();

  const isolateChannel = MethodChannel(
    'com.patricklamphier.patrickMessenger/car_reply_isolate',
  );

  isolateChannel.setMethodCallHandler((call) async {
    if (call.method != 'handleReply' && call.method != 'handleMarkRead') {
      return null;
    }
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final roomId = args['roomId'] as String;

    Client? client;
    try {
      final config = AppConfig.fromEnvironment();
      client = await MatrixClientFactory.create(homeserver: config.homeserver);
      if (!client.isLogged()) {
        throw StateError('No logged-in session to act from.');
      }

      final room = client.getRoomById(roomId);
      if (room == null) {
        throw StateError('Unknown room: $roomId');
      }

      if (call.method == 'handleReply') {
        final replyText = args['replyText'] as String;
        await MatrixMessageSender.guarded(() => room.sendTextEvent(replyText));
      }

      final lastEventId = room.lastEvent?.eventId;
      if (lastEventId != null) {
        try {
          await room.setReadMarker(lastEventId, mRead: lastEventId);
        } catch (_) {
          // Marking read is best-effort; the primary action already
          // succeeded (or, for a bare mark-read, there's nothing else to
          // roll back).
        }
      }
      return true;
    } finally {
      await client?.dispose(closeDatabase: false);
    }
  });

  await isolateChannel.invokeMethod<void>('initialized');
}
