import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/main_dashboard_screen_windows.dart' show AllStudentsListScreen;
import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

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
        'firebaseRefreshToken': 'test-only', 'storageReady': false,
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
    await tester.pump();
    await tester.tap(find.text('Add Student'));
    await tester.pumpAndSettle();
    Finder field(String hint) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);
    final contact = field('Contact No *');
    expect(contact, findsOneWidget);
    await tester.enterText(contact, '98abc765432101');
    expect(tester.widget<TextField>(contact).controller!.text, '9876543210');
    await tester.enterText(contact, '9876543210');
    expect(tester.widget<TextField>(contact).controller!.text, '9876543210');
    await tester.enterText(field('Student Full Name *'), 'Contact Test');
    await tester.enterText(field('Roll No *'), '1');
    for (final invalid in ['987654321', '98765432101', '98765abcde']) {
      // Also exercise save validation independently of keyboard formatters.
      tester.widget<TextField>(contact).controller!.text = invalid;
      await tester.tap(find.text('Save Student'));
      await tester.pump();
      expect(find.text('Add New Student'), findsOneWidget);
      expect((await db.collection('students_directory').get()).docs, isEmpty);
    }
    expect(find.text('Contact number mein exactly 10 digits daalein.'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
