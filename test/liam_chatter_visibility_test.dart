import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/notifications/liam_chatter_visibility.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults to visible in every room', () async {
    final controller = await LiamChatterVisibilityController.load();
    expect(controller.isHidden('!a:example.com'), isFalse);
    expect(controller.isHidden('!b:example.com'), isFalse);
  });

  test('hiding one room does not affect another, and persists', () async {
    final controller = await LiamChatterVisibilityController.load();

    await controller.setHidden('!a:example.com', true);
    expect(controller.isHidden('!a:example.com'), isTrue);
    expect(controller.isHidden('!b:example.com'), isFalse);

    final restored = await LiamChatterVisibilityController.load();
    expect(restored.isHidden('!a:example.com'), isTrue);
    expect(restored.isHidden('!b:example.com'), isFalse);
  });

  test('unhiding a room removes it from the stored set', () async {
    final controller = await LiamChatterVisibilityController.load();
    await controller.setHidden('!a:example.com', true);
    await controller.setHidden('!a:example.com', false);

    final restored = await LiamChatterVisibilityController.load();
    expect(restored.isHidden('!a:example.com'), isFalse);
  });

  test('notifies listeners only when the state actually changes', () async {
    final controller = await LiamChatterVisibilityController.load();
    var notifications = 0;
    controller.addListener(() => notifications++);

    await controller.setHidden('!a:example.com', true);
    expect(notifications, 1);

    // Setting the same value again should not notify again.
    await controller.setHidden('!a:example.com', true);
    expect(notifications, 1);
  });
}
