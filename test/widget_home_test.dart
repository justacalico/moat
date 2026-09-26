import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moat/app_state.dart';
import 'package:moat/ui/app.dart';
import 'package:moat/ui/home_page.dart';
import 'package:moat/ui/widgets/empty_state.dart';
import 'package:moat/ui/widgets/note_card.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

void main() {
  testWidgets('compact layout shows welcome note and drawer', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    await pumpWithState(tester, const NotesHomePage(), s,
        size: const Size(420, 900));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Moat'), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsOneWidget);
    // open drawer
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('All notes'), findsWidgets);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Trash'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('wide layout shows three panes', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    await pumpWithState(tester, const NotesHomePage(), s,
        size: const Size(1400, 900));
    await tester.pumpAndSettle();
    expect(find.text('Moat'), findsWidgets);
    expect(find.text('All notes'), findsOneWidget);
    // editor placeholder visible with no selection
    expect(find.text('Select a note or start a new one'), findsOneWidget);
  });

  testWidgets('new note via FAB opens editor on compact', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    await pumpWithState(tester, const NotesHomePage(), s,
        size: const Size(420, 900));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsWidgets);
  });

  testWidgets('search filters list', (tester) async {
    final s = await makeAppState(prefs: {'seenWelcome': true});
    addTearDown(s.dispose);
    final n = s.createNote();
    await s.updateNote(n, title: 'Apple pie');
    await pumpWithState(tester, const NotesHomePage(), s,
        size: const Size(420, 900));
    await tester.enterText(
        find.widgetWithText(TextField, 'Search notes'), 'apple');
    await tester.pump();
    expect(find.text('Apple pie'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Search notes'), 'zzz');
    await tester.pump();
    expect(find.text('Apple pie'), findsNothing);
    expect(find.text('No matches'), findsOneWidget);
    // clear via suffix icon
    await tester.enterText(
        find.widgetWithText(TextField, 'Search notes'), 'apple');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(s.query, '');
  });

  testWidgets('long-press starts selection with batch bar', (tester) async {
    final s = await makeAppState(prefs: {'seenWelcome': true});
    addTearDown(s.dispose);
    s.createNote();
    await pumpWithState(tester, const NotesHomePage(), s,
        size: const Size(420, 900));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(NoteCard).first);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(s.selectionMode, isFalse);
  });

  testWidgets('NoteCard renders lock/pin/tags', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    final n = s.createNote();
    await s.updateNote(n, title: 'T', body: 'body text');
    await s.togglePin(n);
    await s.setTags(n, ['work']);
    await pumpWithState(
        tester,
        Scaffold(body: NoteCard(note: n, onTap: () {}, onLongPress: () {})),
        s);
    expect(find.text('T'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.text('work'), findsOneWidget);
    expect(find.text('body text'), findsOneWidget);
  });

  testWidgets('NoteCard locked placeholder', (tester) async {
    final s = await makeAppState(prefs: {'autoLockSeconds': 0});
    addTearDown(s.dispose);
    final n = s.createNote();
    await s.setVaultPassphrase('pw');
    await s.updateNote(n, title: 'Hidden', body: 'x');
    await s.lockNote(n);
    s.lockVault();
    await pumpWithState(
        tester, Scaffold(body: NoteCard(note: n)), s);
    expect(find.text('Locked note'), findsOneWidget);
    expect(find.text('Encrypted'), findsOneWidget);
  });

  testWidgets('EmptyState renders', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    await pumpWithState(
        tester,
        const EmptyState(
            icon: Icons.note, title: 'Empty', subtitle: 'hint'),
        s);
    expect(find.text('Empty'), findsOneWidget);
    expect(find.text('hint'), findsOneWidget);
  });

  testWidgets('MoatApp builds via provider', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: s,
      child: const MoatApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Moat'), findsOneWidget);
  });

  testWidgets('lock-on-start shows LockScreen', (tester) async {
    final s = await makeAppState(prefs: {
      'seenWelcome': true,
      'lockOnStart': true,
      'autoLockSeconds': 0,
    });
    addTearDown(s.dispose);
    await s.setVaultPassphrase('pw');
    s.lockVault();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: s,
      child: const MoatApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Moat is locked'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'wrong');
    await tester.tap(find.text('Unlock'));
    for (var i = 0; i < 10 &&
        find.text('Wrong passphrase').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('Wrong passphrase'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'pw');
    await tester.tap(find.text('Unlock'));
    for (var i = 0; i < 10 &&
        find.text('Moat is locked').evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('Moat is locked'), findsNothing);
  });
}
