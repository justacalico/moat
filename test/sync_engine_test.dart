import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moat/models/folder.dart';
import 'package:moat/models/note.dart';
import 'package:moat/models/peer.dart';
import 'package:moat/services/crypto_service.dart';
import 'package:moat/services/sync/discovery.dart';
import 'package:moat/services/sync/engine_io.dart';
import 'package:moat/services/sync/sync_store.dart';
import 'package:moat/services/vault.dart';
import 'package:cryptography/cryptography.dart';

/// In-memory SyncStore with LWW-by-clock merge, mirroring AppState's rules.
class MemStore implements SyncStore {
  final notes = <String, Note>{};
  final folders = <String, Folder>{};
  final Map<String, SecretKey> ltKeys = {};
  VaultRecord? vault;
  int appliedCalls = 0;

  @override
  List<Map<String, dynamic>> noteManifest() =>
      [for (final n in notes.values) {'id': n.id, 'clock': n.clock}];
  @override
  List<Map<String, dynamic>> folderManifest() =>
      [for (final f in folders.values) {'id': f.id, 'clock': f.clock}];
  @override
  Map<String, dynamic>? notePayload(String id) => notes[id]?.toJson();
  @override
  Map<String, dynamic>? folderPayload(String id) => folders[id]?.toJson();
  @override
  String applyRemoteNote(Map<String, dynamic> json) {
    final remote = Note.fromJson(json);
    final local = notes[remote.id];
    if (local == null) {
      notes[remote.id] = remote;
      return 'applied';
    }
    final order = _cmp(local.clock, remote.clock);
    if (order < 0) {
      notes[remote.id] = remote;
      return 'applied';
    }
    if (order == 2) {
      final copy = remote.asConflictCopy('${remote.id}-c');
      notes[copy.id] = copy;
      return 'conflict';
    }
    return 'kept-local';
  }

  @override
  String applyRemoteFolder(Map<String, dynamic> json) {
    final remote = Folder.fromJson(json);
    final local = folders[remote.id];
    if (local == null || _cmp(local.clock, remote.clock) <= 0) {
      folders[remote.id] = remote;
      return 'applied';
    }
    return 'kept-local';
  }

  @override
  VaultRecord? get vaultRecord => vault;
  @override
  bool adoptVaultRecord(Map<String, dynamic> json) {
    if (vault != null) return false;
    vault = VaultRecord.fromJson(json);
    return true;
  }

  @override
  SecretKey? ltKeyFor(String deviceId) => ltKeys[deviceId];
  @override
  void storeLtKey(String deviceId, String name, SecretKey key) =>
      ltKeys[deviceId] = key;
  @override
  void removeLtKey(String deviceId) => ltKeys.remove(deviceId);
  @override
  bool hasLtKey(String deviceId) => ltKeys.containsKey(deviceId);
  @override
  void onSyncApplied() => appliedCalls++;
}

int _cmp(Map<String, int> a, Map<String, int> b) {
  var ag = false, bg = false;
  for (final k in {...a.keys, ...b.keys}) {
    if ((a[k] ?? 0) > (b[k] ?? 0)) ag = true;
    if ((b[k] ?? 0) > (a[k] ?? 0)) bg = true;
  }
  if (ag && bg) return 2;
  if (ag) return 1;
  if (bg) return -1;
  return 0;
}

/// Builds an engine that discovers peers over unicast loopback UDP.
Future<IoSyncEngine> buildEngine(
    MemStore store, String id, String name) async {
  final crypto = CryptoService();
  // Each engine listens for announcements on its own UDP port; tests wire
  // announce targets explicitly.
  return IoSyncEngine(
    store: store,
    crypto: crypto,
    deviceId: id,
    deviceName: name,
    identity: await crypto.newIdentity(),
    autoSyncInterval: const Duration(milliseconds: 300),
    sessionTimeout: const Duration(seconds: 10),
  );
}

void main() {
  test('two engines discover, pair and replicate notes', () async {
    final storeA = MemStore();
    final storeB = MemStore();
    final cryptoA = CryptoService();
    final engineA = IoSyncEngine(
      store: storeA,
      crypto: cryptoA,
      deviceId: 'dev-a',
      deviceName: 'alice',
      identity: await cryptoA.newIdentity(),
      autoSyncInterval: const Duration(milliseconds: 200),
      discoveryEnabled: false,
    );
    final engineB = IoSyncEngine(
      store: storeB,
      crypto: cryptoA,
      deviceId: 'dev-b',
      deviceName: 'bob',
      identity: await cryptoA.newIdentity(),
      autoSyncInterval: const Duration(milliseconds: 200),
      discoveryEnabled: false,
    );
    addTearDown(engineA.dispose);
    addTearDown(engineB.dispose);
    await engineA.start();
    await engineB.start();

    // Wire discovery over loopback unicast so no multicast is needed.
    final discA = await UdpTransport.bind(0);
    final discB = await UdpTransport.bind(0);
    engineA.discovery = DiscoveryService(
      transport: discA,
      deviceId: 'dev-a',
      deviceName: 'alice',
      syncPort: engineA.syncPort,
      announceTo: [InternetAddress.loopbackIPv4],
      announcePort: discB.port,
      announceInterval: const Duration(milliseconds: 50),
      peerTtl: const Duration(seconds: 5),
    )..start();
    engineB.discovery = DiscoveryService(
      transport: discB,
      deviceId: 'dev-b',
      deviceName: 'bob',
      syncPort: engineB.syncPort,
      announceTo: [InternetAddress.loopbackIPv4],
      announcePort: discA.port,
      announceInterval: const Duration(milliseconds: 50),
      peerTtl: const Duration(seconds: 5),
    )..start();

    // wait for discovery
    var tries = 0;
    while ((engineA.peers.isEmpty || engineB.peers.isEmpty) && tries++ < 60) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(engineA.peers.single.deviceId, 'dev-b');
    expect(engineB.peers.single.deviceId, 'dev-a');

    // pair: B asks, A shows the code
    String? code;
    engineA.onPairRequest = (id, name) async => true;
    engineA.onShowPairCode = (c) => code = c;
    await engineB.pairWith(engineB.peers.single, () async {
      while (code == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return code!;
    });
    expect(storeB.ltKeys.containsKey('dev-a'), isTrue);
    expect(storeA.ltKeys.containsKey('dev-b'), isTrue);

    // make a note on A and sync it to B
    storeA.notes['n1'] = Note(
        id: 'n1',
        title: 'Hello',
        body: 'world',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        clock: {'dev-a': 1});
    storeA.folders['f1'] = Folder(
        id: 'f1', name: 'F', createdAt: DateTime(2026), clock: {'dev-a': 1});
    // Session teardown on the responder side is async; retry briefly so the
    // test isn't racing the previous session's cleanup.
    var synced = false;
    for (var i = 0; i < 40 && !synced; i++) {
      await engineB.syncNow();
      synced = storeB.notes['n1']?.title == 'Hello' &&
          storeB.folders['f1']?.name == 'F';
      if (!synced) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    expect(storeB.notes['n1']?.title, 'Hello');
    expect(storeB.folders['f1']?.name, 'F');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('syncNow no-ops when stopped or no paired peers', () async {
    final store = MemStore();
    final engine = await buildEngine(store, 'd1', 'x');
    addTearDown(engine.dispose);
    await engine.syncNow(); // not running
    await engine.start();
    await engine.syncNow(); // no peers
    expect(store.appliedCalls, 0);
    await engine.stop();
  });

  test('conflict produces a copy on the receiving side', () async {
    final storeA = MemStore();
    final storeB = MemStore();
    final cryptoA = CryptoService();
    final engineA = IoSyncEngine(
      store: storeA,
      crypto: cryptoA,
      deviceId: 'dev-a',
      deviceName: 'a',
      identity: await cryptoA.newIdentity(),
      autoSyncInterval: const Duration(hours: 1),
      discoveryEnabled: false,
    );
    final engineB = IoSyncEngine(
      store: storeB,
      crypto: cryptoA,
      deviceId: 'dev-b',
      deviceName: 'b',
      identity: await cryptoA.newIdentity(),
      autoSyncInterval: const Duration(hours: 1),
      discoveryEnabled: false,
    );
    addTearDown(engineA.dispose);
    addTearDown(engineB.dispose);
    await engineA.start();
    await engineB.start();

    // seed shared lt keys so pairing is skipped
    final lt = await cryptoA.newNoteKey();
    storeA.ltKeys['dev-b'] = lt;
    storeB.ltKeys['dev-a'] = lt;

    // same note edited on both devices without seeing each other
    storeA.notes['n'] = Note(
        id: 'n', title: 'A version', body: 'a', createdAt: DateTime(2026),
        updatedAt: DateTime(2026), clock: {'dev-a': 1});
    storeB.notes['n'] = Note(
        id: 'n', title: 'B version', body: 'b', createdAt: DateTime(2026),
        updatedAt: DateTime(2026), clock: {'dev-b': 1});

    final peerB = SyncPeer(
        deviceId: 'dev-b',
        name: 'b',
        host: InternetAddress.loopbackIPv4.address,
        port: engineB.syncPort,
        lastSeen: DateTime.now(),
        paired: true);
    var done = false;
    for (var i = 0; i < 40 && !done; i++) {
      await engineA.connectTo(peerB);
      done = storeA.notes.values
          .any((n) => n.title == 'B version (conflict)');
      if (!done) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    expect(storeA.notes['n']!.title, 'A version');
    expect(storeA.notes.values.any((n) => n.title == 'B version (conflict)'),
        isTrue);
    // B converged the same way (kept its own, filed ours as conflict)
    expect(storeB.notes['n']!.title, 'B version');
    expect(storeB.notes.values.any((n) => n.title == 'A version (conflict)'),
        isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
