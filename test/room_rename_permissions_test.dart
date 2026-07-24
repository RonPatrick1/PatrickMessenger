import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:patrick_messenger/matrix/room_rename_permissions.dart';

void main() {
  test(
    'grants room-name permission without granting other moderator powers',
    () {
      final original = <String, Object?>{
        'ban': 50,
        'kick': 50,
        'redact': 50,
        'state_default': 50,
        'events': <String, Object?>{
          EventTypes.RoomPowerLevels: 100,
          EventTypes.RoomName: 50,
        },
      };

      final updated = withMemberRenamePermission(original);
      final events = updated['events']! as Map<String, Object?>;

      expect(events[EventTypes.RoomName], 0);
      expect(events[EventTypes.RoomPowerLevels], 100);
      expect(updated['ban'], 50);
      expect(updated['kick'], 50);
      expect(updated['redact'], 50);
      expect(updated['state_default'], 50);

      final originalEvents = original['events']! as Map<String, Object?>;
      expect(originalEvents[EventTypes.RoomName], 50);
    },
  );
}
