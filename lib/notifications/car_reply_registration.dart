import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'car_reply_dispatcher.dart';

/// Hands native Kotlin a callback handle it can use to spin up a headless
/// Dart isolate (via `DartExecutor.executeDartCallback`) whenever an
/// Android Auto car reply arrives and the app isn't already running. Native
/// persists the handle to `SharedPreferences` so it's readable from
/// `CarReplyService`, which isn't the same component that calls this.
class CarReplyRegistration {
  static const _channel = MethodChannel(
    'com.patricklamphier.patrickMessenger/car_reply',
  );

  static Future<void> register() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final handle = PluginUtilities.getCallbackHandle(carReplyDispatcher);
    if (handle == null) {
      debugPrint('carReplyDispatcher has no callback handle to register.');
      return;
    }
    try {
      await _channel.invokeMethod<void>('registerCallback', {
        'handle': handle.toRawHandle(),
      });
    } catch (error) {
      debugPrint('Car reply callback could not be registered: $error');
    }
  }
}
