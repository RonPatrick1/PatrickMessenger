import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:patrick_messenger/notifications/message_notification_service.dart';

void main() {
  const ownUser = '@ron:matrix.example';

  bool shouldNotify({
    bool ready = true,
    String type = EventTypes.Message,
    String? relationshipType,
    String sender = '@elizabeth:matrix.example',
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

  test('does not notify for startup history, edits, or reactions', () {
    expect(shouldNotify(ready: false), isFalse);
    expect(shouldNotify(relationshipType: RelationshipTypes.edit), isFalse);
    expect(shouldNotify(type: EventTypes.Reaction), isFalse);
  });

  test('notifies for stickers and undecryptable encrypted messages', () {
    expect(shouldNotify(type: EventTypes.Sticker), isTrue);
    expect(shouldNotify(type: EventTypes.Encrypted), isTrue);
  });
}
