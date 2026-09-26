import 'package:flutter_test/flutter_test.dart';
import 'package:moat/services/crypto_service.dart';
import 'package:moat/services/sync/handshake.dart';
import 'package:moat/services/sync/secure_channel.dart';
import 'package:moat/services/sync/transport.dart';

void main() {
  final crypto = CryptoService();

  Future<(Handshaker, Handshaker)> pair() async {
    final a = Handshaker(
      crypto: crypto,
      deviceId: 'device-a',
      deviceName: 'alice',
      identity: await crypto.newIdentity(),
      timeout: const Duration(milliseconds: 500),
    );
    final b = Handshaker(
      crypto: crypto,
      deviceId: 'device-b',
      deviceName: 'bob',
      identity: await crypto.newIdentity(),
      timeout: const Duration(milliseconds: 500),
    );
    return (a, b);
  }

  test('pairing flow produces a shared long-term key', () async {
    final (a, b) = await pair();
    final (la, lb) = MemoryLink.pair();
    String? shownCode;
    final responder = b.respond(lb,
        hooks: HandshakeHooks()
          ..confirmPair = (id, name) async {
            expect(id, 'device-a');
            expect(name, 'alice');
            return true;
          }
          ..showPairCode = (c) => shownCode = c);
    final initiator = a.initiate(la,
        want: 'pair',
        hooks: HandshakeHooks()
          ..askPairCode = () async {
            // wait until responder surfaced the code
            while (shownCode == null) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            return shownCode!;
          });
    final results = await Future.wait([initiator, responder]);
    expect(results[0].peerId, 'device-b');
    expect(results[1].peerId, 'device-a');
    expect(results[0].paired, isFalse);
    expect(results[0].newLongTermKey, isNotNull);
    expect(await results[0].newLongTermKey!.extractBytes(),
        await results[1].newLongTermKey!.extractBytes());
    await results[0].channel.close();
    await results[1].channel.close();
  });

  test('sync handshake authenticates with stored long-term key', () async {
    final (a, b) = await pair();
    final (la, lb) = MemoryLink.pair();
    final ltKey = await crypto.newNoteKey();
    final responder = b.respond(lb,
        hooks: HandshakeHooks()..ltKeyFor = (id) => ltKey);
    final initiator = a.initiate(la,
        want: 'sync',
        hooks: HandshakeHooks()..ltKeyFor = (id) => ltKey);
    final results = await Future.wait([initiator, responder]);
    expect(results[0].paired, isTrue);
    // channel carries messages
    final msgs = <Map>[];
    final sub = results[1].channel.messages.listen(msgs.add);
    await results[0].channel.send({'hello': 'there'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(msgs.single['hello'], 'there');
    await results[0].channel.close();
    await results[1].channel.close();
    await sub.cancel();
  });

  test('initiator without lt key fails', () async {
    final (a, b) = await pair();
    final (la, lb) = MemoryLink.pair();
    final responder = b.respond(lb,
        hooks: HandshakeHooks()..ltKeyFor = (id) => null);
    final initiator = a.initiate(la,
        want: 'sync',
        hooks: HandshakeHooks()..ltKeyFor = (id) => null);
    await Future.wait([
      expectLater(initiator, throwsA(isA<HandshakeException>())),
      expectLater(responder, throwsA(isA<HandshakeException>())),
    ]);
  });

  test('declined pairing rejects cleanly', () async {
    final (a, b) = await pair();
    final (la, lb) = MemoryLink.pair();
    final responder = b.respond(lb,
        hooks: HandshakeHooks()
          ..confirmPair = (id, name) async => false);
    final initiator = a.initiate(la,
        want: 'pair',
        hooks: HandshakeHooks()..askPairCode = () async => '000000');
    await Future.wait([
      expectLater(initiator, throwsA(isA<HandshakeException>())),
      expectLater(responder, throwsA(isA<HandshakeException>())),
    ]);
  });

  test('wrong code fails the proof', () async {
    final (a, b) = await pair();
    final (la, lb) = MemoryLink.pair();
    final responder = b.respond(lb,
        hooks: HandshakeHooks()
          ..confirmPair = (id, name) async {
              return true;
            }
          ..showPairCode = (_) {});
    final initiator = a.initiate(la,
        want: 'pair',
        hooks: HandshakeHooks()..askPairCode = () async => '999999');
    await Future.wait([
      expectLater(initiator, throwsA(isA<HandshakeException>())),
      expectLater(responder, throwsA(isA<HandshakeException>())),
    ]);
  });

  test('non-hello first message rejected', () async {
    final (_, b) = await pair();
    final (la, lb) = MemoryLink.pair();
    final responder = b.respond(lb, hooks: HandshakeHooks());
    await sendClear(la, {'type': 'nope'});
    await expectLater(responder, throwsA(isA<HandshakeException>()));
    await la.close();
    await lb.close();
  });
}
