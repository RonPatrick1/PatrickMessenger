import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks, per Matrix room, whether Liam questions and answers should be
/// hidden from notifications and the timeline. Unlike the other preferences
/// in this app, this one is scoped to a room rather than the whole account,
/// since one conversation (e.g. a spouse's) may want Liam chatter hidden
/// while another does not.
class LiamChatterVisibilityController extends ChangeNotifier {
  static const _hiddenRoomIdsKey = 'notifications.hide_liam_chatter_room_ids';

  final SharedPreferences _preferences;
  final Set<String> _hiddenRoomIds;

  LiamChatterVisibilityController._(this._preferences, this._hiddenRoomIds);

  static Future<LiamChatterVisibilityController> load() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getStringList(_hiddenRoomIdsKey) ?? const [];
    return LiamChatterVisibilityController._(preferences, stored.toSet());
  }

  bool isHidden(String roomId) => _hiddenRoomIds.contains(roomId);

  Future<void> setHidden(String roomId, bool hidden) async {
    final changed = hidden
        ? _hiddenRoomIds.add(roomId)
        : _hiddenRoomIds.remove(roomId);
    if (!changed) return;
    notifyListeners();
    await _preferences.setStringList(_hiddenRoomIdsKey, _hiddenRoomIds.toList());
  }
}
