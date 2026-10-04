import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/main_windows.dart';
import '../lib/windows_admin_setup.dart';
import '../lib/windows_local_settings.dart';
import '../lib/windows_managed_school_gate.dart';
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 setUp(()=>FlutterSecureStorage.setMockInitialValues({}));
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
  final confirm=find.widgetWithText(TextField,'Confirm Password *'),licence=find.widgetWithText(TextField,'Licence Key (optional during five-day trial)');
  expect(confirm,findsOneWidget);expect(licence,findsOneWidget);expect(tester.getTopLeft(licence).dy,greaterThan(tester.getTopLeft(confirm).dy));
  expect(find.text('Admin Setup'),findsNothing);expect(find.text('Skip'),findsNothing);await tester.pumpWidget(const SizedBox());
 });
}
