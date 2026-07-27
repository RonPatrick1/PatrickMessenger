import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../archive/archive_contract.dart';

/// Tracks, per Matrix room, whether Liam questions and answers should be
/// hidden from notifications and the timeline. Unlike the other preferences
/// in this app, this one is scoped to a room rather than the whole account,
/// since one conversation (e.g. a spouse's) may want Liam chatter hidden
/// while another does not.
class LiamChatterVisibilityController extends ChangeNotifier {
  static const _hiddenRoomIdsKey = 'notifications.hide_liam_chatter_room_ids';
  static const accountDataType =
      'com.patricklamphier.patrick_messenger.liam_visibility';

  final SharedPreferences _preferences;
  final Set<String> _hiddenRoomIds;
  Client? _client;
  String? _liamUserId;
  StreamSubscription<SyncUpdate>? _syncSubscription;

  LiamChatterVisibilityController._(this._preferences, this._hiddenRoomIds);

  static Future<LiamChatterVisibilityController> load() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getStringList(_hiddenRoomIdsKey) ?? const [];
    return LiamChatterVisibilityController._(preferences, stored.toSet());
  }

  bool isHidden(String roomId) => _hiddenRoomIds.contains(roomId);

  Future<void> connect(Client client, String liamUserId) async {
    _client = client;
    _liamUserId = liamUserId;
    _syncSubscription ??= client.onSync.stream.listen((_) {
      _readAccountData();
    });
    _readAccountData();
    for (final roomId in _hiddenRoomIds) {
      try {
        await _setPushRules(roomId, true);
      } catch (_) {
        // The saved local/account-data choice still hides Liam in the app.
        // The next explicit change or online launch retries the push rule.
      }
    }
  }

  void _readAccountData() {
    final content = _client?.accountData[accountDataType]?.content;
    final values = content?['hidden_room_ids'];
    if (values is! List) return;
    final updated = values.whereType<String>().toSet();
    if (setEquals(updated, _hiddenRoomIds)) return;
    _hiddenRoomIds
      ..clear()
      ..addAll(updated);
    unawaited(
      _preferences.setStringList(_hiddenRoomIdsKey, _hiddenRoomIds.toList()),
    );
    notifyListeners();
  }

  Future<void> setHidden(String roomId, bool hidden) async {
    if (hidden == _hiddenRoomIds.contains(roomId)) return;
    await _setPushRules(roomId, hidden);
    if (hidden) {
      _hiddenRoomIds.add(roomId);
    } else {
      _hiddenRoomIds.remove(roomId);
    }
    final client = _client;
    try {
      if (client != null && client.userID != null) {
        await client.setAccountData(client.userID!, accountDataType, {
          'version': 1,
          'hidden_room_ids': _hiddenRoomIds.toList()..sort(),
        });
      }
      await _preferences.setStringList(
        _hiddenRoomIdsKey,
        _hiddenRoomIds.toList(),
      );
      notifyListeners();
    } catch (_) {
      if (hidden) {
        _hiddenRoomIds.remove(roomId);
      } else {
        _hiddenRoomIds.add(roomId);
      }
      await _setPushRules(roomId, !hidden);
      rethrow;
    }
  }

  Future<void> _setPushRules(String roomId, bool hidden) async {
    final client = _client;
    final liamUserId = _liamUserId;
    if (client == null || !client.isLogged() || liamUserId == null) return;
    final suffix = sha256
        .convert(utf8.encode(roomId))
        .toString()
        .substring(0, 20);
    final senderRule = '$accountDataType.sender.$suffix';
    final chatterRule = '$accountDataType.chatter.$suffix';
    if (!hidden) {
      for (final rule in [senderRule, chatterRule]) {
        try {
          await client.deletePushRule(PushRuleKind.override, rule);
        } on MatrixException catch (error) {
          if (error.errcode != 'M_NOT_FOUND') rethrow;
        }
      }
      return;
    }
    await client.setPushRule(
      PushRuleKind.override,
      senderRule,
      const [],
      conditions: [
        PushCondition(
          kind: PushRuleConditions.eventMatch.name,
          key: 'room_id',
          pattern: roomId,
        ),
        PushCondition(
          kind: PushRuleConditions.eventMatch.name,
          key: 'sender',
          pattern: liamUserId,
        ),
      ],
    );
    await client.setPushRule(
      PushRuleKind.override,
      chatterRule,
      const [],
      conditions: [
        PushCondition(
          kind: PushRuleConditions.eventMatch.name,
          key: 'room_id',
          pattern: roomId,
        ),
        PushCondition(
          kind: PushRuleConditions.eventMatch.name,
          key: r'content.m\.relates_to.rel_type',
          pattern: liamChatterRelationType,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _syncSubscription?.cancel();
    super.dispose();
  }
}
