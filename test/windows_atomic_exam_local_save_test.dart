import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/platform/platform_config.dart';
import '../lib/windows_backend_bridge.dart';
import '../lib/windows_connect/atomic_bundle_pilot.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 const studentId='student-001',examId='exam-first';
 final db=FirebaseFirestore.instance;
 late String profile;
 late Uint8List pdf;
 Future<void> seed()async{
   await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()async{
     await db.collection('students_directory').doc(studentId).set({
       'schoolId':school,'name':'Exam Student','studentClass':'Class 5',
       'mobileStableId':'p-'+'b'*32});
     await db.collection('exams').doc(examId).set({
       'schoolId':school,'examId':examId,'examName':'First Term',
       'studentClass':'Class 5','subjects':['Maths'],'fullMarks':100});
   });
 }
 setUp(()async{
   FlutterSecureStorage.setMockInitialValues({
     CentralSchoolCloud.key:jsonEncode({
       'managed':true,'schoolId':school,'uid':'school-admin',
       'projectId':platformProjectId,'endpoint':'https://school.example/school-cloud',
       'firebaseRefreshToken':'saved-refresh','email':'school@example.com',
       'folderId':'managed',
       'storageReady':false,
     }),
   });
   await WindowsRuntimeFlags.setLocalStorageEnabled(false);
   profile='atomic-exam-'+DateTime.now().microsecondsSinceEpoch.toString();
   await db.switchProfile(profile,identity:{'schoolId':school,'schoolSyncId':school});
   pdf=Uint8List(1024);
   pdf.setRange(0,8,latin1.encode('%PDF-1.7'));
   pdf.setRange(pdf.length-5,pdf.length,latin1.encode('%%EOF'));
   await seed();
 });
 final result=<String,dynamic>{
   'action':'save_exam_result','examId':examId,'studentId':studentId,
   'studentName':'Exam Student','marks':{'Maths':95},'result':'PASS',
   'totalMarks':95,'percentage':95.0,
 };
 test('existing original Exam Center result and immutable marksheet commit in one local batch',()async{
   if(!AtomicBundlePilot.buildEnabled)return;
   final first=await WindowsBackendBridge.saveExamResultWithMarksheet(
     profileId:profile,result:result,pdfBytes:pdf);
   expect(first['success'],isTrue);
   final id=first['examResultId'] as String,docId=first['marksheetDocumentId'] as String;
   expect(id,'${examId}_$studentId');
   final row=(await db.collection('exam_center_results').doc(id).get()).data()!;
   expect(row['marksheetDocumentId'],docId);
   expect(row['marks'],{'Maths':95});
   expect(row['personId'],'p-'+'b'*32);
   final document=(await db.collection('_local_student_documents').doc(docId).get()).data()!;
   expect(document['documentKind'],'marksheet');
   expect(document['examResultId'],id);
   expect(document['studentId'],studentId);
   expect(document['optimizedPath'],document['localPath']);
   expect(document['contentHash'],isNotEmpty);
   final business=(await db.collection('_windows_firebase_outbox').get()).docs
     .where((d)=>d.data()['collection']=='exam_center_results').toList();
   final files=(await db.collection('_windows_document_outbox').get()).docs;
   expect(business,hasLength(1));
   expect(files,hasLength(1));
   expect(files.single.id,docId);
   expect(business.single.data()['documentId'],id);
   final revision=files.single.data()['documentRevision'];
   final again=await WindowsBackendBridge.saveExamResultWithMarksheet(
     profileId:profile,result:result,pdfBytes:pdf);
   expect(again['unchanged'],true);
   expect((await db.collection('_windows_document_outbox').get()).docs.single
      .data()['documentRevision'],revision,
      reason:'Same original Save never creates a second PDF generation');
   expect((await db.collection('_windows_firebase_outbox').get()).docs
      .where((d)=>d.data()['collection']=='exam_center_results'),hasLength(1));
 });
 test('oversized or damaged PDF refuses Save without a partial result',()async{
   if(!AtomicBundlePilot.buildEnabled)return;
   final over=Uint8List(150*1024+1);
   over.setRange(0,8,latin1.encode('%PDF-1.7'));
   over.setRange(over.length-5,over.length,latin1.encode('%%EOF'));
   await expectLater(WindowsBackendBridge.saveExamResultWithMarksheet(
     profileId:profile,result:result,pdfBytes:over),throwsFormatException);
   await expectLater(WindowsBackendBridge.saveExamResultWithMarksheet(
     profileId:profile,result:result,pdfBytes:Uint8List.fromList([1,2,3])),
     throwsFormatException);
   expect((await db.collection('exam_center_results').get()).docs,isEmpty);
   expect((await db.collection('_windows_document_outbox').get()).docs,isEmpty);
 });
 test('foreign student or stale school profile cannot retain a marksheet',()async{
   if(!AtomicBundlePilot.buildEnabled)return;
   await expectLater(WindowsBackendBridge.saveExamResultWithMarksheet(
     profileId:'not-active',result:result,pdfBytes:pdf),throwsStateError);
   final changed={...result,'studentId':'unknown'};
   await expectLater(WindowsBackendBridge.saveExamResultWithMarksheet(
     profileId:profile,result:changed,pdfBytes:pdf),throwsStateError);
   expect((await db.collection('_windows_document_outbox').get()).docs,isEmpty);
 });
}
