import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto_service.dart';
import 'secure_channel.dart';
import 'transport.dart';

/// Outcome of a successful handshake.
class HandshakeResult {
  HandshakeResult({
    required this.channel,
    required this.peerId,
    required this.peerName,
    required this.paired,
    this.newLongTermKey,
  });

  final SecureChannel channel;
  final String peerId;
  final String peerName;

  /// True when the peer was already trusted (long-term key known).
  final bool paired;

  /// When a fresh pairing just ran, the long-term key both sides should store.
  final SecretKey? newLongTermKey;
}

/// Callback bundle the UI/store layer provides.
class HandshakeHooks {
  /// Look up the stored long-term key for a peer device id.
  SecretKey? Function(String deviceId)? ltKeyFor;

  /// Responder only: ask the user whether to accept a pairing request.
  /// Must return true to continue.
  Future<bool> Function(String peerId, String peerName)? confirmPair;

  /// Responder only: surface the generated pairing code to the user so the
  /// initiator can type it in.
  void Function(String code)? showPairCode;

  /// Initiator only: prompt for the code shown on the other device.
  Future<String> Function()? askPairCode;
}

/// One end of the Moat handshake. Both sides exchange ephemeral X25519 keys,
/// then authenticate with either a stored long-term key (reconnect) or a
/// 6-digit pairing code (first pair). Result is a [SecureChannel] whose
/// session key mixes the ECDH secret with the auth secret, so neither the
/// code nor the stored key alone is enough to read traffic.
class Handshaker {
  Handshaker({
    required this.crypto,
    required this.deviceId,
    required this.deviceName,
    required this.identity,
    this.timeout = const Duration(seconds: 30),
    Random? random,
  }) : _random = random ?? Random.secure();

  final CryptoService crypto;
  final String deviceId;
  final String deviceName;
  final SimpleKeyPair identity;
  final Duration timeout;
  final Random _random;

  Future<Map<String, dynamic>> _read(ByteLink link) async {
    try {
      return await readClear(link.incoming, timeout);
    } catch (_) {
      throw const HandshakeException('connection lost');
    }
  }

  Future<Uint8List> _pubBytes() async =>
      Uint8List.fromList((await identity.extractPublicKey()).bytes);

  Future<Map<String, dynamic>> _hello(
      Uint8List nonce, String want) async => {
        'type': 'hello',
        'id': deviceId,
        'name': deviceName,
        'pub': crypto.b64(await _pubBytes()),
        'nonce': crypto.b64(nonce),
        'want': want,
      };

  Future<SecretKey> _ecdh(Map<String, dynamic> peerHello) =>
      crypto.sharedSecret(
          identity,
          SimplePublicKey(
              crypto.unb64(peerHello['pub'] as String),
              type: KeyPairType.x25519));

  /// The auth secret (pairing code key or stored long-term key) is mixed into
  /// the HKDF salt so neither side can complete without it — an eavesdropper
  /// holding only the ECDH material cannot forge the proofs or the session.
  Future<SecretKey> _proofKey(
      SecretKey ecdh, SecretKey authSecret, Uint8List salt) async {
    final authBytes = await authSecret.extractBytes();
    return crypto.hkdf(
        ecdh,
        Uint8List.fromList([...salt, ...authBytes]),
        utf8.encode('moat-auth-v1'),
        32);
  }

  Future<SecretKey> _sessionKey(
      SecretKey ecdh, SecretKey authSecret, Uint8List salt) async {
    final authBytes = await authSecret.extractBytes();
    return crypto.hkdf(
        ecdh,
        Uint8List.fromList([...salt, ...authBytes]),
        utf8.encode('moat-session-v1'),
        32);
  }

  /// Initiator side. [want] is `'sync'` for trusted peers or `'pair'` for a
  /// first-time pairing (hooks.askPairCode supplies the code).
  Future<HandshakeResult> initiate(
    ByteLink link, {
    required String want,
    required HandshakeHooks hooks,
  }) async {
    final nonceI = crypto.randomBytes(16);
    await sendClear(link, await _hello(nonceI, want));
    final peerHello = await _read(link);
    if (peerHello['type'] != 'hello') {
      throw const HandshakeException('expected hello');
    }
    if (peerHello['accept'] != true) {
      throw HandshakeException(
          'peer rejected: ${peerHello['reason'] ?? 'unknown'}');
    }
    final peerId = peerHello['id'] as String;
    final peerName = peerHello['name'] as String? ?? 'device';
    final nonceR = crypto.unb64(peerHello['nonce'] as String);
    final ecdh = await _ecdh(peerHello);

    SecretKey authSecret;
    SecretKey? newLtKey;
    final paired = want == 'sync';
    if (paired) {
      authSecret = hooks.ltKeyFor?.call(peerId) ??
          (throw const HandshakeException('peer not paired'));
    } else {
      final code = await hooks.askPairCode?.call() ??
          (throw const HandshakeException('pairing cancelled'));
      authSecret = await _pairingKey(code, peerId);
    }

    final salt = _joinedSalt(nonceI, nonceR);
    final proofKey = await _proofKey(ecdh, authSecret, salt);
    await sendClear(link, {
      'type': 'auth',
      'proof': crypto.b64(await crypto.hmac(
          proofKey, [...utf8.encode('I'), ...nonceR])),
    });
    final authReply = await _read(link);
    if (authReply['type'] != 'auth') {
      throw const HandshakeException('expected auth reply');
    }
    final expected = await crypto.hmac(
        proofKey, [...utf8.encode('R'), ...nonceI]);
    if (!listEquals(
        crypto.unb64(authReply['proof'] as String), expected)) {
      throw const HandshakeException('peer failed proof');
    }

    final session = await _sessionKey(ecdh, authSecret, salt);
    if (!paired) {
      newLtKey =
          await crypto.hkdf(session, const [], utf8.encode('moat-lt-v1'), 32);
    }
    final channel = SecureChannel(link, session, crypto)..listen();
    return HandshakeResult(
      channel: channel,
      peerId: peerId,
      peerName: peerName,
      paired: paired,
      newLongTermKey: newLtKey,
    );
  }

  /// Responder side. For `'pair'` requests the hooks decide whether to accept
  /// and surface the generated code; for `'sync'` the peer must be trusted.
  Future<HandshakeResult> respond(
      ByteLink link, {required HandshakeHooks hooks}) async {
    final peerHello = await _read(link);
    if (peerHello['type'] != 'hello') {
      throw const HandshakeException('expected hello');
    }
    final peerId = peerHello['id'] as String;
    final peerName = peerHello['name'] as String? ?? 'device';
    final want = peerHello['want'] as String? ?? 'sync';
    final nonceI = crypto.unb64(peerHello['nonce'] as String);
    final ecdh = await _ecdh(peerHello);
    final nonceR = crypto.randomBytes(16);

    SecretKey authSecret;
    SecretKey? newLtKey;
    if (want == 'pair') {
      final ok = await hooks.confirmPair?.call(peerId, peerName) ?? false;
      if (!ok) {
        await sendClear(link, await _reject(nonceR, 'declined'));
        throw const HandshakeException('pairing declined');
      }
      final code = _generateCode();
      hooks.showPairCode?.call(code);
      authSecret = await _pairingKey(code, peerId);
      await sendClear(link, await _acceptHello(nonceR));
    } else {
      final lt = hooks.ltKeyFor?.call(peerId);
      if (lt == null) {
        await sendClear(link, await _reject(nonceR, 'not-paired'));
        throw const HandshakeException('peer not paired');
      }
      authSecret = lt;
      await sendClear(link, await _acceptHello(nonceR));
    }

    final salt = _joinedSalt(nonceI, nonceR);
    final proofKey = await _proofKey(ecdh, authSecret, salt);
    final authMsg = await _read(link);
    if (authMsg['type'] != 'auth') {
      throw const HandshakeException('expected auth');
    }
    final expected = await crypto.hmac(
        proofKey, [...utf8.encode('I'), ...nonceR]);
    if (!listEquals(crypto.unb64(authMsg['proof'] as String), expected)) {
      throw const HandshakeException('peer failed proof');
    }
    await sendClear(link, {
      'type': 'auth',
      'proof': crypto.b64(
          await crypto.hmac(proofKey, [...utf8.encode('R'), ...nonceI])),
    });

    final session = await _sessionKey(ecdh, authSecret, salt);
    if (want == 'pair') {
      newLtKey =
          await crypto.hkdf(session, const [], utf8.encode('moat-lt-v1'), 32);
    }
    final channel = SecureChannel(link, session, crypto)..listen();
    return HandshakeResult(
      channel: channel,
      peerId: peerId,
      peerName: peerName,
      paired: want != 'pair',
      newLongTermKey: newLtKey,
    );
  }

  Future<Map<String, dynamic>> _reject(
          Uint8List nonce, String reason) async => {
        'type': 'hello',
        'id': deviceId,
        'name': deviceName,
        'pub': crypto.b64(await _pubBytes()),
        'nonce': crypto.b64(nonce),
        'accept': false,
        'reason': reason,
      };

  Future<Map<String, dynamic>> _acceptHello(Uint8List nonce) async =>
      {
        'type': 'hello',
        'id': deviceId,
        'name': deviceName,
        'pub': crypto.b64(await _pubBytes()),
        'nonce': crypto.b64(nonce),
        'accept': true,
      };

  Uint8List _joinedSalt(Uint8List a, Uint8List b) =>
      Uint8List.fromList([...a, ...b]);

  Future<SecretKey> _pairingKey(String code, String peerId) {
    final ids = [deviceId, peerId]..sort();
    return crypto.hkdf(
      SecretKey(utf8.encode(code.trim())),
      utf8.encode('moat-pair-v1'),
      utf8.encode(ids.join('|')),
      32,
    );
  }

  String _generateCode() =>
      (100000 + _random.nextInt(900000)).toString();

  bool listEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class HandshakeException implements Exception {
  const HandshakeException(this.message);
  final String message;
  @override
  String toString() => 'HandshakeException: $message';
}
