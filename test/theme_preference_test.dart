import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/settings/theme_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults to the system theme and persists a selection', () async {
    final controller = await ThemePreferenceController.load();
    expect(controller.preference, AppThemePreference.system);
    expect(controller.themeMode, ThemeMode.system);

    await controller.setPreference(AppThemePreference.dark);

    final restoredController = await ThemePreferenceController.load();
    expect(restoredController.preference, AppThemePreference.dark);
    expect(restoredController.themeMode, ThemeMode.dark);
  });
}
