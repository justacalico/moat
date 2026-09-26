import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Unlock gate for biometrics/device PIN. Injected into AppState so tests
/// can substitute [FakeBiometricGate].
abstract class BiometricGate {
  Future<bool> get isAvailable;
  Future<bool> authenticate(String reason);
}

class LocalAuthGate implements BiometricGate {
  LocalAuthGate([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> get isAvailable async {
    if (kIsWeb) return false;
    try {
      return await _auth.canCheckBiometrics ||
          await _auth.isDeviceSupported(); // coverage:ignore-line
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    if (kIsWeb) return false;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}
