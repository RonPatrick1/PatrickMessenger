import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:matrix/matrix.dart';

/// Keeps the Matrix long-poll eligible for network access after an Android
/// user leaves the app with Home. Android identifies this as remote messaging
/// and displays the required quiet, ongoing service notification.
class AndroidMessageConnectionService {
  static const _serviceId = 18472;

  final Client _client;
  StreamSubscription<LoginState>? _loginSubscription;
  Timer? _serviceMonitor;
  bool _starting = false;

  AndroidMessageConnectionService(this._client);

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static void initializeCommunicationPort() {
    if (isSupported) {
      FlutterForegroundTask.initCommunicationPort();
    }
  }

  Future<void> initialize() async {
    if (!isSupported) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'message_connection_v1',
        channelName: 'Message connection',
        channelDescription:
            'Keeps encrypted messages connected while the app is in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
        showWhen: false,
        showBadge: false,
        onlyAlertOnce: true,
        visibility: NotificationVisibility.VISIBILITY_PRIVATE,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );

    _loginSubscription ??= _client.onLoginStateChanged.stream.listen((state) {
      if (state == LoginState.loggedIn) {
        unawaited(_start());
      } else if (state == LoginState.loggedOut) {
        unawaited(_stop());
      }
    });

    if (_client.isLogged()) {
      await _start();
    }

    // Starting the service can fail on a fresh Android install until the user
    // grants notification permission. Keep checking so saving that permission
    // takes effect without requiring a logout or reinstall. This also restores
    // the connection service if the device vendor stops it later.
    _serviceMonitor ??= Timer.periodic(const Duration(seconds: 20), (_) {
      if (_client.isLogged()) unawaited(_start());
    });
  }

  Future<void> _start() async {
    if (_starting) return;
    _starting = true;
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      final result = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: const [ForegroundServiceTypes.remoteMessaging],
        notificationTitle: 'Patrick Messenger',
        notificationText: 'Connected for message notifications',
        callback: startMessageConnectionService,
      );
      if (result is ServiceRequestFailure) {
        debugPrint(
          'Android message connection could not start: ${result.error}',
        );
      }
    } catch (error) {
      debugPrint('Android message connection could not start: $error');
    } finally {
      _starting = false;
    }
  }

  Future<void> _stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  Future<void> dispose() async {
    _serviceMonitor?.cancel();
    await _loginSubscription?.cancel();
  }
}

@pragma('vm:entry-point')
void startMessageConnectionService() {
  FlutterForegroundTask.setTaskHandler(_MessageConnectionTaskHandler());
}

class _MessageConnectionTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
