import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/mobile/record_id_card.dart';

void main() {
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  Widget view({
    String owner = school,
    bool verified = true,
    bool showStudentUid = false,
    Future<void> Function()? historical,
  }) => MaterialApp(home: Scaffold(body: SingleChildScrollView(
    child: MobileRecordIdCard(
      schoolName: 'School A',
      schoolId: school,
      personId: 'student-1',
      role: 'student',
      verified: verified,
      showStudentUid: showStudentUid,
      person: <String,dynamic>{
        'schoolId': owner,
        'name': 'Test Student',
        'class': '6',
        'rollNo': '24',
        'parentName': 'Test Parent',
        'studentUidTest': 'TEST-000001',
      },
      onOpenHistoricalPdf: historical,
    ),
  )));

  testWidgets('on-screen front/back preview needs no PDF or raster plugin', (t) async {
    var opened = 0;
    await t.pumpWidget(view(historical: () async { opened++; }));
    expect(find.byKey(const ValueKey('mobile-id-front')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-id-back')), findsOneWidget);
    expect(find.text('Test Student'), findsOneWidget);
    expect(find.text('School A'), findsNWidgets(2));
    expect(opened, 0);
    await t.ensureVisible(find.text('Open previously published PDF'));
    await t.tap(find.text('Open previously published PDF'));
    await t.pump();
    expect(opened, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('student UID is gated by verified school display option', (t) async {
    await t.pumpWidget(view());
    expect(find.text('Student UID'), findsNothing);
    await t.pumpWidget(view(showStudentUid: true));
    expect(find.text('Student UID'), findsOneWidget);
    expect(find.text('TEST-000001'), findsOneWidget);
    expect(find.text('Father / Guardian'), findsOneWidget);
  });

  testWidgets('foreign-school and unverified records are never shown', (t) async {
    await t.pumpWidget(view(owner: 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'));
    expect(find.byKey(const ValueKey('mobile-id-front')), findsNothing);
    expect(find.text('Test Student'), findsNothing);
    await t.pumpWidget(view(verified: false));
    expect(find.byKey(const ValueKey('mobile-id-front')), findsNothing);
  });
}
