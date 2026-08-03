// Named public constructor arguments intentionally initialize private fields.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../config/app_config.dart';
import 'notification_preferences.dart';

class AndroidPushService {
  static const soundChannelId = 'messages_with_sound_v1';
  static const silentChannelId = 'messages_silent_v1';

  final Client _client;
  final NotificationPreferenceController _preferences;
  final AppConfig _config;

  StreamSubscription<LoginState>? _loginSubscription;
  StreamSubscription<String>? _tokenSubscription;
  String? _token;
  bool _updating = false;
  bool _initialized = false;

  AndroidPushService({
    required Client client,
    required NotificationPreferenceController preferences,
    required AppConfig config,
  }) : _client = client,
       _preferences = preferences,
       _config = config;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> initialize() async {
    if (!_supported) return;
    if (!_config.hasAndroidFirebaseConfig) {
      debugPrint(
        'Android push is disabled because ANDROID_FIREBASE_* is not configured.',
      );
      return;
    }

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: FirebaseOptions(
            apiKey: _config.androidFirebaseApiKey,
            appId: _config.androidFirebaseAppId,
            messagingSenderId: _config.androidFirebaseMessagingSenderId,
            projectId: _config.androidFirebaseProjectId,
          ),
        );
      }

      _initialized = true;
      _preferences.addListener(_handlePreferenceChange);
      _loginSubscription ??= _client.onLoginStateChanged.stream.listen((state) {
        if (state == LoginState.loggedIn) {
          unawaited(_refresh());
        }
      });

      final messaging = FirebaseMessaging.instance;
      await messaging.setAutoInitEnabled(true);
      _tokenSubscription ??= messaging.onTokenRefresh.listen(
        (token) {
          _token = token;
          unawaited(_refresh());
        },
        onError: (Object error) {
          debugPrint('FCM token refresh failed: $error');
        },
      );
      _token = await messaging.getToken();
      await _refresh();
    } catch (error, stackTrace) {
      debugPrint('Android FCM initialization failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _handlePreferenceChange() => unawaited(_refresh());

  Future<void> _refresh() async {
    final token = _token;
    if (!_initialized ||
        _updating ||
        token == null ||
        token.isEmpty ||
        !_client.isLogged()) {
      return;
    }

    _updating = true;
    try {
      if (!_preferences.enabled) {
        await _client.deletePusher(
          PusherId(appId: _config.androidPushAppId, pushkey: token),
        );
        return;
      }

      // Sygnal's GCM/FCM pushkin merges the ENTIRE `default_payload` map
      // directly into the outgoing FCM v1 request's `message.data` field
      // (see sygnal/gcmpushkin.py's `_build_data`), which FCM only accepts
      // as flat string values — nesting `notification`/`android` objects in
      // here (as APNs' own `aps` payload legitimately allows) makes Google's
      // API reject the whole request with a 400. Sygnal already populates
      // event_id/room_id/sender/etc. as flat data fields on its own, so
      // nothing needs to be added here at all: this is a silent/data-only
      // push, matching iOS's content-available approach — the app decrypts
      // the referenced event and builds the visible notification itself.
      await _client.postPusher(
        Pusher(
          appId: _config.androidPushAppId,
          pushkey: token,
          appDisplayName: 'Patrick Messenger',
          deviceDisplayName: _client.deviceName ?? 'Android',
          kind: 'http',
          lang: 'en-US',
          data: PusherData(
            format: 'event_id_only',
            url: Uri.parse(_config.pushGatewayUrl),
          ),
        ),
        append: true,
      );
    } catch (error) {
      debugPrint('Matrix Android pusher could not be updated: $error');
    } finally {
      _updating = false;
    }
  }

  Future<void> dispose() async {
    _preferences.removeListener(_handlePreferenceChange);
    await _loginSubscription?.cancel();
    await _tokenSubscription?.cancel();
  }
}
