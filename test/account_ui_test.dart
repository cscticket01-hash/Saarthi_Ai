import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/managed_developer_panel.dart';
import '../lib/school_password_panel.dart';
void main(){
 testWidgets('Schools table follows requested order and asks for initial password',(tester)async{
  await tester.binding.setSurfaceSize(const Size(1600,1000));addTearDown(()=>tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home:Scaffold(body:ManagedDeveloperPanel(schools:const [],refresh:()async{},legacyDelete:(_)async{}))));
  final table=tester.widget<DataTable>(find.byType(DataTable));expect(table.columns.map((c)=>(c.label as Text).data),['School Name','Activity','Total Students','Licence Expiry','Action','Total Data Used']);
  await tester.tap(find.text('Create School'));await tester.pumpAndSettle();expect(find.text('School Login Email'),findsOneWidget);expect(find.text('Initial Password (12–128 characters)'),findsOneWidget);expect(find.text('Confirm Password'),findsOneWidget);expect(find.text('Forgot Password'),findsNothing);
 });
 testWidgets('password change never submits mismatching passwords',(tester)async{
  bool called=false;await tester.pumpWidget(MaterialApp(home:Scaffold(body:SchoolPasswordPanel(change:(_,__)async{called=true;}))));
  await tester.tap(find.text('Change Password'));await tester.pump();expect(called,false);expect(find.textContaining('matching passwords'),findsOneWidget);
 });
}
