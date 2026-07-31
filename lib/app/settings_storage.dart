import 'package:shared_preferences/shared_preferences.dart';

class SettingsStorage {
  SettingsStorage._();

  static const String _keyHeadphonePriority = 'tribe_headphone_priority';
  static const String _keyBedtimeDnd = 'tribe_bedtime_dnd';
  static const String _keyIntercomVolume = 'tribe_intercom_volume';

  static Future<bool> getHeadphonePriority() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyHeadphonePriority) ?? false;
  }

  static Future<void> setHeadphonePriority(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHeadphonePriority, value);
  }

  static Future<bool> getBedtimeDnd() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBedtimeDnd) ?? false;
  }

  static Future<void> setBedtimeDnd(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBedtimeDnd, value);
  }

  static Future<double> getIntercomVolume() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyIntercomVolume) ?? 1.0;
  }

  static Future<void> setIntercomVolume(double value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyIntercomVolume, value.clamp(0.0, 1.0));
  }

  static Future<void> clearAll() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyHeadphonePriority);
    await prefs.remove(_keyBedtimeDnd);
    await prefs.remove(_keyIntercomVolume);
  }
}
