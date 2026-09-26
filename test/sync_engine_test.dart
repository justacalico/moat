import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moat/models/folder.dart';
import 'package:moat/models/note.dart';
import 'package:moat/models/peer.dart';
import 'package:moat/services/crypto_service.dart';
import 'package:moat/services/sync/discovery.dart';
import 'package:moat/services/sync/engine_io.dart';
import 'package:moat/services/sync/handshake.dart';
import 'package:moat/services/sync/transport.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:moat/services/sync/engine.dart' show SyncEventKind;
import 'package:moat/services/sync/sync_store.dart';
import 'package:moat/services/vault.dart';
import 'package:cryptography/cryptography.dart';

import 'helpers/fakes.dart' show fastKdf;

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
    // Session teardown on the responder side is async — wait for it rather
    // than racing the dedup check with fresh connections.
    for (var i = 0; i < 100 && engineA.activeSessionCount > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    var synced = false;
    for (var i = 0; i < 40 && !synced; i++) {
      await engineB.syncNow();
      synced = storeB.notes['n1']?.title == 'Hello' &&
          storeB.folders['f1']?.name == 'F';
      if (!synced) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
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

  group('engine internals', () {
    test('getters expose peers, events and streams', () async {
      final engine = await shortEngine(MemStore(), 'd1');
      addTearDown(engine.dispose);
      expect(engine.supported, isTrue);
      expect(engine.peers, isEmpty);
      expect(engine.events, isEmpty);
      expect(engine.peerStream, isNotNull);
      expect(engine.eventStream, isNotNull);
      expect(engine.running, isFalse);
      await engine.start();
      expect(engine.running, isTrue);
      expect(engine.syncPort, greaterThan(0));
      await engine.stop();
      expect(engine.running, isFalse);
      await engine.start();
      engine.dispose();
    });

    test('pairWith a dead peer logs an error', () async {
      final engine = await shortEngine(MemStore(), 'd1');
      addTearDown(engine.dispose);
      await engine.start();
      await expectLater(
          engine.pairWith(
              SyncPeer(
                  deviceId: 'dev-dead',
                  name: 'ghost',
                  host: '127.0.0.1',
                  port: 1,
                  lastSeen: DateTime.now()),
              () async => '123456'),
          throwsA(anything));
      expect(
          await waitFor(() => engine.events
              .any((e) => e.message.contains('pairing failed'))),
          isTrue);
    });

    test('responder logs a malformed hello', () async {
      final engine = await shortEngine(MemStore(), 'srv');
      addTearDown(engine.dispose);
      await engine.start();
      final sock = await Socket.connect(
          InternetAddress.loopbackIPv4, engine.syncPort);
      addTearDown(() => sock.close());
      sock.add(encodeFrame(
          Uint8List.fromList(utf8.encode(jsonEncode({'type': 'junk'})))));
      await sock.flush();
      expect(
          await waitFor(() => engine.events
              .any((e) => e.kind == SyncEventKind.error)),
          isTrue);
    });

    test('oversize frame hits the generic error branch', () async {
      final engine = await shortEngine(MemStore(), 'srv');
      addTearDown(engine.dispose);
      await engine.start();
      final sock = await Socket.connect(
          InternetAddress.loopbackIPv4, engine.syncPort);
      addTearDown(() => sock.close());
      // claim a gigabyte frame — the decoder errors out mid-handshake
      sock.add(Uint8List(4)..buffer.asByteData().setUint32(0, 0x7fffffff));
      await sock.flush();
      expect(
          await waitFor(() => engine.events
              .any((e) => e.kind == SyncEventKind.error)),
          isTrue);
    });

    test('stalled session times out', () async {
      final crypto = CryptoService();
      final storeA = MemStore();
      final lt = await crypto.newNoteKey();
      storeA.ltKeys['cli'] = lt;
      final engine = await shortEngine(storeA, 'srv',
          session: const Duration(milliseconds: 300));
      addTearDown(engine.dispose);
      await engine.start();
      final sock = await Socket.connect(
          InternetAddress.loopbackIPv4, engine.syncPort);
      addTearDown(() => sock.close());
      final link = SocketLink(sock);
      final result = await Handshaker(
        crypto: crypto,
        deviceId: 'cli',
        deviceName: 'client',
        identity: await crypto.newIdentity(),
      ).initiate(link,
          want: 'sync',
          hooks: HandshakeHooks()..ltKeyFor = (_) => lt);
      // say nothing — the responder session must time itself out
      expect(
          await waitFor(() => engine.events
              .any((e) => e.message.contains('timed out')),
              tries: 40, millis: 100),
          isTrue);
      await result.channel.close();
    });

    test('a tampered frame ends the session', () async {
      final crypto = CryptoService();
      final storeA = MemStore();
      final lt = await crypto.newNoteKey();
      storeA.ltKeys['cli'] = lt;
      final engine = await shortEngine(storeA, 'srv',
          session: const Duration(seconds: 5));
      addTearDown(engine.dispose);
      await engine.start();
      final sock = await Socket.connect(
          InternetAddress.loopbackIPv4, engine.syncPort);
      final link = SocketLink(sock);
      addTearDown(link.close);
      await Handshaker(
        crypto: crypto,
        deviceId: 'cli',
        deviceName: 'client',
        identity: await crypto.newIdentity(),
      ).initiate(link,
          want: 'sync',
          hooks: HandshakeHooks()..ltKeyFor = (_) => lt);
      // one garbage frame — bad MAC kills the channel
      link.send(Uint8List.fromList(List.filled(48, 9)));
      expect(
          await waitFor(() => engine.activeSessionCount == 0,
              tries: 40, millis: 150),
          isTrue);
    });

    test('unpair forgets the long-term key', () async {
      final store = MemStore();
      store.ltKeys['dev-b'] = SecretKey(List.filled(32, 1));
      final engine = await shortEngine(store, 'd1');
      addTearDown(engine.dispose);
      engine.unpair('dev-b');
      expect(store.ltKeys.containsKey('dev-b'), isFalse);
      expect(
          engine.events.any((e) => e.message.contains('unpaired')), isTrue);
    });

    test('autoSyncTick connects to paired discovered peers', () async {
      final storeA = MemStore();
      final storeB = MemStore();
      final cryptoA = CryptoService();
      final lt = await cryptoA.newNoteKey();
      storeA.ltKeys['dev-b'] = lt;
      storeB.ltKeys['dev-a'] = lt;
      final engineA = await shortEngine(storeA, 'dev-a',
          auto: const Duration(milliseconds: 120));
      final engineB = await shortEngine(storeB, 'dev-b');
      addTearDown(engineA.dispose);
      addTearDown(engineB.dispose);
      await engineA.start();
      await engineB.start();
      // discovery that listens but never announces
      final discT = await UdpTransport.bind(0);
      engineA.discovery = DiscoveryService(
        transport: discT,
        deviceId: 'dev-a',
        deviceName: 'a',
        syncPort: engineA.syncPort,
        announceTo: const [],
        announceInterval: const Duration(hours: 1),
      )..start();
      // fabricate dev-b's announcement packet
      final sender = await UdpTransport.bind(0);
      sender.send(
          utf8.encode(jsonEncode({
            'type': 'moat-announce',
            'id': 'dev-b',
            'name': 'b',
            'port': engineB.syncPort,
            'v': 1,
          })),
          InternetAddress.loopbackIPv4,
          discT.port);
      expect(await waitFor(() =>
              engineA.peers.any((p) => p.deviceId == 'dev-b')),
          isTrue);
      engineA.discovery!.markPaired('dev-b', true);
      // the next tick must connectTo the paired peer on its own
      expect(
          await waitFor(() => engineA.events
              .any((e) => e.message.contains('synced')),
              tries: 60, millis: 100),
          isTrue);
      sender.close();
    });

    test('vault record syncs to a peer without one', () async {
      final crypto = CryptoService();
      final storeA = MemStore();
      final storeB = MemStore();
      final lt = await crypto.newNoteKey();
      storeA.ltKeys['dev-b'] = lt;
      storeB.ltKeys['dev-a'] = lt;
      final vault = VaultService(kdf: fastKdf);
      await vault.setPassphrase('pw');
      storeB.vault = vault.record;
      final engineA = await shortEngine(storeA, 'dev-a');
      final engineB = await shortEngine(storeB, 'dev-b');
      addTearDown(engineA.dispose);
      addTearDown(engineB.dispose);
      await engineA.start();
      await engineB.start();
      await engineA.connectTo(SyncPeer(
          deviceId: 'dev-b',
          name: 'b',
          host: '127.0.0.1',
          port: engineB.syncPort,
          lastSeen: DateTime.now(),
          paired: true));
      expect(await waitFor(() => storeA.vault != null), isTrue);
    });

    test('socket that closes mid-handshake hits the generic catch',
        () async {
      final engine = await shortEngine(MemStore(), 'srv');
      addTearDown(engine.dispose);
      await engine.start();
      final sock = await Socket.connect(
          InternetAddress.loopbackIPv4, engine.syncPort);
      await sock.close();
      expect(
          await waitFor(() => engine.events
              .any((e) => e.kind == SyncEventKind.error)),
          isTrue);
    });

    test('non-JSON hello frame is rejected', () async {
      final engine = await shortEngine(MemStore(), 'srv');
      addTearDown(engine.dispose);
      await engine.start();
      final sock = await Socket.connect(
          InternetAddress.loopbackIPv4, engine.syncPort);
      addTearDown(() => sock.destroy());
      sock.add(encodeFrame(
          Uint8List.fromList(utf8.encode('not json at all'))));
      await sock.flush();
      expect(
          await waitFor(() => engine.events
              .any((e) => e.kind == SyncEventKind.error)),
          isTrue);
    });

    test('hello with missing fields hits the generic catch', () async {
      final engine = await shortEngine(MemStore(), 'srv');
      addTearDown(engine.dispose);
      await engine.start();
      final sock = await Socket.connect(
          InternetAddress.loopbackIPv4, engine.syncPort);
      addTearDown(() => sock.destroy());
      // valid JSON + right type, but no pubkey — the cast blows up
      sock.add(encodeFrame(Uint8List.fromList(utf8.encode(
          jsonEncode({'type': 'hello', 'id': 'x', 'name': 'x'})))));
      await sock.flush();
      expect(
          await waitFor(() => engine.events
              .any((e) => e.message.contains('session error'))),
          isTrue);
    });

    test('pairWith a live engine that declines pairing', () async {
      final engineA = await shortEngine(MemStore(), 'd1');
      final engineB = await shortEngine(MemStore(), 'd2');
      addTearDown(engineA.dispose);
      addTearDown(engineB.dispose);
      await engineA.start();
      await engineB.start();
      // no onPairRequest on B — pairing is declined
      await expectLater(
          engineA.pairWith(
              SyncPeer(
                  deviceId: 'd2',
                  name: 'b',
                  host: '127.0.0.1',
                  port: engineB.syncPort,
                  lastSeen: DateTime.now()),
              () async => '123456'),
          throwsA(anything));
      expect(
          engineA.events.any((e) => e.message.contains('pairing failed')),
          isTrue);
    });

    test('connectTo a dead peer logs a sync failure', () async {
      final engine = await shortEngine(MemStore(), 'd1');
      addTearDown(engine.dispose);
      await engine.start();
      await engine.connectTo(SyncPeer(
          deviceId: 'dead',
          name: 'ghost',
          host: '127.0.0.1',
          port: 1,
          lastSeen: DateTime.now(),
          paired: true));
      expect(
          await waitFor(() => engine.events
              .any((e) => e.message.contains('failed'))),
          isTrue);
    });

    test('a second session to the same peer is deduped', () async {
      final crypto = CryptoService();
      final storeA = MemStore();
      final lt = await crypto.newNoteKey();
      storeA.ltKeys['cli'] = lt;
      final engine = await shortEngine(storeA, 'srv',
          session: const Duration(seconds: 10));
      addTearDown(engine.dispose);
      await engine.start();
      final sock = await Socket.connect(
          InternetAddress.loopbackIPv4, engine.syncPort);
      final link = SocketLink(sock);
      addTearDown(link.close);
      await Handshaker(
        crypto: crypto,
        deviceId: 'cli',
        deviceName: 'client',
        identity: await crypto.newIdentity(),
      ).initiate(link,
          want: 'sync',
          hooks: HandshakeHooks()..ltKeyFor = (_) => lt);
      expect(await waitFor(() => engine.activeSessionCount == 1),
          isTrue);
      // now a second outbound attempt to the same device id is a no-op
      await engine.connectTo(SyncPeer(
          deviceId: 'cli',
          name: 'client',
          host: '127.0.0.1',
          port: engine.syncPort,
          lastSeen: DateTime.now(),
          paired: true));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.activeSessionCount, 1);
      // a second inbound session with the same id dedupes inside _runSession
      final sock2 = await Socket.connect(
          InternetAddress.loopbackIPv4, engine.syncPort);
      final link2 = SocketLink(sock2);
      addTearDown(link2.close);
      unawaited(expectLater(link2.done, completes));
      await Handshaker(
        crypto: crypto,
        deviceId: 'cli',
        deviceName: 'client2',
        identity: await crypto.newIdentity(),
      ).initiate(link2,
          want: 'sync',
          hooks: HandshakeHooks()..ltKeyFor = (_) => lt);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.activeSessionCount, 1);
    });

    test('folders pull when the remote clock is newer', () async {
      final crypto = CryptoService();
      final storeA = MemStore();
      final storeB = MemStore();
      final lt = await crypto.newNoteKey();
      storeA.ltKeys['dev-b'] = lt;
      storeB.ltKeys['dev-a'] = lt;
      storeA.folders['f1'] = Folder(
          id: 'f1', name: 'old',
          createdAt: DateTime(2026), clock: {'dev-a': 1});
      storeB.folders['f1'] = Folder(
          id: 'f1', name: 'new',
          createdAt: DateTime(2026),
          clock: {'dev-a': 1, 'dev-b': 5});
      final engineA = await shortEngine(storeA, 'dev-a');
      final engineB = await shortEngine(storeB, 'dev-b');
      addTearDown(engineA.dispose);
      addTearDown(engineB.dispose);
      await engineA.start();
      await engineB.start();
      await engineA.connectTo(SyncPeer(
          deviceId: 'dev-b',
          name: 'b',
          host: '127.0.0.1',
          port: engineB.syncPort,
          lastSeen: DateTime.now(),
          paired: true));
      expect(await waitFor(() => storeA.folders['f1']!.name == 'new'),
          isTrue);
    });
  });
}

/// Helpers shared by the engine-internals group.
Future<IoSyncEngine> shortEngine(MemStore store, String id,
    {Duration session = const Duration(seconds: 2),
    Duration auto = const Duration(hours: 1)}) async {
  final crypto = CryptoService();
  return IoSyncEngine(
    store: store,
    crypto: crypto,
    deviceId: id,
    deviceName: id,
    identity: await crypto.newIdentity(),
    autoSyncInterval: auto,
    sessionTimeout: session,
    discoveryEnabled: false,
  );
}

Future<bool> waitFor(bool Function() cond,
    {int tries = 60, int millis = 50}) async {
  for (var i = 0; i < tries && !cond(); i++) {
    await Future<void>.delayed(Duration(milliseconds: millis));
  }
  return cond();
}
