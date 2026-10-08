import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/main_dashboard_screen_windows.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_settings.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_fee_structure.dart';
import '../lib/platform/platform_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key: jsonEncode({
      'managed':true, 'schoolId':school, 'uid':'fee-admin', 'firebaseRefreshToken':'saved',
      'projectId':platformProjectId, 'folderId':'managed',
      'endpoint':'https://saarthi-oauth-staging.onrender.com/school-cloud',
      'email':'test@school.example', 'storageReady':false,
    })});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('fees-${DateTime.now().microsecondsSinceEpoch}', identity:{'schoolId':school, 'schoolSyncId':school});
    await WindowsLocalSecurity.initialize();
    await WindowsLocalSecurity.create(adminId:'School admin', password:'app-lock-password');
  });
  Future<void> waitFor(WidgetTester tester, Finder target) async {
    for (var i = 0; i < 200 && target.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds:25)));
      await tester.pump(const Duration(milliseconds:50));
    }
    expect(target, findsOneWidget, reason: 'Fee UI operation did not complete');
  }
  Future<T?> io<T>(WidgetTester tester, Future<T> Function() action) async {
    T? value;
    Object? error;
    StackTrace? stack;
    var done = false;
    await tester.runAsync(() async {
      unawaited(action().then<void>((result) {
        value = result;
        done = true;
      }, onError: (Object e, StackTrace st) {
        error = e;
        stack = st;
        done = true;
      }));
    });
    for (var i = 0; i < 200 && !done; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds:25)));
      await tester.pump(const Duration(milliseconds:50));
    }
    expect(done, true, reason: 'Fee storage operation did not complete');
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return value;
  }
  test('session fee changes preserve unknown legacy heads and decimals; restart retains pending changes and other sessions', () async {
    final session=await WindowsFeeStructure.currentSession();
    await db.collection('fee_settings').doc('Class_1').set({'fees':{'Tuition Fees':125.5,'Legacy Custom Fee':35},'configured':true});
    await WindowsFeeStructure.save('Class 1', session, {'Tuition Fees':175.75});
    await WindowsFeeStructure.save('Class 1', '2000-2001', {'Tuition Fees':20});
    final origin=db.activeProfileId;
    await db.resetVolatileSession();await db.switchProfile('fee-away');
    await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
    final active=await WindowsFeeStructure.load('Class 1');
    expect(active['fees'],{'Tuition Fees':175.75,'Legacy Custom Fee':35});
    expect((await WindowsFeeStructure.load('Class 1',session:'2000-2001'))['fees'],{'Tuition Fees':20});
    expect((await db.collection('fee_settings').doc('Class_1').get()).data()?['fees'],{'Tuition Fees':125.5,'Legacy Custom Fee':35});
    expect((await db.collection('_windows_firebase_outbox').get()).docs.length,3);
  });
  testWidgets('local save locks inputs and restart remains read-only; edit requires full wait and correct App Lock', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400,1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home:FeeCollectionSettingsScreen()));await waitFor(tester, find.text('Save / Update Fee Structure'));
    expect(find.text('Save / Update Fee Structure'),findsOneWidget);
    await tester.enterText(find.byType(TextField).first,'125.5');
    await tester.tap(find.text('Save / Update Fee Structure'));await waitFor(tester, find.text('Edit Fee Structure'));
    expect(find.text('Edit Fee Structure'),findsOneWidget);
    expect(find.byType(TextField),findsNothing);expect(find.text('₹ 125.5'),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home:FeeCollectionSettingsScreen()));await waitFor(tester, find.text('Edit Fee Structure'));
    expect(find.text('Edit Fee Structure'),findsOneWidget);expect(find.byType(TextField),findsNothing);
    await tester.tap(find.text('Edit Fee Structure'));await waitFor(tester, find.text('Security Waiting Period'));
    expect(find.text('Security Waiting Period'),findsOneWidget);
    expect(find.text('Verify & Continue'),findsNothing);
    final session=await io(tester, () => WindowsFeeStructure.currentSession());
    final id=WindowsFeeStructure.documentId('Class 1',session!);
    final deadline=await io(tester, () async => (await db.collection('_local_fee_edit_locks').doc(id).get()).data()?['unlockAt']);
    await tester.tap(find.text('Cancel'));await tester.pumpAndSettle();
    await tester.tap(find.text('Edit Fee Structure'));await waitFor(tester, find.text('Security Waiting Period'));
    final retained=await io(tester, () async => (await db.collection('_local_fee_edit_locks').doc(id).get()).data()?['unlockAt']);
    expect(retained,deadline);
    await tester.pump(const Duration(seconds:30));await tester.pump();
    expect(find.text('App Lock Verification'),findsOneWidget);
    await tester.enterText(find.byType(TextField),'wrong-password');
    await tester.tap(find.text('Verify & Continue'));await waitFor(tester, find.text('Galat App Lock Password.'));
    expect(find.text('Galat App Lock Password.'),findsOneWidget);
    await tester.enterText(find.byType(TextField),'app-lock-password');
    await tester.tap(find.text('Verify & Continue'));await waitFor(tester, find.text('Save / Update Fee Structure'));await tester.pumpAndSettle();
    expect(find.text('Save / Update Fee Structure'),findsOneWidget);
    await tester.enterText(find.byType(TextField).first,'200');
    await tester.tap(find.text('Save / Update Fee Structure'));await waitFor(tester, find.text('Edit Fee Structure'));
    expect(find.text('Edit Fee Structure'),findsOneWidget);expect(find.byType(TextField),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('saved custom fee heads remain visible and editable through the protected flow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400,1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await io(tester, () async => WindowsFeeStructure.save('Class 1',await WindowsFeeStructure.currentSession(),{'Legacy Custom Fee':35.25,'Tuition Fees':125.5}));
    await tester.pumpWidget(const MaterialApp(home:FeeCollectionSettingsScreen()));await waitFor(tester, find.text('Edit Fee Structure'));
    expect(find.text('Edit Fee Structure'),findsOneWidget);
    await tester.scrollUntilVisible(find.text('Legacy Custom Fee'),300,scrollable:find.byType(Scrollable).last);
    expect(find.text('Legacy Custom Fee'),findsOneWidget);
    expect(find.text('₹ 35.25'),findsOneWidget);
    expect(find.byType(TextField),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
