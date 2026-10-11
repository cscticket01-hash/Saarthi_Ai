import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../lib/id_card_school_source.dart';
import '../lib/id_card_manifest.dart';
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture=Map<String,dynamic>.from((jsonDecode(File('test/fixtures/windows_person_qr.json').readAsStringSync()) as List).first);
  final school=fixture['schoolId'] as String;
  IdCardSchoolSource source(List<Map<String,dynamic>> rows)=>IdCardSchoolSource(schoolId:school,profile:{'schoolName':'Synthetic School'},records:rows,connection:{'schoolId':school,'managed':fixture['managed'],'endpoint':fixture['centralEndpoint'],'projectId':fixture['firebaseProjectId'],'scriptUrl':fixture['googleScriptUrl']},ensureActive:(){});
  Map<String,dynamic> row(String id)=>{'_recordId':id,'name':'Student $id','studentClass':'5','mobileLinkToken':fixture['linkToken'],'rollNo':'1'};
  final template=IdCardManifest.fromJson(Map<String,dynamic>.from(jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync()) as Map));
  test('designer preview never uses deleted or foreign-school student photos and QR', () {
    final foreign = {...row('foreign'), 'schoolId': 'vs-${'b' * 32}', 'photoUrl': 'foreign-private-photo'};
    final deleted = {...row('deleted'), '_syncDeleted': true};
    final eligible = {...row('eligible'), 'schoolId': school};
    expect(IdCardSchoolSource.previewSample([foreign, deleted, eligible], school)?['_recordId'], 'eligible');
    expect(IdCardSchoolSource.previewSample([foreign, deleted], school), isNull);
    expect(IdCardSchoolSource.previewSample([foreign], null), isNull);
    expect(IdCardSchoolSource.previewSample([
      {...row('foreign-alt'), 'schoolSyncId': 'vs-${'b' * 32}'},
      {...row('deleted-alt'), 'deleted': true},
      {...row('unscoped')},
    ], school)?['_recordId'], 'unscoped');
  });
  test('bulk scoped source rejects schoolSyncId spoofing and excludes deletions', () {
    final valid = {...row('valid'), 'schoolId': school, 'schoolSyncId': school};
    final deleted = {...row('deleted'), 'schoolId': school, 'deleted': true};
    final tombstone = {...row('tombstone'), '_syncDeleted': true};
    expect(IdCardSchoolSource.scopedRecords([valid, deleted, tombstone], school).map((r) => r['_recordId']), ['valid']);
    expect(() => IdCardSchoolSource.scopedRecords([
      {...row('foreign'), 'schoolSyncId': 'vs-${'b' * 32}'},
    ], school), throwsStateError);
    expect(() => IdCardSchoolSource.scopedRecords([
      {...row('foreign2'), 'schoolId': 'vs-${'b' * 32}'},
    ], school), throwsStateError);
    expect(() => IdCardSchoolSource.scopedRecords([row('valid')], ''), throwsStateError);
  });
  test('source only reuses exact legitimate existing credentials',(){
    final s=source([row('first')]);
    expect(s.existingQr(s.records.first),isNotEmpty);
    expect(()=>s.existingQr({...row('missing'),'mobileLinkToken':''}),throwsStateError);
    expect(()=>s.existingQr({...row('foreign'),'idCardQr':s.existingQr(row('first'))}),throwsStateError);
  });
  test('bounded class preflight snapshots source and labels legacy reference',()async{
    final s=source([row('first')]);
    final check=await s.preflight('5',{'first'},template,imageLoader:(_)async=>null);
    expect(check.blocked,false);
    expect(check.students.single.identityKind,'legacy-qr-reference');
    expect(check.students.single.cardIssueId,startsWith('legacy-qr:'));
    expect(check.findings.any((f)=>f['code']=='MISSING_PHOTO'),true);
    await expectLater(s.preflight('other',{'first'},template),throwsStateError);
    await expectLater(s.preflight('5',{},template),throwsStateError);
  });
  test('school guard cancels source preparation without cloud mutation',()async{
    var active=true;
    final s=IdCardSchoolSource(schoolId:school,profile:{'schoolName':'School','logoUrl':'cached'},records:[row('first')],connection:source([]).connection,ensureActive:(){if(!active)throw StateError('School changed');});
    await expectLater(s.preflight('5',{'first'},template,imageLoader:(_)async{active=false;return Uint8List(0);}),throwsStateError);
  });
}
