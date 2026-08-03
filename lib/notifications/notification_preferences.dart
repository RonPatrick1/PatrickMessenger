import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationPreferenceController extends ChangeNotifier {
  static const enabledPreferenceKey = 'notifications.enabled';
  static const soundPreferenceKey = 'notifications.sound';
  static const previewPreferenceKey = 'notifications.show_previews';
  static const notifyIfReadElsewherePreferenceKey =
      'notifications.notify_if_read_elsewhere';

  final SharedPreferences _preferences;
  bool _enabled;
  bool _soundEnabled;
  bool _showPreviews;
  bool _notifyIfReadElsewhere;

  NotificationPreferenceController._(
    this._preferences, {
    required this._enabled,
    required this._soundEnabled,
    required this._showPreviews,
    required this._notifyIfReadElsewhere,
  });

  static Future<NotificationPreferenceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    return NotificationPreferenceController._(
      preferences,
      enabled: preferences.getBool(enabledPreferenceKey) ?? true,
      soundEnabled: preferences.getBool(soundPreferenceKey) ?? true,
      showPreviews: preferences.getBool(previewPreferenceKey) ?? false,
      notifyIfReadElsewhere:
          preferences.getBool(notifyIfReadElsewherePreferenceKey) ?? true,
    );
  }

  bool get enabled => _enabled;

  bool get soundEnabled => _soundEnabled;

  bool get showPreviews => _showPreviews;

  bool get notifyIfReadElsewhere => _notifyIfReadElsewhere;

  Future<void> update({
    required bool enabled,
    required bool soundEnabled,
    required bool showPreviews,
    required bool notifyIfReadElsewhere,
  }) async {
    final changed =
        _enabled != enabled ||
        _soundEnabled != soundEnabled ||
        _showPreviews != showPreviews ||
        _notifyIfReadElsewhere != notifyIfReadElsewhere;
    _enabled = enabled;
    _soundEnabled = soundEnabled;
    _showPreviews = showPreviews;
    _notifyIfReadElsewhere = notifyIfReadElsewhere;
    if (changed) notifyListeners();
    await Future.wait([
      _preferences.setBool(enabledPreferenceKey, enabled),
      _preferences.setBool(soundPreferenceKey, soundEnabled),
      _preferences.setBool(previewPreferenceKey, showPreviews),
      _preferences.setBool(
        notifyIfReadElsewherePreferenceKey,
        notifyIfReadElsewhere,
      ),
    ]);
  }
}
