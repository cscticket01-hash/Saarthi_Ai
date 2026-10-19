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
    debugPrint('Fee fixture: initialize');
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key: jsonEncode({
      'managed':true, 'schoolId':school, 'uid':'fee-admin', 'firebaseRefreshToken':'saved',
      'projectId':platformProjectId, 'folderId':'managed',
      'endpoint':'https://saarthi-oauth-staging.onrender.com/school-cloud',
      'email':'test@school.example', 'storageReady':false,
    })});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    debugPrint('Fee fixture: switch profile');
    await db.switchProfile('fees-${DateTime.now().microsecondsSinceEpoch}', identity:{'schoolId':school, 'schoolSyncId':school});
    debugPrint('Fee fixture: initialize App Lock');
    await WindowsLocalSecurity.initialize();
    await WindowsLocalSecurity.create(adminId:'School admin', password:'app-lock-password');
    debugPrint('Fee fixture: ready');
  });
  Future<void> waitFor(WidgetTester tester, Finder target) async {
    for (var i = 0; i < 200 && target.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds:25)));
      await tester.pump(const Duration(milliseconds:50));
    }
    if (target.evaluate().isEmpty) {
      debugPrint('Fee UI stalled: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}');
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
  test('explicit rename, add and removal persist across restart without touching ledgers, sessions or schools', () async {
    final session = await WindowsFeeStructure.currentSession();
    await WindowsFeeStructure.save('Class 1', session, {'Tuition Fees':125.5, 'Legacy Custom Fee':35});
    await db.collection('fee_ledger').doc('existing').set({'feeItems':{'Tuition Fees':125.5},'totalPaid':50});
    await WindowsFeeStructure.save('Class 1', '2000-2001', {'Old session':20});
    await WindowsFeeStructure.save('Class 1', session, {'Monthly Tuition':175.75,'Transport':40.25}, replaceHeads:true);
    final origin = db.activeProfileId;
    await db.resetVolatileSession(); await db.switchProfile('another-school');
    expect(await WindowsFeeStructure.load('Class 1',session:session),isEmpty);
    await db.switchProfile(origin,identity:{'schoolId':school,'schoolSyncId':school});
    final data = await WindowsFeeStructure.load('Class 1',session:session);
    expect(WindowsFeeStructure.heads(data),['Monthly Tuition','Transport']);
    expect(data['fees'],{'Tuition Fees':0.0,'Legacy Custom Fee':0.0,'Monthly Tuition':175.75,'Transport':40.25});
    expect((await db.collection('fee_ledger').doc('existing').get()).data()?['feeItems'],{'Tuition Fees':125.5});
    expect((await WindowsFeeStructure.load('Class 1',session:'2000-2001'))['fees'],{'Old session':20});
    await WindowsFeeStructure.save('Class 1',session,{},replaceHeads:true);
    final empty = await WindowsFeeStructure.load('Class 1',session:session);
    expect(WindowsFeeStructure.heads(empty),isEmpty);
    expect(empty['configured'],false); expect(empty['feeStructureSaved'],true);
    expect((empty['fees'] as Map).values.every((value)=>value==0),true);
    final pending = (await db.collection('_windows_firebase_outbox').get()).docs;
    expect(pending.any((row) => row.data()['collection']=='fee_settings'),true);
  });
  test('invalid fee names and amounts cannot queue writes', () async {
    final session = await WindowsFeeStructure.currentSession();
    for(final fees in [<String,double>{' ':1}, {'Fee':1,' fee ':2}, {'Fee':double.nan}, {'Fee':-1}]) {
      await expectLater(WindowsFeeStructure.save('Class 1',session,fees,replaceHeads:true),throwsArgumentError);
    }
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  });
  testWidgets('actual editor adds, renames, removes, validates and saves dynamic fee rows', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400,1100));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home:FeeCollectionSettingsScreen()));
    await waitFor(tester,find.text('Save changes'));
    await tester.enterText(find.byKey(const ValueKey('fee-name-0')),'Monthly Tuition');
    await tester.enterText(find.byKey(const ValueKey('fee-amount-0')),'175.75');
    await tester.tap(find.byKey(const ValueKey('add-fee'))); await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('fee-name-20')));
    await tester.enterText(find.byKey(const ValueKey('fee-name-20')),'Transport');
    await tester.enterText(find.byKey(const ValueKey('fee-amount-20')),'40.25');
    await tester.ensureVisible(find.byKey(const ValueKey('delete-fee-1')));
    await tester.tap(find.byKey(const ValueKey('delete-fee-1'))); await tester.pumpAndSettle();
    await tester.tap(find.text('Remove')); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fee-name-1')),findsNothing);
    await tester.ensureVisible(find.text('Save changes'));
    await tester.runAsync(()=>tester.tap(find.text('Save changes')));
    await waitFor(tester,find.text('Edit Fee Structure'));
    final data = await io(tester,()=>WindowsFeeStructure.load('Class 1'));
    expect(WindowsFeeStructure.heads(data!),containsAll(['Monthly Tuition','Transport']));
    expect(WindowsFeeStructure.heads(data),isNot(contains('Admission Fees')));
    expect((data['fees'] as Map)['Monthly Tuition'],175.75);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home:FeeCollectionSettingsScreen()));
    await waitFor(tester,find.text('Edit Fee Structure'));
    expect(find.text('Monthly Tuition'),findsOneWidget);
    expect(find.text('Admission Fees'),findsNothing);
    expect(find.byType(TextField),findsNothing);
    await tester.pumpWidget(const SizedBox());
  },timeout:const Timeout(Duration(minutes:2)));
  testWidgets('local save locks inputs and restart remains read-only; edit requires full wait and correct App Lock', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400,1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    debugPrint('Fee widget: open screen');
    await tester.pumpWidget(const MaterialApp(home:FeeCollectionSettingsScreen()));await waitFor(tester, find.text('Save changes'));
    expect(find.text('Save changes'),findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('fee-amount-0')),'125.5');
    await tester.ensureVisible(find.text('Save changes')); await tester.runAsync(() => tester.tap(find.text('Save changes')));await waitFor(tester, find.text('Edit Fee Structure'));
    expect(find.text('Edit Fee Structure'),findsOneWidget);
    expect(find.byType(TextField),findsNothing);expect(find.text('₹ 125.5'),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugPrint('Fee widget: open screen');
    await tester.pumpWidget(const MaterialApp(home:FeeCollectionSettingsScreen()));await waitFor(tester, find.text('Edit Fee Structure'));
    expect(find.text('Edit Fee Structure'),findsOneWidget);expect(find.byType(TextField),findsNothing);
    await tester.ensureVisible(find.text('Edit Fee Structure')); await tester.runAsync(() => tester.tap(find.text('Edit Fee Structure')));await waitFor(tester, find.text('Security Waiting Period'));
    expect(find.text('Security Waiting Period'),findsOneWidget);
    expect(find.text('Verify & Continue'),findsNothing);
    debugPrint('Fee widget: inspect persisted countdown');
    final session=await io(tester, () => WindowsFeeStructure.currentSession());
    final id=WindowsFeeStructure.documentId('Class 1',session!);
    final deadline=await io(tester, () async => (await db.collection('_local_fee_edit_locks').doc(id).get()).data()?['unlockAt']);
    debugPrint('Fee widget: cancel countdown');
    await tester.runAsync(() => tester.tap(find.text('Cancel')));await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Edit Fee Structure')); await tester.runAsync(() => tester.tap(find.text('Edit Fee Structure')));await waitFor(tester, find.text('Security Waiting Period'));
    final retained=await io(tester, () async => (await db.collection('_local_fee_edit_locks').doc(id).get()).data()?['unlockAt']);
    expect(retained,deadline);
    debugPrint('Fee widget: advance protected wait');
    await tester.pump(const Duration(seconds:30));await tester.pump();
    expect(find.text('App Lock Verification'),findsOneWidget);
    await tester.enterText(find.byType(TextField),'wrong-password');
    await tester.runAsync(() => tester.tap(find.text('Verify & Continue')));await waitFor(tester, find.text('Galat App Lock Password.'));
    expect(find.text('Galat App Lock Password.'),findsOneWidget);
    debugPrint('Fee widget: verify correct App Lock');
    await tester.enterText(find.byType(TextField),'app-lock-password');
    await tester.runAsync(() => tester.tap(find.text('Verify & Continue')));await waitFor(tester, find.text('Save changes'));await tester.pumpAndSettle();
    expect(find.text('Save changes'),findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('fee-amount-0')),'200');
    await tester.ensureVisible(find.text('Save changes')); await tester.runAsync(() => tester.tap(find.text('Save changes')));await waitFor(tester, find.text('Edit Fee Structure'));
    expect(find.text('Edit Fee Structure'),findsOneWidget);expect(find.byType(TextField),findsNothing);
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes:2)));
  testWidgets('saved custom fee heads remain visible and editable through the protected flow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400,1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await io(tester, () async => WindowsFeeStructure.save('Class 1',await WindowsFeeStructure.currentSession(),{'Legacy Custom Fee':35.25,'Tuition Fees':125.5}));
    debugPrint('Fee widget: open screen');
    await tester.pumpWidget(const MaterialApp(home:FeeCollectionSettingsScreen()));await waitFor(tester, find.text('Edit Fee Structure'));
    expect(find.text('Edit Fee Structure'),findsOneWidget);
    await tester.ensureVisible(find.text('Legacy Custom Fee'));
    expect(find.text('Legacy Custom Fee'),findsOneWidget);
    expect(find.text('₹ 35.25'),findsOneWidget);
    expect(find.byType(TextField),findsNothing);
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes:2)));
}
