import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import '../../models/peer.dart';
import '../crypto_service.dart';
import 'discovery.dart';
import 'engine.dart';
import 'handshake.dart';
import 'secure_channel.dart';
import 'sync_store.dart';
import 'transport.dart';

/// Builds the LAN sync engine. Matched by the web stub's no-op factory.
SyncEngine createPlatformSyncEngine({
  required SyncStore store,
  required CryptoService crypto,
  required String deviceId,
  required String deviceName,
  required SimpleKeyPair identity,
}) =>
    IoSyncEngine(
      store: store,
      crypto: crypto,
      deviceId: deviceId,
      deviceName: deviceName,
      identity: identity,
    );

/// LAN sync engine. Owns a TCP server for inbound sessions, a UDP discovery
/// service for finding peers, and drives manifest-based pull/push replication.
class IoSyncEngine implements SyncEngine {
  IoSyncEngine({
    required this.store,
    required this.crypto,
    required this.deviceId,
    required this.deviceName,
    required this.identity,
    this.discovery,
    this.autoSyncInterval = const Duration(seconds: 20),
    this.sessionTimeout = const Duration(seconds: 20),
  });

  final SyncStore store;
  final CryptoService crypto;
  final String deviceId;
  final String deviceName;
  final SimpleKeyPair identity;
  final Duration autoSyncInterval;
  final Duration sessionTimeout;

  /// Injected for tests; built lazily from real sockets in [start].
  DiscoveryService? discovery;

  ServerSocket? _server;
  StreamSubscription<Socket>? _serverSub;
  Timer? _autoSync;
  final _events = <SyncEvent>[];
  final _eventController = StreamController<SyncEvent>.broadcast();
  final _activeSessions = <String>{};
  bool _running = false;

  @override
  Future<bool> Function(String peerId, String peerName)? onPairRequest;
  @override
  void Function(String code)? onShowPairCode;

  @override
  bool get supported => true;
  @override
  bool get running => _running;
  @override
  List<SyncPeer> get peers => discovery?.known ?? const [];
  @override
  List<SyncEvent> get events => List.unmodifiable(_events);
  @override
  Stream<List<SyncPeer>> get peerStream =>
      discovery?.peers ?? const Stream.empty();
  @override
  Stream<SyncEvent> get eventStream => _eventController.stream;

  int get syncPort => _server?.port ?? 0;

  void _log(SyncEventKind kind, String message) {
    final event = SyncEvent(kind, message);
    _events.add(event);
    if (_events.length > 200) _events.removeAt(0);
    _eventController.add(event);
  }

  @override
  Future<void> start() async {
    if (_running) return;
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _serverSub = _server!.listen(_accept, onError: (_) {});

    discovery ??= DiscoveryService(
      transport: await UdpTransport.bind(DiscoveryService.defaultPort,
          multicastGroup: InternetAddress(DiscoveryService.defaultGroup)),
      deviceId: deviceId,
      deviceName: deviceName,
      syncPort: syncPort,
      announceTo: [
        InternetAddress(DiscoveryService.defaultGroup),
        InternetAddress('255.255.255.255'),
      ],
    );
    discovery!.start();
    _running = true;
    _autoSync = Timer.periodic(autoSyncInterval, (_) => _autoSyncTick());
    _log(SyncEventKind.info, 'listening on port $syncPort');
  }

  @override
  Future<void> stop() async {
    _running = false;
    _autoSync?.cancel();
    _autoSync = null;
    await _serverSub?.cancel();
    await _server?.close();
    _server = null;
    discovery?.stop();
    _log(SyncEventKind.info, 'sync stopped');
  }

  void _autoSyncTick() {
    if (!_running) return;
    discovery?.prune();
    for (final peer in peers) {
      if (peer.paired && !_activeSessions.contains(peer.deviceId)) {
        unawaited(_connectAndSync(peer));
      }
    }
  }

  Future<void> _accept(Socket socket) async {
    final link = SocketLink(socket);
    try {
      final result = await Handshaker(
        crypto: crypto,
        deviceId: deviceId,
        deviceName: deviceName,
        identity: identity,
      ).respond(link, hooks: _responderHooks());
      if (result.newLongTermKey != null) {
        store.storeLtKey(result.peerId, result.peerName, result.newLongTermKey!);
        discovery?.markPaired(result.peerId, true);
        _log(SyncEventKind.paired, 'paired with ${result.peerName}');
      }
      await _runSession(result.channel, result.peerId, result.peerName);
    } on HandshakeException catch (e) {
      _log(SyncEventKind.error, 'handshake failed: ${e.message}');
      await link.close();
    } catch (e) {
      _log(SyncEventKind.error, 'session error: $e');
      await link.close();
    }
  }

  HandshakeHooks _responderHooks() => HandshakeHooks()
    ..ltKeyFor = store.ltKeyFor
    ..confirmPair = onPairRequest
    ..showPairCode = onShowPairCode;

  @override
  Future<void> pairWith(
      SyncPeer peer, Future<String> Function() askCode) async {
    _log(SyncEventKind.info, 'pairing with ${peer.name}…');
    final socket = await Socket.connect(peer.host, peer.port,
        timeout: sessionTimeout);
    final link = SocketLink(socket);
    try {
      final result = await Handshaker(
        crypto: crypto,
        deviceId: deviceId,
        deviceName: deviceName,
        identity: identity,
      ).initiate(link,
          want: 'pair',
          hooks: HandshakeHooks()..askPairCode = askCode);
      if (result.newLongTermKey != null) {
        store.storeLtKey(result.peerId, result.peerName, result.newLongTermKey!);
        discovery?.markPaired(result.peerId, true);
      }
      _log(SyncEventKind.paired, 'paired with ${result.peerName}');
      await _runSession(result.channel, result.peerId, result.peerName);
    } catch (e) {
      _log(SyncEventKind.error, 'pairing failed: $e');
      await link.close();
      rethrow;
    }
  }

  @override
  Future<void> syncNow() async {
    if (!_running) {
      _log(SyncEventKind.info, 'sync is off');
      return;
    }
    final targets =
        peers.where((p) => p.paired && p.deviceId != deviceId).toList();
    if (targets.isEmpty) {
      _log(SyncEventKind.info, 'no paired peers in reach');
      return;
    }
    await Future.wait(targets.map(_connectAndSync));
  }

  Future<void> _connectAndSync(SyncPeer peer) async {
    if (_activeSessions.contains(peer.deviceId)) return;
    try {
      final socket = await Socket.connect(peer.host, peer.port,
          timeout: sessionTimeout);
      final link = SocketLink(socket);
      final result = await Handshaker(
        crypto: crypto,
        deviceId: deviceId,
        deviceName: deviceName,
        identity: identity,
      ).initiate(link,
          want: 'sync',
          hooks: HandshakeHooks()..ltKeyFor = store.ltKeyFor);
      await _runSession(result.channel, result.peerId, result.peerName);
    } catch (e) {
      _log(SyncEventKind.error, 'sync with ${peer.name} failed: $e');
    }
  }

  /// Manifest-driven exchange. Both sides run the same dance: send a manifest,
  /// answer the peer's want-list with a push, and apply the peer's push.
  Future<void> _runSession(
      SecureChannel channel, String peerId, String peerName) async {
    if (!_activeSessions.add(peerId)) {
      await channel.close();
      return;
    }
    _log(SyncEventKind.peer, 'connected to $peerName');
    var sent = 0;
    var received = 0;
    var wantSent = false;
    var pushSent = false;
    var pushReceived = false;

    Future<void> maybeFinish() async {
      if (wantSent && pushSent && pushReceived) {
        await channel.send({'type': 'bye'});
        await channel.close();
        store.onSyncApplied();
        _log(SyncEventKind.info,
            'synced with $peerName: ↑$sent ↓$received');
      }
    }

    final done = Completer<void>();
    final sub = channel.messages.listen((msg) async {
      try {
        switch (msg['type']) {
          case 'manifest':
            await channel.send(_wantMessage(msg));
            wantSent = true;
            break;
          case 'want':
            final push = _pushMessage(msg);
            sent += (push['notes'] as List).length +
                (push['folders'] as List).length;
            await channel.send(push);
            pushSent = true;
            break;
          case 'push':
            received += _applyPush(msg);
            pushReceived = true;
            break;
          case 'bye':
            done.complete();
            break;
        }
        await maybeFinish();
        if (done.isCompleted) await channel.close();
      } catch (e) {
        _log(SyncEventKind.error, 'sync message failed: $e');
        if (!done.isCompleted) done.complete();
      }
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    }, onError: (_) {
      if (!done.isCompleted) done.complete();
    });

    await channel.send({
      'type': 'manifest',
      'notes': store.noteManifest(),
      'folders': store.folderManifest(),
      'hasVault': store.vaultRecord != null,
    });

    await done.future.timeout(sessionTimeout, onTimeout: () async {
      _log(SyncEventKind.error, 'session with $peerName timed out');
      await channel.close();
    });
    await sub.cancel();
    _activeSessions.remove(peerId);
  }

  Map<String, dynamic> _wantMessage(Map<String, dynamic> manifest) {
    final localNotes = {
      for (final m in store.noteManifest()) m['id'] as String: m
    };
    final wantNotes = <String>[];
    for (final remote
        in (manifest['notes'] as List? ?? []).cast<Map>()) {
      final m = remote.cast<String, dynamic>();
      final local = localNotes[m['id']];
      if (local == null ||
          _remoteNewer(local['clock'], m['clock'])) {
        wantNotes.add(m['id'] as String);
      }
    }
    final localFolders = {
      for (final m in store.folderManifest()) m['id'] as String: m
    };
    final wantFolders = <String>[];
    for (final remote
        in (manifest['folders'] as List? ?? []).cast<Map>()) {
      final m = remote.cast<String, dynamic>();
      final local = localFolders[m['id']];
      if (local == null ||
          _remoteNewer(local['clock'], m['clock'])) {
        wantFolders.add(m['id'] as String);
      }
    }
    return {
      'type': 'want',
      'notes': wantNotes,
      'folders': wantFolders,
      'wantVault': store.vaultRecord == null && manifest['hasVault'] == true,
    };
  }

  bool _remoteNewer(Object? localClock, Object? remoteClock) {
    // Unknown locally, or remote strictly dominates / diverges — we want it
    // either way so conflicts converge on both devices.
    if (localClock == null) return true;
    final local = (localClock as Map).cast<String, int>();
    final remote = (remoteClock as Map).cast<String, int>();
    var remoteAhead = false;
    for (final k in {...local.keys, ...remote.keys}) {
      if ((remote[k] ?? 0) > (local[k] ?? 0)) remoteAhead = true;
    }
    return remoteAhead;
  }

  Map<String, dynamic> _pushMessage(Map<String, dynamic> want) {
    final notes = <Map<String, dynamic>>[];
    for (final id in (want['notes'] as List? ?? []).cast<String>()) {
      final payload = store.notePayload(id);
      if (payload != null) notes.add(payload);
    }
    final folders = <Map<String, dynamic>>[];
    for (final id in (want['folders'] as List? ?? []).cast<String>()) {
      final payload = store.folderPayload(id);
      if (payload != null) folders.add(payload);
    }
    final vault =
        want['wantVault'] == true ? store.vaultRecord?.toJson() : null;
    return {
      'type': 'push',
      'notes': notes,
      'folders': folders,
      'vault': ?vault,
    };
  }

  int _applyPush(Map<String, dynamic> push) {
    var count = 0;
    for (final raw in (push['folders'] as List? ?? []).cast<Map>()) {
      final result =
          store.applyRemoteFolder(raw.cast<String, dynamic>());
      if (result == 'applied' || result == 'conflict') count++;
    }
    for (final raw in (push['notes'] as List? ?? []).cast<Map>()) {
      final result = store.applyRemoteNote(raw.cast<String, dynamic>());
      if (result == 'applied' || result == 'conflict') count++;
      if (result == 'conflict') {
        _log(SyncEventKind.conflict, 'conflict copy kept for a note');
      }
    }
    final vault = push['vault'];
    if (vault is Map) {
      if (store.adoptVaultRecord(vault.cast<String, dynamic>())) {
        _log(SyncEventKind.received, 'adopted vault settings from peer');
      }
    }
    return count;
  }

  @override
  void unpair(String deviceId) {
    store.removeLtKey(deviceId);
    discovery?.markPaired(deviceId, false);
    _log(SyncEventKind.info, 'unpaired device');
  }

  @override
  void dispose() {
    stop();
    discovery?.dispose();
    _eventController.close();
  }
}
