import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_connect/managed_record_media.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_settings.dart';
import '../lib/windows_local_auth.dart' as auth;
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_school_profile_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({
      'managed':true,'schoolId':school,'uid':'A','projectId':platformProjectId,
      'endpoint':'https://school.example/school-cloud','folderId':'managed',
      'firebaseRefreshToken':'saved-refresh','email':'a@example.com','storageReady':false,
    })});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    await db.switchProfile('local-first-${DateTime.now().microsecondsSinceEpoch}',
      identity:{'schoolId':school,'schoolSyncId':school});
  });
  test('offline school profile and images persist with location and pending outbox', () async {
    final profile = await WindowsSchoolProfileStore.saveLocal({
      'schoolName':'Saved school','principalName':'Principal','latitude':26.1,
      'longitude':93.1,'attendanceRadiusMeters':200,
      'logoBase64':'data:image/png;base64,YWJj',
    });
    expect(profile['logoUrl'],'data:image/png;base64,YWJj');
    final origin=db.activeProfileId;
    await db.switchProfile('other',identity:{'schoolSyncId':'other'});
    expect((await db.collection('school_config').doc('school_profile_cache').get()).exists,false);
    await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
    expect((await db.readSchoolRegistrationCache(school))?['schoolName'],'Saved school');
    expect((await db.collection('school_settings').doc('school_location').get()).data()?['radiusMeters'],200);
    expect((await db.collection('_windows_firebase_outbox').get()).docs.length,2);
  });
  test('a cloud acknowledgement cannot delete a newer local save', () async {
    final ref=db.collection('school_config').doc('school_profile_cache');
    await ref.set({'schoolName':'First'});
    final sent=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    await ref.set({'schoolName':'Second'});
    await db.acknowledgeOutbox(sent.reference,sent.data());
    final pending=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    expect((pending.data()['data'] as Map)['schoolName'],'Second');
    await db.acknowledgeOutbox(pending.reference,pending.data());
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  });
  test('managed images go to own Drive before text records; foreign uploads fail', () async {
    final data={'schoolId':school,'schoolName':'Saved','logoUrl':'data:image/png;base64,YWJj'};
    final safe=await prepareManagedRecord(data,school,(action,body) async {
      expect(action,'managed/file/upload');expect(body['base64'],'YWJj');
      return {'success':true,'schoolId':school,'fileId':'own-logo','fileUrl':'https://drive.google.com/file/d/own-logo/view'};
    });
    expect(safe['logoFileId'],'own-logo');expect(jsonEncode(safe),isNot(contains('base64')));
    await expectLater(prepareManagedRecord(data,school,(a,b) async => {'success':true,'schoolId':'other','fileId':'foreign','fileUrl':'foreign'}),throwsStateError);
    await expectLater(prepareManagedRecord({...data,'schoolId':'other'},school,(a,b) async => throw StateError('must not upload')),throwsStateError);
  });
  test('settings confirmation uses only App Lock without Firebase authentication', () async {
    await WindowsLocalSecurity.initialize();
    await WindowsLocalSecurity.create(adminId:'School app',password:'local-app-lock');
    final user=auth.User(email:'a@example.com',displayName:'School');
    await user.reauthenticateWithCredential(auth.AuthCredential(email:'a@example.com',password:'local-app-lock'));
    await expectLater(user.reauthenticateWithCredential(auth.AuthCredential(email:'a@example.com',password:'school-password')),throwsA(isA<auth.FirebaseAuthException>()));
    expect((await CentralSchoolCloud.saved())['firebaseRefreshToken'],'saved-refresh');
  });
}
