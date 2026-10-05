import 'dart:async';
import 'dart:convert';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/platform/platform_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/main_windows.dart';
import '../lib/windows_admin_setup.dart';
import '../lib/windows_local_settings.dart';
import '../lib/windows_managed_school_gate.dart';
import '../lib/main_dashboard_screen_windows.dart' show WindowsSectionLocks;
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 setUp(()=>FlutterSecureStorage.setMockInitialValues({}));
 testWidgets('legacy Admin lock does not add another password prompt',(tester)async{
  await WindowsSectionLocks.addPassword(sectionKey:'admin_section',password:'admin-only-pass');
  await tester.pumpWidget(const MaterialApp(home:WindowsLocalDashboardGate()));
  await tester.pump();
  expect(find.text('Admin Section Password'),findsNothing);
  expect(find.text('Open Admin Panel'),findsNothing);expect(find.byType(WindowsAdminSessionDashboard,skipOffstage:false),findsOneWidget);
  await tester.pump();await tester.pump(const Duration(milliseconds:350));
  expect(find.text('Admin Section Password'),findsNothing);
  expect(find.byType(WindowsAdminSessionDashboard,skipOffstage:false),findsOneWidget);
  await tester.pumpWidget(const SizedBox());
 });
 testWidgets('fresh Windows startup requires central school login and exposes no licence skip',(tester)async{
  await tester.pumpWidget(VidyaSaarthiWindowsApp(initializeConnections:()async{}));await tester.pump();await tester.pump();
  expect(find.text('School Login'),findsOneWidget);expect(find.text('School login email'),findsOneWidget);expect(find.byKey(const ValueKey('license-skip-button')),findsNothing);expect(find.text('Save & Open App'),findsNothing);expect(find.text('Skip'),findsNothing);
  await tester.pumpWidget(const SizedBox());
 });
 testWidgets('legacy local lock cannot bypass central school login',(tester)async{
  await tester.runAsync(()=>WindowsLocalSecurity.initialize());
  await tester.pumpWidget(const MaterialApp(home:WindowsManagedSchoolGate(child:Text('School data'),legacy:Text('Legacy bypass'))));await tester.pump();await tester.pump();
  expect(find.text('School Login'),findsOneWidget);expect(find.text('Legacy bypass'),findsNothing);expect(find.text('School data'),findsNothing);await tester.pumpWidget(const SizedBox());
 });
 testWidgets('registration licence box sits below confirmation and header is removed',(tester)async{
  await tester.binding.setSurfaceSize(const Size(1400,1000));addTearDown(()=>tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(const MaterialApp(home:WindowsAdminSetupScreen()));
  final confirm=find.widgetWithText(TextField,'Confirm App Lock password'),licence=find.widgetWithText(TextField,'Licence Key (optional during five-day trial)');
  expect(confirm,findsOneWidget);expect(licence,findsOneWidget);expect(tester.getTopLeft(licence).dy,greaterThan(tester.getTopLeft(confirm).dy));
  expect(find.text('Admin Setup'),findsNothing);expect(find.text('Skip'),findsNothing);await tester.pumpWidget(const SizedBox());
 });
 testWidgets('tenant connection completes before registration lookup; restore failure shows retry not setup',(tester)async{
  final connected=Completer<void>();var checked=false;
  await tester.pumpWidget(MaterialApp(home:WindowsStartupFlow(
    initializeConnections:()=>connected.future,
    checkSetup:()async{checked=true;throw StateError('restore unavailable');})));
  await tester.pump();expect(checked,false);
  connected.complete();await tester.pump();await tester.pump();
  expect(checked,true);expect(find.text('Retry school profile restore'),findsOneWidget);
  expect(find.text('Save & Open App'),findsNothing);
  await tester.pumpWidget(const SizedBox());
 });
 testWidgets('verified existing enrollment with no local preferences opens home rather than registration',(tester)async{
  FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({
    'managed':true,'projectId':platformProjectId,'schoolId':'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'uid':'A','email':'a@school.example','folderId':'managed','firebaseRefreshToken':'refresh',
    'endpoint':'https://school.example/school-cloud'})});
  await tester.pumpWidget(MaterialApp(home:WindowsStartupFlow(
    initializeConnections:()async{},checkSetup:()async=>true)));
  await tester.pump();await tester.pump();await tester.pump();
  expect(find.text('Open Admin Panel'),findsNothing);expect(find.byType(WindowsAdminSessionDashboard,skipOffstage:false),findsOneWidget);expect(find.text('Save & Open App'),findsNothing);
  await tester.pumpWidget(const SizedBox());
 });

 test('existing App Lock password survives reload and stays separate from school login and section locks',() async {
  await WindowsLocalSecurity.initialize();
  await WindowsLocalSecurity.create(adminId:'local-admin',password:'existing-lock-123');
  await WindowsSectionLocks.addPassword(sectionKey:'admin_section',password:'section-only-123');
  await WindowsLocalSecurity.initialize();
  expect(WindowsLocalSecurity.verifyPassword('existing-lock-123'),true);
  expect(WindowsLocalSecurity.verifyPassword('wrong-password'),false);
  expect(WindowsLocalSecurity.verifyPassword('school-login-123'),false);
  expect(WindowsLocalSecurity.verifyPassword('section-only-123'),false);
 });

}
