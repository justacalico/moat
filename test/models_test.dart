import 'package:flutter_test/flutter_test.dart';
import 'package:moat/models/clock.dart';
import 'package:moat/models/folder.dart';
import 'package:moat/models/note.dart';
import 'package:moat/models/peer.dart';

void main() {
  group('Clock', () {
    test('tick increments device counter', () {
      final c = Clock.tick({}, 'a');
      expect(c['a'], 1);
      expect(Clock.tick(c, 'a')['a'], 2);
      expect(Clock.tick(c, 'b')['b'], 1);
    });

    test('compare orders clocks', () {
      expect(Clock.compare({}, {}), ClockOrder.equal);
      expect(Clock.compare({'a': 1}, {'a': 1}), ClockOrder.equal);
      expect(Clock.compare({'a': 2}, {'a': 1}), ClockOrder.dominant);
      expect(Clock.compare({'a': 1}, {'a': 2}), ClockOrder.dominated);
      expect(Clock.compare({'a': 1}, {'b': 1}), ClockOrder.concurrent);
      expect(
          Clock.compare({'a': 2, 'b': 1}, {'a': 1, 'b': 2}),
          ClockOrder.concurrent);
    });
  });

  group('Note', () {
    final now = DateTime(2026, 1, 1);
    Note make() => Note(
        id: 'x', title: 't', body: 'b', createdAt: now, updatedAt: now,
        clock: {});

    test('section mapping', () {
      expect(make().section, NoteSection.active);
      expect((make()..archived = true).section, NoteSection.archived);
      expect((make()..deleted = true).section, NoteSection.trash);
      expect(
          (make()
                ..archived = true
                ..deleted = true)
              .section,
          NoteSection.trash);
    });

    test('wordCount and readingMinutes', () {
      expect(make().wordCount, 1);
      expect((make()..body = '').wordCount, 0);
      expect((make()..body = '   ').wordCount, 0);
      expect((make()..body = 'a b c').wordCount, 3);
      expect((make()..body = 'a ' * 500).readingMinutes, 3);
      expect((make()..body = '').readingMinutes, 0);
    });

    test('pushRevision caps at maxRevisions', () {
      final n = make();
      for (var i = 0; i < 25; i++) {
        n.pushRevision();
      }
      expect(n.revisions.length, Note.maxRevisions);
    });

    test('json round trip', () {
      final n = make()
        ..tags = ['a', 'b']
        ..folderId = 'f1'
        ..colorIndex = 2
        ..pinned = true
        ..locked = true
        ..lockedPayload = const LockedPayload(
            ciphertext: 'c', nonce: 'n', wrappedKey: 'w', keyNonce: 'k')
        ..revisions = [
          Revision(title: 'r', body: 'rb', savedAt: now)
        ];
      final copy = Note.fromJson(n.toJson());
      expect(copy.title, 't');
      expect(copy.tags, ['a', 'b']);
      expect(copy.locked, isTrue);
      expect(copy.lockedPayload!.ciphertext, 'c');
      expect(copy.revisions.single.title, 'r');
      expect(copy.clock, <String, int>{});
    });

    test('fromJson tolerates missing fields', () {
      final n = Note.fromJson({
        'id': 'x',
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
      });
      expect(n.title, '');
      expect(n.locked, isFalse);
      expect(n.lockedPayload, isNull);
    });

    test('isDominatedBy and conflictsWith', () {
      final a = make()..clock = {'d1': 1};
      final b = make()..clock = {'d1': 2};
      expect(a.isDominatedBy(b), isTrue);
      expect(b.isDominatedBy(a), isFalse);
      expect(a.conflictsWith(b), isFalse);
      b.clock = {'d2': 1};
      expect(a.conflictsWith(b), isTrue);
    });

    test('asConflictCopy detaches id and marks title', () {
      final n = make()
        ..tags = ['x']
        ..lockedPayload = null;
      final copy = n.asConflictCopy('new-id');
      expect(copy.id, 'new-id');
      expect(copy.title, 't (conflict)');
      copy.tags.add('mutated');
      expect(n.tags, ['x']);
    });
  });

  group('Folder', () {
    test('json round trip', () {
      final f = Folder(
          id: 'f', name: 'Work', createdAt: DateTime(2026), clock: {'a': 1},
          colorIndex: 2, deleted: true);
      final copy = Folder.fromJson(f.toJson());
      expect(copy.name, 'Work');
      expect(copy.deleted, isTrue);
      expect(copy.colorIndex, 2);
    });

    test('fromJson defaults', () {
      final f = Folder.fromJson(
          {'id': 'f', 'name': 'n', 'createdAt': '2026-01-01T00:00:00.000'});
      expect(f.deleted, isFalse);
      expect(f.colorIndex, -1);
    });
  });

  group('SyncPeer', () {
    test('staleness and shortId', () {
      final p = SyncPeer(
          deviceId: 'abcdefghij',
          name: 'x',
          host: '1.2.3.4',
          port: 1,
          lastSeen: DateTime.now());
      expect(p.isStale, isFalse);
      expect(p.shortId, 'abcdefgh');
      p.lastSeen = DateTime.now().subtract(const Duration(minutes: 1));
      expect(p.isStale, isTrue);
      p.deviceId.length <= 8;
      final short = SyncPeer(
          deviceId: 'abc', name: 'x', host: 'h', port: 1,
          lastSeen: DateTime.now());
      expect(short.shortId, 'abc');
    });
  });
}
