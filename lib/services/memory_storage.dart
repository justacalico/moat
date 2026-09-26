import 'dart:convert';

import 'storage.dart';

/// In-memory [Storage] used by tests and by the web build's JSON round-trip
/// semantics (deep-copies everything through jsonEncode so callers can't
/// mutate stored state behind the store's back).
class MemoryStorage implements Storage {
  final Map<String, String> _files = {};
  String exportDir = '/exports';

  @override
  Future<Map<String, dynamic>?> readJson(String path) async {
    final raw = _files[path];
    if (raw == null) return null;
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  @override
  Future<void> writeJson(String path, Map<String, dynamic> data) async {
    _files[path] = jsonEncode(data);
  }

  @override
  Future<void> delete(String path) async {
    _files.remove(path);
  }

  @override
  Future<List<String>> list(String dir) async {
    final prefix = dir.endsWith('/') ? dir : '$dir/';
    return _files.keys
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .where((k) => !k.contains('/'))
        .toList();
  }

  @override
  Future<String> exportDirectory() async => exportDir;
}
