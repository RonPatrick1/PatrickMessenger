import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:share_receiver/share_receiver.dart';

class IncomingShareController extends ChangeNotifier {
  static const _iosAppGroup = 'group.com.patricklamphier.patrickMessenger';

  final Queue<SharedData> _pending = Queue<SharedData>();
  StreamSubscription<SharedData>? _subscription;
  String? _lastFingerprint;
  DateTime? _lastReceivedAt;

  SharedData? get current => _pending.isEmpty ? null : _pending.first;

  Future<void> initialize() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      await ShareReceiver.instance.initialize(
        appGroupId: Platform.isIOS ? _iosAppGroup : null,
      );
      _subscription = ShareReceiver.instance.getMediaStream().listen(_receive);
      final initial = await ShareReceiver.instance.getInitialSharing();
      if (initial != null) _receive(initial);
    } catch (_) {
      // Sharing is optional. Normal app startup must continue if a platform
      // does not provide the native share receiver.
    }
  }

  void consumeCurrent() {
    if (_pending.isEmpty) return;
    _pending.removeFirst();
    notifyListeners();
  }

  void _receive(SharedData data) {
    if (!data.hasContent) return;
    final fingerprint =
        '${data.text}\u0000${data.mimeType}\u0000'
        '${data.filePaths.join('\u0000')}';
    final now = DateTime.now();
    if (fingerprint == _lastFingerprint &&
        _lastReceivedAt != null &&
        now.difference(_lastReceivedAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastFingerprint = fingerprint;
    _lastReceivedAt = now;
    _pending.add(data);
    unawaited(ShareReceiver.instance.clear());
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    ShareReceiver.instance.dispose();
    super.dispose();
  }
}
