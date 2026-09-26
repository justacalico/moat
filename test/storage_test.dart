import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moat/services/file_storage.dart';
import 'package:moat/services/memory_storage.dart';

void main() {
  group('MemoryStorage', () {
    test('write/read/delete/list round trip', () async {
      final s = MemoryStorage();
      expect(await s.readJson('x.json'), isNull);
      await s.writeJson('notes/a.json', {'v': 1});
      await s.writeJson('notes/b.json', {'v': 2});
      await s.writeJson('notes/sub/c.json', {'v': 3});
      await s.writeJson('other.json', {'v': 4});
      expect((await s.readJson('notes/a.json'))!['v'], 1);
      final list = await s.list('notes');
      expect(list, containsAll(['a.json', 'b.json']));
      expect(list, isNot(contains('sub')));
      await s.delete('notes/a.json');
      expect(await s.readJson('notes/a.json'), isNull);
      // list with trailing slash form
      expect(await s.list('notes/'), contains('b.json'));
      expect(await s.exportDirectory(), '/exports');
    });

    test('stored copies are isolated from caller mutation', () async {
      final s = MemoryStorage();
      final data = {'nested': <String, int>{'k': 1}};
      await s.writeJson('a.json', data);
      (data['nested'] as Map)['k'] = 99;
      expect((await s.readJson('a.json'))!['nested']['k'], 1);
    });
  });

  group('FileStorage', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('moat-test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('json files persist under the root', () async {
      final s = FileStorage(rootPath: dir.path);
      await s.writeJson('notes/n1.json', {'hello': 'world'});
      expect(File('${dir.path}/notes/n1.json').existsSync(), isTrue);
      expect((await s.readJson('notes/n1.json'))!['hello'], 'world');
      expect(await s.readJson('missing.json'), isNull);
      expect(await s.list('notes'), ['n1.json']);
      expect(await s.list('nope'), isEmpty);
      await s.delete('notes/n1.json');
      expect(await s.list('notes'), isEmpty);
      await s.delete('notes/n1.json'); // idempotent
    });

    test('readJson tolerates corrupt files', () async {
      final s = FileStorage(rootPath: dir.path);
      File('${dir.path}/bad.json').writeAsStringSync('{not json');
      expect(await s.readJson('bad.json'), isNull);
    });

    test('exportDirectory lives under root when overridden', () async {
      final s = FileStorage(rootPath: dir.path);
      final path = await s.exportDirectory();
      expect(path, '${dir.path}/exports');
      expect(Directory(path).existsSync(), isTrue);
    });
  });
}
