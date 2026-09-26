/// Persistence boundary. Everything the app stores goes through this
/// interface so tests can swap in [MemoryStorage] and the web build can swap
/// in a localStorage-backed implementation without touching app code.
abstract class Storage {
  Future<Map<String, dynamic>?> readJson(String path);
  Future<void> writeJson(String path, Map<String, dynamic> data);
  Future<void> delete(String path);

  /// Lists entry names (not full paths) directly under [dir].
  Future<List<String>> list(String dir);

  /// Directory used for user-facing exports.
  Future<String> exportDirectory();
}
