import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moat/services/sync/transport.dart';

void main() {
  test('encodeFrame prefixes big-endian length', () {
    final f = encodeFrame(Uint8List.fromList([1, 2, 3]));
    expect(f.length, 7);
    expect(f.sublist(0, 4), [0, 0, 0, 3]);
    expect(f.sublist(4), [1, 2, 3]);
  });

  test('FrameDecoder reassembles chunked frames', () async {
    final d = FrameDecoder();
    final frames = <Uint8List>[];
    final sub = d.frames.listen(frames.add);
    final payload = encodeFrame(Uint8List.fromList(List.filled(100, 7)));
    // feed byte by byte to force partial reads
    for (final b in payload) {
      d.add([b]);
    }
    await Future<void>.delayed(Duration.zero);
    expect(frames.single.length, 100);
    await d.close();
    await sub.cancel();
  });

  test('FrameDecoder rejects oversize frames', () async {
    final d = FrameDecoder();
    Object? error;
    final sub = d.frames.listen((_) {}, onError: (e) => error = e);
    d.add(Uint8List(4)..buffer.asByteData().setUint32(0, maxFrameSize + 1));
    await Future<void>.delayed(Duration.zero);
    expect(error, isA<StateError>());
    await sub.cancel();
  });

  test('FrameDecoder ignores input after close', () async {
    final d = FrameDecoder();
    await d.close();
    d.add(encodeFrame(Uint8List.fromList([1]))); // no-op
  });

  test('MemoryLink pair delivers both ways', () async {
    final (a, b) = MemoryLink.pair();
    final got = <List<int>>[];
    final sub = b.incoming.listen(got.add);
    await a.send(Uint8List.fromList([9]));
    await Future<void>.delayed(Duration.zero);
    expect(got.single, [9]);
    await a.close();
    await b.close();
    await sub.cancel();
  });

  test('MemoryLink close is safe without remote', () async {
    final (a, b) = MemoryLink.pair();
    await b.close();
    await a.send(Uint8List.fromList([1])); // delivers to closed peer: no-op
    await a.close();
  });

  test('SocketLink frames over a real loopback socket', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final serverDone = Completer<List<int>>();
    server.listen((socket) async {
      final link = SocketLink(socket);
      await for (final frame in link.incoming) {
        serverDone.complete(frame);
        await link.close();
        break;
      }
    });
    final client = SocketLink(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port));
    await client.send(Uint8List.fromList(utf8.encode('hello')));
    expect(utf8.decode(await serverDone.future), 'hello');
    await client.close();
  });
}
