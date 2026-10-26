import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_school_cloud_backup.dart';

void main() {
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const other = 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const collections = <String>[
    'students_directory','teachers_directory','attendance_logs','teacher_attendance',
    'attendance_records','teacher_schedules','school_notices','school_calendar',
    'exam_results','teacher_salary','school_config','school_settings','fee_settings',
    'fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices',
    'documents','backups','exams','exam_center_results',
  ];
  late Directory cache;
  late bool own;
  late List<String> missing;
  Map<String,dynamic> census() => {
    'success':true,'schoolId':school,'snapshotProtocol':1,'recordsComplete':true,
    'collections':collections,
    'records':{for(final c in collections)c:<String,dynamic>{}},
    'collectionRevisions':{for(final c in collections)c:'legacy'},
  };
  Map<String,dynamic> inventory(List<Map<String,dynamic>> files) => {
    'success':true,'schoolId':school,'binaryInventoryVersion':1,
    'inventoryFingerprint':sha256.convert(utf8.encode('synthetic inventory')).toString(),
    'inventoryScope':'application_media_folders','items':files,'observedAt':1800000000000,
    'partial':false,'scanLimited':false,'coverageComplete':true,'nextCursor':null,
  };
  Future<Map<String,dynamic>?> capture(Future<Map<String,dynamic>> Function(String,Map<String,dynamic>) request) =>
    collectWindowsSchoolCloudBackup(schoolId:school,own:()=>own,cacheRoot:cache,missing:missing,request:request);
  setUp(() async {
    cache=await Directory.systemTemp.createTemp('synthetic-cloud-backup-');own=true;missing=[];
  });
  tearDown(() async {await cache.delete(recursive:true);});

  test('valid school census and empty authenticated inventory report complete capture',() async {
    final actions=<String>[];
    final result=await capture((action,body)async {actions.add(action);return action=='managed/backup/snapshot'?census():inventory([]);});
    expect(result?['recordsComplete'],true);expect(result?['cloudFileInventory'],isEmpty);
    expect(missing,isEmpty);expect(actions,['managed/backup/snapshot','managed/file/inventory']);
  });
  test('unsupported snapshot protocol remains explicitly missing while file inspection continues',() async {
    final result=await capture((action,body)async =>action=='managed/backup/snapshot'?{...census(),'snapshotProtocol':999}:inventory([]));
    expect(result,isNull);expect(missing,hasLength(1));expect(missing.single,contains('record census unavailable'));
  });
  test('foreign snapshot proof is rejected without accepting foreign records',() async {
    final result=await capture((action,body)async=>action=='managed/backup/snapshot'?{...census(),'schoolId':other}:inventory([]));
    expect(result,isNull);expect(missing,hasLength(1));
  });
  test('duplicate collection claim cannot masquerade as a complete census',() async {
    final response=census();
    response['collections']=[...collections.take(21),collections.first];
    final result=await capture((action,body)async=>action=='managed/backup/snapshot'?response:inventory([]));
    expect(result,isNull);expect(missing,hasLength(1));
  });
  test('foreign row is rejected despite a matching response school proof',() async {
    final response=census();
    (response['records'] as Map)['students_directory']={'foreign':{'schoolId':other,'name':'Synthetic'}};
    final result=await capture((action,body)async=>action=='managed/backup/snapshot'?response:inventory([]));
    expect(result,isNull);expect(missing,hasLength(1));
  });
  test('missing revision or collection record map cannot be marked complete',() async {
    for(final bad in ['records','collectionRevisions']) {
      final response=census();(response[bad] as Map).remove('students_directory');
      final result=await capture((action,body)async=>action=='managed/backup/snapshot'?response:inventory([]));
      expect(result,isNull);
    }
    expect(missing,hasLength(2));
  });
  test('school switch during snapshot aborts remaining cloud requests',() async {
    var calls=0;
    await expectLater(capture((action,body)async {calls++;own=false;return census();}),throwsStateError);
    expect(calls,1);
  });
  test('hash-verified file bytes are captured only after actual download',() async {
    final bytes=utf8.encode('synthetic original document bytes');
    final hash=sha256.convert(bytes).toString();
    final item=<String,dynamic>{'fileId':'synthetic_document','name':'document.pdf','mime':'application/pdf',
      'sizeBytes':bytes.length,'sha256':hash,'version':'v1','verification':'bytes_hashed'};
    final result=await capture((action,body)async {
      if(action=='managed/backup/snapshot')return census();
      if(action=='managed/file/inventory')return inventory([item]);
      return {...item,'success':true,'schoolId':school,'binaryDownloadVersion':1,'base64':base64Encode(bytes)};
    });
    expect(missing,isEmpty);expect((result!['cloudFileInventory'] as List).single['state'],'verified');
    expect(await File('${cache.path}/$school/$hash.bin').readAsBytes(),bytes);
  });
  test('corrupt cloud file retains census but reports missing data without verified file',() async {
    final bytes=utf8.encode('expected synthetic document');
    final item=<String,dynamic>{'fileId':'synthetic_document','name':'document.pdf','mime':'application/pdf',
      'sizeBytes':bytes.length,'sha256':sha256.convert(bytes).toString(),'version':'v1','verification':'bytes_hashed'};
    final result=await capture((action,body)async {
      if(action=='managed/backup/snapshot')return census();
      if(action=='managed/file/inventory')return inventory([item]);
      return {...item,'success':true,'schoolId':school,'binaryDownloadVersion':1,'base64':base64Encode(utf8.encode('bad'))};
    });
    expect(result?['recordsComplete'],true);expect(missing,isNotEmpty);
    final bins=await cache.list(recursive:true).where((file)=>file.path.endsWith('.bin')).toList();expect(bins,isEmpty);
  });
}
