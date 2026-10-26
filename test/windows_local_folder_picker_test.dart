import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:saarthi_ai/windows_local_folder_picker.dart';
class DirectoryPicker extends FileSelectorPlatform {
  int calls = 0;
  @override
  Future<String?> getDirectoryPath({String? initialDirectory, String? confirmButtonText}) async {
    calls++; expect(initialDirectory, 'C:/School'); expect(confirmButtonText, 'Select Folder');
    return 'D:/School';
  }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('default route invokes registered native directory picker API', () async {
    final original = FileSelectorPlatform.instance, picker = DirectoryPicker();
    FileSelectorPlatform.instance = picker;
    addTearDown(() => FileSelectorPlatform.instance = original);
    String? migrated;
    expect(await selectLocalStorageFolder(initialDirectory: 'C:/School',
      migrate: (path) async { migrated = path; }), isTrue);
    expect(picker.calls, 1); expect(migrated, 'D:/School');
  });
  test('folder selection delegates only selected path to verified migration', () async {
    final paths = <String>[];
    expect(await selectLocalStorageFolder(initialDirectory: 'C:/School',
      select: (initial) async { expect(initial, 'C:/School'); return 'D:/School'; },
      migrate: (path) async => paths.add(path)), isTrue);
    expect(paths, ['D:/School']);
  });
  test('cancel makes no migration or configuration change', () async {
    expect(await selectLocalStorageFolder(initialDirectory: 'C:/School',
      select: (_) async => null, migrate: (_) async => fail('must not migrate')), isFalse);
  });
  test('migration failure propagates and cannot report activated', () async {
    await expectLater(selectLocalStorageFolder(initialDirectory: 'C:/School',
      select: (_) async => 'D:/School', migrate: (_) async => throw StateError('verification failed')),
      throwsStateError);
  });
}
