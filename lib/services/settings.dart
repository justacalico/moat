import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum NoteSort { updated, created, title }

enum ListDensity { comfortable, compact }

/// User preferences, persisted through SharedPreferences.
class Settings {
  Settings(this._prefs);

  final SharedPreferences _prefs;

  static Future<Settings> load() async =>
      Settings(await SharedPreferences.getInstance());

  ThemeMode get themeMode =>
      ThemeMode.values[_prefs.getInt('themeMode') ?? 0];
  set themeMode(ThemeMode v) => _prefs.setInt('themeMode', v.index);

  int get accentColor => _prefs.getInt('accentColor') ?? 0xFF0A84FF;
  set accentColor(int v) => _prefs.setInt('accentColor', v);

  NoteSort get sort => NoteSort.values[_prefs.getInt('sort') ?? 0];
  set sort(NoteSort v) => _prefs.setInt('sort', v.index);

  bool get gridView => _prefs.getBool('gridView') ?? false;
  set gridView(bool v) => _prefs.setBool('gridView', v);

  ListDensity get density =>
      ListDensity.values[_prefs.getInt('density') ?? 0];
  set density(ListDensity v) => _prefs.setInt('density', v.index);

  /// Seconds of inactivity before an unlocked vault re-locks. 0 = never.
  int get autoLockSeconds => _prefs.getInt('autoLockSeconds') ?? 300;
  set autoLockSeconds(int v) => _prefs.setInt('autoLockSeconds', v);

  bool get biometricUnlock => _prefs.getBool('biometricUnlock') ?? false;
  set biometricUnlock(bool v) => _prefs.setBool('biometricUnlock', v);

  bool get lockOnStart => _prefs.getBool('lockOnStart') ?? false;
  set lockOnStart(bool v) => _prefs.setBool('lockOnStart', v);

  bool get syncEnabled => _prefs.getBool('syncEnabled') ?? true;
  set syncEnabled(bool v) => _prefs.setBool('syncEnabled', v);

  String get deviceName => _prefs.getString('deviceName') ?? '';
  set deviceName(String v) => _prefs.setString('deviceName', v);

  String get deviceId => _prefs.getString('deviceId') ?? '';
  set deviceId(String v) => _prefs.setString('deviceId', v);

  bool get seenWelcome => _prefs.getBool('seenWelcome') ?? false;
  set seenWelcome(bool v) => _prefs.setBool('seenWelcome', v);

  /// Vault-locked app start: require passphrase before showing any notes.
  Future<void> clearAll() => _prefs.clear();
}
