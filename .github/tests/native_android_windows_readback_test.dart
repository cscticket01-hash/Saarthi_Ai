import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../lib/windows_connect/managed_school_session.dart';
import '../../lib/windows_local_firestore.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual native Android capture -> cloud -> hosted Windows durable local read and newer-edit protection', () async {
    const school = 'vs-db8afb01a3be46a983c8284714d06e5d';
    const endpoint = 'https://saarthi-sync-v2-test.onrender.com/school-cloud';
    final run = '${Platform.environment['GITHUB_RUN_ID']}-${Platform.environment['GITHUB_RUN_ATTEMPT']}';
    if (!Platform.isWindows || Platform.environment['GITHUB_ACTIONS'] != 'true' ||
        Platform.environment['VS_TEST_CONNECT_CONFIRM'] != school) {
      throw StateError('Isolated hosted Windows TEST runner required');
    }
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    final report = <String,dynamic>{
      'scope': 'Hosted Windows production local-store classes read the actual Android API 35 emulator capture; no physical PC',
      'schoolId': school, 'status': 'RUNNING'
    };
    try {
      final proof = jsonDecode(await File('build/native-evidence/android-os.json').readAsString()) as Map;
      expect(proof['status'], 'PASS');
      expect(proof['schoolId'], school);
      expect(proof['windowsNoticeReadOnNativeAndroid'], true);
      expect(proof['syntheticPersonId'], 'synthetic-android-$run');
      expect(proof['originalCapturedAt'], isA<int>());
      final login = await ManagedSchoolSession.login(
        Platform.environment['VS_TEST_LOGIN_EMAIL']!, Platform.environment['VS_TEST_LOGIN_PASSWORD']!, endpoint: endpoint);
      expect(login['schoolId'], school);
      final watch = Stopwatch()..start();
      final reply = await ManagedSchoolSession.callForSchool(school, 'managed/records',
        {'operation':'read','collection':'attendance_records','syncProtocol':2});
      expect(reply['schoolId'], school);
      final entries = (reply['records'] as Map).entries.where((e) =>
        e.value is Map && e.value['personId'] == proof['syntheticPersonId']).toList();
      expect(entries, hasLength(1), reason:'Duplicate native capture must not create duplicate attendance');
      final entry = entries.single;
      final remote = Map<String,dynamic>.from(entry.value as Map);
      expect(remote['schoolId'], school);
      expect(remote['entryCapturedAt'], proof['originalCapturedAt']);
      expect(remote['_syncRevision'], isA<String>());
      report['windowsCloudReadMs'] = watch.elapsedMilliseconds;
      final folder = await Directory.systemTemp.createTemp('vs-native-windows-readback-');
      final db = FirebaseFirestore.instance;
      await db.changeLocalStorageLocation(folder.path);
      final profile = 'TEST-native-readback-$run';
      await db.switchProfile(profile, identity:{'schoolId':school,'schoolSyncId':school});
      final local = db.collection('attendance_records').doc(entry.key.toString());
      await db.applySyncedDocument(local, remote);
      expect((await local.get()).data()?['entryCapturedAt'], proof['originalCapturedAt']);
      await local.update({'syntheticOfflineNote':'Newer Windows edit retained'});
      await db.applySyncedDocument(local, remote);
      expect((await local.get()).data()?['syntheticOfflineNote'], 'Newer Windows edit retained');
      await db.resetVolatileSession();
      await db.switchProfile('TEST-away');
      await db.switchProfile(profile, identity:{'schoolId':school,'schoolSyncId':school});
      final restored = await db.collection('attendance_records').doc(entry.key.toString()).get();
      expect(restored.data()?['entryCapturedAt'], proof['originalCapturedAt']);
      expect(restored.data()?['syntheticOfflineNote'], 'Newer Windows edit retained');
      expect((await db.collection('_windows_firebase_outbox').get()).docs, hasLength(1));
      await expectLater(ManagedSchoolSession.callForSchool('vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'managed/records', {'operation':'read','collection':'attendance_records'}), throwsStateError);
      report.addAll({'status':'PASS','nativeAndroidToWindowsRecordIntegrity':true,
        'newerLocalEditProtected':true,'durableWindowsPending':1,
        'originalCapturedAt':proof['originalCapturedAt'],'foreignSchoolClientRejected':true});
    } catch (_) {
      report['status'] = 'FAIL';
      rethrow;
    } finally {
      await Directory('build/cloud-prerequisites').create(recursive:true);
      await File('build/cloud-prerequisites/native-windows-readback.json').writeAsString(jsonEncode(report));
      print('VS_NATIVE_WINDOWS_EVIDENCE ${jsonEncode(report)}');
    }
  }, timeout:const Timeout(Duration(minutes:5)));
}
