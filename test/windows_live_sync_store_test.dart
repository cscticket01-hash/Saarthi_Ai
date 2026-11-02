import 'package:flutter_test/flutter_test.dart';
import '../lib/live_sync_protocol.dart';
import '../lib/windows_live_sync_store.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 final db=FirebaseFirestore.instance;
 setUp(()async{
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
