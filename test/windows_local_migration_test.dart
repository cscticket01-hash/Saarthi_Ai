import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/platform/platform_config.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_storage.dart';
import '../lib/windows_backend_bridge.dart';
import '../lib/windows_runtime_flags.dart';
void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 final db=FirebaseFirestore.instance;
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 setUp(() async {
  FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({'managed':true,'schoolId':school,'uid':'migration-review','projectId':platformProjectId,'endpoint':'https://unreachable.example/school-cloud','storageReady':false})});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  await db.switchProfile('migration-review',identity:{'schoolSyncId':school,'schoolId':school});
 });
  test('folder migration preserves original, rebases document paths, and rejects occupied/nested destinations', () async {
    final source = await WindowsLocalStorage.dataDirectory();
    final files = await WindowsLocalStorage.localFilesDirectory();
    await files.create(recursive: true);
    final original = File('${files.path}${Platform.pathSeparator}migration-original.pdf');
    await original.writeAsBytes([37,80,68,70,45,49,55,10], flush: true);
    await db.collection('documents').doc('migration-fixture').set({'schoolId':school,'originalPath':original.path,'originalUrl':original.uri.toString()});
    final sourceDb = await WindowsLocalStorage.databaseFile();
    final before = await sourceDb.readAsString();
    final root = await Directory.systemTemp.createTemp('vs-folder-review-');
    final occupied = Directory('${root.path}${Platform.pathSeparator}occupied');
    await occupied.create();
    await File('${occupied.path}${Platform.pathSeparator}${WindowsLocalStorage.databaseName}').writeAsString('existing school');
    await expectLater(WindowsBackendBridge.changeLocalStorageLocation(occupied.path), throwsStateError);
    expect(await WindowsLocalStorage.currentPath(), source.path);
    await expectLater(WindowsBackendBridge.changeLocalStorageLocation('${source.path}${Platform.pathSeparator}nested'), throwsStateError);
    final target = '${root.path}${Platform.pathSeparator}new-location';
    await WindowsBackendBridge.changeLocalStorageLocation(target);
    expect(await sourceDb.readAsString(), before);
    expect(await original.readAsBytes(), [37,80,68,70,45,49,55,10]);
    final record = (await db.collection('documents').doc('migration-fixture').get()).data()!;
    expect((record['originalPath'] as String).startsWith(target), true);
    expect(await File(record['originalPath'] as String).readAsBytes(), await original.readAsBytes());
    expect(Uri.parse(record['originalUrl'] as String).toFilePath(windows:Platform.isWindows), record['originalPath']);
    await WindowsLocalStorage.initialize();
    expect(await WindowsLocalStorage.currentPath(), target);
  });

}
