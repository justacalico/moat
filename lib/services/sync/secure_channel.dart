import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto_service.dart';
import 'transport.dart';

/// An encrypted JSON message pipe over a [ByteLink]. Every frame is a fresh
/// AES-GCM box under the session key; the random nonce travels with the
/// ciphertext.
class SecureChannel {
  SecureChannel(this._link, this._key, this._crypto);

  final ByteLink _link;
  final SecretKey _key;
  final CryptoService _crypto;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<Uint8List>? _sub;

  /// Starts decrypting incoming frames. Call exactly once after construction.
  void listen({void Function()? onClosed}) {
    _sub = _link.incoming.listen((frame) async {
      try {
        if (frame.length < 13) return;
        final plain = await _crypto.open(_key, frame);
        final msg = jsonDecode(utf8.decode(plain));
        if (msg is Map) {
          _messages.add(msg.cast<String, dynamic>());
        }
      } on SecretBoxAuthenticationError {
        _messages.addError(StateError('sync channel authentication failed'));
      } on FormatException {
        _messages.addError(StateError('bad sync message'));
      }
    }, onDone: () {
      _messages.close();
      onClosed?.call();
    });
  }

  Stream<Map<String, dynamic>> get messages => _messages.stream;

  Future<void> send(Map<String, dynamic> message) async {
    await _link
        .send(await _crypto.seal(_key, utf8.encode(jsonEncode(message))));
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _link.close();
    await _messages.close();
  }
}

/// Sends a plaintext (pre-handshake) JSON frame.
Future<void> sendClear(ByteLink link, Map<String, dynamic> msg) =>
    link.send(Uint8List.fromList(utf8.encode(jsonEncode(msg))));

/// Reads the next plaintext frame, decoding it as a JSON object.
Future<Map<String, dynamic>> readClear(
    Stream<Uint8List> stream, Duration timeout) async {
  final completer = Completer<Map<String, dynamic>>();
  late StreamSubscription<Uint8List> sub;
  sub = stream.listen((frame) {
    if (completer.isCompleted) return;
    try {
      final decoded = jsonDecode(utf8.decode(frame));
      if (decoded is Map) {
        completer.complete(decoded.cast<String, dynamic>());
      } else {
        completer.completeError(const FormatException('expected object'));
      }
    } on FormatException catch (e) {
      completer.completeError(e);
    }
  }, onError: completer.completeError, onDone: () {
    if (!completer.isCompleted) {
      completer.completeError(StateError('connection closed'));
    }
  });
  try {
    return await completer.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
}
