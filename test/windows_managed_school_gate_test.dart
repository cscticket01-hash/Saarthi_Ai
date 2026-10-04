import 'dart:convert';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_firebase_sync.dart';
import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_managed_school_gate.dart';
import '../lib/windows_connect/managed_school_session.dart';
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  test('queued local writes and stale batches cannot cross a school switch',()async{
    final db=FirebaseFirestore.instance;
    final suffix=DateTime.now().microsecondsSinceEpoch;
    final a='managed-a-$suffix',b='managed-b-$suffix';
    await db.switchProfile(a);
    final ref=db.collection('students_directory').doc('same');
    final batch=db.batch()..set(ref,{'name':'Old batch'});
    final write=ref.set({'name':'School A'});
    final switched=db.switchProfile(b);
    await write;await switched;
    expect((await db.collection('students_directory').doc('same').get()).exists,false);
    await expectLater(ref.set({'name':'Wrong school'}),throwsStateError);
    await expectLater(batch.commit(),throwsStateError);
    await db.switchProfile(a);
    expect((await db.collection('students_directory').doc('same').get()).data()?['name'],'School A');
  });
  test('managed sync refuses A outbox after B credentials replace the session',()async{
    const a='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',b='vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({'managed':true,'projectId':platformProjectId,'schoolId':b,'uid':'B','email':'b@school.example','folderId':'managed','firebaseRefreshToken':'B-refresh','endpoint':'https://school.example/school-cloud'})});
    await FirebaseFirestore.instance.switchProfile('central_$a',identity:{'schoolId':a,'schoolSyncId':a,'firebaseProjectId':platformProjectId});
    await expectLater(WindowsFirebaseRemote.writeDocument(projectId:platformProjectId,idToken:'A-token',collection:'students_directory',documentId:'same',data:{'name':'School A'}),throwsStateError);
    await expectLater(WindowsFirebaseRemote.readCollection(projectId:platformProjectId,idToken:'A-token',collection:'students_directory'),throwsStateError);
  });
  testWidgets('managed logout cannot expose legacy dashboard or licence skip',(tester)async{
    FlutterSecureStorage.setMockInitialValues({'vidya_saarthi_managed_required':'true'});
    await tester.pumpWidget(const MaterialApp(home:WindowsManagedSchoolGate(child:Text('School data'),legacy:Text('Legacy skip'))));
    await tester.pump();await tester.pump();
    expect(find.text('School Login'),findsOneWidget);expect(find.text('School data'),findsNothing);expect(find.text('Legacy skip'),findsNothing);
    await ManagedSchoolSession.logout();await tester.pump();await tester.pump();
    expect(find.text('School Login'),findsOneWidget);expect(find.text('Legacy skip'),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
