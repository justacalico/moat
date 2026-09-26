import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Tunable Argon2id parameters. Stored alongside the vault so a passphrase
/// change or a param bump can re-derive keys deterministically.
class KdfParams {
  const KdfParams({
    this.memory = 32 * 1024,
    this.iterations = 2,
    this.parallelism = 2,
    this.hashLength = 32,
  });

  final int memory;
  final int iterations;
  final int parallelism;
  final int hashLength;

  Map<String, dynamic> toJson() => {
        'memory': memory,
        'iterations': iterations,
        'parallelism': parallelism,
        'hashLength': hashLength,
      };

  factory KdfParams.fromJson(Map<String, dynamic> json) => KdfParams(
        memory: json['memory'] as int,
        iterations: json['iterations'] as int,
        parallelism: json['parallelism'] as int,
        hashLength: json['hashLength'] as int,
      );
}

/// All symmetric crypto in Moat goes through here so the primitives stay in
/// one audited place.
class CryptoService {
  CryptoService({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  final _aes = AesGcm.with256bits();
  final _x25519 = X25519();

  Uint8List randomBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  Future<SecretKey> deriveKey(
      String passphrase, Uint8List salt, KdfParams params) async {
    final argon = Argon2id(
      memory: params.memory,
      iterations: params.iterations,
      parallelism: params.parallelism,
      hashLength: params.hashLength,
    );
    return argon.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  /// AES-256-GCM with a fresh random nonce. The returned blob is
  /// `nonce(12) || ciphertext || mac(16)` — everything needed to reopen.
  Future<Uint8List> seal(SecretKey key, List<int> plaintext) async {
    final nonce = randomBytes(12);
    final box = await _aes.encrypt(plaintext, secretKey: key, nonce: nonce);
    final out = Uint8List(12 + box.cipherText.length + 16);
    out.setRange(0, 12, nonce);
    out.setRange(12, 12 + box.cipherText.length, box.cipherText);
    out.setRange(12 + box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  /// Reverses [seal]. Throws [SecretBoxAuthenticationError] on wrong keys
  /// or tampering.
  Future<Uint8List> open(SecretKey key, List<int> blob) async {
    if (blob.length < 12 + 16) {
      throw const FormatException('sealed blob too short');
    }
    final nonce = blob.sublist(0, 12);
    final macStart = blob.length - 16;
    final box = SecretBox(
      blob.sublist(12, macStart),
      nonce: nonce,
      mac: Mac(blob.sublist(macStart)),
    );
    final plain = await _aes.decrypt(box, secretKey: key);
    return Uint8List.fromList(plain);
  }

  /// Convenience: encrypt with a fresh ephemeral key. Returns everything a
  /// note needs to persist (ciphertext + the wrapped key material handled
  /// by the caller).
  Future<SecretKey> newNoteKey() => _aes.newSecretKey();

  Future<SimpleKeyPair> newIdentity() => _x25519.newKeyPair();

  /// Restores an identity from its stored private seed bytes.
  Future<SimpleKeyPair> x25519FromSeed(List<int> seed) =>
      _x25519.newKeyPairFromSeed(seed);

  /// Extracts the private seed bytes of an identity for persistence.
  Future<Uint8List> identitySeed(SimpleKeyPair pair) async {
    final data = await pair.extract();
    return Uint8List.fromList(data.bytes);
  }

  Future<SecretKey> sharedSecret(SimpleKeyPair mine, SimplePublicKey theirs) =>
      _x25519.sharedSecretKey(keyPair: mine, remotePublicKey: theirs);

  Future<SecretKey> hkdf(
      SecretKey input, List<int> salt, List<int> info, int length) {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
    return hkdf.deriveKey(secretKey: input, nonce: salt, info: info);
  }

  Future<Uint8List> hmac(SecretKey key, List<int> data) async {
    final mac = await Hmac.sha256().calculateMac(data, secretKey: key);
    return Uint8List.fromList(mac.bytes);
  }

  /// Short hex fingerprint for displaying key/device identity.
  Future<String> fingerprint(List<int> bytes) async {
    final digest = crypto.sha256.convert(bytes);
    return digest.toString().substring(0, 16);
  }

  String b64(List<int> bytes) => base64Encode(bytes);
  Uint8List unb64(String s) => base64Decode(s);
}
