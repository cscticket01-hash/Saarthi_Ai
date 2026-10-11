import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_student_import.dart';
import 'package:saarthi_ai/windows_connect/central_school_cloud.dart';

void main() {
  testWidgets('Account switch during request discards old-school response and disables import', (tester) async {
    var identity='school-a/profile-a';
    final pending=Completer<Map<String,dynamic>>();
    var calls=0;
    Future<Map<String,dynamic>> call(String action,[Map<String,dynamic> body=const {}]) async {calls++;return pending.future;}
    await tester.pumpWidget(MaterialApp(home:WindowsStudentImport(cloudCall:call,readIdentity:()async=>identity)));
    await tester.pump();
    await tester.tap(find.text('Validate and preview'));await tester.pump();
    identity='school-b/profile-b';
    pending.complete({'success':true,'planId':'old-school-plan','errors':[],'operations':[{'studentId':'private-old-school'}]});
    await tester.pumpAndSettle();
    expect(find.textContaining('Server preview (redacted)'),findsNothing);
    expect(find.textContaining('private-old-school'),findsNothing);
    expect(find.textContaining('School identity changed.'),findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton,'Validate and preview')).onPressed,isNull);
    expect(calls,1);
    await tester.pumpWidget(const SizedBox());
  });

  for(final initial in ['pending','conflict','lost-ack']) {
    testWidgets('$initial retains original plan and retries same ID until verified', (tester) async {
      final submitted=<String>[];
      var previews=0;
      Future<Map<String,dynamic>> call(String action,[Map<String,dynamic> body=const {}]) async {
        if(action.endsWith('/preview')) { previews++; return {'success':true,'planId':'original-plan','errors':[],'operations':[{'operationId':'stable-operation'}]}; }
        if(action.endsWith('/commit')) {
          submitted.add(body['planId'] as String);
          if(submitted.length==1) {
            if(initial=='lost-ack') throw TimeoutException('Unknown cloud acknowledgement');
            return {'success':true,'planId':'original-plan','verified':false,'outcomes':[{'operationId':'stable-operation','state':initial}],'remaining':1};
          }
          return {'success':true,'planId':'original-plan','verified':true,'outcomes':[{'operationId':'stable-operation','state':'verified'}],'remaining':0};
        }
        throw StateError('Unexpected route $action');
      }
      await tester.pumpWidget(MaterialApp(home:WindowsStudentImport(cloudCall:call,readIdentity:()async=>'school-a/profile-a')));
      await tester.tap(find.text('Validate and preview')); await tester.pumpAndSettle();
      await tester.tap(find.text('Review and commit')); await tester.pumpAndSettle();
      expect(submitted,isEmpty);
      await tester.tap(find.text('Confirm')); await tester.pumpAndSettle();
      expect(find.text('Retry original import plan'),findsOneWidget);
      expect(find.textContaining('Server preview (redacted)'),findsOneWidget);
      await tester.tap(find.text('Retry original import plan')); await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm')); await tester.pumpAndSettle();
      expect(submitted,['original-plan','original-plan']); expect(previews,1);
      expect(find.textContaining('Server preview (redacted)'),findsNothing);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton,'Review and commit')).onPressed,isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('Expired import requires explicit new preview and never auto replans', (tester) async {
    var previews=0,commits=0;
    Future<Map<String,dynamic>> call(String action,[Map<String,dynamic> body=const {}]) async {
      if(action.endsWith('/preview')) {previews++;return {'success':true,'planId':'plan-$previews','errors':[]};}
      commits++;throw CentralCloudException(409,'school_cloud','Import preview changed or expired');
    }
    await tester.pumpWidget(MaterialApp(home:WindowsStudentImport(cloudCall:call,readIdentity:()async=>'school-a/profile-a')));
    await tester.tap(find.text('Validate and preview'));await tester.pumpAndSettle();
    await tester.tap(find.text('Review and commit'));await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));await tester.pumpAndSettle();
    expect(previews,1);expect(commits,1);
    expect(find.textContaining('The import plan changed or expired.'),findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton,'Retry original import plan')).onPressed,isNull);
    await tester.tap(find.text('Validate and preview'));await tester.pumpAndSettle();
    expect(previews,2);expect(commits,1);
    expect(find.text('Review and commit'),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Mismatched response plan cannot clear original preview', (tester) async {
    Future<Map<String,dynamic>> call(String action,[Map<String,dynamic> body=const {}]) async => action.endsWith('/preview')
      ? {'success':true,'planId':'original-plan','errors':[]}
      : {'success':true,'planId':'foreign-plan','verified':true,'outcomes':[],'remaining':0};
    await tester.pumpWidget(MaterialApp(home:WindowsStudentImport(cloudCall:call,readIdentity:()async=>'school-a/profile-a')));
    await tester.tap(find.text('Validate and preview'));await tester.pumpAndSettle();
    await tester.tap(find.text('Review and commit'));await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));await tester.pumpAndSettle();
    expect(find.text('Retry original import plan'),findsOneWidget);
    expect(find.textContaining('Server preview (redacted)'),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
