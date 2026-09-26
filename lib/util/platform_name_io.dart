import 'dart:io';

/// Hostname-based default device name for discovery ("alice's macbook" shows
/// up nicer in a peer list than "Moat device").
String platformDeviceName() {
  try {
    final host = Platform.localHostname;
    if (host.isNotEmpty) return host;
  } catch (_) {}
  return 'Moat ${Platform.operatingSystem}';
}
