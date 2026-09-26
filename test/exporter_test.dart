import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moat/models/folder.dart';
import 'package:moat/services/exporter.dart';

import 'helpers/fakes.dart';

void main() {
  test('buildBackup/parseBackup round trip', () {
    final n = makeNote(title: 'T', body: 'B');
    final f = Folder(
        id: 'f1', name: 'Folder', createdAt: DateTime(2026), clock: {});
    final backup = buildBackup([n], [f]);
    expect(backup['app'], 'moat');
    expect(backup['version'], backupVersion);
    final parsed = parseBackup(backup);
    expect(parsed.notes.single.title, 'T');
    expect(parsed.folders.single.name, 'Folder');
  });

  test('parseBackup rejects non-moat and future versions', () {
    expect(() => parseBackup({'app': 'other'}), throwsFormatException);
    expect(
        () => parseBackup(
            {'app': 'moat', 'version': 999}),
        throwsFormatException);
    // missing or non-int version rejected too
    expect(() => parseBackup({'app': 'moat'}), throwsFormatException);
    expect(() => parseBackup({'app': 'moat', 'version': 'x'}),
        throwsFormatException);
  });

  test('exportToFile/importFile round trip through disk', () async {
    final dir = Directory.systemTemp.createTempSync('moat-exp');
    try {
      final n = makeNote(title: 'A', body: 'content');
      final file = await exportToFile(dir.path, [n], []);
      expect(file.path, contains('moat-backup'));
      expect(file.existsSync(), isTrue);
      final parsed = await importFile(file.path);
      expect(parsed.notes.single.id, n.id);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('importFile rejects malformed files', () async {
    final dir = Directory.systemTemp.createTempSync('moat-exp');
    try {
      final bad = File('${dir.path}/bad.json');
      await bad.writeAsString('[1,2,3]');
      await expectLater(importFile(bad.path), throwsFormatException);
      await bad.writeAsString('{bad');
      await expectLater(importFile(bad.path), throwsFormatException);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('exportNoteMarkdownFile writes markdown', () async {
    final dir = Directory.systemTemp.createTempSync('moat-exp');
    try {
      final n = makeNote(title: 'My Note!', body: 'hello');
      final file =
          await exportNoteMarkdownFile(dir.path, n);
      expect(file.path, endsWith('My-Note.md'));
      expect(await file.readAsString(), contains('hello'));

      final untitled = makeNote(title: '', body: 'x');
      final f2 = await exportNoteMarkdownFile(dir.path, untitled);
      expect(f2.path, contains('note-n1'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
