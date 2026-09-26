import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moat/ui/editor_page.dart';
import 'package:moat/ui/home_page.dart';
import 'package:moat/ui/lock_screen.dart';
import 'package:moat/ui/settings_page.dart';
import 'package:moat/ui/sync_page.dart';

import 'helpers/fakes.dart';

/// Rasterizers differ slightly between machines — allow a small pixel
/// diff instead of regenerating per host.
class TolerantGoldenComparator extends LocalFileComparator {
  TolerantGoldenComparator(super.testFile, this.tolerance);

  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
        imageBytes, await getGoldenBytes(golden));
    return result.passed || result.diffPercent <= tolerance;
  }
}

Future<void> settle(WidgetTester tester, [int times = 8]) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  goldenFileComparator = TolerantGoldenComparator(
      Uri.file('test/goldens_test.dart'), 0.5);

  testWidgets('golden: compact home', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    s.createFolder('Work');
    final n = s.createNote();
    await s.updateNote(n, title: 'Shopping', body: 'milk, eggs', );
    await s.setTags(n, ['errands']);
    await pumpWithState(tester, const NotesHomePage(), s,
        size: const Size(420, 840));
    await settle(tester);
    await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/home_compact.png'));
  });

  testWidgets('golden: wide home with selection bar', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    s.createFolder('Work', colorIndex: 1);
    s.createNote();
    await pumpWithState(tester, const NotesHomePage(), s,
        size: const Size(1400, 900));
    await settle(tester);
    await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/home_wide.png'));
  });

  testWidgets('golden: editor with toolbar', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    final n = s.createNote();
    await s.updateNote(n, title: 'Ideas', body: 'moat keeps notes safe');
    await pumpWithState(tester, EditorPage(noteId: n.id), s,
        size: const Size(500, 900));
    await settle(tester);
    await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/editor.png'));
    await tester.pumpWidget(const SizedBox());
    await settle(tester, 2);
  });

  testWidgets('golden: lock screen', (tester) async {
    final s = await makeAppState(prefs: {'autoLockSeconds': 0});
    addTearDown(s.dispose);
    await s.setVaultPassphrase('pw');
    s.lockVault();
    await pumpWithState(tester, const LockScreen(), s,
        size: const Size(420, 840));
    await tester.pump();
    await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/lock.png'));
  });

  testWidgets('golden: settings page', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    await pumpWithState(tester, const SettingsPage(), s,
        size: const Size(800, 1400));
    await settle(tester);
    await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/settings.png'));
  });

  testWidgets('golden: sync page', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    await pumpWithState(tester, const SyncPage(), s,
        size: const Size(800, 1400));
    await settle(tester);
    await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/sync.png'));
  });
}
