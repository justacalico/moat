import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'package:moat/models/note.dart';
import 'package:moat/services/crypto_service.dart';
import 'package:moat/services/vault.dart';

void main() {
  test('lifecycle: set, lock, unlock, wrong passphrase', () async {
    final v = VaultService(kdf: fastKdf);
    expect(v.status, VaultStatus.none);
    expect(v.hasVault, isFalse);

    await v.setPassphrase('correct horse');
    expect(v.status, VaultStatus.unlocked);
    v.lock();
    expect(v.status, VaultStatus.locked);
    expect(await v.unlock('wrong'), isFalse);
    expect(await v.unlock('correct horse'), isTrue);
    expect(v.isUnlocked, isTrue);
  });

  test('record persists and reloads locked', () async {
    final v = VaultService(kdf: fastKdf);
    await v.setPassphrase('pw');
    final json = v.toJson();
    expect(json, isNotNull);

    final v2 = VaultService(kdf: fastKdf);
    v2.loadJson(json);
    expect(v2.hasVault, isTrue);
    expect(v2.status, VaultStatus.locked);
    expect(await v2.unlock('pw'), isTrue);

    v2.loadJson(null);
    expect(v2.hasVault, isFalse);
  });

  test('seal/open a note payload', () async {
    final v = VaultService(kdf: fastKdf);
    await v.setPassphrase('pw');
    final payload = await v.seal('title', 'body text');
    final back = await v.open(payload);
    expect(back.title, 'title');
    expect(back.body, 'body text');
  });

  test('reseal keeps same wrapped key', () async {
    final v = VaultService(kdf: fastKdf);
    await v.setPassphrase('pw');
    final p1 = await v.seal('t', 'b');
    final p2 = await v.reseal(p1, 't2', 'b2');
    expect(p2.wrappedKey, p1.wrappedKey);
    final back = await v.open(p2);
    expect(back.title, 't2');
  });

  test('seal throws when locked', () async {
    final v = VaultService(kdf: fastKdf);
    await expectLater(v.seal('a', 'b'), throwsStateError);
    await v.setPassphrase('pw');
    v.lock();
    await expectLater(v.seal('a', 'b'), throwsStateError);
  });

  test('open throws when locked / wrong key', () async {
    final v1 = VaultService(kdf: fastKdf);
    final v2 = VaultService(kdf: fastKdf);
    await v2.setPassphrase('pw2');
    await v1.setPassphrase('pw1');
    final p = await v1.seal('t', 'b');
    // different vault key cannot unwrap
    await expectLater(
        v2.open(p), throwsA(isA<SecretBoxAuthenticationError>()));
    v2.lock();
    await expectLater(v2.open(p), throwsStateError);
    await expectLater(v2.reseal(p, 'a', 'b'), throwsStateError);
  });

  test('changePassphrase re-wraps note keys', () async {
    final v = VaultService(kdf: fastKdf);
    await v.setPassphrase('old');
    final note = Note(
        id: 'n',
        title: '',
        body: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        clock: {},
        locked: true,
        lockedPayload: await v.seal('t', 'b'));
    final notes = await v.changePassphrase('new', [note]);
    expect(v.isUnlocked, isTrue);
    final back = await v.open(notes.first.lockedPayload!);
    expect(back.body, 'b');
    // old passphrase no longer opens
    v.lock();
    expect(await v.unlock('old'), isFalse);
    expect(await v.unlock('new'), isTrue);
  });

  test('changePassphrase requires unlocked vault', () async {
    final v = VaultService(kdf: fastKdf);
    await v.setPassphrase('a');
    v.lock();
    await expectLater(v.changePassphrase('b', []), throwsStateError);
  });

  test('changePassphrase skips notes without payloads', () async {
    final v = VaultService(kdf: fastKdf);
    await v.setPassphrase('a');
    final note = Note(
        id: 'n', title: '', body: '', createdAt: DateTime.now(),
        updatedAt: DateTime.now(), clock: {}, locked: true);
    await v.changePassphrase('b', [note]);
    expect(note.lockedPayload, isNull);
  });

  test('adoptRecord only when no vault exists', () {
    final v = VaultService(kdf: fastKdf);
    final rec = VaultRecord(
        salt: 's',
        params: const KdfParams(),
        verifierNonce: 'n',
        verifier: 'v');
    expect(v.adoptRecord(rec), isTrue);
    expect(v.record, rec);
    expect(v.adoptRecord(rec), isFalse);
  });

  test('VaultRecord json round trip', () {
    final rec = VaultRecord(
        salt: 's',
        params: const KdfParams(),
        verifierNonce: 'n',
        verifier: 'v');
    final c = VaultRecord.fromJson(rec.toJson());
    expect(c.salt, 's');
    expect(c.params.iterations, const KdfParams().iterations);
  });

  test('open with unlocked note edge: utf8 decode', () async {
    final v = VaultService(kdf: fastKdf);
    await v.setPassphrase('pw');
    final p = await v.seal('', '');
    final back = await v.open(p);
    expect(back.title, '');
    // non-string fields tolerated
    final payload = LockedPayload(
        ciphertext: p.ciphertext, nonce: '', wrappedKey: p.wrappedKey,
        keyNonce: '');
    expect(payload.toJson()['ciphertext'], p.ciphertext);
  });

  test('unlock returns false with no record', () async {
    final v = VaultService(kdf: fastKdf);
    expect(await v.unlock('x'), isFalse);
  });

  test('unlock fails on malformed verifier', () async {
    final v = VaultService(kdf: fastKdf);
    await v.setPassphrase('pw');
    final salt = v.record!.salt;
    final params = v.record!.params;
    v.loadJson({
      'salt': salt,
      'params': params.toJson(),
      'verifierNonce': '',
      'verifier': base64Encode([1, 2, 3]),
      'v': 1,
    });
    expect(await v.unlock('pw'), isFalse);
  });
}
