import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/peer.dart';

/// Thin wrapper over UDP so discovery can run on real sockets or test fakes.
abstract class DatagramTransport {
  void send(List<int> data, InternetAddress address, int port);
  Stream<Datagram> get datagrams;
  void close();
}

class UdpTransport implements DatagramTransport {
  UdpTransport._(this._socket);

  final RawDatagramSocket _socket;

  /// Binds a shared UDP socket on [port] and joins [multicastGroup] when one
  /// is given (tests pass null and announce over unicast instead).
  static Future<UdpTransport> bind(int port,
      {InternetAddress? multicastGroup}) async {
    final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, port,
        reuseAddress: true, reusePort: true);
    socket.broadcastEnabled = true;
    if (multicastGroup != null) {
      try {
        socket.joinMulticast(multicastGroup); // coverage:ignore-line
      } on OSError {
        // Interface without multicast support; broadcast still reaches
        // most LANs, so discovery keeps working.
      }
    }
    return UdpTransport._(socket);
  }

  /// The local UDP port this socket is bound to.
  int get port => _socket.port;

  @override
  void send(List<int> data, InternetAddress address, int port) {
    _socket.send(data, address, port);
  }

  @override
  Stream<Datagram> get datagrams =>
      _socket.where((e) => e == RawSocketEvent.read).map((_) {
        final d = _socket.receive();
        if (d == null) {
          return Datagram(Uint8List(0), InternetAddress.anyIPv4, 0); // coverage:ignore-line
        }
        return d;
      }).where((d) => d.data.isNotEmpty);

  @override
  void close() => _socket.close();
}

/// Announces this device on the LAN and keeps a table of heard peers.
///
/// Announcements go to the multicast group and the subnet broadcast address,
/// so discovery works on networks where one of the two is filtered.
class DiscoveryService {
  DiscoveryService({
    required this.transport,
    required this.deviceId,
    required this.deviceName,
    required this.syncPort,
    this.announceTo = const [],
    this.announcePort = defaultPort,
    this.announceInterval = const Duration(seconds: 4),
    this.peerTtl = const Duration(seconds: 30),
  });

  static const defaultGroup = '239.77.73.77';
  static const defaultPort = 47395;

  final DatagramTransport transport;
  final String deviceId;
  final String deviceName;
  final int syncPort;

  /// Addresses announcements are sent to (multicast group, broadcast, or a
  /// unicast target in tests).
  final List<InternetAddress> announceTo;

  /// UDP port announcements are sent to.
  final int announcePort;
  final Duration announceInterval;
  final Duration peerTtl;

  final _peers = <String, SyncPeer>{};
  final _peerController = StreamController<List<SyncPeer>>.broadcast();
  Timer? _announceTimer;
  StreamSubscription<Datagram>? _sub;
  bool _running = false;

  Stream<List<SyncPeer>> get peers => _peerController.stream;
  List<SyncPeer> get known =>
      _peers.values.where((p) => !p.isStale).toList(growable: false);

  void start() {
    if (_running) return;
    _running = true;
    _sub = transport.datagrams.listen(_onDatagram, onError: (_) {});
    _announce();
    _announceTimer =
        Timer.periodic(announceInterval, (_) => _announce());
  }

  void stop() {
    _running = false;
    _announceTimer?.cancel();
    _sub?.cancel();
  }

  void _announce() {
    if (!_running) return;
    prune();
    final packet = utf8.encode(jsonEncode({
      'type': 'moat-announce',
      'id': deviceId,
      'name': deviceName,
      'port': syncPort,
      'v': 1,
    }));
    for (final target in announceTo) {
      try {
        transport.send(packet, target, announcePort);
      } catch (_) {
        // A dead route shouldn't kill discovery.
      }
    }
  }

  void _onDatagram(Datagram d) {
    try {
      final msg = jsonDecode(utf8.decode(d.data));
      if (msg is! Map || msg['type'] != 'moat-announce') return;
      final id = msg['id'] as String?;
      if (id == null || id == deviceId) return;
      final port = msg['port'];
      if (port is! int || port <= 0 || port > 65535) return;
      final existing = _peers[id];
      if (existing == null) {
        _peers[id] = SyncPeer(
          deviceId: id,
          name: msg['name'] as String? ?? 'device',
          host: d.address.address,
          port: port,
          lastSeen: DateTime.now(),
        );
      } else {
        existing
          ..name = msg['name'] as String? ?? existing.name
          ..host = d.address.address
          ..port = port
          ..lastSeen = DateTime.now();
      }
      _peerController.add(known);
    } on FormatException {
      // Not a Moat packet — the port is shared, that's fine.
    }
  }

  /// Drops peers that stopped announcing. Returns ids that disappeared.
  List<String> prune() {
    final before = _peers.keys.toSet();
    _peers.removeWhere((_, p) => p.isStale);
    final removed = before.difference(_peers.keys.toSet()).toList();
    if (removed.isNotEmpty) _peerController.add(known);
    return removed;
  }

  void markPaired(String deviceId, bool paired) {
    final peer = _peers[deviceId];
    if (peer != null) {
      peer.paired = paired;
      _peerController.add(known);
    }
  }

  void dispose() {
    stop();
    _peerController.close();
    transport.close();
  }
}
