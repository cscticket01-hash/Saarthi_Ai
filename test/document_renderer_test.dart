import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/school_document_renderer.dart';
void main(){
 test('default and all sixteen selected layouts generate printable PDFs',()async{
  final output=Directory('build/document-previews');await output.create(recursive:true);
  final sample={'schoolName':'Vidya Saarthi School','name':'Arup Das','class':'Class 5','studentClass':'Class 5','rollNo':'12','dob':'15/03/2015','parentName':'Guardian Name','teacherId':'T-12','designation':'Senior Teacher','subject':'Mathematics','examName':'Final Exam','marks':{'English':84,'Mathematics':91,'Science':87},'fullMarks':100,'totalMarks':262,'percentage':'87.3','result':'PASS','feeItems':{'Tuition':1000,'Exam':200},'totalAmount':1200,'receiptNo':'VS-001','dateText':'01/10/2026'};
  for(final kind in schoolTemplateNames.keys){for(var i=-1;i<4;i++){
   final bytes=await renderSchoolDocument(kind:kind,template:i,data:sample,qr:'{"v":2,"type":"student","personId":"Class 5_Roll_12","linkToken":"${'a'*48}","firebaseProjectId":"school-one","googleScriptUrl":"https://script.google.com/macros/s/longSchoolScriptIdentifier_0123456789/exec","firebaseLink":"exampleFirebaseConnection"}',photo:await File('assets/school_logo.png').readAsBytes(),logo:await File('assets/school_logo.png').readAsBytes());
   expect(String.fromCharCodes(bytes.take(4)),'%PDF');expect(bytes.length,greaterThan(500));await File('${output.path}/${kind}_$i.pdf').writeAsBytes(bytes);
  }}
 });
}
