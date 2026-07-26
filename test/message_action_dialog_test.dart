import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:patrick_messenger/screens/chat/message_action_dialog.dart';

void main() {
  test('own text messages expose edit and delete-for-everyone', () {
    final actions = availableMessageActions(
      mine: true,
      isText: true,
      canRedact: true,
      status: EventStatus.synced,
    );

    expect(actions, contains(MessageAction.edit));
    expect(actions, contains(MessageAction.delete));
    expect(actions, contains(MessageAction.reply));
    expect(actions, contains(MessageAction.forward));
  });

  test('another person message cannot be edited or deleted without power', () {
    final actions = availableMessageActions(
      mine: false,
      isText: true,
      canRedact: false,
      status: EventStatus.synced,
    );

    expect(actions, isNot(contains(MessageAction.edit)));
    expect(actions, isNot(contains(MessageAction.delete)));
    expect(actions, contains(MessageAction.copy));
  });
}
