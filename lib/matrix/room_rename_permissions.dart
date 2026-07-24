import 'dart:async';

import 'package:matrix/matrix.dart';

Map<String, Object?> withMemberRenamePermission(
  Map<String, Object?> currentPowerLevels,
) {
  final updated = Map<String, Object?>.from(currentPowerLevels);
  final currentEvents = currentPowerLevels['events'];
  final events = currentEvents is Map
      ? Map<String, Object?>.from(currentEvents)
      : <String, Object?>{};
  events[EventTypes.RoomName] = 0;
  updated['events'] = events;
  return updated;
}

bool membersCanRename(Room room) {
  return room.powerForChangingStateEvent(EventTypes.RoomName).level == 0;
}

class RoomRenamePermissionUpgrader {
  static final Map<Client, Set<String>> _attemptedRooms = {};
  static final Map<Client, Future<void>> _activeUpgrades = {};

  static void schedule(Client client) {
    if (_activeUpgrades.containsKey(client)) return;
    final upgrade = _upgrade(client);
    _activeUpgrades[client] = upgrade;
    unawaited(
      upgrade.whenComplete(() {
        if (identical(_activeUpgrades[client], upgrade)) {
          _activeUpgrades.remove(client);
        }
      }),
    );
  }

  static Future<void> _upgrade(Client client) async {
    final attempted = _attemptedRooms.putIfAbsent(client, () => <String>{});
    final rooms = client.rooms
        .where(
          (room) =>
              room.membership == Membership.join &&
              room.encrypted &&
              !attempted.contains(room.id),
        )
        .toList();

    for (final room in rooms) {
      attempted.add(room.id);
      try {
        await room.postLoad();
        if (membersCanRename(room)) continue;
        if (!room.canChangeStateEvent(EventTypes.RoomPowerLevels)) continue;

        final current =
            room.getState(EventTypes.RoomPowerLevels)?.content ??
            const <String, Object?>{};
        await client.setRoomStateWithKey(
          room.id,
          EventTypes.RoomPowerLevels,
          '',
          withMemberRenamePermission(current),
        );
      } catch (_) {
        // Reopening the app provides another upgrade attempt. Users without
        // creator/admin permission simply leave the room policy unchanged.
      }
    }
  }
}
