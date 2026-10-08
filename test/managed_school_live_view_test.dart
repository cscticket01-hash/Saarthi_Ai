import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/managed_school_live_view.dart';
void main() {
  testWidgets('automatic website delta refresh retains unchanged groups, removes acknowledged rows and stops when closed', (tester) async {
    var calls=0;final checkpoints=<Map<String,String>>[];
    Future<Map<String,dynamic>> load(Map<String,String> known)async{
      checkpoints.add(known);calls++;
      return {'schoolId':'school-a','revisions':{'exams':calls==1?'r1':'r2'},
        'groups':calls==1?{'exams':{'count':1,'rows':[{'id':'unit','schoolId':'school-a','examName':'Unit Test'}]}}:
          calls==2?{}:{'exams':{'count':0,'rows':[]}}};
    }
    await tester.pumpWidget(MaterialApp(home:Builder(builder:(context)=>TextButton(
      onPressed:()=>showDialog<void>(context:context,builder:(_)=>ManagedSchoolLiveView(
        schoolId:'school-a',schoolName:'School A',load:load)),child:const Text('Open')))));
    await tester.tap(find.text('Open'));await tester.pumpAndSettle();
    expect(find.text('Unit Test'),findsOneWidget);
    await tester.pump(const Duration(seconds:15));await tester.pump();
    expect(checkpoints.last['exams'],'r1');expect(find.text('Unit Test'),findsOneWidget);
    await tester.pump(const Duration(seconds:15));await tester.pump();
    expect(find.text('Unit Test'),findsNothing);expect(find.text('No acknowledged records.'),findsOneWidget);
    await tester.tap(find.text('Close'));await tester.pumpAndSettle();final stopped=calls;
    await tester.pump(const Duration(seconds:30));expect(calls,stopped);
  });
  testWidgets('foreign school response is rejected; never rendered as verified data', (tester) async {
    await tester.pumpWidget(MaterialApp(home:ManagedSchoolLiveView(
      schoolId:'school-a',schoolName:'School A',load:(_)async=>{
        'schoolId':'school-b','groups':{},'revisions':{}})));
    await tester.pump();await tester.pump();
    expect(find.textContaining('Cloud verification failed'),findsOneWidget);
    expect(find.textContaining('Last verified:'),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
