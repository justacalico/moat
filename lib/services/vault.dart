import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../models/note.dart';
import 'crypto_service.dart';

enum VaultStatus { none, locked, unlocked }

/// Metadata persisted to disk. Never contains key material.
class VaultRecord {
  VaultRecord({
    required this.salt,
    required this.params,
    required this.verifierNonce,
    required this.verifier,
  });

  final String salt;
  final KdfParams params;
  final String verifierNonce;
  final String verifier;

  Map<String, dynamic> toJson() => {
        'salt': salt,
        'params': params.toJson(),
        'verifierNonce': verifierNonce,
        'verifier': verifier,
        'v': 1,
      };

  factory VaultRecord.fromJson(Map<String, dynamic> json) => VaultRecord(
        salt: json['salt'] as String,
        params:
            KdfParams.fromJson((json['params'] as Map).cast<String, dynamic>()),
        verifierNonce: json['verifierNonce'] as String,
        verifier: json['verifier'] as String,
      );
}

/// Owns the master key derived from the user's vault passphrase. Locked notes
/// keep a random per-note key wrapped (encrypted) under the master key, so the
/// passphrase never touches note payloads directly and can be rotated by
/// re-wrapping keys alone.
class VaultService {
  VaultService({CryptoService? crypto, this.kdf})
      : crypto = crypto ?? CryptoService();

  final CryptoService crypto;

  /// KDF profile for new vaults. Stored in the record so unlock always uses
  /// whatever the vault was created with — this only controls creation.
  final KdfParams? kdf;

  static const _verifierPlaintext = 'moat-vault-v1';

  VaultRecord? record;
  SecretKey? _masterKey;

  VaultStatus get status {
    if (record == null) return VaultStatus.none;
    return _masterKey == null ? VaultStatus.locked : VaultStatus.unlocked;
  }

  bool get hasVault => record != null;
  bool get isUnlocked => _masterKey != null;

  void lock() => _masterKey = null;

  Future<void> setPassphrase(String passphrase) async {
    final salt = crypto.randomBytes(16);
    final params = kdf ?? const KdfParams();
    final key = await crypto.deriveKey(passphrase, salt, params);
    final sealed = await crypto.seal(key, utf8.encode(_verifierPlaintext));
    record = VaultRecord(
      salt: crypto.b64(salt),
      params: params,
      verifierNonce: '',
      verifier: crypto.b64(sealed),
    );
    _masterKey = key;
  }

  /// Returns true when [passphrase] opens the vault.
  Future<bool> unlock(String passphrase) async {
    final rec = record;
    if (rec == null) return false;
    final key = await crypto.deriveKey(
        passphrase, crypto.unb64(rec.salt), rec.params);
    try {
      final plain = await crypto.open(key, crypto.unb64(rec.verifier));
      if (utf8.decode(plain) != _verifierPlaintext) return false;
      _masterKey = key;
      return true;
    } on SecretBoxAuthenticationError {
      return false;
    } on FormatException {
      return false;
    }
  }

  /// Re-wraps every locked note under a freshly derived key. Returns the notes
  /// that were re-wrapped so the caller can persist them. Requires the vault
  /// to be unlocked first.
  Future<List<Note>> changePassphrase(
      String newPassphrase, List<Note> lockedNotes) async {
    final oldKey = _masterKey;
    if (oldKey == null) {
      throw StateError('vault must be unlocked to change passphrase');
    }
    // Unwrap all note keys with the old master key first.
    final noteKeys = <String, SecretKey>{};
    for (final note in lockedNotes) {
      final payload = note.lockedPayload;
      if (payload == null) continue;
      noteKeys[note.id] = await _unwrapNoteKey(payload, oldKey);
    }
    await setPassphrase(newPassphrase);
    for (final note in lockedNotes) {
      final noteKey = noteKeys[note.id];
      final payload = note.lockedPayload;
      if (noteKey == null || payload == null) continue;
      final wrapped = await crypto.seal(
          _masterKey!, await noteKey.extractBytes());
      note.lockedPayload = LockedPayload(
        ciphertext: payload.ciphertext,
        nonce: '',
        wrappedKey: crypto.b64(wrapped),
        keyNonce: '',
      );
    }
    return lockedNotes;
  }

  /// Encrypts a note's title+body into a [LockedPayload]. The note's plaintext
  /// fields are cleared by the caller.
  Future<LockedPayload> seal(String title, String body) async {
    final key = _masterKey;
    if (key == null) throw StateError('vault is locked');
    final noteKey = await crypto.newNoteKey();
    final plain = jsonEncode({'title': title, 'body': body});
    final sealed = await crypto.seal(noteKey, utf8.encode(plain));
    final wrapped = await crypto.seal(key, await noteKey.extractBytes());
    return LockedPayload(
      ciphertext: crypto.b64(sealed),
      nonce: '',
      wrappedKey: crypto.b64(wrapped),
      keyNonce: '',
    );
  }

  /// Decrypts a locked note. Throws [SecretBoxAuthenticationError] when the
  /// current master key cannot unwrap it (e.g. note synced from a device with
  /// a different vault passphrase).
  Future<({String title, String body})> open(LockedPayload payload) async {
    final key = _masterKey;
    if (key == null) throw StateError('vault is locked');
    final noteKey = await _unwrapNoteKey(payload, key);
    final plain =
        await crypto.open(noteKey, crypto.unb64(payload.ciphertext));
    final decoded = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    return (
      title: decoded['title'] as String? ?? '',
      body: decoded['body'] as String? ?? '',
    );
  }

  /// Re-seals previously decrypted content under the note's existing key.
  Future<LockedPayload> reseal(LockedPayload payload, String title,
      String body) async {
    final key = _masterKey;
    if (key == null) throw StateError('vault is locked');
    final noteKey = await _unwrapNoteKey(payload, key);
    final plain = jsonEncode({'title': title, 'body': body});
    final sealed = await crypto.seal(noteKey, utf8.encode(plain));
    return LockedPayload(
      ciphertext: crypto.b64(sealed),
      nonce: '',
      wrappedKey: payload.wrappedKey,
      keyNonce: payload.keyNonce,
    );
  }

  Future<SecretKey> _unwrapNoteKey(
      LockedPayload payload, SecretKey master) async {
    final raw = await crypto.open(master, crypto.unb64(payload.wrappedKey));
    return SecretKey(raw);
  }

  Map<String, dynamic>? toJson() => record?.toJson();

  void loadJson(Map<String, dynamic>? json) {
    record = json == null ? null : VaultRecord.fromJson(json);
    _masterKey = null;
  }

  /// Adopts a vault record synced from another device. Only applied when this
  /// device has no vault yet; mismatched vaults are surfaced to the user.
  bool adoptRecord(VaultRecord remote) {
    if (record != null) return false;
    record = remote;
    _masterKey = null;
    return true;
  }
}
