import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/id_card_bulk_engine.dart';
import '../lib/id_card_bulk_job_store.dart';
import '../lib/id_card_manifest.dart';
import '../lib/school_qr_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final fixture = Map<String, dynamic>.from(
    (jsonDecode(File('test/fixtures/windows_person_qr.json').readAsStringSync())
        as List).first,
  );
  final school = fixture['schoolId'] as String;
  IdCardBulkPlan selection(int count) {
    final template = IdCardManifest.fromJson(Map<String, dynamic>.from(
      jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync())
          as Map,
    ));
    return IdCardBulkPlan(
      template: template,
      students: [
        for (var i = 0; i < count; i++)
          IdCardBulkStudent(
            schoolId: school,
            classId: 'class-5',
            studentId: 'student-$i',
            cardIssueId: 'existing-$i',
            qr: SchoolLink.encodeCompact({
              ...fixture, 'personId': 'student-$i', 'role': 'student',
            }),
            data: {
              'name': 'Student $i',
              'schoolName': 'Synthetic Test School',
              'rollNo': '$i',
            },
          ),
      ],
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('id-bulk-job-');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('bulk metadata and completed PDF are protected; inventory omits credentials', () async {
    final plan=selection(1);
    final store=IdCardBulkJobStore(rootPath:root.path,schoolId:school,keyProvider:()async=>Uint8List.fromList(List.filled(32,7)));
    await store.savePending('protected-test',plan);
    final meta=root.listSync().whereType<File>().firstWhere((f)=>f.path.endsWith('.json'));
    expect(meta.readAsStringSync(),isNot(contains('Synthetic Test School')));
    expect(meta.readAsStringSync(),isNot(contains(plan.students.first.qr)));
    final list=await store.listJobs();
    expect(list.single['count'],1);
    expect(list.single.containsKey('selection'),false);
    final result=await store.resumeAndRender('protected-test');
    final pdf=root.listSync().whereType<File>().firstWhere((f)=>f.path.endsWith('.pdf'));
    expect(pdf.readAsStringSync().startsWith('%PDF'),false);
    expect(await store.readCompletedPdf('protected-test'),result.pdf);
  });

  test('durable immutable selection survives restart and retains stable identity', () async {
    final plan = selection(2);
    final store = IdCardBulkJobStore(rootPath: root.path, keyProvider: () async => Uint8List.fromList(List.filled(32, 7)), schoolId: school);
    await store.savePending('class-5-2026', plan);
    final next = IdCardBulkJobStore(rootPath: root.path, keyProvider: () async => Uint8List.fromList(List.filled(32, 7)), schoolId: school);
    final recovered = await next.resumePlan('class-5-2026');
    expect(recovered.selectionFingerprint, plan.selectionFingerprint);
    expect(recovered.students.length, 2);
    expect(recovered.students.first.qr, plan.students.first.qr);
    await expectLater(
      next.savePending('class-5-2026', selection(1)),
      throwsStateError,
    );
  });

  test('cancellation leaves pending journal; restart completes once', () async {
    final store = IdCardBulkJobStore(rootPath: root.path, keyProvider: () async => Uint8List.fromList(List.filled(32, 7)), schoolId: school);
    await store.savePending('job-1', selection(1));
    await expectLater(
      store.resumeAndRender('job-1', isCancelled: () => true),
      throwsA(isA<IdCardBulkCancelled>()),
    );
    expect(await store.readCompletedPdf('job-1'), isNull);
    final fresh = IdCardBulkJobStore(rootPath: root.path, keyProvider: () async => Uint8List.fromList(List.filled(32, 7)), schoolId: school);
    final result = await fresh.resumeAndRender('job-1');
    expect(result.pdf.isNotEmpty, true);
    final verified = await fresh.readCompletedPdf('job-1');
    expect(verified, isNotNull);
    expect(result.pdfSha256.length, 64);
    final repeat = await fresh.resumeAndRender('job-1');
    expect(repeat.pdfSha256, result.pdfSha256);
  });

  test('foreign school and corrupted checkpoint fail closed', () async {
    final plan = selection(1);
    final a = IdCardBulkJobStore(rootPath: root.path, keyProvider: () async => Uint8List.fromList(List.filled(32, 7)), schoolId: school);
    final b = IdCardBulkJobStore(rootPath: root.path, keyProvider: () async => Uint8List.fromList(List.filled(32, 7)), schoolId: 'another-school');
    await a.savePending('A', plan);
    await expectLater(b.resumePlan('A'), throwsStateError);
    await expectLater(b.savePending('A', plan), throwsFormatException);
    final file = root.listSync().whereType<File>()
        .firstWhere((f) => f.path.endsWith('.json'));
    final parsed = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    parsed['mac'] = base64Encode(List.filled(16, 0));
    file.writeAsStringSync(jsonEncode(parsed), flush: true);
    await expectLater(a.resumePlan('A'), throwsFormatException);
  });

  test('tampered complete PDF never passes verified output readback', () async {
    final a = IdCardBulkJobStore(rootPath: root.path, keyProvider: () async => Uint8List.fromList(List.filled(32, 7)), schoolId: school);
    await a.savePending('A', selection(1));
    await a.resumeAndRender('A');
    final file = root.listSync().whereType<File>()
        .firstWhere((f) => f.path.endsWith('.pdf'));
    final bytes = file.readAsBytesSync();
    bytes[bytes.length - 1] ^= 1;
    file.writeAsBytesSync(bytes, flush: true);
    await expectLater(a.readCompletedPdf('A'), throwsStateError);
  });
}
