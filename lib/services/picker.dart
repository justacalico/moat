// coverage:ignore-file
import 'package:file_picker/file_picker.dart';

/// File-picking boundary so the rest of the app never touches the plugin.
class PickService {
  /// Swappable instance so tests can feed a path without the plugin.
  static PickService instance = PickService();

  /// Returns the chosen file's path, or null when cancelled.
  Future<String?> pickBackupFile() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Choose a Moat backup',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (files.isEmpty) return null;
    return files.single.path;
  }
}
