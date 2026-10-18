import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_developer_notifications.dart';
import '../lib/windows_local_firestore.dart' as local;
import '../lib/windows_runtime_flags.dart';
import '../lib/platform/platform_config.dart';

const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Map<String,dynamic> note(String audience,String id,{String title='Developer message'})=>{
 'name':'projects/$platformProjectId/databases/(default)/documents/platform_developer_notifications/$audience/messages/$id',
 'fields':{'audience':{'stringValue':audience},'title':{'stringValue':title},
 'message':{'stringValue':'Synthetic developer notification body'},'createdAt':{'timestampValue':'2026-10-18T11:00:00Z'}}};
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 final db=local.FirebaseFirestore.instance;
 setUp(()async{
  FlutterSecureStorage.setMockInitialValues({});
  await WindowsRuntimeFlags.setLocalStorageEnabled(false);
  await db.switchProfile('notification-${DateTime.now().microsecondsSinceEpoch}',identity:{'schoolSyncId':school});
 });
 testWidgets('broadcast and own notifications deduplicate, paginate, open and retain read status offline without creating sync work',(tester)async{
  var offline=false;
  final inbox=DeveloperInbox(readPage:(audience,cursor)async{
   if(offline)throw StateError('Offline');
   return {'documents':[note(audience,cursor==null?'first':'older')],if(cursor==null)'nextPageToken':'next'};
  });
  await inbox.initialize();
  expect(inbox.unread,2);expect(inbox.hasMore,true);
  await inbox.refresh();expect(inbox.messages.length,2);
  await inbox.refresh(more:true);expect(inbox.messages.length,4);
  await tester.pumpWidget(MaterialApp(home:DeveloperInboxScreen(inbox:inbox)));
  await tester.tap(find.text('Developer message').first);await tester.pumpAndSettle();
  expect(find.text('Synthetic developer notification body'),findsOneWidget);
  await tester.tap(find.text('Close'));await tester.pumpAndSettle();
  expect(inbox.unread,3);
  expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  await tester.pumpWidget(const SizedBox());inbox.dispose();
  final cached=DeveloperInbox(readPage:(a,c)async=>throw StateError('Offline'));
  await cached.initialize();expect(cached.messages.length,4);expect(cached.unread,3);expect(cached.error,isNotNull);
  cached.dispose();
 });
 test('foreign path and changed profile during a response cannot write cache or expose another school',()async{
  final bad=DeveloperInbox(readPage:(a,c)async=>{'documents':[note('foreign-school','bad')]});
  await bad.initialize();expect(bad.error,isNotNull);expect(bad.messages,isEmpty);
  expect((await db.collection('_developer_inbox').get()).docs,isEmpty);bad.dispose();
  final response=Completer<Map<String,dynamic>>();
  final started=Completer<void>();
  final switched=DeveloperInbox(readPage:(a,c){ if(!started.isCompleted)started.complete();return response.future; });
  final loading=switched.initialize();
  await started.future;
  await db.switchProfile('another-school',identity:{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
  response.complete({'documents':[note('all','late')]});await loading;
  expect(switched.current,false);expect(switched.messages,isEmpty);
  expect((await db.collection('_developer_inbox').get()).docs,isEmpty);switched.dispose();
 });
}
