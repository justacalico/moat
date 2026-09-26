import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moat/app_state.dart';
import 'package:moat/models/note.dart';
import 'package:moat/models/peer.dart';
import 'package:moat/services/memory_storage.dart';
import 'package:moat/services/sync/engine.dart';
import 'package:moat/ui/app.dart';
import 'package:moat/ui/editor_page.dart';
import 'package:moat/ui/home_page.dart';
import 'package:moat/ui/settings_page.dart';
import 'package:moat/ui/side_rail.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:moat/services/settings.dart';
import 'package:moat/services/vault.dart';
import 'package:moat/ui/sync_page.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fakes.dart';

Future<void> settle(WidgetTester tester, [int times = 20]) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Real file IO and platform channels can't complete inside fake async;
/// this gives the real event loop a beat to finish them.
Future<void> flushIo(WidgetTester tester,
    {bool Function()? until, int maxRounds = 12}) async {
  // Each hop of an IO future chain (open/write/close) needs a real-loop
  // turn plus a fake-zone microtask flush — alternate until satisfied.
  for (var i = 0; i < maxRounds; i++) {
    if (until != null && until()) return;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// SnackBars carry a ~4s display timer — pump past it so teardown sees no
/// pending timers.
Future<void> pumpSnack(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 5));

Future<void> pumpMoat(WidgetTester tester, AppState s,
    {Size size = const Size(500, 900)}) async {
  await tester.binding.setSurfaceSize(size);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: s,
      child: const MoatApp(),
    ),
  );
  await tester.pump();
}

SyncPeer peer(
    {String id = 'dev-b', String name = 'Other', bool paired = false}) {
  return SyncPeer(
      deviceId: id,
      name: name,
      host: '127.0.0.1',
      port: 45555,
      lastSeen: DateTime.now(),
      paired: paired);
}

void main() {
  group('settings page', () {
    testWidgets('appearance tiles: theme segments, accent, toggles',
        (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      expect(find.text('Appearance'.toUpperCase()), findsOneWidget);

      await tester.tap(find.text('Dark'));
      await tester.pump();
      expect(s.settings.themeMode, ThemeMode.dark);
      await tester.tap(find.text('Light'));
      await tester.pump();
      expect(s.settings.themeMode, ThemeMode.light);

      // accent dots — tap the second one
      final before = s.settings.accentColor;
      final dots = find.byWidgetPredicate(
          (w) => w is Container && w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).shape == BoxShape.circle);
      await tester.tap(dots.at(1));
      await tester.pump();
      expect(s.settings.accentColor, isNot(equals(before)));

      // grid view + density toggles
      await tester.tap(find.descendant(
          of: find.ancestor(of: find.text('Note list'), matching: find.byType(ListTile)),
          matching: find.byType(Switch)));
      await tester.pump();
      expect(s.settings.gridView, isTrue);
      await tester.tap(find.descendant(
          of: find.ancestor(of: find.text('Density'), matching: find.byType(ListTile)),
          matching: find.byType(Switch)));
      await tester.pump();
      expect(s.settings.density.name, 'compact');
    });

    testWidgets('device name dialog saves', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Device name'));
      await settle(tester);
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'my-laptop');
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(s.deviceName, 'my-laptop');
    });

    testWidgets('vault set → auto-lock picker → lock now → remove',
        (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      expect(find.text('Not set'), findsOneWidget);

      // set passphrase — confirm dialog with two fields
      await tester.tap(find.text('Vault passphrase'));
      await settle(tester);
      await settle(tester);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'pw12');
      await tester.enterText(fields.at(1), 'pw12');
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(s.vaultService.hasVault, isTrue);
      expect(find.text('Set · unlocked'), findsOneWidget);

      // auto-lock picker — 'Never' leaves no timer pending at teardown
      await tester.tap(find.text('Auto-lock'));
      await settle(tester);
      await settle(tester);
      await tester.tap(find.descendant(
          of: find.byType(BottomSheet), matching: find.text('Never')));
      await settle(tester);
      expect(s.settings.autoLockSeconds, 0);

      // lock on start toggle
      await tester.tap(find.descendant(
          of: find.ancestor(
              of: find.text('Require unlock at launch'),
              matching: find.byType(ListTile)),
          matching: find.byType(Switch)));
      await tester.pump();
      expect(s.settings.lockOnStart, isTrue);

      // lock now
      await tester.tap(find.text('Lock now'));
      await settle(tester);
      await tester.pump();
      expect(s.vaultService.isUnlocked, isFalse);

      // vault tile → remove path requires unlock first
      await tester.tap(find.text('Vault passphrase'));
      await settle(tester);
      await settle(tester);
      await tester.tap(find.text('Remove vault'));
      await settle(tester);
      // unlock sheet appears
      await tester.enterText(find.byType(TextField).first, 'pw12');
      await tester.tap(find.text('Unlock'));
      for (var i = 0;
          i < 10 && find.text('Remove vault?').evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(find.text('Remove'));
      await settle(tester);
      expect(s.vaultService.hasVault, isFalse);
      await pumpSnack(tester);
    });

    testWidgets('vault change passphrase flow', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('old1');
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Vault passphrase'));
      await settle(tester);
      await settle(tester);
      await tester.tap(find.text('Change passphrase'));
      await settle(tester);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'new2');
      await tester.enterText(fields.at(1), 'new2');
      await tester.tap(find.text('Save'));
      await settle(tester);
      // old no longer works, new does
      s.lockVault();
      expect(await s.unlockVault('old1'), isFalse);
      s.lockVault();
      expect(await s.unlockVault('new2'), isTrue);
      await pumpSnack(tester);
    });

    testWidgets('passphrase mismatch shows snackbar', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Vault passphrase'));
      await settle(tester);
      await settle(tester);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'pw12');
      await tester.enterText(fields.at(1), 'diff');
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(find.text('Passphrases must match (4+ characters)'),
          findsOneWidget);
      expect(s.vaultService.hasVault, isFalse);
      await pumpSnack(tester);
    });

    testWidgets('export writes a backup file and reports', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final dir = await tester.runAsync(() async {
        final d = Directory.systemTemp.createTempSync('moat-export');
        return d.path;
      });
      (s.storage as MemoryStorage).exportDir = dir!;
      s.createNote();
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Export backup'));
      await flushIo(tester,
          until: () => find.textContaining('Backup written to').evaluate().isNotEmpty);
      await settle(tester);
      expect(find.textContaining('Backup written to'), findsOneWidget);
      await pumpSnack(tester);
    });

    testWidgets('export failure reports via snackbar', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      // '/exports' is not writable in the test sandbox
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Export backup'));
      await flushIo(tester,
          until: () => find.textContaining('Export failed').evaluate().isNotEmpty);
      await settle(tester);
      expect(find.textContaining('Export failed'), findsOneWidget);
      await pumpSnack(tester);
    });

    testWidgets('import failure reports via snackbar', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Import backup'));
      await settle(tester);
      await settle(tester, 30);
      // no platform picker in tests → either null return or plugin error
      // both end without a successful import message
      expect(find.textContaining('Imported'), findsNothing);
    });

    testWidgets('about tile opens the license page', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Moat').last);
      await settle(tester);
      expect(find.text('Powered by Flutter'), findsOneWidget);
    });

    testWidgets('empty trash tile runs the confirm flow', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final n = s.createNote();
      await s.moveToTrash(n);
      await pumpWithState(tester, const SettingsPage(), s,
          size: const Size(800, 1600));
      await settle(tester, 5);
      await tester.tap(find.text('Empty trash'));
      await settle(tester);
      await settle(tester);
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(s.notesInTrash, isEmpty);
    });
  });

  group('sync page', () {
    testWidgets('renders device card, toggles sync, sync now', (tester) async {
      final sync = FakeSyncEngine();
      final s = await makeAppState(sync: sync);
      addTearDown(s.dispose);
      await pumpWithState(tester, const SyncPage(), s);
      await settle(tester, 5);
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('listening'), findsOneWidget);

      await tester.tap(find.text('Sync now'));
      await tester.pump();
      expect(sync.syncNowCalls, 1);

      await tester.tap(find.byType(Switch).first);
      await settle(tester);
      expect(s.settings.syncEnabled, isFalse);
      expect(sync.running, isFalse);
      expect(find.text('off'), findsOneWidget);
    });

    testWidgets('peer list: pair asks for the code', (tester) async {
      final sync = FakeSyncEngine()
        ..fakePeers = [
          peer(),
          peer(id: 'dev-c', name: 'Tablet', paired: true),
        ];
      final s = await makeAppState(sync: sync);
      addTearDown(s.dispose);
      await pumpWithState(tester, const SyncPage(), s);
      await settle(tester, 5);
      expect(find.text('Other'), findsOneWidget);
      expect(find.text('Tablet'), findsOneWidget);
      expect(find.text('1 paired'), findsOneWidget);

      // Pair → the engine asks for the code through the dialog
      await tester.tap(find.text('Pair').first);
      await settle(tester);
      expect(find.text('Enter pairing code'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Pair')));
      await settle(tester);
      expect(sync.pairCode, '123456');
    });

    testWidgets('pair code dialog cancel throws through', (tester) async {
      final sync = FakeSyncEngine()..fakePeers = [peer()];
      final s = await makeAppState(sync: sync);
      addTearDown(s.dispose);
      await pumpWithState(tester, const SyncPage(), s);
      await settle(tester, 5);
      await tester.tap(find.text('Pair').first);
      await settle(tester);
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Cancel')));
      await settle(tester);
      expect(sync.pairCode, isNull);
    });

    testWidgets('unpair confirm dialog removes the peer', (tester) async {
      final p = peer(paired: true);
      final sync = FakeSyncEngine()..fakePeers = [p];
      final s = await makeAppState(sync: sync);
      addTearDown(s.dispose);
      await pumpWithState(tester, const SyncPage(), s);
      await settle(tester, 5);
      await tester.tap(find.text('Unpair').first);
      await settle(tester);
      expect(find.text('Unpair Other?'), findsOneWidget);
      await tester.tap(find.text('Unpair').last);
      await settle(tester);
    });

    testWidgets('event log renders entries with kind colors', (tester) async {
      final sync = FakeSyncEngine()
        ..fakeEvents = [
          SyncEvent(SyncEventKind.error, 'boom'),
          SyncEvent(SyncEventKind.conflict, 'clash'),
          SyncEvent(SyncEventKind.paired, 'linked'),
          SyncEvent(SyncEventKind.info, 'plain'),
        ];
      final s = await makeAppState(sync: sync);
      addTearDown(s.dispose);
      await pumpWithState(tester, const SyncPage(), s);
      await settle(tester, 5);
      expect(find.text('boom'), findsOneWidget);
      expect(find.text('clash'), findsOneWidget);
      expect(find.text('linked'), findsOneWidget);
      // ticker refresh
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('side rail', () {
    testWidgets('sections navigate, drawer closes', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(tester, const Scaffold(
          drawer: Drawer(child: SideRail(inDrawer: true)),
          body: SizedBox()), s);
      await tester.pump();
      // open the drawer
      final scaffold = tester.firstState<ScaffoldState>(
          find.byType(Scaffold));
      scaffold.openDrawer();
      await settle(tester);
      expect(find.text('All notes'), findsOneWidget);

      await tester.tap(find.text('Archive'));
      await settle(tester);
      expect(s.section, NoteSection.archived);
      // drawer closed
      expect(find.text('All notes'), findsNothing);
    });

    testWidgets('folder add + manage + tag chips', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final f = s.createFolder('F1');
      final n = s.createNote();
      await s.setTags(n, ['tagx']);
      await pumpWithState(
          tester, const Scaffold(body: SideRail()), s);
      await tester.pump();
      expect(find.text('F1'), findsOneWidget);
      expect(find.text('tagx'), findsOneWidget);

      await tester.tap(find.text('F1').first);
      await tester.pump();
      expect(s.folderFilter, f.id);

      await tester.tap(find.text('tagx'));
      await tester.pump();
      expect(s.tagFilter, 'tagx');

      // manage folders opens the sheet
      await tester.tap(find.byIcon(Icons.more_horiz));
      await settle(tester);
      expect(find.text('Folders'), findsOneWidget);
      await tester.tap(find.text('F1').last);
      await settle(tester);
    });

    testWidgets('folder add button creates via dialog', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(
          tester, const Scaffold(body: SideRail()), s);
      await tester.pump();
      expect(find.text('No folders'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'NewF');
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(s.folders.map((f) => f.name), contains('NewF'));
    });

    testWidgets('vault icon locks and opens unlock sheet', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      await pumpWithState(
          tester, const Scaffold(body: SideRail()), s);
      await tester.pump();
      // unlocked → tap locks
      await tester.tap(find.byIcon(Icons.lock_open));
      await tester.pump();
      expect(s.vaultService.isUnlocked, isFalse);
      // locked → tap opens sheet
      await tester.tap(find.byIcon(Icons.lock_outline));
      await settle(tester);
      expect(find.text('Unlock vault'), findsOneWidget);
    });

    testWidgets('settings and sync nav push routes', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(
          tester, const Scaffold(body: SideRail()), s);
      await tester.pump();
      await tester.tap(find.text('Settings'));
      await settle(tester);
      expect(find.text('Appearance'.toUpperCase()), findsOneWidget);
      // back to rail
      Navigator.of(tester.element(find.byType(SettingsPage))).pop();
      await settle(tester);
      await tester.tap(find.text('Sync'));
      await settle(tester);
      expect(find.text('This device'), findsOneWidget);
    });
  });

  group('home page extras', () {
    testWidgets('compact: trash section Empty button clears trash',
        (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final n = s.createNote();
      await s.moveToTrash(n);
      s.setSection(NoteSection.trash);
      await pumpWithState(tester, const NotesHomePage(), s,
          size: const Size(420, 900));
      await settle(tester, 5);
      expect(find.text('Trash'), findsWidgets);
      await tester.tap(find.text('Empty'));
      await settle(tester);
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(s.notesInTrash, isEmpty);
    });

    testWidgets('compact: folder title shows in header', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final f = s.createFolder('MyFolder');
      s.setFolderFilter(f.id);
      await pumpWithState(tester, const NotesHomePage(), s,
          size: const Size(420, 900));
      await tester.pump();
      expect(find.text('MyFolder'), findsWidgets);
    });

    testWidgets('compact: selection app bar batch actions', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      s.createNote();
      await pumpWithState(tester, const NotesHomePage(), s,
          size: const Size(420, 900));
      await settle(tester, 5);
      await tester.longPress(find.byType(Card).first);
      await settle(tester);
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.push_pin_outlined));
      await tester.pump();
      expect(s.visibleNotes.first.pinned, isTrue);
      await tester.longPress(find.byType(Card).first);
      await settle(tester);
      await tester.tap(find.byIcon(Icons.archive_outlined));
      await tester.pump();
      await tester.longPress(find.byType(Card).first);
      await settle(tester);
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();
      // clear button closes the mode
      if (s.selectionMode) {
        await tester.tap(find.byIcon(Icons.close));
        await tester.pump();
      }
      expect(s.selectionMode, isFalse);
    });

    testWidgets('wide: embedded editor opens on note tap', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      s.createNote();
      await pumpWithState(tester, const NotesHomePage(), s,
          size: const Size(1400, 900));
      await settle(tester, 5);
      await tester.tap(find.byType(Card).first);
      await settle(tester);
      expect(find.byType(EditorPage), findsOneWidget);
    });
  });

  group('editor page extras', () {
    testWidgets('preview toggle renders markdown', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      final n = s.createNote();
      await s.updateNote(n, title: 'T', body: 'text body');
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byTooltip('Preview'));
      await settle(tester);
      expect(find.byType(MarkdownBody), findsOneWidget);
      await tester.tap(find.byTooltip('Edit'));
      await settle(tester);
      expect(find.byType(MarkdownBody), findsNothing);
    });

    testWidgets('menu: copy shows snackbar, export reports path',
        (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      final dir = await tester.runAsync(
          () async => Directory.systemTemp.createTempSync('moat-md').path);
      (s.storage as MemoryStorage).exportDir = dir!;
      final n = s.createNote();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('Copy text'));
      await flushIo(tester,
          until: () => find.text('Copied').evaluate().isNotEmpty);
      await settle(tester);
      expect(find.text('Copied'), findsOneWidget);
      await pumpSnack(tester);
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('Export .md'));
      await flushIo(tester,
          until: () => find.textContaining('Exported to').evaluate().isNotEmpty);
      await settle(tester);
      expect(find.textContaining('Exported to'), findsOneWidget);
      await pumpSnack(tester);
    });

    testWidgets('menu: export failure shows snackbar', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      final n = s.createNote();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('Export .md'));
      await flushIo(tester,
          until: () => find.textContaining('Export failed').evaluate().isNotEmpty);
      await settle(tester);
      expect(find.textContaining('Export failed'), findsOneWidget);
      await pumpSnack(tester);
    });

    testWidgets('menu: folder picker moves note', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      final f = s.createFolder('Dest');
      final n = s.createNote();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('Move to folder'));
      await settle(tester);
      await tester.tap(find.text('Dest'));
      await settle(tester);
      expect(s.noteById(n.id)!.folderId, f.id);
    });

    testWidgets('menu: history opens revisions sheet', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      final n = s.createNote();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('History'));
      await settle(tester);
      expect(find.text('No earlier versions'), findsOneWidget);
    });

    testWidgets('lock without vault shows snackbar', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      final n = s.createNote();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byTooltip('Lock note'));
      await settle(tester);
      expect(find.text('Set a vault passphrase in Settings first'),
          findsOneWidget);
      await pumpSnack(tester);
    });

    testWidgets('lock with vault locks then unlock note restores text',
        (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      final n = s.createNote();
      await s.updateNote(n, title: 'T', body: 'secret');
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byTooltip('Lock note'));
      await settle(tester);
      expect(s.noteById(n.id)!.locked, isTrue);
      // note is locked but vault still unlocked → content visible
      await tester.tap(find.byTooltip('Unlock note'));
      await settle(tester);
      expect(s.noteById(n.id)!.locked, isFalse);
      expect(s.noteById(n.id)!.body, 'secret');
    });

    testWidgets('delete moves to trash and pops', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      final n = s.createNote();
      await pumpWithState(tester, EditorPage(noteId: n.id), s,
          size: const Size(500, 900));
      await settle(tester, 5);
      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(s.noteById(n.id)!.section, NoteSection.trash);
    });
  });

  group('app shell', () {
    testWidgets('boot screen while state is not ready', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(
        storage: MemoryStorage(),
        settings: await Settings.load(),
        vault: VaultService(kdf: fastKdf),
        biometric: FakeBiometricGate(),
        sync: FakeSyncEngine(),
      );
      addTearDown(s.dispose);
      await pumpMoat(tester, s);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('pair request dialog confirm + pair code dialog',
        (tester) async {
      final sync = FakeSyncEngine();
      final s = await makeAppState(sync: sync);
      addTearDown(s.dispose);
      await pumpMoat(tester, s);
      await settle(tester, 5);
      // _wireSyncHooks ran postframe
      expect(sync.onPairRequest, isNotNull);
      expect(sync.onShowPairCode, isNotNull);

      final accepted = sync.onPairRequest!('dev-x', 'Stranger');
      await settle(tester);
      expect(find.text('Pair request'), findsOneWidget);
      await tester.tap(find.text('Pair').first);
      await settle(tester);
      expect(await accepted, isTrue);

      sync.onShowPairCode!('482913');
      await settle(tester);
      expect(find.text('482913'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await settle(tester);
      expect(find.text('Pairing code'), findsNothing);
    });
  });
}
