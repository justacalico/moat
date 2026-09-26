import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moat/app_state.dart';
import 'package:moat/models/note.dart';
import 'package:moat/models/peer.dart';
import 'package:moat/services/biometric.dart';
import 'package:moat/services/memory_storage.dart';
import 'package:moat/services/settings.dart';
import 'package:moat/services/crypto_service.dart';
import 'package:moat/services/sync/engine.dart';
import 'package:moat/services/vault.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// No-op sync engine for widget tests.
class FakeSyncEngine implements SyncEngine {
  List<SyncPeer> fakePeers = [];
  List<SyncEvent> fakeEvents = [];
  @override
  bool running = false;
  int syncNowCalls = 0;

  @override
  bool get supported => true;
  @override
  List<SyncPeer> get peers => fakePeers;
  @override
  List<SyncEvent> get events => fakeEvents;
  @override
  Stream<List<SyncPeer>> get peerStream => const Stream.empty();
  @override
  Stream<SyncEvent> get eventStream => const Stream.empty();
  @override
  Future<bool> Function(String, String)? onPairRequest;
  @override
  void Function(String)? onShowPairCode;
  @override
  Future<void> start() async => running = true;
  @override
  Future<void> stop() async => running = false;
  String? pairCode;
  @override
  Future<void> pairWith(
      SyncPeer peer, Future<String> Function() askCode) async {
    pairCode = await askCode();
  }
  @override
  Future<void> syncNow() async => syncNowCalls++;
  @override
  void unpair(String deviceId) {}
  @override
  void dispose() {}
}

class FakeBiometricGate implements BiometricGate {
  bool available = false;
  bool result = true;
  int calls = 0;

  @override
  Future<bool> get isAvailable async => available;
  @override
  Future<bool> authenticate(String reason) async {
    calls++;
    return result;
  }
}

/// Builds an AppState fully offline: memory storage, mocked prefs, fake
/// biometric gate, fake sync engine.
/// Argon2id with production parameters is too heavy for the fake-async zone
/// widget tests run in — this profile keeps the same code path real.
// Memory must stay below 800 blocks so Argon2id keeps the whole
// computation in the current isolate — spawned isolates can't report
// back inside the fake-async zone widget tests run in.
const fastKdf =
    KdfParams(memory: 64, iterations: 1, parallelism: 1);

Future<AppState> makeAppState({
  Map<String, Object> prefs = const {},
  FakeSyncEngine? sync,
  FakeBiometricGate? biometric,
  bool isWeb = false,
  bool fastVault = true,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final state = AppState(
    storage: MemoryStorage(),
    settings: await Settings.load(),
    vault: fastVault ? VaultService(kdf: fastKdf) : VaultService(),
    biometric: biometric ?? FakeBiometricGate(),
    sync: sync ?? FakeSyncEngine(),
    isWeb: isWeb,
  );
  await state.init();
  return state;
}

/// Pumps [child] under a provider supplying [state].
Future<void> pumpWithState(
    WidgetTester tester, Widget child, AppState state,
    {Size? size, Brightness brightness = Brightness.light}) async {
  if (size != null) {
    await tester.binding.setSurfaceSize(size);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: child,
      ),
    ),
  );
  await tester.pump();
}

Note makeNote({
  String id = 'n1',
  String title = 'Title',
  String body = 'body',
  DateTime? at,
}) {
  final t = at ?? DateTime(2026, 1, 1);
  return Note(
      id: id, title: title, body: body, createdAt: t, updatedAt: t, clock: {});
}
