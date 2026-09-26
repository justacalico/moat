import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'storage.dart';

Storage createPlatformStorage() => FileStorage();

/// File-backed [Storage]. All app data lives under
/// `<documents>/moat/` as plain JSON files — notes as one file each, plus
/// `folders.json`, `vault.json`, `peers.json`.
class FileStorage implements Storage {
  FileStorage({this.rootPath});

  /// Overridable root — tests pass a temp dir, production resolves lazily.
  final String? rootPath;
  Directory? _root;

  Future<Directory> _rootDir() async {
    if (_root != null) return _root!;
    if (rootPath != null) {
      _root = Directory(rootPath!);
    } else {
      // Platform channel, unreachable in VM tests.
      // coverage:ignore-start
      final docs = await getApplicationDocumentsDirectory();
      _root = Directory('${docs.path}/moat');
      // coverage:ignore-end
    }
    await _root!.create(recursive: true);
    return _root!;
  }

  Future<File> _file(String path) async =>
      File('${(await _rootDir()).path}/$path');

  @override
  Future<Map<String, dynamic>?> readJson(String path) async {
    final file = await _file(path);
    if (!await file.exists()) return null;
    try {
      return (jsonDecode(await file.readAsString()) as Map)
          .cast<String, dynamic>();
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeJson(String path, Map<String, dynamic> data) async {
    final file = await _file(path);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(data));
    await tmp.rename(file.path);
  }

  @override
  Future<void> delete(String path) async {
    final file = await _file(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<List<String>> list(String dir) async {
    final d = Directory('${(await _rootDir()).path}/$dir');
    if (!await d.exists()) return [];
    return d
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .map((e) => e.uri.pathSegments.last)
        .toList();
  }

  @override
  Future<String> exportDirectory() async {
    if (rootPath != null) {
      final dir = Directory('${rootPath!}/exports');
      await dir.create(recursive: true);
      return dir.path;
    }
    // Platform channel, unreachable in VM tests.
    // coverage:ignore-start
    final dir = await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final out = Directory('${dir.path}/moat-exports');
    await out.create(recursive: true);
    return out.path;
    // coverage:ignore-end
  }
}
