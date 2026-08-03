// Named public constructor arguments intentionally initialize private fields.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import 'notification_preferences.dart';

Map<String, Object?> buildIosPushApsPayload({required bool soundEnabled}) {
  return <String, Object?>{
    'mutable-content': 1,
    'content-available': 1,
    // Sygnal replaces this fallback with the Matrix unread count when the
    // homeserver includes one. Keeping a nonzero fallback ensures APNs can
    // still badge event-only notifications that omit counts.
    'badge': 1,
    'alert': <String, Object?>{
      'title': 'Patrick Messenger',
      'body': 'New encrypted message',
    },
    if (soundEnabled) 'sound': 'default',
  };
}

class IosPushService {
  static const _channel = MethodChannel(
    'com.patricklamphier.patrickMessenger/apns',
  );

  final Client _client;
  final NotificationPreferenceController _preferences;
  final Uri _gateway;
  final String _appId;

  StreamSubscription<LoginState>? _loginSubscription;
  String? _token;
  bool _updating = false;

  IosPushService({
    required Client client,
    required NotificationPreferenceController preferences,
    required Uri gateway,
    required String appId,
  }) : _client = client,
       _preferences = preferences,
       _gateway = gateway,
       _appId = appId;

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> initialize() async {
    if (!_supported) return;
    _channel.setMethodCallHandler(_handleNativeCall);
    _preferences.addListener(_handlePreferenceChange);
    _loginSubscription ??= _client.onLoginStateChanged.stream.listen((state) {
      if (state == LoginState.loggedIn) unawaited(_refresh());
    });

    try {
      _token = await _channel.invokeMethod<String>('getToken');
      await _refresh();
    } on PlatformException catch (error) {
      debugPrint('APNs registration is not ready: ${error.message}');
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'token' && call.arguments is String) {
      _token = call.arguments as String;
      await _refresh();
    } else if (call.method == 'error') {
      debugPrint('APNs registration failed: ${call.arguments}');
    }
  }

  void _handlePreferenceChange() => unawaited(_refresh());

  Future<void> _refresh() async {
    final token = _token;
    if (_updating || token == null || token.isEmpty || !_client.isLogged()) {
      return;
    }
    _updating = true;
    try {
      await _channel.invokeMethod<void>('configureNotificationExtension', {
        'homeserver': _client.homeserver.toString(),
        'accessToken': _client.accessToken,
        'userId': _client.userID,
        'showPreviews': _preferences.showPreviews,
        'notifyIfReadElsewhere': _preferences.notifyIfReadElsewhere,
      });
      if (!_preferences.enabled) {
        await _client.deletePusher(PusherId(appId: _appId, pushkey: token));
        return;
      }

      final aps = buildIosPushApsPayload(
        soundEnabled: _preferences.soundEnabled,
      );
      await _client.postPusher(
        Pusher(
          appId: _appId,
          pushkey: token,
          appDisplayName: 'Patrick Messenger',
          deviceDisplayName: _client.deviceName ?? 'iPhone',
          kind: 'http',
          lang: 'en-US',
          data: PusherData(
            format: 'event_id_only',
            url: _gateway,
            additionalProperties: <String, Object?>{
              'default_payload': <String, Object?>{'aps': aps},
            },
          ),
        ),
        append: true,
      );
    } catch (error) {
      debugPrint('Matrix APNs pusher could not be updated: $error');
    } finally {
      _updating = false;
    }
  }

  Future<void> dispose() async {
    _preferences.removeListener(_handlePreferenceChange);
    await _loginSubscription?.cancel();
    _channel.setMethodCallHandler(null);
  }
}
