import '../../models/peer.dart';

enum SyncEventKind { info, peer, paired, sent, received, conflict, error }

class SyncEvent {
  SyncEvent(this.kind, this.message) : at = DateTime.now();
  final DateTime at;
  final SyncEventKind kind;
  final String message;
}

/// Serverless sync contract. The native implementation does LAN discovery
/// plus encrypted TCP sessions; the web implementation is a no-op.
abstract class SyncEngine {
  bool get supported;
  bool get running;
  List<SyncPeer> get peers;
  List<SyncEvent> get events;
  Stream<List<SyncPeer>> get peerStream;
  Stream<SyncEvent> get eventStream;

  /// Responder-side pairing ask: return true to accept. Set by the UI layer.
  Future<bool> Function(String peerId, String peerName)? onPairRequest;

  /// Responder-side hook: show the code the other device must type.
  void Function(String code)? onShowPairCode;

  Future<void> start();
  Future<void> stop();

  /// Pair with a discovered peer. [askCode] prompts for the 6-digit code
  /// shown on the other device.
  Future<void> pairWith(
      SyncPeer peer, Future<String> Function() askCode);

  /// Pull/push with every paired peer currently visible.
  Future<void> syncNow();

  void unpair(String deviceId);
  void dispose();
}
