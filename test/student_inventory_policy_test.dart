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
}
