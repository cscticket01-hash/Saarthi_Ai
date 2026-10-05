import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_ui_localization.dart' as ui;
import '../lib/windows_ui_translations.dart';
import '../lib/windows_admin_sidebar.dart';
import '../lib/windows_license_gate.dart';
import '../lib/windows_platform_client.dart';
import '../lib/windows_notice_delivery.dart';
import '../lib/windows_monthly_attendance.dart';
import '../lib/windows_backend_bridge.dart';
import '../lib/windows_exam_service.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_local_firestore.dart' as local;
import '../lib/windows_preferences_reset.dart';
import '../lib/windows_local_settings.dart';
import '../lib/windows_sync_engine.dart';
import '../lib/main_dashboard_screen_windows.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    WindowsPlatformClient.skippedOverride = null;
    ui.WindowsUiLanguage.change('en');
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await local.FirebaseFirestore.instance.switchProfile('test-${DateTime.now().microsecondsSinceEpoch}');
  });
  tearDown(() => ui.WindowsUiLanguage.change('en'));

  testWidgets('both sidebar modes render all ten identical options and separate bottom logout', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final drawer in [false, true]) {
      final sidebar = WindowsAdminSidebar(header: const SizedBox(height: 80),
        onSelected: (_) {}, onLogout: () {});
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: drawer ? Drawer(
        width: WindowsAdminSidebar.width, child: sidebar) : sidebar)));
      await tester.pumpAndSettle();
      for (final entry in WindowsAdminSidebar.entries) {
        expect(find.byKey(ValueKey('admin-nav-${entry.$1.name}')), findsOneWidget);
      }
      expect(tester.getSize(find.byType(WindowsAdminSidebar)).width, 320);
      final logout = find.byKey(const ValueKey('admin-logout'));
      expect(logout, findsOneWidget);
      expect(tester.getTopLeft(logout).dy, greaterThan(1400));
      expect(find.ancestor(of: logout, matching: find.byType(ListTile)), findsNothing);
    }
  });
  testWidgets('short sidebar scrolls without overlapping logout', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(height: 210,
      child: WindowsAdminSidebar(header: const SizedBox(height: 50), onSelected: (_) {}, onLogout: () {})))));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -1800));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('admin-logout')), findsOneWidget);
  });
  testWidgets('trial warning reserves header space and never covers settings', (tester) async {
    final state = WindowsLicenseState(allowed: true, status: 'trial', expiresAt: DateTime.now().add(const Duration(days: 3)));
    WindowsPlatformClient.instance.state.value = state;
    await tester.pumpWidget(MaterialApp(home: WindowsLicenseGate(connectionBuilder: (_) => const SizedBox(),
      child: Scaffold(appBar: AppBar(title: const Text('Dashboard'), actions: [IconButton(
        key: const ValueKey('settings-test'), onPressed: () {}, icon: const Icon(Icons.settings))])))));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('license-skip-button')));
    await tester.pumpAndSettle();
    expect(find.text('License not activated — Activate now'), findsOneWidget);
    final bannerBottom = tester.getBottomLeft(find.byType(WindowsTrialBanner)).dy;
    expect(tester.getTopLeft(find.byKey(const ValueKey('settings-test'))).dy, greaterThanOrEqualTo(bannerBottom));
  });
  testWidgets('licensed schools have no trial warning', (tester) async {
    await tester.pumpWidget(MaterialApp(home: WindowsTrialBanner(state: WindowsLicenseState(
      allowed: true, status: 'licensed', expiresAt: DateTime.now().add(const Duration(days: 365))))));
    expect(find.byType(Icon), findsNothing);
  });
  testWidgets('expired warning explicitly says ended', (tester) async {
    await tester.pumpWidget(MaterialApp(home: WindowsTrialBanner(state: WindowsLicenseState(
      allowed: false, status: 'expired', expiresAt: DateTime.now()))));
    expect(find.textContaining('licence ended'), findsOneWidget);
  });
  testWidgets('all languages update const labels and fields without losing form state', (tester) async {
    final controller = TextEditingController(text: 'A school student');
    addTearDown(controller.dispose);
    await tester.pumpWidget(ValueListenableBuilder<String>(valueListenable: ui.WindowsUiLanguage.changed,
      builder: (_, language, __) => MaterialApp(locale: Locale(language),
        supportedLocales: const [Locale('en'), Locale('hi'), Locale('bn'), Locale('as')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: Column(children: [const ui.Text('Save'), TextField(controller: controller,
          decoration: const ui.InputDecoration(labelText: 'Student Name'))])))));
    final field = tester.state<EditableTextState>(find.byType(EditableText));
    for (final language in ['hi', 'bn', 'as', 'en']) {
      ui.WindowsUiLanguage.change(language);
      await tester.pumpAndSettle();
      expect(find.text(ui.WindowsUiLanguage.translate('Save')), findsOneWidget);
      expect(find.text(ui.WindowsUiLanguage.translate('Student Name')), findsOneWidget);
      expect(controller.text, 'A school student');
      expect(identical(field, tester.state<EditableTextState>(find.byType(EditableText))), isTrue);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('student and school data can remain verbatim in every language', (tester) async {
    ui.WindowsUiLanguage.change('hi');
    await tester.pumpWidget(const MaterialApp(home: ui.Text('Save', translate: false)));
    expect(find.text('Save'), findsOneWidget);
  });
  test('language survives reopening and is independent of the school data namespace', () {
    ui.WindowsUiLanguage.change('bn');
    ui.WindowsUiLanguage.changed.value = 'en';
    ui.WindowsUiLanguage.restore();
    expect(ui.WindowsUiLanguage.current,'bn');
  });
  test('translation templates preserve dates and counts', () {
    ui.WindowsUiLanguage.change('hi');
    final translated = ui.WindowsUiLanguage.translate('Free trial: 3 days remaining. Ends 9/10/2026. Add a licence key to continue.');
    expect(translated, contains('3')); expect(translated, contains('9/10/2026'));
    expect(translated, isNot(contains('days remaining')));
  });
  test('entire catalogue covers all supported translations', () {
    expect(windowsUiTranslations.length, greaterThan(500));
    for (final entry in windowsUiTranslations.entries) {
      for (final language in ['hi', 'bn', 'as']) expect(entry.value[language], isNotEmpty, reason: entry.key);
    }
  });
  test('notice requires real QR-linked students and registered student-app users', () {
    final student = {'mobileLinkToken': 'a' * 48};
    expect(schoolNoticeRecipients([], []), 0);
    expect(schoolNoticeRecipients([student], []), 0);
    expect(schoolNoticeRecipients([{}], [{'role': 'student'}]), 0);
    expect(schoolNoticeRecipients([{'mobileLinkToken':'invalid'}], [{'role':'student'}]), 0);
    expect(schoolNoticeRecipients([student], [{'role': 'teacher'}]), 0);
    expect(schoolNoticeRecipients([student], [{'role': 'student'}]), 1);
    expect(schoolNoticeRecipients([student], [{'role': 'student'}, {'role': 'student'}]), 1);
  });
  test('offline exam definitions and subjects save with Local Data OFF', () async {
    final saved = await WindowsExamService.request({'action':'save_exam', 'examName':'Final Exam',
      'studentClass':'Class 5', 'subjects':['English','Maths'], 'isFinal':true, 'fullMarks':100, 'passMarks':33});
    expect(saved['success'], true); expect(saved['windowsLocalFallback'], true); expect(saved['sessionOnly'], true);
    final listed = await WindowsExamService.request({'action':'list_exam_center'});
    expect((listed['exams'] as List).single['subjects'], ['English','Maths']);
    expect((listed['exams'] as List).single['isFinal'], true);
  });
  test('exam actions reject unrelated mutations', () async {
    expect(() => WindowsBackendBridge.localExamAction({'action':'delete_student'}), throwsArgumentError);
  });
  test('offline exam results preserve timestamps and stable IDs on retries', () async {
    final body = {'action':'save_exam_result', 'examId':'exam-one', 'studentId':'p-one',
      'result':'FAIL','timestamp':1234567,'marks':{'Maths':20}};
    await WindowsBackendBridge.localExamAction(body); await WindowsBackendBridge.localExamAction(body);
    final listed = await WindowsBackendBridge.localExamAction({'action':'list_exam_center'});
    expect((listed['results'] as List).length, 1);
    expect((listed['results'] as List).single['timestamp'], 1234567);
  });
  testWidgets('school branding memory cannot carry School A into School B',(tester)async{
    await tester.binding.setSurfaceSize(const Size(1500,1600));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    final db=local.FirebaseFirestore.instance;
    await tester.runAsync(()async{
      await db.collection('school_config').doc('school_profile_cache').set({'schoolName':'Private School A','principalName':'Principal A'});
      await tester.pumpWidget(const MaterialApp(home:SchoolSettingsScreen()));
      await Future<void>.delayed(const Duration(milliseconds:200));
    });
    await tester.pump();
    bool hasName(String name)=>find.byWidgetPredicate((w)=>w is TextField&&w.controller?.text==name).evaluate().isNotEmpty;
    expect(hasName('Private School A'),true);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(()=>db.switchProfile('branding-school-b'));
    await tester.pumpWidget(const MaterialApp(home:SchoolSettingsScreen()));
    expect(hasName('Private School A'),false);
    expect(hasName('Principal A'),false);
    await tester.pumpWidget(const SizedBox());
  });
  test('offline exams and queued edits stay inside their original school', () async {
    final db = local.FirebaseFirestore.instance;
    final original = db.activeProfileId;
    await WindowsExamService.request({'action':'save_exam','examId':'exam-a','examName':'School A exam'});
    await db.switchProfile('isolated-school-b');
    final empty = await WindowsExamService.request({'action':'list_exam_center'});
    expect(empty['exams'], isEmpty);
    expect((await db.collection('_windows_exam_pending').get()).docs, isEmpty);
    await db.switchProfile(original);
    expect((await WindowsExamService.request({'action':'list_exam_center'}))['exams'], hasLength(1));
  });
  test('app reset removes passwords and links while preserving all school data and trial identity', () async {
    FlutterSecureStorage.setMockInitialValues({'vs_trial_start':'2026-09-30','vs_installation_id':'original-device',
      'vs_license_cache':'existing-licence','vidya_saarthi_windows_admin_password_v1':'remove-password',
      'vidya_saarthi_windows_admin_id_v1':'Old admin','vidya_saarthi_windows_section_password_v1_admin':'old-section'});
    await WindowsLocalSecurity.initialize();
    await WindowsExternalConnections.save(googleEmail:'example@gmail.com',googleScriptUrl:'https://script.google.com/macros/s/example/exec');
    final db = local.FirebaseFirestore.instance;
    final profile = db.activeProfileId;
    for (final collection in ['students_directory','teachers_directory','fee_payments','school_calendar','school_notices','_windows_exam_pending']) {
      await db.collection(collection).doc('preserve').set({'keep':true});
    }
    await db.collection('school_settings').doc('document_templates').set({'studentId':3});
    await WindowsPreferencesReset.reset();
    expect(db.activeProfileId, isNot(profile));
    expect(WindowsLocalSecurity.configured, false);
    expect(await WindowsExternalConnections.googleScriptUrl(), isEmpty);
    await db.switchProfile(profile); // reconnecting the same profile restores it
    for (final collection in ['students_directory','teachers_directory','fee_payments','school_calendar','school_notices','_windows_exam_pending']) {
      expect((await db.collection(collection).doc('preserve').get()).data()?['keep'], true);
    }
    expect(db.activeProfileId, profile); expect(await WindowsRuntimeFlags.localStorageEnabled(), false);
    expect((await db.collection('school_settings').doc('document_templates').get()).data()?['studentId'], 3);
    const secure = FlutterSecureStorage();
    expect(await secure.read(key:'vs_trial_start'),'2026-09-30');
    expect(await secure.read(key:'vs_installation_id'),'original-device');
    expect(await secure.read(key:'vs_license_cache'),isNull);
    expect(await secure.read(key:'vidya_saarthi_windows_admin_password_v1'),isNull);
    expect(await secure.read(key:'vidya_saarthi_windows_section_password_v1_admin'),isNull);
    await WindowsSyncEngine.instance.pauseForAppReset();
  });
  test('offline publish retains a pending notice without reporting delivery', () async {
    await expectLater(WindowsPlatformClient.instance.publishNotice('unsent', {'title':'Example'}), throwsStateError);
    final pending=(await local.FirebaseFirestore.instance.collection('school_notices').doc('unsent').get()).data();
    expect(pending?['title'],'Example');
    expect(pending?['deliveryStatus'],'sync_pending');
  });
  test('monthly attendance honours closures, duplicates, role and future days', () {
    final january = windowsMonthlyAttendance(records: [
      {'date':'2026-01-01','role':'student','personId':'s1','checkIn':1},
      {'date':'2026-01-01','role':'student','personId':'s1','checkIn':2,'checkOut':3},
      {'date':'2026-01-02','role':'student','personId':'s1','checkIn':1},
      {'date':'2026-01-01','role':'teacher','personId':'t1','checkIn':1},
      {'date':'2026-02-01','role':'student','personId':'s1','checkIn':1},
    ], calendar:[{'date':'2026-01-02','isOpen':false}], role:'student', people:1,
      startYear:2026, rolloverMonth:1, today:DateTime(2026,1,2));
    expect(january[0],100); expect(january[1],0);
  });
  test('April academic year includes next January but excludes the previous January', () {
    final months = windowsMonthlyAttendance(records: [
      {'date':'2027-01-01','role':'student','personId':'s1','checkIn':1},
      {'date':'2026-01-01','role':'student','personId':'s1','checkIn':1},
    ], calendar:[], role:'student', people:1, startYear:2026, rolloverMonth:4, today:DateTime(2027,1,1));
    expect(months[0],100);
  });
  test('monthly attendance does not invent attendance without check-ins or people', () {
    final months = windowsMonthlyAttendance(records:[],calendar:[],role:'student',people:0,
      startYear:2026,rolloverMonth:1,today:DateTime(2026,10,2));
    expect(months.every((m)=>m==0),isTrue);
  });
  testWidgets('Exam Center shows creation tools without Firebase or Google', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600,1800));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: ExamCenterScreen()));
      await Future<void>.delayed(const Duration(milliseconds:250));
    });
    for (var i=0;i<30;i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds:30)));
      await tester.pump(const Duration(milliseconds:30));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    expect(find.text('Create Exam'), findsWidgets);
    expect(find.textContaining('Remote school connection ready nahi hai'), findsNothing);
    expect(tester.takeException(),isNull);
  });
  testWidgets('monthly analytics filters show distinct real fee values', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800,2200));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      final db=local.FirebaseFirestore.instance;
      await db.collection('fee_payments').doc('jan').set({'amount':500,'timestamp':DateTime(DateTime.now().year,1,10).millisecondsSinceEpoch});
      await db.collection('fee_payments').doc('feb').set({'amount':900,'timestamp':DateTime(DateTime.now().year,2,10).millisecondsSinceEpoch});
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home:AdminAnalyticsScreen()));
      await Future<void>.delayed(const Duration(milliseconds:250));
    });
    for(var i=0;i<30;i++) {
      await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:30)));
      await tester.pump(const Duration(milliseconds:30));
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
    final menus=find.byType(PopupMenuButton<int>);
    expect(menus, findsNWidgets(5));
    await tester.tap(menus.at(1)); await tester.pumpAndSettle();
    await tester.tap(find.text('Jan ${DateTime.now().year}')); await tester.pumpAndSettle();
    expect(find.text('Jan: ₹500'),findsOneWidget);
    await tester.tap(menus.at(1)); await tester.pumpAndSettle();
    await tester.tap(find.text('Feb ${DateTime.now().year}')); await tester.pumpAndSettle();
    expect(find.text('Feb: ₹900'),findsOneWidget);
    expect(tester.takeException(),isNull);
  });

}
