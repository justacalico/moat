import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moat/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load();
    expect(s.themeMode, ThemeMode.system);
    expect(s.accentColor, 0xFF0A84FF);
    expect(s.sort, NoteSort.updated);
    expect(s.gridView, isFalse);
    expect(s.density, ListDensity.comfortable);
    expect(s.autoLockSeconds, 300);
    expect(s.biometricUnlock, isFalse);
    expect(s.lockOnStart, isFalse);
    expect(s.syncEnabled, isTrue);
    expect(s.deviceName, '');
    expect(s.deviceId, '');
    expect(s.seenWelcome, isFalse);
  });

  test('setters persist', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load();
    s.themeMode = ThemeMode.dark;
    s.accentColor = 0xFF30D158;
    s.sort = NoteSort.title;
    s.gridView = true;
    s.density = ListDensity.compact;
    s.autoLockSeconds = 0;
    s.biometricUnlock = true;
    s.lockOnStart = true;
    s.syncEnabled = false;
    s.deviceName = 'my box';
    s.deviceId = 'abc';
    s.seenWelcome = true;

    final s2 = await Settings.load();
    expect(s2.themeMode, ThemeMode.dark);
    expect(s2.accentColor, 0xFF30D158);
    expect(s2.sort, NoteSort.title);
    expect(s2.gridView, isTrue);
    expect(s2.density, ListDensity.compact);
    expect(s2.autoLockSeconds, 0);
    expect(s2.biometricUnlock, isTrue);
    expect(s2.lockOnStart, isTrue);
    expect(s2.syncEnabled, isFalse);
    expect(s2.deviceName, 'my box');
    expect(s2.deviceId, 'abc');
    expect(s2.seenWelcome, isTrue);
  });

  test('clearAll wipes', () async {
    SharedPreferences.setMockInitialValues({'sort': 2});
    final s = await Settings.load();
    expect(s.sort, NoteSort.title);
    await s.clearAll();
    expect(s.sort, NoteSort.updated);
  });
}
