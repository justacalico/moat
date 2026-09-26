import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moat/ui/editor_page.dart';

import 'helpers/fakes.dart';

void main() {
  testWidgets('editor edits title and body', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    final n = s.createNote();
    await pumpWithState(tester, EditorPage(noteId: n.id), s,
        size: const Size(500, 900));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Title'), 'My title');
    await tester.enterText(
        find.widgetWithText(TextField, 'Start writing…'), 'Some **body**');
    await tester.pump();
    // toggle preview → triggers save + markdown render
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();
    final note = s.noteById(n.id)!;
    expect(note.title, 'My title');
    expect(note.body, 'Some **body**');
    expect(find.textContaining('My title'), findsWidgets);
  });

  testWidgets('editor menu: tags, color, delete flow', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    final n = s.createNote();
    await pumpWithState(tester, EditorPage(noteId: n.id), s,
        size: const Size(500, 900));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tags'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'tag1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(s.noteById(n.id)!.tags, contains('tag1'));
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('editor pin + archive via menu', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    final n = s.createNote();
    await pumpWithState(tester, EditorPage(noteId: n.id), s,
        size: const Size(500, 900));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.push_pin_outlined));
    await tester.pump();
    expect(n.pinned, isTrue);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pump();
    expect(n.archived, isTrue);
  });

  testWidgets('locked note shows unlock prompt', (tester) async {
    final s = await makeAppState(prefs: {'autoLockSeconds': 0});
    addTearDown(s.dispose);
    final n = s.createNote();
    await s.setVaultPassphrase('pw');
    await s.updateNote(n, title: 'S', body: 'secret body');
    await s.lockNote(n);
    s.lockVault();
    await pumpWithState(tester, EditorPage(noteId: n.id), s,
        size: const Size(500, 900));
    await tester.pumpAndSettle();
    expect(find.text('This note is locked'), findsOneWidget);
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Unlock vault'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'pw');
    await tester.tap(find.text('Unlock').last);
    for (var i = 0; i < 10 &&
        find.text('secret body').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('secret body'), findsOneWidget);
  });

  testWidgets('deleted note shows deleted state', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    await pumpWithState(tester, const EditorPage(noteId: 'gone'), s,
        size: const Size(500, 900));
    expect(find.text('Note deleted'), findsOneWidget);
  });
}
