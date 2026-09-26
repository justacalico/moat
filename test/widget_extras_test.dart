import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moat/app_state.dart';
import 'package:moat/models/peer.dart';
import 'package:moat/services/sync/engine.dart';
import 'package:moat/services/sync/transport.dart';
import 'package:moat/services/sync/discovery.dart';
import 'package:moat/services/sync/handshake.dart';
import 'package:moat/services/file_storage.dart';
import 'package:moat/services/picker.dart';
import 'package:moat/theme.dart';
import 'package:moat/ui/app.dart';
import 'package:moat/models/note.dart' show LockedPayload, NoteSection;
import 'package:moat/ui/editor_page.dart';
import 'package:moat/ui/home_page.dart';
import 'package:moat/ui/lock_screen.dart';
import 'package:moat/ui/settings_page.dart';
import 'package:moat/ui/side_rail.dart';
import 'package:moat/ui/widgets/note_list_pane.dart';
import 'package:moat/ui/sync_page.dart';
import 'package:moat/ui/widgets/sheets.dart';
import 'package:moat/util/platform_name_io.dart' show platformDeviceName;
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'helpers/fakes.dart';
import 'package:moat/services/memory_storage.dart';

Future<void> settle(WidgetTester tester, [int times = 20]) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> flushIo(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

class _FakePicker extends PickService {
  _FakePicker(this.path);
  final String? path;
  @override
  Future<String?> pickBackupFile() async => path;
}

/// Fake engine whose event stream can be fed.
class EmittingSync extends FakeSyncEngine {
  final _events = StreamController<SyncEvent>.broadcast();
  @override
  Stream<SyncEvent> get eventStream => _events.stream;
  void emit(SyncEvent e) => _events.add(e);
  @override
  void dispose() => _events.close();
}

void main() {
  group('note list pane', () {
    testWidgets('sort menu, grid toggle, tag filter, clear search',
        (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final n = s.createNote();
      await s.updateNote(n, title: 'Alpha', body: 'x');
      await s.setTags(n, ['work']);
      await pumpWithState(
          tester, const Scaffold(body: NoteListPane()), s);
      await settle(tester, 5);

      // sort menu → Title
      await tester.tap(find.byIcon(Icons.sort));
      await settle(tester);
      await tester.tap(find.text('Title'));
      await settle(tester);
      expect(s.settings.sort.name, 'title');

      // grid toggle
      await tester.tap(find.byTooltip('Toggle view'));
      await settle(tester);
      expect(s.settings.gridView, isTrue);
      expect(find.byType(GridView), findsOneWidget);
      await tester.tap(find.byTooltip('Toggle view'));
      await settle(tester);

      // tag chip filters
      final chip = find.descendant(
          of: find.byType(FilterChip), matching: find.text('work'));
      await tester.tap(chip);
      await settle(tester);
      expect(s.tagFilter, 'work');
      await tester.tap(chip);
      await settle(tester);
      expect(s.tagFilter, isEmpty);

      // search + clear
      await tester.enterText(find.byType(TextField).first, 'Alpha');
      await settle(tester);
      expect(s.query, 'Alpha');
      await tester.tap(find.byIcon(Icons.close));
      await settle(tester);
      expect(s.query, isEmpty);
    });

    testWidgets('tap opens editor (standalone), select mode toggles',
        (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      s.createNote();
      await pumpWithState(
          tester, const Scaffold(body: NoteListPane()), s);
      await settle(tester, 5);
      // long-press enters selection mode, tap toggles
      await tester.longPress(find.byType(Card).first);
      await settle(tester);
      expect(s.selectionMode, isTrue);
      await tester.tap(find.byType(Card).first);
      await settle(tester);
      expect(s.selection, isEmpty);
      expect(s.selectionMode, isFalse);
      // plain tap pushes the editor route
      await tester.tap(find.byType(Card).first);
      await settle(tester);
      expect(find.byType(EditorPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('embedded tap selects without pushing', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      s.createNote();
      await pumpWithState(tester,
          const Scaffold(body: NoteListPane(embedded: true)), s);
      await settle(tester, 5);
      await tester.tap(find.byType(Card).first);
      await settle(tester);
      expect(s.selectedNoteId, isNotNull);
      expect(find.byType(EditorPage), findsNothing);
    });

    testWidgets('empty states vary by section', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      s.setSection(NoteSection.trash);
      await pumpWithState(
          tester, const Scaffold(body: NoteListPane()), s);
      await tester.pump();
      expect(find.text('Trash is empty'), findsOneWidget);
      s.setSection(NoteSection.archived);
      await tester.pump();
      expect(find.text('No archived notes'), findsOneWidget);
      s.setQuery('zzz');
      await tester.pump();
      expect(find.text('No matches'), findsOneWidget);
    });
  });

  group('lock screen', () {
    testWidgets('biometric gate runs on init', (tester) async {
      final bio = FakeBiometricGate()..available = true;
      final s = await makeAppState(
          prefs: {'autoLockSeconds': 0, 'biometricUnlock': true},
          biometric: bio);
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      s.lockVault();
      await pumpWithState(tester, const LockScreen(), s);
      await tester.pump();
      expect(bio.calls, greaterThanOrEqualTo(1));
    });

    testWidgets('enter submits the passphrase', (tester) async {
      final s = await makeAppState(
          prefs: {'autoLockSeconds': 0, 'lockOnStart': true});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      s.lockVault();
      await pumpMoatLike(tester, s);
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'pw');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 30 && !s.vaultService.isUnlocked; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(s.vaultService.isUnlocked, isTrue);
    });
  });

  group('side rail extras', () {
    testWidgets('all notes / trash / empty sections', (tester) async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      addTearDown(s.dispose);
      final n = s.createNote();
      await s.moveToTrash(n);
      await pumpWithState(
          tester, const Scaffold(body: SideRail()), s,
          size: const Size(400, 1400));
      await tester.pump();
      expect(find.text('No folders'), findsOneWidget);
      expect(find.text('No tags'), findsOneWidget);
      // trash badge shows the count
      expect(find.text('1'), findsWidgets);
      await tester.tap(find.text('Trash'));
      await tester.pump();
      expect(s.section, NoteSection.trash);
      await tester.tap(find.text('All notes'));
      await tester.pump();
      expect(s.section, NoteSection.active);
      expect(s.folderFilter, isEmpty);
    });

    testWidgets('colored folder icon renders', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      s.createFolder('Hue', colorIndex: 1);
      await pumpWithState(
          tester, const Scaffold(body: SideRail()), s);
      await tester.pump();
      expect(find.text('Hue'), findsOneWidget);
      expect(MoatTheme.folderColor(1), isA<Color>());
    });
  });

  group('home extras', () {
    testWidgets('wide FAB creates a note and selects it', (tester) async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      addTearDown(s.dispose);
      await pumpWithState(tester, const NotesHomePage(), s,
          size: const Size(1400, 900));
      await settle(tester, 5);
      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);
      expect(s.visibleNotes.length, 1);
      expect(s.selectedNoteId, isNotNull);
      expect(find.byType(EditorPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('wide selection bar buttons run batch ops', (tester) async {
      final s = await makeAppState(prefs: {'seenWelcome': true});
      addTearDown(s.dispose);
      final n = s.createNote();
      await pumpWithState(tester, const NotesHomePage(), s,
          size: const Size(1400, 900));
      await settle(tester, 5);
      await tester.longPress(find.byType(Card).first);
      await settle(tester);
      expect(s.selectionMode, isTrue);
      // pin keeps the note in place
      await tester.tap(find.ancestor(
          of: find.byIcon(Icons.push_pin_outlined),
          matching: find.byType(IconButton)).first);
      await settle(tester);
      expect(s.noteById(n.id)!.pinned, isTrue);
      await tester.longPress(find.byType(Card).first);
      await settle(tester);
      // archive moves it out of the active list
      await tester.tap(find.ancestor(
          of: find.byIcon(Icons.archive_outlined),
          matching: find.byType(IconButton)).first);
      await settle(tester);
      expect(s.noteById(n.id)!.archived, isTrue);
      // selection clears after the batch op — restart it
      if (!s.selectionMode) {
        await tester.tap(find.text('Archive'));
        await tester.pump();
        await tester.longPress(find.byType(Card).first);
        await settle(tester);
      }
      // trash via the delete button, then close the bar
      await tester.tap(find.ancestor(
          of: find.byIcon(Icons.delete_outline),
          matching: find.byType(IconButton)).first);
      await settle(tester);
      expect(s.noteById(n.id)!.deleted, isTrue);
      if (s.selectionMode) {
        await tester.tap(find.ancestor(
          of: find.byIcon(Icons.close),
          matching: find.byType(IconButton)).first);
        await tester.pump();
      }
      expect(s.selectionMode, isFalse);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });
  });

  group('settings leftovers', () {
    testWidgets('auto-lock labels render for each range', (tester) async {
      for (final (secs, label) in [
        (30, '30 seconds'),
        (300, '5 minutes'),
        (3600, '1 hour'),
        (7200, '2 hours'),
      ]) {
        final s = await makeAppState(prefs: {'autoLockSeconds': secs});
        addTearDown(s.dispose);
        await s.setVaultPassphrase('pw');
        await pumpWithState(tester, const SettingsPage(), s,
            size: const Size(800, 1600));
        await settle(tester, 4);
        expect(find.text(label), findsOneWidget);
        s.lockVault();
      }
    });

    testWidgets('device name prefilled with existing name', (tester) async {
      final s = await makeAppState(prefs: {'deviceName': 'old-name'});
      addTearDown(s.dispose);
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Device name'));
      await settle(tester);
      expect(find.text('old-name'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
    });

    testWidgets('biometric tile appears when available', (tester) async {
      final bio = FakeBiometricGate()..available = true;
      final s = await makeAppState(
          prefs: {'autoLockSeconds': 0}, biometric: bio);
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 10);
      expect(find.text('Biometric unlock'), findsOneWidget);
      await tester.tap(find.descendant(
          of: find.ancestor(
              of: find.text('Biometric unlock'),
              matching: find.byType(ListTile)),
          matching: find.byType(Switch)));
      await tester.pump();
      expect(s.settings.biometricUnlock, isTrue);
    });

    testWidgets('change passphrase with locked vault asks to unlock first',
        (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      s.lockVault();
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Vault passphrase'));
      await settle(tester);
      await tester.tap(find.text('Change passphrase'));
      await settle(tester);
      expect(find.text('Unlock vault'), findsOneWidget);
      await tester.enterText(
          find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(TextField)),
          'pw');
      await tester.tap(find.descendant(
          of: find.byType(BottomSheet), matching: find.text('Unlock')));
      for (var i = 0; i < 30 && !s.vaultService.isUnlocked; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(s.vaultService.isUnlocked, isTrue);
      // the change-passphrase dialog opens next — cancel out of it
      await settle(tester, 3);
      if (find.text('Cancel').evaluate().isNotEmpty) {
        await tester.tap(find.text('Cancel').last);
        await settle(tester);
      }
    });

    testWidgets('passphrase dialog cancel does nothing', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Vault passphrase'));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(s.vaultService.hasVault, isFalse);
    });
  });

  group('sheets leftovers', () {
    testWidgets('text input submits via keyboard action', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      String? result;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: s,
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: FilledButton(
                  onPressed: () async {
                    result = await showTextInputDialog(ctx, title: 'T');
                  },
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'submitted');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(result, 'submitted');
    });

    testWidgets('unlock sheet via field submit', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      s.lockVault();
      bool? ok;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: s,
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: FilledButton(
                  onPressed: () async => ok = await showUnlockSheet(ctx),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, 'pw');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 10 && ok == null; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(ok, isTrue);
    });

    testWidgets('folder picker shows colored folder', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      s.createFolder('Tint', colorIndex: 0);
      final n = s.createNote();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: s,
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: FilledButton(
                  onPressed: () => showFolderPicker(ctx, n),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('Tint'), findsOneWidget);
      await tester.tap(find.text('Tint'));
      await settle(tester);
      expect(s.noteById(n.id)!.folderId, s.folders.first.id);
    });
  });

  group('editor leftovers', () {
    testWidgets('lock a note then locked view needs unlock', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      final n = s.createNote();
      await s.updateNote(n, title: 'T', body: 'secret');
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      // lock the note, then lock the vault → locked body + unlock sheet path
      await tester.tap(find.byTooltip('Lock note'));
      await settle(tester);
      s.lockVault();
      await tester.pump();
      expect(find.text('This note is locked'), findsOneWidget);
      await tester.tap(find.text('Unlock'));
      await settle(tester);
      expect(find.text('Unlock vault'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'pw');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0;
          i < 10 && find.text('secret').evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('secret'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('cannot-decrypt snackbar for tampered note',
        (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      final n = s.createNote();
      await s.updateNote(n, title: 'T', body: 'secret');
      await s.lockNote(n);
      // corrupt the ciphertext so GCM auth fails on open
      final p = n.lockedPayload!;
      final tampered = (p.ciphertext.startsWith('A') ? 'B' : 'A') +
          p.ciphertext.substring(1);
      n.lockedPayload = LockedPayload(
          ciphertext: tampered,
          nonce: p.nonce,
          wrappedKey: p.wrappedKey,
          keyNonce: p.keyNonce);
      s.lockVault();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      expect(find.text('This note is locked'), findsOneWidget);
      await tester.tap(find.text('Unlock'));
      await settle(tester);
      expect(find.text('Unlock vault'), findsOneWidget);
      await tester.enterText(
          find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(TextField)),
          'pw');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0;
          i < 20 &&
              find.textContaining('Cannot decrypt').evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.textContaining('Cannot decrypt'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('menu archive + unarchive', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      final n = s.createNote();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('Archive'));
      await settle(tester);
      expect(s.noteById(n.id)!.archived, isTrue);
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('Unarchive'));
      await settle(tester);
      expect(s.noteById(n.id)!.archived, isFalse);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('toggle lock asks for sheet when vault locked',
        (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      s.lockVault();
      final n = s.createNote();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byTooltip('Lock note'));
      await settle(tester);
      expect(find.text('Unlock vault'), findsOneWidget);
      // unlock via sheet → note locks
      await tester.enterText(
          find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(TextField)),
          'pw');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0;
          i < 10 && !s.noteById(n.id)!.locked;
          i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(s.noteById(n.id)!.locked, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('sync page stream', () {
    testWidgets('live events append to the log', (tester) async {
      final sync = EmittingSync();
      final s = await makeAppState(sync: sync);
      addTearDown(s.dispose);
      await pumpWithState(tester, const SyncPage(), s);
      await settle(tester, 5);
      sync.emit(SyncEvent(SyncEventKind.info, 'late arrival'));
      await tester.pump();
      await tester.pump();
      expect(find.text('late arrival'), findsOneWidget);
    });
  });

  group('last gaps', () {
    testWidgets('toolbar line button appends with no selection',
        (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final n = s.createNote();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.text('H1'));
      await tester.pump();
      expect(
          find.byWidgetPredicate((w) =>
              w is EditableText && w.controller.text.endsWith('# ')),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('manage folders renders colored folder icon',
        (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      s.createFolder('Tint', colorIndex: 0);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: s,
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: FilledButton(
                  onPressed: () => showManageFolders(ctx),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('Tint'), findsOneWidget);
      expect(
          find.byWidgetPredicate((w) =>
              w is Icon &&
              w.icon == Icons.folder_outlined &&
              w.color == MoatTheme.folderColor(0)),
          findsOneWidget);
    });

    testWidgets('locked note unlock flows through the sheet',
        (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      final n = s.createNote();
      await s.updateNote(n, title: 'T', body: 'secret');
      await s.lockNote(n);
      s.lockVault();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byTooltip('Unlock note'));
      await settle(tester);
      expect(find.text('Unlock vault'), findsOneWidget);
      await tester.enterText(
          find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(TextField)),
          'pw');
      await tester.tap(find.descendant(
          of: find.byType(BottomSheet), matching: find.text('Unlock')));
      for (var i = 0; i < 30 && s.noteById(n.id)!.locked; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(s.noteById(n.id)!.locked, isFalse);
      expect(find.text('secret'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('history menu opens revisions', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final n = s.createNote();
      await s.updateNote(n, title: 'T', body: 'v1');
      await s.updateNote(n, title: 'T', body: 'v2', contentChanged: true);
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('History'));
      await settle(tester);
      expect(find.text('Restore'), findsOneWidget);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await settle(tester);
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('Color'));
      await settle(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, 2);
    });

    testWidgets('import backup shows the summary snackbar',
        (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      final dir = Directory.systemTemp.createTempSync('moat-imp');
      (s.storage as MemoryStorage).exportDir = dir.path;
      s.createNote();
      final path = await tester
          .runAsync(() => s.exportBackup());
      PickService.instance = _FakePicker(path);
      addTearDown(() => PickService.instance = PickService());
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Import backup'));
      await flushIo(tester);
      await settle(tester);
      expect(find.textContaining('Imported'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('small units', () {
    test('HandshakeException formats its message', () {
      expect(const HandshakeException('nope').toString(),
          contains('nope'));
    });

    test('platformName falls back to OS name', () {
      expect(platformDeviceName(), isNotEmpty);
    });

    test('createPlatformStorage returns FileStorage', () {
      expect(createPlatformStorage(), isA<FileStorage>());
    });

    test('FrameHub replays queued errors to late subscribers', () async {
      final dec = FrameDecoder();
      dec.add(Uint8List(4)..buffer.asByteData().setUint32(0, 0x7fffffff));
      final stream = dec.frames;
      await expectLater(stream.first, throwsA(anything));
      await dec.close();
    });

    test('MemoryLink pair close is safe', () async {
      final (a, b) = MemoryLink.pair();
      await a.close();
      await b.close();
    });

    test('theme builder produces light and dark themes', () {
      expect(MoatTheme.light(0xFF0A84FF).brightness, Brightness.light);
      expect(MoatTheme.dark(0xFF0A84FF).brightness, Brightness.dark);
      expect(MoatTheme.folderColor(99), isA<Color>());
    });

    test('updateNote with no args reseals a locked note', () async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      final n = s.createNote();
      await s.updateNote(n, title: 't', body: 'b');
      await s.lockNote(n);
      // no args → both fields fall back to cached plaintext
      await s.updateNote(n);
      expect(s.displayTitle(n), 't');
      expect(s.displayBody(n), 'b');
    });

    test('UdpTransport ignores an unusable multicast group', () async {
      final t = await UdpTransport.bind(0,
          multicastGroup: InternetAddress('0.0.0.0'));
      t.close();
    });

    test('DiscoveryService getters and malformed packets', () async {
      final a = await UdpTransport.bind(0);
      final b = await UdpTransport.bind(0);
      final d = DiscoveryService(
        transport: a,
        deviceId: 'd1',
        deviceName: 'one',
        syncPort: 1,
        announceTo: [InternetAddress.loopbackIPv4],
        announcePort: b.port,
        announceInterval: const Duration(milliseconds: 30),
      )..start();
      expect(d.peers, isA<Stream<List<SyncPeer>>>());
      expect(d.known, isEmpty);
      // junk datagram → FormatException path is swallowed
      b.send(Uint8List.fromList([1, 2, 3]),
          InternetAddress.loopbackIPv4, a.port);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // announce ran — B should know about d1 once it processes announce
      final dB = DiscoveryService(
        transport: b,
        deviceId: 'd2',
        deviceName: 'two',
        syncPort: 1,
        announceTo: const [],
        announceInterval: const Duration(hours: 1),
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(dB.known.any((p) => p.deviceId == 'd1'), isTrue);
      d.dispose();
      dB.dispose();
      a.close();
      b.close();
    });
  });
}

/// Pumps the real MoatApp so lock-on-start paths resolve.
Future<void> pumpMoatLike(WidgetTester tester, AppState s) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: s,
      child: MoatApp(),
    ),
  );
  await tester.pump();
}
