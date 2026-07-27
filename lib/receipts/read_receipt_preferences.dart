import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../archive/archive_contract.dart';

class ReadReceiptPreferenceController extends ChangeNotifier {
  static const _localKey = 'privacy.send_read_receipts';

  final SharedPreferences _preferences;
  bool _enabled;
  Client? _client;
  StreamSubscription<SyncUpdate>? _syncSubscription;

  ReadReceiptPreferenceController._(this._preferences, this._enabled);

  bool get enabled => _enabled;

  static Future<ReadReceiptPreferenceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    return ReadReceiptPreferenceController._(
      preferences,
      preferences.getBool(_localKey) ?? true,
    );
  }

  Future<void> connect(Client client) async {
    _client = client;
    _readAccountData();
    _syncSubscription ??= client.onSync.stream.listen(
      (_) => _readAccountData(),
    );
  }

  void _readAccountData() {
    final value =
        _client?.accountData[readReceiptsAccountDataType]?.content['enabled'];
    if (value is! bool || value == _enabled) return;
    _enabled = value;
    unawaited(_preferences.setBool(_localKey, value));
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    final old = _enabled;
    _enabled = value;
    notifyListeners();
    try {
      await _preferences.setBool(_localKey, value);
      final client = _client;
      if (client?.userID != null) {
        await client!.setAccountData(
          client.userID!,
          readReceiptsAccountDataType,
          {'version': 1, 'enabled': value},
        );
      }
    } catch (_) {
      _enabled = old;
      notifyListeners();
      rethrow;
    }
  }

  @override
  void dispose() {
    _syncSubscription?.cancel();
    super.dispose();
  }
}
