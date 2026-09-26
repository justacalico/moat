import 'dart:convert';
import 'dart:io';

import '../models/folder.dart';
import '../models/note.dart';

/// Backup format version written into every export file.
const backupVersion = 1;

/// Pure-logic backup build/parse. File IO lives in [exportToFile]/[importFile]
/// which take explicit paths so tests control the filesystem.
Map<String, dynamic> buildBackup(
    List<Note> notes, List<Folder> folders) => {
      'app': 'moat',
      'version': backupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'folders': folders.map((f) => f.toJson()).toList(),
      'notes': notes.map((n) => n.toJson()).toList(),
    };

/// Parses a backup payload. Throws [FormatException] on anything malformed.
({List<Note> notes, List<Folder> folders}) parseBackup(
    Map<String, dynamic> json) {
  if (json['app'] != 'moat') {
    throw const FormatException('not a Moat backup');
  }
  final version = json['version'];
  if (version is! int || version > backupVersion) {
    throw const FormatException('unsupported backup version');
  }
  final notes = (json['notes'] as List? ?? [])
      .map((n) => Note.fromJson((n as Map).cast<String, dynamic>()))
      .toList();
  final folders = (json['folders'] as List? ?? [])
      .map((f) => Folder.fromJson((f as Map).cast<String, dynamic>()))
      .toList();
  return (notes: notes, folders: folders);
}

Future<File> exportToFile(
    String dir, List<Note> notes, List<Folder> folders) async {
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.')
      .first;
  final file = File('$dir/moat-backup-$stamp.json');
  await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(buildBackup(notes, folders)));
  return file;
}

Future<({List<Note> notes, List<Folder> folders})> importFile(
    String path) async {
  final raw = await File(path).readAsString();
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw const FormatException('invalid backup file');
  return parseBackup(decoded.cast<String, dynamic>());
}

/// Single-note markdown export.
Future<File> exportNoteMarkdownFile(String dir, Note note,
    {String? title, String? body}) async {
  final safeTitle = (title ?? note.title)
      .replaceAll(RegExp(r'[^\w\- ]'), '')
      .trim()
      .replaceAll(' ', '-');
  final name = safeTitle.isEmpty ? 'note-${note.id.substring(0, 8)}' : safeTitle;
  final file = File('$dir/$name.md');
  final buffer = StringBuffer()
    ..writeln('# ${title ?? note.title}')
    ..writeln()
    ..writeln(body ?? note.body);
  await file.writeAsString(buffer.toString());
  return file;
}
