import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TextScalePreferenceController extends ChangeNotifier {
  static const _preferenceKey = 'appearance.text_scale';
  static const minimumScale = 1.0;
  static const maximumScale = 2.0;

  final SharedPreferences _preferences;
  double _scale;

  TextScalePreferenceController._(this._preferences, this._scale);

  static Future<TextScalePreferenceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getDouble(_preferenceKey) ?? 1.0;
    return TextScalePreferenceController._(
      preferences,
      saved.clamp(minimumScale, maximumScale).toDouble(),
    );
  }

  double get scale => _scale;

  void previewScale(double value) {
    final next = value.clamp(minimumScale, maximumScale).toDouble();
    if (next == _scale) return;
    _scale = next;
    notifyListeners();
  }

  Future<void> persistScale() => _preferences.setDouble(_preferenceKey, _scale);

  Future<void> setScale(double value) async {
    previewScale(value);
    await persistScale();
  }
}
