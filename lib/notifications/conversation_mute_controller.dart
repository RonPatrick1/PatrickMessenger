import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the standard Matrix per-room mute rule available immediately to the
/// UI and local notification path. The server rule is account-wide, while the
/// preference is only a startup cache until the next sync refreshes it.
class ConversationMuteController extends ChangeNotifier {
  static const preferenceKey = 'notifications.muted_room_ids';

  final SharedPreferences _preferences;
  final Set<String> _mutedRoomIds;
  final Map<String, bool> _pendingMutedStates = <String, bool>{};
  Client? _client;
  StreamSubscription<SyncUpdate>? _syncSubscription;

  ConversationMuteController._(this._preferences, this._mutedRoomIds);

  static Future<ConversationMuteController> load() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getStringList(preferenceKey) ?? const [];
    return ConversationMuteController._(preferences, stored.toSet());
  }

  bool isMuted(String roomId) => _mutedRoomIds.contains(roomId);

  Future<void> connect(Client client) async {
    _client = client;
    _syncSubscription ??= client.onSync.stream.listen((_) {
      _refreshFromMatrixPushRules();
    });
    _refreshFromMatrixPushRules();
  }

  Future<void> setMuted(Room room, bool muted) async {
    await _setServerMuteRule(room, muted);
    _pendingMutedStates[room.id] = muted;
    if (muted) {
      _mutedRoomIds.add(room.id);
    } else {
      _mutedRoomIds.remove(room.id);
    }
    await _persist();
    notifyListeners();
  }

  void removeRoom(String roomId) {
    _pendingMutedStates.remove(roomId);
    if (!_mutedRoomIds.remove(roomId)) return;
    unawaited(_persist());
    notifyListeners();
  }

  void _refreshFromMatrixPushRules() {
    final client = _client;
    if (client?.globalPushRules == null) return;
    final updated = <String>{..._mutedRoomIds};
    for (final room in client!.rooms) {
      final serverMuted = room.pushRuleState == PushRuleState.dontNotify;
      final pending = _pendingMutedStates[room.id];
      if (pending == serverMuted) {
        _pendingMutedStates.remove(room.id);
      }
      final muted = pending ?? serverMuted;
      if (muted) {
        updated.add(room.id);
      } else {
        updated.remove(room.id);
      }
    }
    if (setEquals(updated, _mutedRoomIds)) return;
    _mutedRoomIds
      ..clear()
      ..addAll(updated);
    unawaited(_persist());
    notifyListeners();
  }

  Future<void> _setServerMuteRule(Room room, bool muted) async {
    final client = _client ?? room.client;
    if (muted) {
      if (room.pushRuleState == PushRuleState.mentionsOnly) {
        await _deleteRuleIfPresent(client, PushRuleKind.room, room.id);
      }
      await client.setPushRule(
        PushRuleKind.override,
        room.id,
        const [],
        conditions: [
          PushCondition(
            kind: PushRuleConditions.eventMatch.name,
            key: 'room_id',
            pattern: room.id,
          ),
        ],
      );
      return;
    }
    await _deleteRuleIfPresent(client, PushRuleKind.override, room.id);
  }

  Future<void> _deleteRuleIfPresent(
    Client client,
    PushRuleKind kind,
    String roomId,
  ) async {
    try {
      await client.deletePushRule(kind, roomId);
    } on MatrixException catch (error) {
      if (error.errcode != 'M_NOT_FOUND') rethrow;
    }
  }

  Future<void> _persist() =>
      _preferences.setStringList(preferenceKey, _mutedRoomIds.toList()..sort());

  @override
  void dispose() {
    _syncSubscription?.cancel();
    super.dispose();
  }
}
