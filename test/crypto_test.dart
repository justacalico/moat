import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moat/services/crypto_service.dart';

void main() {
  final crypto = CryptoService();

  test('seal/open round trip', () async {
    final key = await crypto.newNoteKey();
    final blob = await crypto.seal(key, utf8.encode('secret'));
    expect(blob.length, greaterThan(6));
    final plain = await crypto.open(key, blob);
    expect(utf8.decode(plain), 'secret');
  });

  test('open rejects wrong key and short blobs', () async {
    final k1 = await crypto.newNoteKey();
    final k2 = await crypto.newNoteKey();
    final blob = await crypto.seal(k1, utf8.encode('x'));
    await expectLater(crypto.open(k2, blob),
        throwsA(isA<SecretBoxAuthenticationError>()));
    await expectLater(
        crypto.open(k1, [1, 2, 3]), throwsA(isA<FormatException>()));
  });

  test('deriveKey is deterministic per passphrase+salt', () async {
    const params = KdfParams(memory: 8 * 1024, iterations: 1, parallelism: 1);
    final salt = crypto.randomBytes(16);
    final a = await crypto.deriveKey('pw', salt, params);
    final b = await crypto.deriveKey('pw', salt, params);
    final c = await crypto.deriveKey('other', salt, params);
    expect(await a.extractBytes(), await b.extractBytes());
    expect(await a.extractBytes(), isNot(await c.extractBytes()));
  });

  test('KdfParams json round trip', () {
    const p = KdfParams(memory: 1, iterations: 2, parallelism: 3, hashLength: 4);
    final c = KdfParams.fromJson(p.toJson());
    expect(c.memory, 1);
    expect(c.iterations, 2);
    expect(c.parallelism, 3);
    expect(c.hashLength, 4);
  });

  test('x25519 shared secret agrees both directions', () async {
    final a = await crypto.newIdentity();
    final b = await crypto.newIdentity();
    final sa = await crypto.sharedSecret(a, await b.extractPublicKey());
    final sb = await crypto.sharedSecret(b, await a.extractPublicKey());
    expect(await sa.extractBytes(), await sb.extractBytes());
  });

  test('identity seed round trip', () async {
    final id = await crypto.newIdentity();
    final seed = await crypto.identitySeed(id);
    final restored = await crypto.x25519FromSeed(seed);
    expect((await restored.extractPublicKey()).bytes,
        (await id.extractPublicKey()).bytes);
  });

  test('hkdf derives deterministic keys', () async {
    final k1 = await crypto.hkdf(
        SecretKey([1, 2, 3]), [4], utf8.encode('i'), 32);
    final k2 = await crypto.hkdf(
        SecretKey([1, 2, 3]), [4], utf8.encode('i'), 32);
    expect(await k1.extractBytes(), await k2.extractBytes());
  });

  test('hmac and fingerprint produce stable output', () async {
    final mac = await crypto.hmac(SecretKey([1]), [2]);
    expect(mac.length, 32);
    expect(await crypto.fingerprint([1, 2, 3]), hasLength(16));
  });

  test('b64 helpers round trip', () {
    final b = crypto.b64([1, 2, 3]);
    expect(crypto.unb64(b), [1, 2, 3]);
  });
}
