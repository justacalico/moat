import 'package:cryptography/cryptography.dart';

import '../vault.dart';

/// What the sync engine needs from the app's data layer. Implemented by
/// AppState; keeps the engine fully testable without Flutter widgets.
abstract class SyncStore {
  /// Compact per-note manifest entries for comparison.
  List<Map<String, dynamic>> noteManifest();
  List<Map<String, dynamic>> folderManifest();

  /// Full payloads for notes the peer asked for.
  Map<String, dynamic>? notePayload(String id);
  Map<String, dynamic>? folderPayload(String id);

  /// Merge result of pushing a remote replica in.
  /// Returns 'applied', 'kept-local', 'conflict', or 'ignored'.
  String applyRemoteNote(Map<String, dynamic> json);
  String applyRemoteFolder(Map<String, dynamic> json);

  VaultRecord? get vaultRecord;
  bool adoptVaultRecord(Map<String, dynamic> json);

  /// Long-term keys for paired devices, keyed by device id.
  SecretKey? ltKeyFor(String deviceId);
  void storeLtKey(String deviceId, String name, SecretKey key);
  void removeLtKey(String deviceId);
  bool hasLtKey(String deviceId);

  /// Called after a sync session so the store can persist merged changes.
  void onSyncApplied();
}
