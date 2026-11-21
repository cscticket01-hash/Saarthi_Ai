import 'package:flutter_test/flutter_test.dart';
import '../lib/student_inventory_policy.dart';

void main() {
  test(
      'historical generated cards are hidden by type, without changing records',
      () {
    final row = {
      'documentKind': 'idCard',
      'documentId': 'ID-existing',
      'originalPath': 'keep.pdf'
    };
    expect(StudentInventoryPolicy.visible(row), false);
    expect(row['originalPath'], 'keep.pdf');
    expect(row['documentId'], 'ID-existing');
  });
  test('new generation category is hidden; user scanned ID names stay visible',
      () {
    expect(
        StudentInventoryPolicy.visible(
            {'inventoryCategory': 'generatedIdCard'}),
        false);
    expect(
        StudentInventoryPolicy.visible({
          'fileName': 'ID-existing.pdf',
          'documentName': 'School ID card • Front & back'
        }),
        true);
    expect(StudentInventoryPolicy.visible({'documentKind': 'studentDocument'}),
        true);
  });
  test('cumulative budget counts scan bytes and pages, excluding generated docs', () {
    final usage = StudentInventoryPolicy.usage([
      {'documentId': 'pdf', 'sizeBytes': 390 * 1024, 'pageCount': 6, 'mimeType': 'application/pdf'},
      {'documentId': 'photo', 'sizeBytes': 80 * 1024, 'mimeType': 'image/jpeg'},
      {'documentKind': 'feeReceipt', 'sizeBytes': 999999},
      {'documentKind': 'marksheet', 'sizeBytes': 999999},
      {'documentKind': 'idCard', 'sizeBytes': 999999},
      {'documentId': 'deleted', 'deleted': true, 'sizeBytes': 999999},
    ]);
    expect(usage.unknown, false);
    expect(usage.pages, 7);
    expect(usage.bytes, 470 * 1024);
    expect(usage.problem(addingBytes: 30 * 1024, addingPages: 1), isNull);
    expect(usage.problem(addingBytes: 31 * 1024, addingPages: 1), isNotNull);
    expect(usage.problem(addingBytes: 1000, addingPages: 2), isNotNull);
  });

  test('replacement deducts existing scan and unknown legacy PDF is not guessed', () {
    final scans = [
      {'documentId': 'legacy', 'sizeBytes': 3000, 'mimeType': 'application/pdf'},
      {'documentId': 'photo', 'sizeBytes': 1000, 'mimeType': 'image/png'},
    ];
    expect(StudentInventoryPolicy.usage(scans).unknown, isTrue);
    final usage = StudentInventoryPolicy.usage(scans, replacingId: 'legacy');
    expect(usage.unknown, isFalse);
    expect(usage.pages, 1);
    expect(usage.problem(addingBytes: 3000, addingPages: 7), isNull);
  });
}
