// coverage:ignore-file — web-only storage, never imported by VM tests
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'storage.dart';

Storage createPlatformStorage() => WebStorage();

/// localStorage-backed [Storage] for the web build. Same JSON contract as
/// [FileStorage]; keys are prefixed so Moat can coexist with anything else on
/// the same origin.
class WebStorage implements Storage {
  static const _prefix = 'moat/';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<Map<String, dynamic>?> readJson(String path) async {
    final raw = (await _prefs).getString('$_prefix$path');
    if (raw == null) return null;
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  @override
  Future<void> writeJson(String path, Map<String, dynamic> data) async {
    await (await _prefs).setString('$_prefix$path', jsonEncode(data));
  }

  @override
  Future<void> delete(String path) async {
    await (await _prefs).remove('$_prefix$path');
  }

  @override
  Future<List<String>> list(String dir) async {
    final prefix = '$_prefix${dir.endsWith('/') ? dir : '$dir/'}';
    return (await _prefs)
        .getKeys()
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .where((k) => !k.contains('/'))
        .toList();
  }

  @override
  Future<String> exportDirectory() async => 'browser-downloads';
}
