import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationPreferenceController extends ChangeNotifier {
  static const enabledPreferenceKey = 'notifications.enabled';
  static const soundPreferenceKey = 'notifications.sound';
  static const previewPreferenceKey = 'notifications.show_previews';

  final SharedPreferences _preferences;
  bool _enabled;
  bool _soundEnabled;
  bool _showPreviews;

  NotificationPreferenceController._(
    this._preferences, {
    required this._enabled,
    required this._soundEnabled,
    required this._showPreviews,
  });

  static Future<NotificationPreferenceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    return NotificationPreferenceController._(
      preferences,
      enabled: preferences.getBool(enabledPreferenceKey) ?? true,
      soundEnabled: preferences.getBool(soundPreferenceKey) ?? true,
      showPreviews: preferences.getBool(previewPreferenceKey) ?? false,
    );
  }

  bool get enabled => _enabled;

  bool get soundEnabled => _soundEnabled;

  bool get showPreviews => _showPreviews;

  Future<void> update({
    required bool enabled,
    required bool soundEnabled,
    required bool showPreviews,
  }) async {
    final changed =
        _enabled != enabled ||
        _soundEnabled != soundEnabled ||
        _showPreviews != showPreviews;
    _enabled = enabled;
    _soundEnabled = soundEnabled;
    _showPreviews = showPreviews;
    if (changed) notifyListeners();
    await Future.wait([
      _preferences.setBool(enabledPreferenceKey, enabled),
      _preferences.setBool(soundPreferenceKey, soundEnabled),
      _preferences.setBool(previewPreferenceKey, showPreviews),
    ]);
  }
}
