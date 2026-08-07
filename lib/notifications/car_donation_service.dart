import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../matrix/display_names.dart';

/// Tells iOS (via `AppDelegate.donateSendMessageIntent`) about a room so
/// Siri can resolve "send a message to `name`" -- including from CarPlay --
/// to this room's `conversationIdentifier`, which `IntentHandler` (the
/// CarPlay Intents Extension) then reads to know which room to send into.
class CarDonationService {
  static const _channel = MethodChannel(
    'com.patricklamphier.patrickMessenger/car_donation',
  );

  static Future<void> donate(Room room) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>('donate', {
        'roomId': room.id,
        'recipientName': readableMatrixRoomName(room),
        'isGroupConversation': !room.isDirectChat,
      });
    } catch (error) {
      debugPrint('CarPlay donation could not be sent: $error');
    }
  }
}
