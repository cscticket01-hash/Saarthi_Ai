import 'dart:io';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_admin_setup.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/platform/platform_config.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_school_profile_restore.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-11111111111111111111111111111111';
  const profile = {'schoolId':school,'schoolName':'School A','principalName':'Principal A'};
  test('new PC restores saved school and private logo without writing registration', () async {
    final actions = <String>[];
    final restored = await WindowsSchoolProfileRestore.resolve(schoolId:school,localProfile:{},call:(action,body) async {
      actions.add(action);
      return {'success':true,'schoolId':school,
        if(action=='managed/records') 'records':{'school_profile_cache':{...profile,'logoFileId':'own-logo'}},
        if(action=='managed/file/read') ...{'mime':'image/png','base64':'YWJj'}};
    });
    expect(restored['schoolName'],'School A');
    expect(restored['logoUrl'],'data:image/png;base64,YWJj');
    expect(actions,['managed/records','managed/file/read']);
  });
  test('existing PC uploads initial branding as Drive files, never inline records', () async {
    Map<String,dynamic>? written;
    final restored = await WindowsSchoolProfileRestore.resolve(schoolId:school,localProfile:{...profile,'logoUrl':'data:image/png;base64,YWJj'},call:(action,body) async {
      if(body['operation']=='write') written=Map<String,dynamic>.from(body['data']);
      return {'success':true,'schoolId':school,
        if(body['operation']=='read') 'records':{},
        if(action=='managed/file/upload') ...{'fileId':'logo','fileUrl':'https://drive.google.com/file/d/logo/view'},
        if(action=='managed/file/read') ...{'mime':'image/png','base64':'YWJj'}};
    });
    expect(written!['logoFileId'],'logo');
    expect(written!['logoUrl'],startsWith('https:'));
    expect(restored['logoUrl'],startsWith('data:image/'));
  });
  test('foreign tenant responses cannot complete registration', () async {
    await expectLater(WindowsSchoolProfileRestore.resolve(schoolId:school,localProfile:{},call:(a,b) async=>{'success':true,'schoolId':'other','records':{'school_profile_cache':profile}}),throwsStateError);
    await expectLater(WindowsSchoolProfileRestore.resolve(schoolId:school,localProfile:{},call:(a,b) async=>{'success':true,'schoolId':school,'records':{'school_profile_cache':{...profile,'schoolId':'other'}}}),throwsStateError);
  });
  test('network failure is not an empty school, genuine empty school needs setup', () async {
    await expectLater(WindowsSchoolProfileRestore.resolve(schoolId:school,localProfile:{},call:(a,b) async=>throw StateError('offline')),throwsStateError);
    expect(await WindowsSchoolProfileRestore.resolve(schoolId:school,localProfile:{},call:(a,b) async=>{'success':true,'schoolId':school,'records':{}}),isEmpty);
  });
  Map<String, dynamic> enrollment(String state, {bool storage = false}) => {
    'success': true, 'schoolId': school, 'registrationState': state,
    'storageReady': storage, 'profile': state == 'complete' ? profile : null};
  test('new PC restores central names with no script and honestly reports unsynced files', () async {
    final actions = <String>[];
    final result = await WindowsSchoolProfileRestore.resolveEnrollment(schoolId: school,
      localProfile: {}, call: (action, body) async {
        actions.add(action); return enrollment('complete');
      });
    expect(result['schoolName'], 'School A');
    expect(result['restoreNotice'], contains('not synced'));
    expect(result.containsKey('logoUrl'), false);
    expect(actions, ['managed/profile']);
  });
  test('new school setup requires explicit server new state, not an empty PC', () async {
    expect(await WindowsSchoolProfileRestore.resolveEnrollment(schoolId: school,
      localProfile: {}, call: (a, b) async => enrollment('new')), isEmpty);
    await expectLater(WindowsSchoolProfileRestore.resolveEnrollment(schoolId: school,
      localProfile: {}, call: (a, b) async => enrollment('unknown')), throwsStateError);
  });
  test('existing Drive profile backfills central metadata without registering another school', () async {
    final operations = <String>[];
    final result = await WindowsSchoolProfileRestore.resolveEnrollment(schoolId: school,
      localProfile: {}, call: (action, body) async {
        operations.add('$action:${body['operation']}');
        if (action == 'managed/profile') {
          if (body['operation'] == 'initialize') {
            expect(body.keys, unorderedEquals(['operation', 'schoolName', 'principalName']));
            return enrollment('complete', storage: true);
          }
          return enrollment('unknown', storage: true);
        }
        return {'success': true, 'schoolId': school,
          'records': {'school_profile_cache': profile}};
      });
    expect(result['schoolName'], 'School A');
    expect(operations, ['managed/profile:read', 'managed/records:read', 'managed/profile:initialize']);
  });
  test('missing Drive registration uses saved central enrollment and does not recreate it', () async {
    final result = await WindowsSchoolProfileRestore.resolveEnrollment(schoolId: school,
      localProfile: {}, call: (action, body) async => action == 'managed/profile'
        ? enrollment('complete', storage: true)
        : {'success': true, 'schoolId': school, 'records': {}});
    expect(result['schoolId'], school); expect(result['restoreNotice'], isNotEmpty);
  });
  test('known local registration backfills metadata before storage has been connected', () async {
    final result = await WindowsSchoolProfileRestore.resolveEnrollment(schoolId: school,
      localProfile: {...profile, 'logoUrl': 'data:image/png;base64,YWJj'},
      call: (action, body) async => enrollment(body['operation'] == 'read' ? 'unknown' : 'complete'));
    expect(result['logoUrl'], startsWith('data:image/'));
    expect(result.containsKey('restoreNotice'), false);
  });
  test('blocked, failed, malformed and foreign registration responses never show setup', () async {
    for (final response in [
      {...enrollment('new'), 'schoolId': 'other'},
      {...enrollment('new'), 'profile': {...profile, 'schoolId': 'other'}},
      {...enrollment('unknown'), 'profile': profile},
      {...enrollment('complete'), 'profile': {...profile, 'schoolId': 'other'}},
      {...enrollment('complete'), 'profile': {}},
      {...enrollment('new'), 'success': false},
      {...enrollment('new'), 'registrationState': 'invalid'},
    ]) {
      await expectLater(WindowsSchoolProfileRestore.resolveEnrollment(schoolId: school,
        localProfile: {}, call: (a, b) async => response), throwsStateError);
    }
    await expectLater(WindowsSchoolProfileRestore.resolveEnrollment(schoolId: school,
      localProfile: profile, call: (a, b) async => throw StateError('blocked or offline')), throwsStateError);
    await expectLater(WindowsSchoolProfileRestore.resolveEnrollment(schoolId: school,
      localProfile: {...profile, 'schoolId': 'other'}, call: (a, b) async => enrollment('complete')), throwsStateError);
  });

  test('legacy local registration provenance follows its tenant file and foreign IDs are never relabelled', () async {
    final base = Platform.environment['APPDATA'] ?? Platform.environment['LOCALAPPDATA'];
    expect(base, isNotNull);
    final file = File('$base${Platform.pathSeparator}VidyaSaarthi${Platform.pathSeparator}admin_setup_v1_$school.json');
    final previous = await file.exists() ? await file.readAsBytes() : null;
    addTearDown(() async {
      if (previous != null) { await file.writeAsBytes(previous); }
      else if (await file.exists()) { await file.delete(); }
    });
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key: jsonEncode({
      'managed': true, 'projectId': platformProjectId, 'schoolId': school,
      'uid': 'A', 'email': 'a@school.example', 'folderId': 'managed',
      'firebaseRefreshToken': 'refresh', 'endpoint': 'https://school.example/school-cloud'})});
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'schoolName': 'School A', 'principalName': 'Principal A'}));
    expect((await WindowsAdminSetup.read())['schoolId'], school);
    await file.writeAsString(jsonEncode({...profile, 'schoolId': 'other'}));
    final foreign = await WindowsAdminSetup.read();
    expect(foreign['schoolId'], 'other');
    await expectLater(WindowsSchoolProfileRestore.resolveEnrollment(schoolId: school,
      localProfile: foreign, call: (a, b) async => enrollment('complete')), throwsStateError);
  });

}

// Enrollment routing covers PCs without any local preferences or profile files.
