import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:patrick_messenger/archive/archive_contract.dart';
import 'package:patrick_messenger/notifications/message_notification_service.dart';

void main() {
  const ownUser = '@alice:matrix.example';

  bool shouldNotify({
    bool ready = true,
    String type = EventTypes.Message,
    String? relationshipType,
    String sender = '@bob:matrix.example',
    String? transactionId,
  }) {
    return shouldNotifyForTimelineEvent(
      timelineReady: ready,
      eventType: type,
      relationshipType: relationshipType,
      senderId: sender,
      ownUserId: ownUser,
      transactionId: transactionId,
    );
  }

  test('notifies for a live message from another account', () {
    expect(shouldNotify(), isTrue);
  });

  test('notifies for the same account from another device', () {
    expect(shouldNotify(sender: ownUser), isTrue);
  });

  test('does not notify the exact device that sent the message', () {
    expect(
      shouldNotify(sender: ownUser, transactionId: 'local-transaction'),
      isFalse,
    );
  });

  test(
    'does not notify for startup history, edits, controls, or reactions',
    () {
      expect(shouldNotify(ready: false), isFalse);
      expect(shouldNotify(relationshipType: RelationshipTypes.edit), isFalse);
      expect(shouldNotify(relationshipType: controlRelationType), isFalse);
      expect(shouldNotify(type: EventTypes.Reaction), isFalse);
    },
  );

  test(
    'waits for decryption before notifying and still notifies for stickers',
    () {
      expect(shouldNotify(type: EventTypes.Sticker), isTrue);
      expect(shouldNotify(type: EventTypes.Encrypted), isFalse);
    },
  );
}
