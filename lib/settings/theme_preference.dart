import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemePreference {
  system,
  light,
  dark;

  ThemeMode get themeMode => switch (this) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };

  String get label => switch (this) {
    AppThemePreference.system => 'System',
    AppThemePreference.light => 'Light',
    AppThemePreference.dark => 'Dark',
  };

  IconData get icon => switch (this) {
    AppThemePreference.system => Icons.brightness_auto_outlined,
    AppThemePreference.light => Icons.light_mode_outlined,
    AppThemePreference.dark => Icons.dark_mode_outlined,
  };
}

class ThemePreferenceController extends ChangeNotifier {
  static const preferenceKey = 'appearance.theme';

  final SharedPreferences _preferences;
  AppThemePreference _preference;

  ThemePreferenceController._(this._preferences, this._preference);

  static Future<ThemePreferenceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(preferenceKey);
    final preference = AppThemePreference.values.firstWhere(
      (candidate) => candidate.name == saved,
      orElse: () => AppThemePreference.system,
    );
    return ThemePreferenceController._(preferences, preference);
  }

  AppThemePreference get preference => _preference;

  ThemeMode get themeMode => _preference.themeMode;

  Future<void> setPreference(AppThemePreference preference) async {
    if (_preference == preference) return;
    _preference = preference;
    notifyListeners();
    await _preferences.setString(preferenceKey, preference.name);
  }
}

class ThemePreferenceMenuButton extends StatelessWidget {
  final ThemePreferenceController controller;

  const ThemePreferenceMenuButton({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => PopupMenuButton<AppThemePreference>(
        initialValue: controller.preference,
        tooltip: 'Appearance: ${controller.preference.label}',
        icon: Icon(controller.preference.icon),
        onSelected: controller.setPreference,
        itemBuilder: (context) => [
          for (final preference in AppThemePreference.values)
            CheckedPopupMenuItem(
              value: preference,
              checked: controller.preference == preference,
              child: ListTile(
                leading: Icon(preference.icon),
                title: Text(preference.label),
                contentPadding: EdgeInsets.zero,
              ),
            ),
        ],
      ),
    );
  }
}
