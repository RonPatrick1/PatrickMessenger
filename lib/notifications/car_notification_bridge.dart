import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges to native Kotlin so a message notification can also be posted as
/// an Android Auto-compatible `NotificationCompat.MessagingStyle`
/// notification (reply + mark-as-read actions, conversation grouping).
/// Building that notification shape natively keeps title/body computation
/// in one place (the callers below already compute it for the phone-side
/// notification) instead of duplicating sender/room-name logic in Kotlin.
class CarNotificationBridge {
  static const _channel = MethodChannel(
    'com.patricklamphier.patrickMessenger/car_notification',
  );

  static Future<void> show({
    required String roomId,
    required int notificationId,
    required String senderId,
    required String senderName,
    required String conversationTitle,
    required bool isGroupConversation,
    required String body,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('show', {
        'roomId': roomId,
        'notificationId': notificationId,
        'senderId': senderId,
        'senderName': senderName,
        'conversationTitle': conversationTitle,
        'isGroupConversation': isGroupConversation,
        'body': body,
      });
    } catch (error) {
      debugPrint('Car notification could not be shown: $error');
    }
  }
}
