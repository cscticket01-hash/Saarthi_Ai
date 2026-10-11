import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import '../lib/storage/windows_sqlite_store.dart';
import '../lib/windows_backup_integrity.dart';
import '../lib/windows_clean_install_recovery.dart';

const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Map<String,dynamic> fixture(String media)=>{'version':2,'activeProfileHint':'school',
  'profiles':{'school':{'identity':{'schoolId':school,'schoolSyncId':school},'collections':{
    'fee_payments':{'fee':{'schoolId':school,'amount':500,'capturedAt':1791500000123,'_syncRevision':'original-revision','originalPath':media}},
    '_windows_firebase_outbox':{'fee':{'schoolId':school,'operationId':'never-uploaded-original','syncState':'pending','baseCloudRevision':'original-revision','data':{'capturedAt':1791500000123,'amount':500}}}
  }}}};
void main(){
  late Directory temp,backup,current,control,staging;
  late WindowsCleanInstallRecovery recovery;
  setUp(()async{
    temp=await Directory.systemTemp.createTemp('vs-recovery-test-');
    backup=Directory('${temp.path}/backup');current=Directory('${temp.path}/fresh');control=Directory('${temp.path}/control');staging=Directory('${temp.path}/staging');
    await backup.create();await current.create();await control.create();
    await Directory('${backup.path}/LocalFiles').create();
    await File('${backup.path}/LocalFiles/photo.jpg').writeAsBytes([1,2,3,4]);
    await File('${backup.path}/local_database_v1.json').writeAsString(jsonEncode(fixture('C:/OldSchool/LocalFiles/photo.jpg')));
    await WindowsBackupIntegrity.seal(backup);
    recovery=WindowsCleanInstallRecovery(controlDirectory:control,currentDataDirectory:current,authenticateSchool:()async=>school);
  });
  tearDown(()async{await temp.delete(recursive:true);});
  test('fresh restore preserves pending identity timestamp and source bytes',()async{
    final source=await File('${backup.path}/local_database_v1.json').readAsBytes();
    final proof=await recovery.prepare(backup,staging);
    expect(proof['pendingCount'],1);
    final root=jsonDecode(await File('${staging.path}/local_database_v1.json').readAsString());
    final collections=root['profiles']['school']['collections'];
    expect(collections['_windows_firebase_outbox']['fee']['operationId'],'never-uploaded-original');
    expect(collections['_windows_firebase_outbox']['fee']['syncState'],'pending');
    expect(collections['fee_payments']['fee']['capturedAt'],1791500000123);
    expect(collections['fee_payments']['fee']['_syncRevision'],'original-revision');
    expect(collections['fee_payments']['fee']['originalPath'],'${staging.absolute.path}/LocalFiles/photo.jpg');
    expect(await File('${backup.path}/local_database_v1.json').readAsBytes(),source);
    await recovery.activate(administratorConfirmed:true);
    expect(await recovery.recoverInterruptedActivation(),'active');
    expect(jsonDecode(await File('${control.path}/storage_config_v1.json').readAsString())['dataPath'],staging.absolute.path);
  });
  test('administrator gate rejects activation and leaves no pointer',()async{
    await recovery.prepare(backup,staging);
    await expectLater(recovery.activate(administratorConfirmed:false),throwsStateError);
    expect(await File('${control.path}/storage_config_v1.json').exists(),false);
  });
  test('interrupted copy resumes same sealed generation',()async{
    await expectLater(recovery.prepare(backup,staging,onFileVerified:(n)async{throw StateError('interruption');}),throwsStateError);
    final proof=await recovery.prepare(backup,staging);
    expect(proof['state'],'prepared');
    await WindowsBackupIntegrity.verify(backup);
  });
  test('foreign school rejected before staging',()async{
    recovery=WindowsCleanInstallRecovery(controlDirectory:control,currentDataDirectory:current,authenticateSchool:()async=>'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    await expectLater(recovery.prepare(backup,staging),throwsStateError);
    expect(await staging.exists(),false);
  });
  test('corrupt sealed backup rejected',()async{
    await File('${backup.path}/LocalFiles/photo.jpg').writeAsBytes([9]);
    await expectLater(recovery.prepare(backup,staging),throwsStateError);
  });
  test('missing referenced media rejected despite resealed manifest',()async{
    await File('${backup.path}/LocalFiles/photo.jpg').delete();
    await WindowsBackupIntegrity.seal(backup);
    await expectLater(recovery.prepare(backup,staging),throwsStateError);
  });
  test('duplicate queue operation blocked',()async{
    final root=fixture('LocalFiles/photo.jpg');
    root['profiles']['school']['collections']['_windows_firebase_outbox']['duplicate']={'schoolId':school,'operationId':'never-uploaded-original'};
    await File('${backup.path}/local_database_v1.json').writeAsString(jsonEncode(root));
    await WindowsBackupIntegrity.seal(backup);
    await expectLater(recovery.prepare(backup,staging),throwsStateError);
  });
  test('existing or newer school records prohibit activation',()async{
    await recovery.prepare(backup,staging);
    await File('${current.path}/local_database_v1.json').writeAsString(jsonEncode(fixture('LocalFiles/photo.jpg')));
    await expectLater(recovery.activate(administratorConfirmed:true),throwsStateError);
    expect(await File('${control.path}/storage_config_v1.json').exists(),false);
  });
  test('authenticated empty local profile remains eligible',()async{
    await File('${current.path}/local_database_v1.json').writeAsString(jsonEncode({'version':2,'profiles':{'school':{'identity':{'schoolSyncId':school,'schoolId':school},'collections':{}}}}));
    expect(await recovery.isFreshInstallation(),true);
  });
  test('failed pointer switch rolls back without removing previous data',()async{
    final previous=jsonEncode({'dataPath':current.path});
    await File('${control.path}/storage_config_v1.json').writeAsString(previous);
    await recovery.prepare(backup,staging);
    await expectLater(recovery.activate(administratorConfirmed:true,checkpoint:(stage)async{if(stage=='previous_retained')throw StateError('crash');}),throwsStateError);
    expect(await recovery.recoverInterruptedActivation(),'rolledBack');
    expect(await File('${control.path}/storage_config_v1.json').readAsString(),previous);
    expect(await staging.exists(),true);
  });
  test('pointer switched crash recovers after restart verification',()async{
    await recovery.prepare(backup,staging);
    await expectLater(recovery.activate(administratorConfirmed:true,checkpoint:(stage)async{if(stage=='pointer_switched')throw StateError('crash');}),throwsStateError);
    final restarted=WindowsCleanInstallRecovery(controlDirectory:control,currentDataDirectory:current,authenticateSchool:()async=>school);
    expect(await restarted.recoverInterruptedActivation(),'active');
  });
  test('changed staged media rolls back activated pointer',()async{
    await recovery.prepare(backup,staging);
    await recovery.activate(administratorConfirmed:true);
    await File('${staging.path}/LocalFiles/photo.jpg').writeAsBytes([8]);
    expect(await recovery.recoverInterruptedActivation(),'rolledBack');
    expect(await staging.exists(),true);
  });
  test('stale changed source cannot resume another generation',()async{
    await recovery.prepare(backup,staging);
    await File('${backup.path}/LocalFiles/photo.jpg').writeAsBytes([5]);
    await WindowsBackupIntegrity.seal(backup);
    await expectLater(recovery.prepare(backup,staging),throwsStateError);
    expect(sha256.convert(await File('${staging.path}/LocalFiles/photo.jpg').readAsBytes()).toString(),sha256.convert([1,2,3,4]).toString());
  });
  test('SQLite sealed source stays byte-identical with queue and revision retained',()async{
    final json=File('${backup.path}/local_database_v1.json');
    final root=jsonDecode(await json.readAsString());
    final source=await WindowsSqliteStore.open('${backup.path}/${WindowsSqliteStore.databaseName}');
    try {await source.writeRoot(Map<String,dynamic>.from(root));}
    finally {await source.close();}
    await json.delete();
    await WindowsBackupIntegrity.seal(backup);
    final bytes=await File('${backup.path}/${WindowsSqliteStore.databaseName}').readAsBytes();
    await recovery.prepare(backup,staging);
    expect(await File('${backup.path}/${WindowsSqliteStore.databaseName}').readAsBytes(),bytes);
    final restored=await WindowsSqliteStore.open('${staging.path}/${WindowsSqliteStore.databaseName}');
    try {
      expect((await restored.readDocument('school','_windows_firebase_outbox','fee'))!['operationId'],'never-uploaded-original');
      expect((await restored.readDocument('school','fee_payments','fee'))!['capturedAt'],1791500000123);
      expect((await restored.readDocument('school','fee_payments','fee'))!['_syncRevision'],'original-revision');
    } finally {await restored.close();}
  });
  test('mixed school profiles and unsupported external media require review',()async{
    final root=fixture('C:/Unbacked/photo.jpg');
    await File('${backup.path}/local_database_v1.json').writeAsString(jsonEncode(root));
    await WindowsBackupIntegrity.seal(backup);
    await expectLater(recovery.prepare(backup,staging),throwsStateError);
    root['profiles']['foreign']={'identity':{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},'collections':{}};
    await File('${backup.path}/local_database_v1.json').writeAsString(jsonEncode(root));
    await WindowsBackupIntegrity.seal(backup);
    await expectLater(recovery.prepare(backup,staging),throwsStateError);
  });
  test('confirmed restart does not revalidate against later legitimate edits',()async{
    await recovery.prepare(backup,staging);
    await recovery.activate(administratorConfirmed:true);
    expect(await recovery.recoverInterruptedActivation(),'active');
    await File('${staging.path}/local_database_v1.json').writeAsString('legitimate later application change');
    expect(await recovery.recoverInterruptedActivation(),'verifiedAfterRestart');
    expect(await File('${control.path}/storage_config_v1.json').exists(),true);
  });

  test('document and retained restore intents preserve their actual identities',()async{
    final root=fixture('LocalFiles/photo.jpg');
    final collections=root['profiles']['school']['collections'];
    collections['_windows_document_outbox']={'doc':{'schoolId':school,'documentRevision':'original-doc-generation','localPath':'LocalFiles/photo.jpg','optimizedPath':'LocalFiles/photo.jpg','syncState':'retry'}};
    collections['_windows_local_deletions']={'original-delete':{'schoolId':school,'operationId':'original-delete','collection':'school_notices','documentId':'notice','snapshot':{'schoolId':school,'capturedAt':456}}};
    collections['_windows_recycle_requests']={'restore':{'schoolId':school,'localRestore':true,'operationId':'original-restore','deletionOperationId':'original-delete','administratorApproved':true,'state':'awaitingDeleteAck'}};
    await File('${backup.path}/local_database_v1.json').writeAsString(jsonEncode(root));
    await WindowsBackupIntegrity.seal(backup);
    final proof=await recovery.prepare(backup,staging);
    expect(proof['documentPendingCount'],1);
    expect(proof['restorePendingCount'],1);
    final restored=jsonDecode(await File('${staging.path}/local_database_v1.json').readAsString())['profiles']['school']['collections'];
    expect(restored['_windows_document_outbox']['doc']['documentRevision'],'original-doc-generation');
    expect(restored['_windows_recycle_requests']['restore']['operationId'],'original-restore');
    expect(restored['_windows_recycle_requests']['restore']['state'],'awaitingDeleteAck');
    expect(restored['_windows_local_deletions']['original-delete']['operationId'],'original-delete');
  });
  test('disagreeing SQLite and JSON generation fails closed',()async{
    final root=fixture('LocalFiles/photo.jpg');
    root['profiles']['school']['collections']['fee_payments']['fee']['amount']=999;
    final source=await WindowsSqliteStore.open('${backup.path}/${WindowsSqliteStore.databaseName}');
    try {await source.writeRoot(root);} finally {await source.close();}
    await WindowsBackupIntegrity.seal(backup);
    await expectLater(recovery.prepare(backup,staging),throwsStateError);
    expect(await staging.exists(),false);
  });

}
