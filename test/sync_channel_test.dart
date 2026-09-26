import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moat/services/crypto_service.dart';
import 'package:moat/services/sync/secure_channel.dart';
import 'package:moat/services/sync/transport.dart';

void main() {
  final crypto = CryptoService();

  Future<(SecureChannel, SecureChannel)> pairChannels() async {
    final key = await crypto.newNoteKey();
    final (la, lb) = MemoryLink.pair();
    final a = SecureChannel(la, key, crypto)..listen();
    final b = SecureChannel(lb, key, crypto)..listen();
    return (a, b);
  }

  test('encrypted JSON messages round trip', () async {
    final (a, b) = await pairChannels();
    final got = <Map<String, dynamic>>[];
    final sub = b.messages.listen(got.add);
    await a.send({'type': 'ping', 'n': 1});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(got.single['type'], 'ping');
    await a.close();
    await b.close();
    await sub.cancel();
  });

  test('tampered frames surface an error, not a message', () async {
    final key = await crypto.newNoteKey();
    final (la, lb) = MemoryLink.pair();
    final b = SecureChannel(lb, key, crypto)..listen();
    final errors = <Object>[];
    final msgs = <Map<String, dynamic>>[];
    final sub = b.messages.listen(msgs.add, onError: errors.add);
    // seal under the right key then corrupt the MAC byte
    final blob = await crypto.seal(key, utf8.encode('{"x":1}'));
    blob[blob.length - 1] ^= 0xFF;
    await la.send(blob);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(errors.length, 1);
    expect(msgs, isEmpty);
    await la.close();
    await b.close();
    await sub.cancel();
  });

  test('bad JSON inside a valid frame reports an error', () async {
    final key = await crypto.newNoteKey();
    final (la, lb) = MemoryLink.pair();
    final b = SecureChannel(lb, key, crypto)..listen();
    final errors = <Object>[];
    final msgs = <Map<String, dynamic>>[];
    final sub = b.messages.listen(msgs.add, onError: errors.add);
    // hand-seal malformed JSON under the right key
    await la.send(await crypto.seal(key, utf8.encode('not json')));
    // and a non-map JSON value
    await la.send(await crypto.seal(key, utf8.encode('[1,2]')));
    // and a too-short frame
    await la.send(Uint8List.fromList([1, 2]));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(errors.length, 1);
    expect(msgs, isEmpty);
    await la.close();
    await b.close();
    await sub.cancel();
  });

  test('onClosed fires when the link ends', () async {
    final key = await crypto.newNoteKey();
    final (la, lb) = MemoryLink.pair();
    var closed = false;
    SecureChannel(lb, key, crypto).listen(onClosed: () => closed = true);
    await la.close();
    await Future<void>.delayed(Duration.zero);
    expect(closed, isTrue);
  });

  test('sendClear/readClear exchange plain frames', () async {
    final (a, b) = MemoryLink.pair();
    await sendClear(a, {'type': 'hello', 'v': 1});
    final got = await readClear(b.incoming, const Duration(seconds: 1));
    expect(got['type'], 'hello');
    await a.close();
    await b.close();
  });

  test('readClear errors on non-object JSON and on close', () async {
    final (a, b) = MemoryLink.pair();
    await a.send(Uint8List.fromList(utf8.encode('[1]')));
    await expectLater(readClear(b.incoming, const Duration(seconds: 1)),
        throwsFormatException);
    await a.close();
    await expectLater(readClear(b.incoming, const Duration(seconds: 1)),
        throwsStateError);
    await b.close();
  });
}
