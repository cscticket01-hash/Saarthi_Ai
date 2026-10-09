import 'dart:convert';
import 'package:image/image.dart' as img;
import '../lib/windows_backend_bridge.dart';
import '../lib/windows_school_operations.dart';
import '../lib/windows_school_image_cache.dart';
import '../lib/windows_connect/school_drive_images.dart';
import 'dart:typed_data';
import '../lib/windows_browser_print.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_school_profile_restore.dart';
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
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
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
  test('network failure retains durable data; later retry publishes only the original school',() async {
    await db.collection('teachers_directory').doc('same').set({'name':'School A teacher','schoolId':school,'photoUrl':'data:image/png;base64,YWJj'});
    final profile=db.activeProfileId;
    await expectLater(WindowsPendingSchoolSync.flush(profileId:profile,send:(c,id,op,data) async=>throw StateError('Network unavailable')),throwsStateError);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(1));
    await db.switchProfile('sync-school-B',identity:{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
    await expectLater(WindowsPendingSchoolSync.flush(profileId:profile,send:(c,id,op,data) async=>fail('Must not publish A as B')),throwsStateError);
    expect((await db.collection('teachers_directory').get()).docs,isEmpty);
    await db.switchProfile(profile,identity:{'schoolId':school,'schoolSyncId':school});
    await WindowsPendingSchoolSync.flush(profileId:profile,send:(c,id,op,data) async {
      expect(c,'teachers_directory');expect(data!['schoolId'],school);
      final safe=await prepareManagedRecord(data,school,(action,body) async=>{'success':true,'schoolId':school,'fileId':'own','fileUrl':'https://drive.google.com/file/d/own/view'});
      expect(safe['photoFileId'],'own');expect(safe['name'],'School A teacher');
    });
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  });
  test('sync retry never acknowledges edits saved while an older version was uploading',() async {
    final ref=db.collection('teachers_directory').doc('same');
    await ref.set({'name':'First'});
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(c,id,op,data) async {expect(data!['name'],'First');await ref.set({'name':'Second'});});
    expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(1));
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(c,id,op,data) async=>expect(data!['name'],'Second'));
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  });
  test('pending offline branding wins over stale Drive registration at startup',() async {
    final restored=await WindowsSchoolProfileRestore.resolveEnrollment(schoolId:school,
      localProfile:{'schoolId':school,'schoolName':'New offline name','principalName':'Principal','logoUrl':'data:image/png;base64,YWJj'},
      preferLocalProfile:true,call:(action,body) async {
        expect(action,'managed/profile');expect(body['operation'],'read');
        return {'success':true,'schoolId':school,'registrationState':'complete','storageReady':true,
          'profile':{'schoolId':school,'schoolName':'Old cloud name','principalName':'Principal'}};
      });
    expect(restored['schoolName'],'New offline name');expect(restored['logoUrl'],'data:image/png;base64,YWJj');
  });

  test('browser preview retains both print pages locally and fits printable paper',() {
    final html=WindowsBrowserPrint.html([(png:Uint8List.fromList([1,2,3]),width:638,height:1011),(png:Uint8List.fromList([4,5,6]),width:638,height:1011)]);
    expect('<section>'.allMatches(html),hasLength(2));
    expect(html,contains('AQID'));expect(html,contains('BAUG'));expect(html,contains('window.print()'));
    expect(html,contains('max-width:190mm;max-height:277mm;height:auto'));
    expect(html, isNot(contains('https://')));
  });

  test('uploaded Drive images remain available offline and never enter another school cache',() async {
    final origin=db.activeProfileId;
    await WindowsSchoolImageCache.store(school,'own-logo','data:image/png;base64,YWJj');
    expect(await schoolImageBytes('https://drive.google.com/file/d/own-logo/view'),[97,98,99]);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    await db.switchProfile('image-school-B',identity:{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
    expect(await WindowsSchoolImageCache.read(school,'own-logo'),isNull);
    await expectLater(WindowsSchoolImageCache.store(school,'own-logo','data:image/png;base64,YWJj',profileId:origin),throwsStateError);
    expect((await db.collection('_windows_school_image_cache').get()).docs,isEmpty);
  });

  test('managed directory mutations work without Drive configuration and retain photos for deferred sync',() async {
    final response=await WindowsBackendBridge.post(Uri.parse(''),body:jsonEncode({'action':'add_teacher','name':'Own teacher','photoBase64':'YWJj','photoMimeType':'image/png'}));
    final result=jsonDecode(response.body);
    expect(response.statusCode,200);expect(result['schoolId'],school);expect(result['cloudSyncPending'],true);
    expect(result['teacherId'],isNotEmpty);expect(result['photoUrl'],'data:image/png;base64,YWJj');
    final deletion=jsonDecode((await WindowsBackendBridge.post(Uri.parse(''),body:jsonEncode({'action':'delete_student'}))).body);
    expect(deletion['cloudSyncPending'],true);expect(deletion['alreadyDeleted'],isNull);
    await db.switchProfile('directory-school-B',identity:{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
    await expectLater(WindowsBackendBridge.post(Uri.parse(''),body:jsonEncode({'action':'add_teacher'})),throwsStateError);
  });
  test('local student photo data preserves the actual image MIME before Drive is connected',() {
    final raw=WindowsSchoolImageCache.dataUrl([137,80,78,71,1,2]);
    expect(raw,startsWith('data:image/png;base64,'));expect(UriData.parse(raw).contentAsBytes(),[137,80,78,71,1,2]);
  });

  test('stale cloud pull and delete cannot overwrite a newer queued photo edit',() async {
    final ref=db.collection('students_directory').doc('same');
    final newer=ref.set({'name':'Newer edit','photoUrl':'data:image/png;base64,YWJj'});
    final stalePull=db.applySyncedDocument(ref,{'name':'Old cloud edit','photoUrl':'https://drive.google.com/file/d/old/view'});
    await newer;await stalePull;
    await db.applySyncedDocument(ref,null);
    expect((await ref.get()).data()?['name'],'Newer edit');
    expect((await ref.get()).data()?['photoUrl'],'data:image/png;base64,YWJj');
    final pending=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    expect((pending.data()['data'] as Map)['name'],'Newer edit');
  });
  test('offline photo and pending sync reopen from disk; successful sync retains an offline image after reopen',() async {
    final origin=db.activeProfileId;
    final ref=db.collection('students_directory').doc('photo-pupil');
    final original=img.encodePng(img.Image(width:64,height:96));
    final local='data:image/png;base64,${base64Encode(original)}';
    await ref.set({'name':'Own pupil','schoolId':school,'photoUrl':local});
    await db.resetVolatileSession();
    await db.switchProfile('temporary-reopen',identity:{});
    await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
    expect((await db.collection('students_directory').doc('photo-pupil').get()).data()?['photoUrl'],local);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,hasLength(1));
    late Map<String,dynamic> published;
    await WindowsPendingSchoolSync.flush(profileId:origin,send:(c,id,op,data) async {
      published=await prepareManagedRecord(data!,school,(action,body) async=>{'success':true,'schoolId':school,'fileId':'own-photo','fileUrl':'https://drive.google.com/file/d/own-photo/view'});
    });
    await db.applySyncedDocument(db.collection('students_directory').doc('photo-pupil'),published);
    await db.resetVolatileSession();
    await db.switchProfile('temporary-second-reopen',identity:{});
    await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    expect(await schoolImageBytes((await db.collection('students_directory').doc('photo-pupil').get()).data()!['photoUrl'] as String),original);
  });

  test('nested other-staff photos retain usable local copies and cannot continue under another school', () async {
    final origin=db.activeProfileId;
    final original=img.encodePng(img.Image(width:64,height:96));
    final photo='data:image/png;base64,${base64Encode(original)}';
    final prepared=await prepareManagedRecord({'staff':[{'id':'staff:own','photoUrl':photo}]},school,(action,body) async => {'success':true,'schoolId':school,'fileId':'staff-photo','fileUrl':'https://drive.google.com/file/d/staff-photo/view'});
    expect((prepared['staff'] as List).single['photoUrl'],'https://drive.google.com/file/d/staff-photo/view');
    expect(await WindowsSchoolImageCache.read(school,'staff-photo'),original);
    var requests=0;
    await expectLater(prepareManagedRecord({'staff':[{'photoUrl':photo},{'photoUrl':photo}]},school,(action,body) async {
      requests++;
      await db.switchProfile('foreign-media',identity:{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
      return {'success':true,'schoolId':school,'fileId':'wrong-session','fileUrl':'https://drive.google.com/file/d/wrong-session/view'};
    }),throwsStateError);
    expect(requests,1);
    expect(await WindowsSchoolImageCache.read('vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','staff-photo'),isNull);
    await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
  });

  test('malformed portrait remains local and never reaches cloud upload', () async {
    var uploads=0;
    final original={'schoolId':school,'photoUrl':'data:image/png;base64,YWJj'};
    await expectLater(prepareManagedRecord(original,school,(action,body) async {
      uploads++;
      return {'success':true};
    }),throwsFormatException);
    expect(uploads,0);
    expect(original['photoUrl'],'data:image/png;base64,YWJj');
  });

  test('saved final results promote PASS offline, retain FAIL and audit the deliberate override', () async {
    final exam={'examId':'final-local','examName':'Final','isFinal':true};
    await db.collection('_local_exam_center_exams').doc('final-local').set(exam);
    await db.collection('students_directory').doc('passed').set({'name':'Passed pupil','class':'Class 1','rollNo':'1'});
    await db.collection('students_directory').doc('failed').set({'name':'Retained pupil','class':'Class 1','rollNo':'2'});
    await db.collection('exam_results').doc('final-local_passed').set({'studentId':'passed','result':'PASS'});
    await db.collection('exam_results').doc('final-local_failed').set({'studentId':'failed','result':'FAIL'});
    await SchoolPromotionService.apply(studentId:'passed',student:{},exam:exam,result:'PASS');
    expect((await db.collection('students_directory').doc('Class 2_Roll_1').get()).data()?['classMovement'],'PROMOTED');
    expect((await db.collection('students_directory').doc('passed').get()).exists,false);
    await SchoolPromotionService.apply(studentId:'failed',student:{},exam:exam,result:'FAIL');
    expect((await db.collection('students_directory').doc('failed').get()).data()?['class'],'Class 1');
    expect((await db.collection('students_directory').doc('failed').get()).data()?['classMovement'],'RETAINED');
    await db.collection('school_settings').doc('promotion_policy').set({'allowForcedPromotion':true});
    await expectLater(SchoolPromotionService.apply(studentId:'failed',student:{},exam:exam,result:'FAIL',force:true),throwsStateError);
    await SchoolPromotionService.apply(studentId:'failed',student:{},exam:exam,result:'FAIL',force:true,reason:'Approved remedial review');
    final audit=(await db.collection('school_settings').doc('promotion_audit_final-local_failed').get()).data()!;
    expect(audit['manualAdminOverride'],true);
    expect(audit['fromClass'],'Class 1');expect(audit['toClass'],'Class 2');
    expect(audit['reason'],'Approved remedial review');
    expect(audit['at'],isA<int>());
    expect((await db.collection('students_directory').doc('Class 2_Roll_2').get()).data()?['classMovement'],'FORCE_PROMOTED');
  });

  test('nested photo preparation leaves exam marks and payment structures unchanged', () async {
    final original={'marks':{'Math':80,'English':75},'payments':[{'id':'payment-1','amountPaise':15000}]};
    final prepared=await prepareManagedRecord(original,school,(_,__) async => throw StateError('No upload expected'));
    expect(prepared['schoolId'],school);
    expect(prepared['marks'],original['marks']);
    expect(prepared['payments'],original['payments']);
  });

}
