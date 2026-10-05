import 'dart:io';
import 'dart:ui' as rendering;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_staff_payroll.dart';
import '../lib/windows_other_staff.dart';
import '../lib/windows_local_firestore.dart' as local;
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_license_gate.dart';
import '../lib/windows_platform_client.dart';
import '../lib/windows_ui_localization.dart' as ui;
import '../lib/windows_html_shim.dart' as html;
import '../lib/windows_app_reset.dart';
import '../lib/windows_local_settings.dart';
import '../lib/windows_local_session.dart';
import '../lib/windows_sync_engine.dart';
import '../lib/windows_school_operations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = local.FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    WindowsPlatformClient.skippedOverride = null;
    ui.WindowsUiLanguage.change('en');
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('payroll-${DateTime.now().microsecondsSinceEpoch}');
  });
  Future<Map<String,dynamic>> teacher() async {
    await db.collection('teachers_directory').doc('teacher-doc').set({'name':'School Teacher','teacherId':'T-11'});
    return (await StaffPayroll.staff(db.activeProfileId)).single;
  }
  test('salary money is exact in paise and rejects negative, NaN and excess decimals', () {
    expect(StaffPayroll.money('12000.05'),1200005);
    expect(StaffPayroll.net(basic:100000,allowance:20000,bonus:1050,overtime:900,deduction:5000),116950);
    for (final value in ['-2','NaN','Infinity','2.001','1e8']) expect(() => StaffPayroll.money(value), throwsFormatException);
    expect(() => StaffPayroll.net(basic:100,deduction:101),throwsArgumentError);
  });
  test('monthly salary is idempotent and teachers retain mobile identity', () async {
    final person = await teacher(); final profile = db.activeProfileId;
    final row = await StaffPayroll.save(profile,person,'2026-11',basic:1200000,allowance:100000);
    await StaffPayroll.save(profile,person,'2026-11',basic:1200000,allowance:100000);
    await StaffPayroll.save(profile,person,'2026-12',basic:1250000);
    expect((await db.collection('teacher_salary').get()).docs,hasLength(2));
    expect(row['teacherId'],'T-11'); expect(row['amount'],13000);
    expect(row['status'],'Pending'); expect(row['balancePaise'],1300000);
  });
  test('partial payments, repeated submit and overpayment preserve financial history', () async {
    final person = await teacher(); final profile = db.activeProfileId;
    final row = await StaffPayroll.save(profile,person,'2026-11',basic:100000);
    Future<void> pay(String id,int amount) => StaffPayroll.recordPayment(profile,row['id'] as String,amount,paymentId:id,date:DateTime(2026,11,5),mode:'Cash');
    await Future.wait([pay('one',30000),pay('one',30000)]);
    var saved = (await db.collection('teacher_salary').doc(row['id'] as String).get()).data()!;
    expect(saved['paidPaise'],30000); expect(saved['payments'],hasLength(1)); expect(saved['status'],'Part paid');
    await expectLater(pay('over',80000),throwsStateError);
    await expectLater(StaffPayroll.save(profile,person,'2026-11',basic:20000),throwsStateError);
    await pay('two',70000);
    saved = (await db.collection('teacher_salary').doc(row['id'] as String).get()).data()!;
    expect(saved['status'],'Paid'); expect(saved['balancePaise'],0); expect(saved['payments'],hasLength(2));
  });
  test('worker records are school-isolated and cannot be confused with teacher salary', () async {
    final profile = db.activeProfileId;
    await StaffPayroll.addStaff(profile,'Driver One','Driver','School bus');
    final driver = (await StaffPayroll.staff(profile)).single;
    final row = await StaffPayroll.save(profile,driver,'2026-11',basic:900000);
    expect(row['teacherId'],'');
    await db.switchProfile('different-school');
    expect(await StaffPayroll.staff(db.activeProfileId),isEmpty);
    expect((await db.collection('teacher_salary').get()).docs,isEmpty);
    await expectLater(StaffPayroll.save(profile,driver,'2026-11',basic:1),throwsStateError);
    await db.switchProfile(profile);
    expect((await db.collection('teacher_salary').get()).docs,hasLength(1));
  });
  testWidgets('trial banner opens activation and back preserves an unsaved form', (tester) async {
    WindowsPlatformClient.instance.state.value = WindowsLicenseState(allowed:true,status:'trial',expiresAt:DateTime.now().add(const Duration(days:3)));
    final controller = TextEditingController(); addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home:WindowsLicenseGate(connectionBuilder: (_) => const SizedBox(),
      child: Scaffold(body:TextField(controller:controller,key:const ValueKey('draft'))))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('license-skip-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('draft')),'Unsaved student');
    final field = tester.state<EditableTextState>(find.byType(EditableText));
    await tester.tap(find.byType(WindowsTrialBanner)); await tester.pumpAndSettle();
    expect(find.text('Activate Vidya Saarthi'),findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back)); await tester.pumpAndSettle();
    expect(controller.text,'Unsaved student');
    expect(identical(field,tester.state<EditableTextState>(find.byType(EditableText))),true);
    expect(tester.takeException(),isNull);
  });
  testWidgets('denied licensed status cannot hide the warning', (tester) async {
    await tester.pumpWidget(MaterialApp(home:WindowsTrialBanner(state:WindowsLicenseState(allowed:false,status:'licensed',expiresAt:DateTime.now()))));
    expect(find.textContaining('licence ended'),findsOneWidget);
  });
  test('reset clears credentials, every profile session and links but not school data or trial', () async {
    FlutterSecureStorage.setMockInitialValues({'vs_trial_start':'2026-09-30','vs_license_denied':'true',
      'vs_installation_id':'device','vs_active_license_hash':'a' * 64,'vs_license_cache':'old',
      'vidya_saarthi_windows_admin_id_v1':'old','vidya_saarthi_windows_admin_password_v1':'password',
      'vidya_saarthi_firebase_refresh_token_v1':'old-token'});
    await WindowsLocalSecurity.initialize();
    await WindowsExternalConnections.save(googleEmail:'school@example.com',googleScriptUrl:'https://script.google.com/macros/s/school/exec');
    await WindowsLocalSession.logout();
    final profile = db.activeProfileId;
    await db.collection('students_directory').doc('keep').set({'name':'Keep student'});
    await db.collection('teacher_salary').doc('keep').set({'amount':1234});
    for (final namespace in ['school-one','school-two']) {
      html.setSchoolStorageNamespace(namespace);
      html.window.localStorage['saarthi_portal_role_v1']='admin';
      html.window.localStorage['school-record-cache']='preserve';
    }
    await WindowsAppReset.reset();
    expect(WindowsLocalSecurity.configured,false); expect(WindowsLocalSession.loggedOut,false);
    expect(await WindowsExternalConnections.googleScriptUrl(),'');
    const secure=FlutterSecureStorage();
    expect(await secure.read(key:'vs_trial_start'),'2026-09-30');
    expect(await secure.read(key:'vs_license_denied'),'true');
    expect(await secure.read(key:'vs_license_cache'),isNull);
    expect(await secure.read(key:'vidya_saarthi_firebase_refresh_token_v1'),isNull);
    await db.switchProfile(profile);
    expect((await db.collection('students_directory').doc('keep').get()).data()?['name'],'Keep student');
    expect((await db.collection('teacher_salary').doc('keep').get()).data()?['amount'],1234);
    for (final namespace in ['school-one','school-two']) {
      html.setSchoolStorageNamespace(namespace);
      expect(html.window.localStorage['saarthi_portal_role_v1'],isNull);
      expect(html.window.localStorage['school-record-cache'],'preserve');
    }
    await WindowsSyncEngine.instance.pauseForAppReset();
  });
  test('other staff directory feeds payroll without changing teachers or mixing schools', () async {
    final profile=db.activeProfileId;
    final teacherRecord=await teacher();
    await OtherStaffDirectory.save(profile, {'id':'staff:guard','name':'School Guard','employeeId':'G-1','role':'Guard','active':true});
    final people=await StaffPayroll.staff(profile);
    expect(people.length,2);
    expect(people.singleWhere((p)=>p['role']=='Guard')['employeeId'],'G-1');
    expect(people.singleWhere((p)=>p['role']=='Teacher')['id'],teacherRecord['id']);
    await expectLater(OtherStaffDirectory.save(profile, {'name':'Duplicate','employeeId':'g-1','role':'Guard'}),throwsStateError);
    await expectLater(OtherStaffDirectory.save(profile, {'name':'Duplicate Teacher','employeeId':'T-11','role':'Other'}),throwsStateError);
    await db.switchProfile('other-school');
    expect(await StaffPayroll.staff(db.activeProfileId),isEmpty);
    await expectLater(OtherStaffDirectory.load(profile),throwsStateError);
    await expectLater(OtherStaffDirectory.save(profile, {'name':'Foreign','employeeId':'F-1','role':'Other'}),throwsStateError);
    await db.switchProfile(profile);
    expect((await OtherStaffDirectory.load(profile)).single['name'],'School Guard');
  });
  test('promotion rejects invented final flags, unsaved results and mismatched results', () async {
    final exam={'examId':'final-check','isFinal':true};
    await db.collection('students_directory').doc('student').set({'name':'Student','class':'Class 1','rollNo':'1'});
    await expectLater(SchoolPromotionService.apply(studentId:'student',student:{},exam:exam,result:'PASS'),throwsStateError);
    await db.collection('_local_exam_center_exams').doc('final-check').set(exam);
    await expectLater(SchoolPromotionService.apply(studentId:'student',student:{},exam:exam,result:'PASS'),throwsStateError);
    await db.collection('exam_results').doc('final-check_student').set({'studentId':'student','result':'FAIL'});
    await expectLater(SchoolPromotionService.apply(studentId:'student',student:{},exam:exam,result:'PASS'),throwsStateError);
    expect((await db.collection('students_directory').doc('student').get()).data()?['class'],'Class 1');
  });
  test('Class 12 final pass graduates; a final failure remains in Class 12', () async {
    await db.collection('students_directory').doc('pass').set({'name':'Senior','class':'Class 12','rollNo':'1'});
    await db.collection('students_directory').doc('fail').set({'name':'Retained','class':'Class 12','rollNo':'2'});
    final exam={'examId':'final-12','examName':'Final','isFinal':true};
    await db.collection('_local_exam_center_exams').doc('final-12').set(exam);
    for (final entry in {'pass':'PASS','fail':'FAIL'}.entries) {
      await db.collection('exam_results').doc('final-12_${entry.key}').set({'studentId':entry.key,'result':entry.value});
    }
    expect(await SchoolPromotionService.apply(studentId:'pass',student:{},exam:exam,result:'PASS'),'Completed Class 12');
    expect(await SchoolPromotionService.apply(studentId:'fail',student:{},exam:exam,result:'FAIL'),'Retained in Class 12');
    expect((await db.collection('students_directory').doc('fail').get()).data()?['class'],'Class 12');
  });
  test('senior students progress through Class 11 and 12 before graduation', () {
    expect(SchoolPromotionService.nextClassNumber(10),11);
    expect(SchoolPromotionService.nextClassNumber(11),12);
    expect(SchoolPromotionService.nextClassNumber(12),isNull);
    expect(() => SchoolPromotionService.nextClassNumber(13),throwsArgumentError);
  });
  testWidgets('payroll displays teacher salary, totals and actionable payments', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600,900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final previewKey=GlobalKey();
    await tester.runAsync(() async {
      final fonts=FontLoader('Roboto')..addFont(rootBundle.load('assets/id_card_regular.ttf'));
      await fonts.load();
      final icons=FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      await WindowsRuntimeFlags.setLocalStorageEnabled(true);
      final person = await teacher();
      await StaffPayroll.save(db.activeProfileId,person,'${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2,'0')}',basic:1000000);
      await tester.pumpWidget(MaterialApp(home:RepaintBoundary(key:previewKey,child:const StaffSalaryScreen())));
      await Future<void>.delayed(const Duration(milliseconds:200));
    });
    for (var i=0;i<20;i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds:30)));
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
    expect(find.text('School Teacher'),findsOneWidget);
    expect(find.text('View Payslip'),findsOneWidget);
    await tester.tap(find.byTooltip('Salary actions'));
    await tester.pumpAndSettle();
    expect(find.text('Record payment'),findsOneWidget);
    expect(find.text('Payment history'),findsOneWidget);
    await tester.tapAt(const Offset(20,20));
    await tester.pumpAndSettle();
    expect(find.text('Net payroll'),findsOneWidget);
    expect(find.text('Generate Payslips'),findsOneWidget);
    expect(find.text('Export CSV'),findsOneWidget);
    expect(find.text('Total Deductions'),findsOneWidget);
    expect(find.byType(DataTable),findsOneWidget);
    expect(tester.takeException(),isNull);
    await tester.runAsync(() async {
      final image=await (previewKey.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio:1);
      final bytes=await image.toByteData(format:rendering.ImageByteFormat.png);
      final output=File('build/payroll-preview/staff-salary.png');
      await output.parent.create(recursive:true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
