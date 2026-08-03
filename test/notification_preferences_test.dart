import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/notifications/notification_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'notification choices have safe defaults and persist per device',
    () async {
      final controller = await NotificationPreferenceController.load();
      expect(controller.enabled, isTrue);
      expect(controller.soundEnabled, isTrue);
      expect(controller.showPreviews, isFalse);
      expect(controller.notifyIfReadElsewhere, isTrue);

      await controller.update(
        enabled: true,
        soundEnabled: false,
        showPreviews: true,
        notifyIfReadElsewhere: false,
      );

      final restored = await NotificationPreferenceController.load();
      expect(restored.enabled, isTrue);
      expect(restored.soundEnabled, isFalse);
      expect(restored.showPreviews, isTrue);
      expect(restored.notifyIfReadElsewhere, isFalse);
    },
  );
}
