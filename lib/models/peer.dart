/// A device discovered on the local network, paired or not.
class SyncPeer {
  SyncPeer({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.port,
    required this.lastSeen,
    this.paired = false,
  });

  final String deviceId;
  String name;
  String host;
  int port;
  DateTime lastSeen;
  bool paired;

  Duration get age => DateTime.now().difference(lastSeen);
  bool get isStale => age > const Duration(seconds: 30);

  String get shortId => deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;
}
