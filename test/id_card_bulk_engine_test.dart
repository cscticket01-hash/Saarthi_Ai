import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';

import '../lib/id_card_bulk_engine.dart';
import '../lib/id_card_engine.dart';
import '../lib/id_card_manifest.dart';
import '../lib/school_qr_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Map<String, dynamic>.from(
    (jsonDecode(
      File('test/fixtures/windows_person_qr.json').readAsStringSync(),
    ) as List).first,
  );
  final school = fixture['schoolId'].toString();
  IdCardManifest template() => IdCardManifest.fromJson(
    Map<String, dynamic>.from(
      jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync())
          as Map,
    ),
  );
  IdCardBulkStudent student(
    int index, {
    String? classId,
    Map<String, dynamic>? data,
    Map<String, Uint8List> images = const {},
  }) {
    final id = 'synthetic-$index';
    return IdCardBulkStudent(
      schoolId: school,
      classId: classId ?? 'synthetic-class',
      studentId: id,
      cardIssueId: 'existing-issue-$index',
      qr: SchoolLink.encodeCompact({
        ...fixture,
        'personId': id,
        'role': 'student',
      }),
      data:
          data ??
          {
            'name': 'Synthetic $index',
            'schoolName': 'Synthetic School',
            'rollNo': '$index',
          },
      images: images,
    );
  }

  IdCardBulkPlan plan(
    int count, {
    bool landscape = false,
    IdCardBackPlacement placement = IdCardBackPlacement.mirrorColumns,
  }) => IdCardBulkPlan(
    template: template(),
    students: [for (var i = 0; i < count; i++) student(i)],
    landscape: landscape,
    backPlacement: placement,
  );

  test('A4 portrait9 and landscape8 exact centred geometry with stable back mapping', () {
    final portrait = plan(50);
    expect(portrait.capacity, 9);
    expect(portrait.sheetCount, 6);
    expect(portrait.leftMarginMm, closeTo(21, 1e-8));
    expect(portrait.topMarginMm, closeTo(17.1, 1e-8));
    final front = portrait.placement(0, back: false);
    final back = portrait.placement(0, back: true);
    expect(front['page'], 0);
    expect(back['page'], 1);
    expect(front['leftMm'], closeTo(21, 1e-8));
    expect(back['leftMm'], closeTo(135, 1e-8));
    expect(front['topMm'], back['topMm']);
    final landscape = plan(100, landscape: true);
    expect(landscape.capacity, 8);
    expect(landscape.sheetCount, 13);
    expect(landscape.leftMarginMm, closeTo(36, 1e-8));
    expect(landscape.topMarginMm, closeTo(17.9, 1e-8));
  });

  test(
    '50 100 500 manifests cover exactly every selected identity and both sides',
    () {
      for (final count in [50, 100, 500]) {
        final selection = plan(count);
        final rows = selection.manifest['cards'] as List;
        expect(rows.length, count);
        expect(rows.map((row) => row['studentId']).toSet().length, count);
        expect(selection.manifest['pageCount'], ((count / 9).ceil()) * 2);
        for (var i = 0; i < count; i++) {
          expect(rows[i]['studentId'], 'synthetic-$i');
          expect((rows[i]['front'] as Map)['page'], 2 * (i ~/ 9));
          expect((rows[i]['back'] as Map)['page'], 2 * (i ~/ 9) + 1);
        }
        expect(
          selection.selectionFingerprint,
          plan(count).selectionFingerprint,
        );
      }
    },
  );

  test('snapshot rejects school student duplicate class and bounded count mismatches', () {
    expect(
      () => IdCardBulkStudent(
        schoolId: 'foreign',
        classId: 'c',
        studentId: 's',
        cardIssueId: 'i',
        qr: SchoolLink.encodeCompact(fixture),
        data: {},
      ),
      throwsFormatException,
    );
    expect(
      () => IdCardBulkPlan(
        template: template(),
        students: [student(0), student(0)],
      ),
      throwsFormatException,
    );
    expect(
      () => IdCardBulkPlan(
        template: template(),
        students: [
          student(0),
          student(1, classId: 'foreign-class'),
        ],
      ),
      throwsFormatException,
    );
    expect(() => plan(501), throwsFormatException);
    expect(() => plan(0), throwsFormatException);
  });

  test(
    'selection assets data and returned manifest cannot mutate fingerprint',
    () {
      final image = Uint8List.fromList([1, 2, 3]);
      final data = <String, dynamic>{
        'name': 'Original',
        'schoolName': 'Synthetic School',
        'nested': {'value': 'Original'},
      };
      final record = student(0, data: data, images: {'photo': image});
      final selection = IdCardBulkPlan(
        template: template(),
        students: [record],
      );
      final original = selection.selectionFingerprint;
      image[0] = 9;
      data['name'] = 'Changed';
      (data['nested'] as Map)['value'] = 'Changed';
      record.images['photo']![0] = 8;
      (selection.manifest['cards'] as List).clear();
      selection.template.regions.clear();
      expect(selection.selectionFingerprint, original);
      expect(record.data['name'], 'Original');
    },
  );

  test('real application bulk rendering preserves A4 two-sided page counts and no partial cancel result', () async {
    final selection = plan(10);
    final progress = <int>[];
    final result = await IdCardBulkEngine.render(
      selection,
      onProgress: (completed, total) {
        expect(total, 10);
        progress.add(completed);
      },
    );
    final raw = latin1.decode(result.pdf);
    expect(raw.startsWith('%PDF'), true);
    expect(RegExp(r'/Type\s*/Page\b').allMatches(raw).length, 4);
    expect(progress, [9, 10]);
    expect(result.selectionFingerprint, selection.selectionFingerprint);
    expect(result.manifest['pageCount'], 4);
    expect(result.pdfSha256.length, 64);
    var cancel = false;
    await expectLater(
      IdCardBulkEngine.render(
        selection,
        isCancelled: () => cancel,
        onProgress: (done, total) {
          cancel = true;
        },
      ),
      throwsA(
        isA<IdCardBulkCancelled>()
            .having((e) => e.completedStudents, 'completedStudents', 9)
            .having(
              (e) => e.selectionFingerprint,
              'fingerprint',
              selection.selectionFingerprint,
            ),
      ),
    );
  });

  test('resume drift fails before rendering and identical selection rebuild is stable', () async {
    final selection = plan(1);
    await expectLater(
      IdCardBulkEngine.render(
        selection,
        resumeSelectionFingerprint: plan(2).selectionFingerprint,
      ),
      throwsFormatException,
    );
    await expectLater(
      IdCardBulkEngine.render(selection, isCancelled: () => true),
      throwsA(isA<IdCardBulkCancelled>()),
    );
    final result = await IdCardBulkEngine.render(
      selection,
      resumeSelectionFingerprint: selection.selectionFingerprint,
    );
    expect(result.selectionFingerprint, selection.selectionFingerprint);
  });

  test('actual application renderer exports50 100 500 front/back PDFs and exact QR crop inventories', () async {
    final output = Directory('build/idcard-bulk-core');
    await output.create(recursive: true);
    for (final count in [50, 100, 500]) {
      final selection = plan(count);
      final watch = Stopwatch()..start();
      final result = await IdCardBulkEngine.render(selection);
      watch.stop();
      final bytes = result.pdf;
      final raw = latin1.decode(bytes);
      final pages = selection.sheetCount * 2;
      expect(RegExp(r'/Type\s*/Page\b').allMatches(raw).length, pages);
      expect(result.manifest['cards'], hasLength(count));
      final qrRegions = selection.template.regions
          .where((r) => r.kind == 'qr')
          .toList();
      expect(qrRegions, isNotEmpty);
      final inventory = <Map<String, dynamic>>[];
      final qrPages = <int>{};
      for (var index = 0; index < count; index++) {
        final student = selection.students[index];
        for (final region in qrRegions) {
          final placement = selection.placement(
            index,
            back: region.side == 'back',
          );
          final scaleMm =
              selection.template.printWidth / selection.template.width;
          final availableWidth = region.width - 2 * region.padding;
          final availableHeight = region.height - 2 * region.padding;
          final side = math.min(availableWidth, availableHeight);
          final left =
              (placement['leftMm'] as double) +
              (region.x + region.padding + (availableWidth - side) / 2) *
                  scaleMm;
          final top =
              (placement['topMm'] as double) +
              (region.y + region.padding + (availableHeight - side) / 2) *
                  scaleMm;
          final right = left + side * scaleMm, bottom = top + side * scaleMm;
          final page = placement['page'] as int;
          qrPages.add(page);
          inventory.add({
            'schoolId': school,
            'studentId': student.studentId,
            'cardIssueId': student.cardIssueId,
            'side': region.side,
            'page': page,
            'qrBoxPt': [
              left,
              top,
              right,
              bottom,
            ].map((mm) => mm * 72 / 25.4).toList(),
            'modules': QrCode.fromData(
              data: student.qr,
              errorCorrectLevel: QrErrorCorrectLevel.L,
            ).moduleCount,
            'quietZoneModules': 4,
            'qrPayload': student.qr,
          });
        }
      }
      expect(inventory.length, count * qrRegions.length);
      await File('${output.path}/application-$count.pdf').writeAsBytes(bytes);
      await File('${output.path}/application-$count-verification.json')
          .writeAsString(
            jsonEncode({
              'version': 1,
              'schoolId': school,
              'pageSizesPt': [
                for (var page = 0; page < pages; page++)
                  [210 * 72 / 25.4, 297 * 72 / 25.4],
              ],
              'nonQrPages': [
                for (var page = 0; page < pages; page++)
                  if (!qrPages.contains(page)) page,
              ],
              'cards': inventory,
            }),
          );
      await File('${output.path}/application-$count-result.json').writeAsString(
        jsonEncode({
          'scope': 'Actual isolated Dart application renderer with synthetic students; no UI integration or physical acceptance',
          'studentCount': count,
          'pageCount': pages,
          'pdfBytes': bytes.length,
          'renderMilliseconds': watch.elapsedMilliseconds,
          'pdfSha256': result.pdfSha256,
          'selectionFingerprint': result.selectionFingerprint,
          'manifest': result.manifest,
          'finalPdfQrDecoding': 'UNVERIFIED until independent verifier run',
        }),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('existing singlepair API retains its physical page format after shared artwork refactor', () async {
    final record = student(0);
    final bytes = await IdCardEngine.render(
      template(),
      record.data,
      qr: record.qr,
    );
    final raw = latin1.decode(bytes);
    expect(RegExp(r'/Type\s*/Page\b').allMatches(raw).length, 1);
    final box = RegExp(
      r'/MediaBox\s*\[\s*0(?:\.0+)?\s+0(?:\.0+)?\s+([\d.]+)\s+([\d.]+)',
    ).firstMatch(raw)!;
    expect(double.parse(box.group(1)!), closeTo(116 * 72 / 25.4, .02));
    expect(double.parse(box.group(2)!), closeTo(85.6 * 72 / 25.4, .02));
  });
}
