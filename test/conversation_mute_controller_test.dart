import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/notifications/conversation_mute_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restores the cached muted conversations at startup', () async {
    SharedPreferences.setMockInitialValues({
      ConversationMuteController.preferenceKey: <String>['!muted:example.com'],
    });

    final controller = await ConversationMuteController.load();

    expect(controller.isMuted('!muted:example.com'), isTrue);
    expect(controller.isMuted('!normal:example.com'), isFalse);
  });
}
