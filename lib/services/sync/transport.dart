import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// A framed byte pipe: [send] takes a payload, [incoming] yields payloads.
/// Frames on the wire are `[4-byte big-endian length][payload]`.
abstract class ByteLink {
  Stream<Uint8List> get incoming;
  Future<void> send(Uint8List frame);
  Future<void> close();
}

/// Maximum frame size — notes are text, 8 MiB is generous headroom.
const maxFrameSize = 8 * 1024 * 1024;

Uint8List encodeFrame(Uint8List payload) {
  final out = Uint8List(4 + payload.length);
  ByteData.sublistView(out).setUint32(0, payload.length);
  out.setRange(4, out.length, payload);
  return out;
}

/// A buffered frame source: frames received while nobody is listening queue
/// up and are replayed to the next subscriber. Sequential one-shot consumers
/// (like the handshake's read calls) therefore can't lose frames that arrived
/// between subscriptions.
class FrameHub {
  final _queue = Queue<Object>();
  final _subs = <StreamController<Uint8List>>[];
  bool _done = false;

  Stream<Uint8List> subscribe() {
    final c = StreamController<Uint8List>();
    while (_queue.isNotEmpty) {
      final event = _queue.removeFirst();
      if (event is Uint8List) {
        c.add(event);
      } else {
        c.addError(event);
      }
    }
    if (_done) {
      unawaited(c.close());
    } else {
      _subs.add(c);
      c.onCancel = () => _subs.remove(c);
    }
    return c.stream;
  }

  void emit(Uint8List frame) {
    if (_subs.isEmpty) {
      _queue.add(frame);
    } else {
      for (final s in List.of(_subs)) {
        s.add(frame);
      }
    }
  }

  void emitError(Object error) {
    if (_subs.isEmpty) {
      _queue.add(error);
    } else {
      for (final s in List.of(_subs)) {
        s.addError(error);
      }
    }
  }

  Future<void> close() async {
    _done = true;
    for (final s in List.of(_subs)) {
      await s.close();
    }
    _subs.clear();
  }
}

/// Incremental decoder for the length-prefixed frame format.
class FrameDecoder {
  final _buffer = <int>[];
  final _hub = FrameHub();
  bool _closed = false;

  Stream<Uint8List> get frames => _hub.subscribe();

  void add(List<int> chunk) {
    if (_closed) return;
    _buffer.addAll(chunk);
    while (_buffer.length >= 4) {
      final len = ByteData.sublistView(Uint8List.fromList(_buffer.sublist(0, 4)))
          .getUint32(0);
      if (len > maxFrameSize) {
        _hub.emitError(StateError('frame too large: $len'));
        close();
        return;
      }
      if (_buffer.length < 4 + len) break;
      _hub.emit(Uint8List.fromList(_buffer.sublist(4, 4 + len)));
      _buffer.removeRange(0, 4 + len);
    }
  }

  Future<void> close() async {
    _closed = true;
    await _hub.close();
  }
}

/// ByteLink over a real TCP socket.
class SocketLink implements ByteLink {
  SocketLink(this._socket) {
    _subscription = _socket.listen(
      _decoder.add,
      onError: (Object e) => _decoder.frames.isEmpty, // coverage:ignore-line
      onDone: () {
        _done.complete();
        _decoder.close();
      },
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final _decoder = FrameDecoder();
  final _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;

  Future<void> get done => _done.future;

  @override
  Stream<Uint8List> get incoming => _decoder.frames;

  @override
  Future<void> send(Uint8List frame) async {
    _socket.add(encodeFrame(frame));
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _decoder.close();
    await _socket.close().catchError((_) => _socket.destroy());
  }
}

/// In-memory loopback pair used by tests (and reachable from lib code that
/// wants a transport without sockets).
class MemoryLink implements ByteLink {
  /// Returns the two connected ends.
  static (MemoryLink, MemoryLink) pair() {
    final a = MemoryLink._();
    final b = MemoryLink._();
    a._remote = b;
    b._remote = a;
    return (a, b);
  }

  MemoryLink._();

  MemoryLink? _remote;
  final _hub = FrameHub();
  bool _closed = false;

  void deliver(Uint8List frame) {
    if (!_closed) _hub.emit(frame);
  }

  @override
  Stream<Uint8List> get incoming => _hub.subscribe();

  @override
  Future<void> send(Uint8List frame) async {
    _remote?.deliver(frame);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _remote?._hub.close();
    await _hub.close();
  }
}
