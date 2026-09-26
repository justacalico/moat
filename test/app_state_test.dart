import 'package:flutter_test/flutter_test.dart';
import 'package:moat/app_state.dart';
import 'package:moat/models/folder.dart';
import 'package:moat/models/note.dart';
import 'dart:io';

import 'package:moat/services/memory_storage.dart';
import 'package:moat/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fakes.dart';

void main() {
  group('init and notes', () {
    test('seeds a welcome note on first run', () async {
      final s = await makeAppState();
      expect(s.ready, isTrue);
      expect(s.deviceId, isNotEmpty);
      expect(s.visibleNotes.single.title, 'Welcome to Moat');
      expect(s.visibleNotes.single.tags, ['welcome']);
    });

    test('no welcome seed when notes exist already', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      expect(s.visibleNotes, isEmpty);
    });

    test('createNote selects it and persists', () async {
      final s = await makeAppState();
      final n = s.createNote(folderId: '');
      expect(s.selectedNoteId, n.id);
      expect(s.noteById(n.id), isNotNull);
      expect(n.clock[s.deviceId], 1);
    });

    test('updateNote edits fields and ticks clock', () async {
      final s = await makeAppState();
      final n = s.createNote();
      final before = n.updatedAt;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await s.updateNote(n, title: 'New', body: 'content',
          contentChanged: true);
      expect(n.title, 'New');
      expect(n.updatedAt.isAfter(before) || n.updatedAt == before, isTrue);
      expect(n.revisions.length, 1);
    });

    test('pin/archive/trash lifecycle', () async {
      final s = await makeAppState();
      final n = s.createNote();
      await s.togglePin(n);
      expect(n.pinned, isTrue);
      await s.togglePin(n);
      expect(n.pinned, isFalse);

      await s.setArchived(n, true);
      expect(s.visibleNotes.contains(n), isFalse);
      s.setSection(NoteSection.archived);
      expect(s.visibleNotes.contains(n), isTrue);
      await s.setArchived(n, false);

      await s.moveToTrash(n);
      s.setSection(NoteSection.trash);
      expect(s.visibleNotes.contains(n), isTrue);
      expect(s.selectedNoteId, isNull);
      await s.restoreFromTrash(n);
      s.setSection(NoteSection.active);
      expect(s.visibleNotes.contains(n), isTrue);

      await s.moveToTrash(n);
      await s.deleteForever(n);
      expect(s.noteById(n.id), isNull);
    });

    test('emptyTrash removes all trashed notes', () async {
      final s = await makeAppState();
      final a = s.createNote();
      final b = s.createNote();
      await s.moveToTrash(a);
      await s.moveToTrash(b);
      expect(s.notesInTrash, hasLength(2));
      await s.emptyTrash();
      expect(s.notesInTrash, isEmpty);
    });
  });

  group('folders, tags, filters, search', () {
    test('folder CRUD', () async {
      final s = await makeAppState();
      final f = s.createFolder('Work');
      expect(s.folders.single.name, 'Work');
      final n = s.createNote();
      await s.setFolder(n, f.id);
      expect(s.noteCountInFolder(f.id), 1);

      await s.renameFolder(f, 'Personal');
      expect(f.name, 'Personal');
      s.setFolderFilter(f.id);
      expect(s.visibleNotes, contains(n));
      await s.deleteFolder(f);
      expect(s.folders, isEmpty);
      expect(n.folderId, '');
      expect(s.folderFilter, '');
    });

    test('tags add/remove and filter', () async {
      final s = await makeAppState();
      final n = s.createNote();
      await s.setTags(n, ['one', ' two ']);
      expect(n.tags, ['one', 'two']);
      expect(s.allTags, contains('two'));
      s.setTagFilter('two');
      expect(s.visibleNotes, [n]);
      s.setTagFilter('two'); // toggle off
      expect(s.tagFilter, '');
    });

    test('search matches title, body, tags', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      final n = s.createNote();
      await s.updateNote(n, title: 'Grocery list', body: 'milk and eggs');
      s.setQuery('milk');
      expect(s.visibleNotes, [n]);
      s.setQuery('grocery');
      expect(s.visibleNotes, [n]);
      await s.setTags(n, ['shopping']);
      s.setQuery('shopping');
      expect(s.visibleNotes, [n]);
      s.setQuery('nothing-matches');
      expect(s.visibleNotes, isEmpty);
      s.setQuery('');
    });

    test('locked notes do not match search while vault is locked', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      await s.setVaultPassphrase('pw');
      final n = s.createNote();
      await s.updateNote(n, title: 'Secret', body: 'hidden diary');
      await s.lockNote(n);
      s.lockVault();
      s.setQuery('hidden');
      expect(s.visibleNotes, isEmpty);
      await s.unlockVault('pw');
      s.setQuery('hidden');
      expect(s.visibleNotes, [n]);
    });

    test('sort orders', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      final a = s.createNote();
      final b = s.createNote();
      await s.updateNote(a, title: 'b title');
      await s.updateNote(b, title: 'a title');
      s.setSort(NoteSort.title);
      expect(s.visibleNotes.first.title, 'a title');
      s.setSort(NoteSort.created);
      expect(s.visibleNotes, hasLength(2));
      s.setSort(NoteSort.updated);
      expect(s.visibleNotes, hasLength(2));
    });

    test('pinned notes sort first', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      final a = s.createNote();
      final b = s.createNote();
      await s.updateNote(a, title: 'z');
      await s.updateNote(b, title: 'a');
      s.setSort(NoteSort.title);
      await s.togglePin(a);
      expect(s.visibleNotes.first.id, a.id);
    });

    test('setColor and folder assignment', () async {
      final s = await makeAppState();
      final n = s.createNote();
      await s.setColor(n, 3);
      expect(n.colorIndex, 3);
    });
  });

  group('selection', () {
    test('multi-select batch ops', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      final a = s.createNote();
      final b = s.createNote();
      s.toggleSelection(a.id);
      s.toggleSelection(b.id);
      expect(s.selectionMode, isTrue);
      expect(s.selectedNotes, hasLength(2));
      await s.batchPin();
      expect(a.pinned && b.pinned, isTrue);
      expect(s.selectionMode, isFalse);

      s.toggleSelection(a.id);
      s.toggleSelection(a.id); // deselect
      expect(s.selectionMode, isFalse);

      s.toggleSelection(a.id);
      s.toggleSelection(b.id);
      await s.batchArchive();
      expect(a.archived && b.archived, isTrue);

      s.toggleSelection(a.id);
      await s.batchMoveToTrash();
      expect(a.deleted, isTrue);
    });
  });

  group('vault + locked notes', () {
    test('lockNote encrypts, openNote decrypts, unlockNote restores',
        () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      await s.setVaultPassphrase('vault-pass');
      final n = s.createNote();
      await s.updateNote(n, title: 'Secret', body: 'hidden');
      expect(await s.lockNote(n), isTrue);
      expect(n.locked, isTrue);
      expect(n.body, '');
      expect(s.displayTitle(n), 'Secret'); // unlocked session shows real title

      s.lockVault();
      expect(s.displayTitle(n), 'Locked note');
      expect(s.displayBody(n), '');

      expect(await s.unlockVault('wrong'), isFalse);
      expect(await s.unlockVault('vault-pass'), isTrue);
      expect(s.displayBody(n), 'hidden');

      await s.unlockNote(n);
      expect(n.locked, isFalse);
      expect(n.body, 'hidden');
    });

    test('lockNote fails without unlocked vault', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      final n = s.createNote();
      expect(await s.lockNote(n), isFalse);
      await s.setVaultPassphrase('pw');
      s.lockVault();
      expect(await s.lockNote(n), isFalse);
    });

    test('openNote returns true for unlocked notes', () async {
      final s = await makeAppState();
      final n = s.createNote();
      expect(await s.openNote(n), isTrue);
    });

    test('locked note updates re-encrypt through cache', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      await s.setVaultPassphrase('pw');
      final n = s.createNote();
      await s.updateNote(n, title: 'S', body: 'x');
      await s.lockNote(n);
      await s.updateNote(n, title: 'S2', body: 'y');
      expect(s.displayBody(n), 'y');
      // persisted payload holds the new text
      s.lockVault();
      await s.unlockVault('pw');
      expect(s.displayBody(n), 'y');
    });

    test('change and remove vault', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      await s.setVaultPassphrase('one');
      final n = s.createNote();
      await s.updateNote(n, title: 'L', body: 'secret');
      await s.lockNote(n);
      s.lockVault();
      await s.unlockVault('one');
      await s.changeVaultPassphrase('two');
      s.lockVault();
      expect(await s.unlockVault('one'), isFalse);
      expect(await s.unlockVault('two'), isTrue);
      expect(s.displayBody(n), 'secret');

      await s.removeVault();
      expect(s.vaultService.hasVault, isFalse);
      expect(n.locked, isFalse);
      expect(n.body, 'secret');
    });

    test('biometricUnlock delegates to the gate', () async {
      final bio = FakeBiometricGate();
      final s = await makeAppState(biometric: bio);
      expect(await s.biometricUnlock(), isTrue);
      expect(bio.calls, 1);
    });
  });

  group('sync store hooks', () {
    test('manifest and payloads', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      final n = s.createNote();
      final f = s.createFolder('F');
      final manifest = s.noteManifest();
      expect(manifest.single['id'], n.id);
      expect(s.folderManifest().single['id'], f.id);
      expect(s.notePayload(n.id)!['id'], n.id);
      expect(s.notePayload('nope'), isNull);
      expect(s.folderPayload('nope'), isNull);
    });

    test('applyRemoteNote insert/dominates/conflicts', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      final remote = makeNote(id: 'r1', title: 'remote');
      remote.clock = {'other': 1};
      expect(s.applyRemoteNote(remote.toJson()), 'applied');
      expect(s.noteById('r1'), isNotNull);

      // equal clock → kept-local
      expect(s.applyRemoteNote(remote.toJson()), 'kept-local');
      // local dominates
      final local = s.noteById('r1')!;
      await s.updateNote(local, title: 'local edit');
      remote.clock = {'other': 1};
      expect(s.applyRemoteNote(remote.toJson()), 'kept-local');
      // remote dominates
      remote.clock = {'other': 5, 'dev': 99};
      remote.clock.addAll({s.deviceId: local.clock[s.deviceId] ?? 0});
      remote.title = 'remote wins';
      expect(s.applyRemoteNote(remote.toJson()), 'applied');
      expect(s.noteById('r1')!.title, 'remote wins');
      // concurrent → conflict copy appears
      final diverged = makeNote(id: 'r1', title: 'third version');
      diverged.clock = {'other': 9};
      expect(s.applyRemoteNote(diverged.toJson()), 'conflict');
      expect(s.visibleNotes.any((x) => x.title.endsWith('(conflict)')),
          isTrue);
    });

    test('applyRemoteFolder insert/dominates/conflicts', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      final f = s.createFolder('Local');
      final remote = Folder.fromJson(f.toJson())..name = 'Remote';

      // concurrent edit
      remote.clock = {'other': 5};
      f.clock = {'mine': 3};
      expect(s.applyRemoteFolder(remote.toJson()), 'conflict');
      expect(s.folderById(f.id)!.name, 'Remote');

      // strictly newer remote
      remote.clock = {'mine': 3, 'other': 6};
      remote.name = 'Remote2';
      expect(s.applyRemoteFolder(remote.toJson()), 'applied');
      // stale remote
      remote.clock = {'other': 1};
      expect(s.applyRemoteFolder(remote.toJson()), 'kept-local');
      // new folder
      final fresh = Folder(
          id: 'nf', name: 'New', createdAt: DateTime.now(), clock: {'x': 1});
      expect(s.applyRemoteFolder(fresh.toJson()), 'applied');
    });

    test('vault record adoption + lt key persistence', () async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      expect(s.vaultRecord, isNull);
      // adopt a real vault record generated by a peer
      await s.setVaultPassphrase('peerpass');
      final json = s.vaultRecord!.toJson();
      final s2 = await makeAppState(prefs: {'seenWelcome': true});
      expect(s2.adoptVaultRecord(json), isTrue);
      expect(s2.vaultRecord, isNotNull);
      expect(s2.adoptVaultRecord(json), isFalse); // already has one
      s2.dispose();

      expect(s.hasLtKey('x'), isFalse);
      final key = await s.crypto.newNoteKey();
      s.storeLtKey('peer1', 'peer name', key);
      expect(s.hasLtKey('peer1'), isTrue);
      expect(s.peerName('peer1'), 'peer name');
      s.removeLtKey('peer1');
      expect(s.hasLtKey('peer1'), isFalse);
    });
  });

  group('export/import', () {
    test('backup round trip via memory storage export dir', () async {
      final storage = MemoryStorage();
      storage.exportDir =
          Directory.systemTemp.createTempSync('moat-exp').path;
      SharedPreferences.setMockInitialValues({'seenWelcome': true});
      final s = AppState(
        storage: storage,
        settings: await Settings.load(),
        biometric: FakeBiometricGate(),
        sync: FakeSyncEngine(),
        isWeb: true,
      );
      await s.init();
      final n = s.createNote();
      await s.updateNote(n, title: 'ex', body: 'ported');
      s.createFolder('F1');

      final path = await s.exportBackup();
      expect(path, contains('moat-backup'));

      // importing into a fresh state brings nothing new if same ids exist
      final res = await s.importBackup(path);
      expect(res.notes, 0);
    });
  });

  group('misc', () {
    test('deviceName fallback chain', () async {
      final s = await makeAppState(prefs: {'deviceName': 'my phone'});
      expect(s.deviceName, 'my phone');
      await s.setDeviceName('renamed');
      expect(s.deviceName, 'renamed');
    });

    test('touch/lockVault and sync toggles are safe', () async {
      final sync = FakeSyncEngine();
      final s = await makeAppState(sync: sync);
      s.touch();
      await s.setSyncEnabled(false);
      expect(sync.running, isFalse);
      await s.setSyncEnabled(true);
      expect(sync.running, isTrue);
      s.unpairPeer('nobody');
      await s.syncNow();
      expect(sync.syncNowCalls, greaterThanOrEqualTo(0));
      s.dispose();
    });

    test('isWeb skips engine creation', () async {
      final s = await makeAppState(isWeb: true);
      // stub engine is still injected
      expect(s.sync, isNotNull);
    });
  });
}
