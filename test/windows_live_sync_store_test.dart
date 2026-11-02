import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/live_sync_protocol.dart';
import '../lib/windows_live_sync_store.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 final db=FirebaseFirestore.instance;
 setUp(()async{
  FlutterSecureStorage.setMockInitialValues({});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  await db.switchProfile('live-${DateTime.now().microsecondsSinceEpoch}',
    identity:{'schoolId':school,'schoolSyncId':school});
 });
 LiveSyncPage page(int after,int next)=>LiveSyncPage(school,after,next,next,[
  {'sequence':next,'collection':'school_expenses','id':'one',
   'record':{'schoolId':school,'amount':10,'_syncRevision':'live-original'}},
 ]);
 test('incoming page and cursor persist together without becoming an upload ACK',()async{
  final store=WindowsLiveSyncStore(db);expect(await store.cursor(school),0);
  await store.retainPage(page(0,1));expect(await store.cursor(school),1);
  expect((await db.collection('_windows_live_incoming').get()).docs.length,1);
  expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  expect((await db.collection('school_expenses').get()).docs,isEmpty);
 });
 test('retired authority retains a Drive invalidation without fabricating business truth',()async{
  final store=WindowsLiveSyncStore(db);
  final events=<Map<String,dynamic>>[{'sequence':1,'collection':'school_expenses',
    'id':'one','retired':true,'source':'drive','recordAuthority':'school-drive','record':null}];
  await store.retainPage(LiveSyncPage(school,0,1,1,events));
  expect(await store.cursor(school),1);
  final incoming=(await db.collection('_windows_live_incoming').get()).docs.single.data();
  expect(incoming['retired'],isTrue);
  expect(incoming['source'],'drive');
  expect(incoming['recordAuthority'],'school-drive');
  expect(incoming.containsKey('record'),isTrue);
  expect(incoming['record'],isNull);
  expect((await db.collection('school_expenses').get()).docs,isEmpty);
  expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
 });
 test('incomplete retired proof or retired record payload cannot advance a checkpoint',()async{
  final store=WindowsLiveSyncStore(db);
  for(final record in [<String,dynamic>{'schoolId':school,'_syncRevision':'live-fake'},null]) {
   final event=<String,dynamic>{'sequence':1,'collection':'school_expenses','id':'one',
     'retired':true,'source':'drive','record':record};
   if(record!=null)event['recordAuthority']='school-drive';
   await expectLater(store.retainPage(LiveSyncPage(school,0,1,1,[event])),throwsStateError);
  }
  expect(await store.cursor(school),0);
  expect((await db.collection('_windows_live_incoming').get()).docs,isEmpty);
 });
 test('two replay owners cannot overwrite a newer durable checkpoint',()async{
  final store=WindowsLiveSyncStore(db);await store.retainPage(page(0,1));
  await expectLater(store.retainPage(page(0,1)),throwsStateError);
  expect(await store.cursor(school),1);
 });
 test('foreign and gapped pages cannot advance the local cursor',()async{
  final store=WindowsLiveSyncStore(db);
  await expectLater(store.retainPage(LiveSyncPage('other-school',0,1,1,[])),throwsStateError);
  await expectLater(store.retainPage(page(0,2)),throwsStateError);
  expect(await store.cursor(school),0);
 });
}
