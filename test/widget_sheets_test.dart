import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moat/app_state.dart';
import 'package:moat/ui/widgets/markdown_toolbar.dart';
import 'package:moat/ui/widgets/sheets.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

/// Pumps a button that runs [action] with a provider-scoped context, so each
/// sheet/dialog can be launched like a real screen would.
Future<void> pumpHost(
  WidgetTester tester,
  AppState state,
  void Function(BuildContext) action,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => action(ctx),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('confirm + text input dialogs', () {
    testWidgets('confirm returns true on confirm, false on cancel',
        (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final results = <bool>[];
      await pumpHost(tester, s, (ctx) async {
        results.add(await showConfirmDialog(ctx,
            title: 'T', message: 'M', confirmLabel: 'Yep'));
      });
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('T'), findsOneWidget);
      expect(find.text('M'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      await tester.tap(find.text('go'));
      await settle(tester);
      await tester.tap(find.text('Yep'));
      await settle(tester);
      expect(results, [false, true]);
    });

    testWidgets('text input returns entered text or null', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final results = <String?>[];
      await pumpHost(tester, s, (ctx) async {
        results.add(await showTextInputDialog(ctx,
            title: 'Name', hint: 'hint', initial: 'seed'));
      });
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('seed'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'typed');
      await tester.tap(find.text('Save'));
      await settle(tester);
      await tester.tap(find.text('go'));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(results, ['typed', null]);
    });
  });

  group('PassphraseField', () {
    testWidgets('strength hints progress and obscure toggles', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(
          tester,
          const Scaffold(body: PassphraseField(showConfirm: true)),
          s);
      await tester.enterText(find.byType(TextField).first, 'short');
      await tester.pump();
      expect(find.text('Weak — use 8+ characters'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'ninechars');
      await tester.pump();
      expect(find.text('Okay — longer is stronger'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'a long passphrase');
      await tester.pump();
      expect(find.text('Strong'), findsOneWidget);
      // obscure toggle switches the icon
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump();
      expect(find.byIcon(Icons.visibility), findsOneWidget);
      // confirm field exists
      expect(find.byType(TextField), findsNWidgets(2));
    });
  });

  group('unlock sheet', () {
    testWidgets('wrong pass shows error, right pass pops true', (tester) async {
      final s = await makeAppState(prefs: {'autoLockSeconds': 0});
      addTearDown(s.dispose);
      await s.setVaultPassphrase('pw');
      s.lockVault();
      final results = <bool>[];
      await pumpHost(tester, s, (ctx) async {
        results.add(await showUnlockSheet(ctx));
      });
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('Unlock vault'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'nope');
      await tester.tap(find.text('Unlock'));
      for (var i = 0;
          i < 10 && find.text('Wrong passphrase').evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Wrong passphrase'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'pw');
      await tester.tap(find.text('Unlock'));
      for (var i = 0; i < 10 && results.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(results, [true]);
      expect(s.vaultService.isUnlocked, isTrue);
    });
  });

  group('folder picker', () {
    testWidgets('pick folder then clear it', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final f = s.createFolder('Work');
      final n = s.createNote();
      await pumpHost(tester, s, (ctx) => showFolderPicker(ctx, n));
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('Move to folder'), findsOneWidget);
      await tester.tap(find.text('Work'));
      await settle(tester);
      expect(s.noteById(n.id)!.folderId, f.id);

      // Reopen against the now-foldered note and clear it.
      await tester.tap(find.text('go'));
      await settle(tester);
      await tester.tap(find.text('No folder'));
      await settle(tester);
      expect(s.noteById(n.id)!.folderId, isEmpty);
    });
  });

  group('tag editor', () {
    testWidgets('add via button, suggestion chip, delete chip', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final n = s.createNote();
      final other = s.createNote();
      await s.setTags(other, ['existing']);
      await pumpHost(tester, s, (ctx) => showTagEditor(ctx, n));
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('No tags yet'), findsOneWidget);
      // suggestion chip from another note's tags
      expect(find.text('existing'), findsOneWidget);
      await tester.tap(find.text('existing'));
      await settle(tester);
      expect(s.noteById(n.id)!.tags, contains('existing'));

      await tester.enterText(find.byType(TextField), 'fresh');
      await tester.tap(find.byIcon(Icons.add));
      await settle(tester);
      expect(s.noteById(n.id)!.tags, containsAll(['existing', 'fresh']));

      // submit path
      await tester.enterText(find.byType(TextField), 'third');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(s.noteById(n.id)!.tags, contains('third'));

      // delete a chip via its delete affordance
      final chip = find.widgetWithText(InputChip, 'fresh');
      await tester.tap(find.descendant(
          of: chip,
          matching: find.byWidgetPredicate(
              (w) => w is Icon && w.size == 18)));
      await settle(tester);
      expect(s.noteById(n.id)!.tags, isNot(contains('fresh')));
    });
  });

  group('color picker', () {
    testWidgets('pick a color then clear it', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final n = s.createNote();
      await pumpHost(tester, s, (ctx) => showColorPicker(ctx, n));
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('Note color'), findsOneWidget);
      // last dot = last palette entry
      await tester.tap(find.byType(InkWell).last);
      await settle(tester);
      expect(s.noteById(n.id)!.colorIndex,
          greaterThan(0));
      await tester.tap(find.text('go'));
      await settle(tester);
      // 'go' is the first InkWell; the clear dot comes right after
      await tester.tap(find.byType(InkWell).at(1));
      await settle(tester);
      expect(s.noteById(n.id)!.colorIndex, -1);
    });
  });

  group('empty trash', () {
    testWidgets('no dialog when trash is empty; confirm deletes', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpHost(tester, s, (ctx) => confirmEmptyTrash(ctx));
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('Empty trash?'), findsNothing);

      final n = s.createNote();
      await s.moveToTrash(n);
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('Empty trash?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(s.notesInTrash.length, 1);
      await tester.tap(find.text('go'));
      await settle(tester);
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(s.notesInTrash, isEmpty);
    });
  });

  group('manage folders', () {
    testWidgets('create, rename, delete, filter', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpHost(tester, s, (ctx) => showManageFolders(ctx));
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('Folders'), findsOneWidget);

      // create
      await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'Alpha');
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(s.folders.map((f) => f.name), contains('Alpha'));

      // rename
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'Beta');
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(s.folders.map((f) => f.name), contains('Beta'));

      // delete
      await tester.tap(find.byIcon(Icons.delete_outline));
      await settle(tester);
      await tester.tap(find.text('Delete folder'));
      await settle(tester);
      expect(s.folders, isEmpty);
    });

    testWidgets('tapping a folder filters and closes', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final f = s.createFolder('Pick');
      s.createNote();
      await pumpHost(tester, s, (ctx) => showManageFolders(ctx));
      await tester.tap(find.text('go'));
      await settle(tester);
      await tester.tap(find.text('Pick'));
      await settle(tester);
      expect(s.folderFilter, f.id);
      expect(find.text('Folders'), findsNothing);
    });
  });

  group('revisions', () {
    testWidgets('empty history shows placeholder', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final n = s.createNote();
      await pumpHost(tester, s, (ctx) => showRevisions(ctx, n));
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('No earlier versions'), findsOneWidget);
    });

    testWidgets('restore brings back an old version', (tester) async {
      final s = await makeAppState();
      addTearDown(s.dispose);
      final n = s.createNote();
      await s.updateNote(n, title: 'v1', body: 'first');
      await s.updateNote(n, title: 'v2', body: 'second',
          contentChanged: true);
      await pumpHost(tester, s, (ctx) => showRevisions(ctx, n));
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.text('v1'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await settle(tester);
      await tester.tap(find.text('Restore').last);
      await settle(tester);
      expect(s.noteById(n.id)!.body, 'first');
    });
  });

  group('markdown toolbar', () {
    Future<TextEditingController> pumpToolbar(WidgetTester tester) async {
      final controller = TextEditingController(text: 'hello world');
      controller.selection =
          const TextSelection(baseOffset: 0, extentOffset: 5);
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(
          tester,
          Scaffold(body: MarkdownToolbar(controller: controller)),
          s);
      return controller;
    }

    testWidgets('wrap buttons surround the selection', (tester) async {
      final c = await pumpToolbar(tester);
      await tester.tap(find.byIcon(Icons.format_bold));
      expect(c.text, '**hello** world');
      await tester.tap(find.byIcon(Icons.format_italic));
      await tester.tap(find.byIcon(Icons.strikethrough_s));
      await tester.tap(find.byIcon(Icons.code));
      await tester.tap(find.byIcon(Icons.link));
    });

    testWidgets('line prefixes insert at line start', (tester) async {
      final c = await pumpToolbar(tester);
      await tester.tap(find.text('H1'));
      expect(c.text, startsWith('# '));
      await tester.tap(find.text('H2'));
      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await tester.tap(find.byIcon(Icons.format_list_numbered));
      await tester.tap(find.byIcon(Icons.check_box_outlined));
      await tester.tap(find.byIcon(Icons.format_quote));
      await tester.tap(find.byIcon(Icons.horizontal_rule));
    });

    testWidgets('invalid selection appends', (tester) async {
      final controller = TextEditingController(text: 'abc');
      // leave selection invalid (-1)
      final s = await makeAppState();
      addTearDown(s.dispose);
      await pumpWithState(
          tester,
          Scaffold(body: MarkdownToolbar(controller: controller)),
          s);
      await tester.tap(find.byIcon(Icons.format_bold));
      expect(controller.text, 'abc**');
      await tester.tap(find.text('H1'));
      expect(controller.text, '# abc**');
    });
  });
}
