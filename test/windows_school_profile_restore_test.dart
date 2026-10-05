import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_school_profile_restore.dart';
void main() {
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
}
