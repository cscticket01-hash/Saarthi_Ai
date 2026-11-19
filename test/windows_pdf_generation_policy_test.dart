import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_pdf_generation_policy.dart';

void main() {
  test('Sync 3.0 record saves never generate an automatic PDF', () {
    // This is a product rule, not a user preference or a temporary test flag.
    expect(WindowsPdfGenerationPolicy.generateOnRecordSave, isFalse);
  });
}
