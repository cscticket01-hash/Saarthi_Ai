import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_managed_school_gate.dart';
import '../lib/windows_connect/managed_school_session.dart';
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('managed logout cannot expose legacy dashboard or licence skip',(tester)async{
    FlutterSecureStorage.setMockInitialValues({'vidya_saarthi_managed_required':'true'});
    await tester.pumpWidget(const MaterialApp(home:WindowsManagedSchoolGate(child:Text('School data'),legacy:Text('Legacy skip'))));
    await tester.pump();await tester.pump();
    expect(find.text('School Login'),findsOneWidget);expect(find.text('School data'),findsNothing);expect(find.text('Legacy skip'),findsNothing);
    await ManagedSchoolSession.logout();await tester.pump();await tester.pump();
    expect(find.text('School Login'),findsOneWidget);expect(find.text('Legacy skip'),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
