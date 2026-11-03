import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_storage.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_test_school_local_demo_seed.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school=WindowsTestSchoolLocalDemoSeed.schoolId;
  final db=FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key:jsonEncode({
        'managed':true,'projectId':platformProjectId,
        'schoolId':school,'uid':'qa-test-school-user',
        'folderId':'managed',
        'firebaseRefreshToken':'qa-test-only',
        'endpoint':'https://unreachable.example/school-cloud'
      })
    });
    expect(WindowsLocalStorage.sqliteEnabled,true);
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    final tmp=await Directory.systemTemp.createTemp('local-100k-demo-');
    await db.changeLocalStorageLocation(tmp.path);
    await db.switchProfile('qa-test-${DateTime.now().microsecondsSinceEpoch}',
        identity:{'schoolId':school,'schoolSyncId':school});
  });
  test('1001 durable local student rows use unique class/section/roll slots, no fake sync ACK', () async {
    await db.collection('students_directory').doc('real-student').set({
      'schoolId':school,'name':'Existing school pupil'});
    final queuedBefore=(await db.collection('_windows_firebase_outbox').get())
        .docs.map((e)=>e.data()['operationId']).toList();
    final steps=<int>[];
    final count=await WindowsTestSchoolLocalDemoSeed.create(
      count:1001,verifyActiveSchool:() async=>true,
      onProgress:(current,total){expect(total,1001);steps.add(current);});
    expect(count,1001);
    expect(steps,[250,500,750,1000,1001]);
    final rows=(await db.collection('students_directory').get()).docs;
    expect(rows,hasLength(1002));
    final seen=<String>{};
    for(final index in [1,61,1001]) {
      final record=(await db.collection('students_directory')
          .doc(WindowsTestSchoolLocalDemoSeed.idFor(index)).get()).data()!;
      expect(record['schoolId'],school);
      expect(record['studentClass'],startsWith('Class '));
      expect(record['rollNo'],index.toString());
      expect(record['syntheticTestLocal'],true);
      expect(record['qaSource'],'local-only-no-drive-ack');
      expect(record.containsKey('_syncRevision'),false);
      expect(seen.add('${record['class']}/${record['section']}/${record['rollNo']}'),true);
    }
    expect((await db.collection('students_directory').doc('real-student').get()).data()?['name'],
      'Existing school pupil');
    expect((await db.collection('_windows_firebase_outbox').get()).docs
       .map((e)=>e.data()['operationId']).toList(),queuedBefore);
    final again=await WindowsTestSchoolLocalDemoSeed.create(
      count:1001,verifyActiveSchool:()async=>true);
    expect(again,1001);
    expect((await db.collection('students_directory').get()).docs,hasLength(1002));
  });
  test('denies other schools, invalid session, and existing conflicting TEST IDs',() async {
    await expectLater(WindowsTestSchoolLocalDemoSeed.create(
      count:5,verifyActiveSchool:()async=>false),throwsStateError);
    final id=WindowsTestSchoolLocalDemoSeed.idFor(2);
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
      ()=>db.collection('students_directory').doc(id).set({
        'schoolId':school,'name':'Real pupil protected'}));
    await expectLater(WindowsTestSchoolLocalDemoSeed.create(
      count:5,verifyActiveSchool:()async=>true),throwsStateError);
    expect((await db.collection('students_directory').doc(id).get()).data()?['name'],
      'Real pupil protected');
    await db.switchProfile('foreign-profile', identity:{
      'schoolId':'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'schoolSyncId':'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'});
    await expectLater(WindowsTestSchoolLocalDemoSeed.create(
      count:5,verifyActiveSchool:()async=>true),throwsStateError);
  });
}
