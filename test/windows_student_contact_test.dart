import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/main_dashboard_screen_windows.dart' show AllStudentsListScreen;
import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/india_address_fields.dart';
import '../lib/india_locations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = FirebaseFirestore.instance;
  setUp(() async {
    const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key: jsonEncode({
        'managed': true, 'schoolId': school, 'uid': 'contact-test',
        'projectId': platformProjectId,
        'endpoint': 'https://school.example/school-cloud',
        'firebaseRefreshToken': 'test-only', 'folderId': 'managed', 'storageReady': false,
      }),
    });
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('student-contact-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolId': school, 'schoolSyncId': school});
  });

  testWidgets('Add Student restricts contact input and rejects invalid save without writes', (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: AllStudentsListScreen()));
    for (var i = 0; i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Add Student'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('address-country'))).controller!.text, 'India');
    Finder field(String hint) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);
    final contact = field('Contact No *');
    expect(contact, findsOneWidget);
    await tester.enterText(contact, '98abc765432101');
    expect(tester.widget<TextField>(contact).controller!.text, '9876543210');
    await tester.enterText(contact, '9876543210');
    expect(tester.widget<TextField>(contact).controller!.text, '9876543210');
    await tester.enterText(field('Student Full Name *'), 'Contact Test');
    await tester.enterText(field('Roll No *'), 'a01-b2');
    expect(tester.widget<TextField>(field('Roll No *')).controller!.text, '012');
    await tester.enterText(field('Roll No *'), '1');
    for (final invalid in ['987654321', '98765432101', '98765abcde']) {
      // Also exercise save validation independently of keyboard formatters.
      tester.widget<TextField>(contact).controller!.text = invalid;
      await tester.tap(find.text('Save Student'));
      await tester.pump();
      expect(find.text('Add New Student'), findsOneWidget);
      final records = await tester.runAsync(() => db.collection('students_directory').get());
      expect(records!.docs, isEmpty);
    }
    expect(find.text('Contact number mein exactly 10 digits daalein.'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('offline State selection limits districts, clears stale district and preserves legacy values until changed', (tester) async {
    final country = TextEditingController(text: 'India');
    final state = TextEditingController(text: 'Assam');
    final district = TextEditingController(text: 'Legacy saved district');
    addTearDown(() {country.dispose(); state.dispose(); district.dispose();});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: IndiaAddressFields(
      country: country, state: state, district: district))));
    expect(district.text, 'Legacy saved district');
    expect(indiaDistricts.length, 36);
    expect(indiaDistricts.values.fold<int>(0, (sum, rows) => sum + rows.length), 784);
    expect(indiaDistricts['Assam'], containsAll(['Sribhumi', 'Dima Hasao', 'Cachar']));
    await tester.tap(find.byKey(const ValueKey('address-district')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Sribhumi');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Sribhumi'));
    await tester.pumpAndSettle();
    expect(district.text, 'Sribhumi');
    await tester.tap(find.byKey(const ValueKey('address-state')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Bihar');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Bihar'));
    await tester.pumpAndSettle();
    expect(state.text, 'Bihar');
    expect(district.text, isEmpty);
    await tester.tap(find.byKey(const ValueKey('address-district')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Sribhumi');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Sribhumi'), findsNothing);
    await tester.enterText(find.byType(TextField).last, 'Patna');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Patna'));
    await tester.pumpAndSettle();
    expect(district.text, 'Patna');
    await tester.pumpWidget(const SizedBox());
  });
}
