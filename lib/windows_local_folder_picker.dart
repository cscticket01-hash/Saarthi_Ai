import 'package:file_selector/file_selector.dart' as files;

/// Native directory selection only. The existing bridge owns verified migration.
Future<bool> selectLocalStorageFolder({
  required String initialDirectory,
  required Future<void> Function(String) migrate,
  Future<String?> Function(String initialDirectory)? select,
}) async {
  final path = await (select?.call(initialDirectory) ??
      files.getDirectoryPath(
        initialDirectory: initialDirectory.isEmpty ? null : initialDirectory,
        confirmButtonText: 'Select Folder',
      ));
  if (path == null || path.trim().isEmpty) return false;
  await migrate(path);
  return true;
}
