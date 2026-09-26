import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moat/models/peer.dart';
import 'package:moat/ui/settings_page.dart';
import 'package:moat/ui/sync_page.dart';

import 'helpers/fakes.dart';

void main() {
  testWidgets('settings renders all groups and toggles work', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    await pumpWithState(tester, const SettingsPage(), s,
        size: const Size(500, 1200));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('SECURITY'), findsOneWidget);
    expect(find.text('SYNC'), findsOneWidget);
    expect(find.text('DATA'), findsOneWidget);
    expect(find.text('ABOUT'), findsOneWidget);

    // toggle grid view — the first switch on the page is the note list toggle
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(s.settings.gridView, isTrue);
    // theme mode switch to dark
    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect(s.settings.themeMode, ThemeMode.dark);
    // scroll to bottom so all groups render
    await tester.dragUntilVisible(find.text('Moat'),
        find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('Moat'), findsWidgets);
  });

  testWidgets('sync page shows device card and empty peers', (tester) async {
    final s = await makeAppState();
    addTearDown(s.dispose);
    await pumpWithState(tester, const SyncPage(), s,
        size: const Size(500, 900));
    await tester.pumpAndSettle();
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.textContaining('No devices found'), findsOneWidget);
    await tester.tap(find.text('Sync now'));
    await tester.pump();
  });

  testWidgets('sync page lists peers with pair button', (tester) async {
    final sync = FakeSyncEngine();
    sync.fakePeers.add(SyncPeer(
        deviceId: 'peer-xyz',
        name: 'bob-phone',
        host: '192.168.1.5',
        port: 47395,
        lastSeen: DateTime.now()));
    final s = await makeAppState(sync: sync);
    addTearDown(s.dispose);
    await pumpWithState(tester, const SyncPage(), s,
        size: const Size(500, 900));
    await tester.pumpAndSettle();
    expect(find.text('bob-phone'), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
  });
}
