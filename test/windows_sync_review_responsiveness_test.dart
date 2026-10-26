import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_sync_conflict_review.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final item = <String,dynamic>{'id':'review', 'documentId':'review',
    'collection':'fee_payments', 'schoolId':school, 'syncState':'conflict',
    '_queueCollection':'_windows_firebase_outbox',
    'data':{'schoolId':school,'amount':100}};
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await FirebaseFirestore.instance.switchProfile('responsive-${DateTime.now().microsecondsSinceEpoch}',
      identity:{'schoolSyncId':school});
  });
  Future<void> open(WidgetTester tester, Future<Map<String,dynamic>?> Function(String,String) queue,
      Future<Map<String,dynamic>> Function(Map<String,dynamic>) cloud) async {
    await tester.pumpWidget(MaterialApp(home:Builder(builder:(context)=>Scaffold(body:
      TextButton(onPressed:()=>showWindowsConflictReview(context,item,
        verificationTimeout:const Duration(seconds:2),queueReader:queue,cloudReader:cloud),
        child:const Text('Review'))))));
    await tester.tap(find.text('Review')); await tester.pumpAndSettle();
    await tester.tap(find.text('Verify cloud version')); await tester.pump();
  }
  testWidgets('local queue stall times out and late completion cannot start cloud read', (tester) async {
    final pending = Completer<Map<String,dynamic>?>(); var cloudCalls = 0;
    await open(tester,(_,__)=>pending.future,(_)async{cloudCalls++;return {'schoolId':school,'syncProtocol':2,'records':{'review':{'schoolId':school,'amount':100,'_syncRevision':'synthetic'}}};});
    expect(find.textContaining('Reading local pending record…'),findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton,'Close')).onPressed,isNotNull);
    await tester.pump(const Duration(seconds:3)); await tester.pumpAndSettle();
    expect(find.textContaining('timed out during Reading local pending record'),findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton,'Verify cloud version')).onPressed,isNotNull);
    pending.complete(item); await tester.pump();
    expect(cloudCalls,0); expect(find.text('Use local version'),findsNothing);
    await tester.tap(find.text('Verify cloud version')); await tester.pumpAndSettle();
    expect(cloudCalls,1); expect(find.text('Record already synced'),findsOneWidget);
    expect(item['syncState'],'conflict');
    expect(tester.takeException(),isNull); await tester.pumpWidget(const SizedBox());
  });
  testWidgets('closing a hung cloud verification preserves originals and ignores late response', (tester) async {
    final pending = Completer<Map<String,dynamic>>();
    await open(tester,(_,__)async=>item,(_)=>pending.future);
    await tester.pump();
    expect(find.textContaining('Reading authenticated cloud version…'),findsOneWidget);
    await tester.tap(find.text('Close')); await tester.pumpAndSettle();
    pending.complete({'schoolId':school,'syncProtocol':2,'records':{'review':
      {'schoolId':school,'amount':100,'_syncRevision':'synthetic'}}});
    await tester.pump(const Duration(seconds:3)); await tester.pumpAndSettle();
    expect(find.text('Review sync conflict'),findsNothing);
    expect(item['syncState'],'conflict'); expect(tester.takeException(),isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
