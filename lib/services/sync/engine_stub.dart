// coverage:ignore-file
import 'package:cryptography/cryptography.dart';

import '../../models/peer.dart';
import '../crypto_service.dart';
import 'engine.dart';
import 'sync_store.dart';

/// Web build gets a stub: browsers can't open TCP sockets or UDP, so peer
/// sync isn't offered there.
SyncEngine createPlatformSyncEngine({
  required SyncStore store,
  required CryptoService crypto,
  required String deviceId,
  required String deviceName,
  required SimpleKeyPair identity,
}) =>
    StubSyncEngine();

/// No-op engine for the web build.
class StubSyncEngine implements SyncEngine {
  final _events = <SyncEvent>[];

  @override
  bool get supported => false;
  @override
  bool get running => false;
  @override
  List<SyncPeer> get peers => const [];
  @override
  List<SyncEvent> get events => _events;
  @override
  Stream<List<SyncPeer>> get peerStream => const Stream.empty();
  @override
  Stream<SyncEvent> get eventStream => const Stream.empty();

  @override
  Future<bool> Function(String peerId, String peerName)? onPairRequest;
  @override
  void Function(String code)? onShowPairCode;

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> pairWith(
      SyncPeer peer, Future<String> Function() askCode) async {}
  @override
  Future<void> syncNow() async {}
  @override
  void unpair(String deviceId) {}
  @override
  void dispose() {}
}
