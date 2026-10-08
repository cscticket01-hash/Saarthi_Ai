import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_save_pdf.dart';
void main() {
  test('Save As writes to selected path and cancellation creates no file', () async {
    final dir = await Directory.systemTemp.createTemp('saarthi_pdf_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/chosen.pdf';
    final bytes = Uint8List.fromList([37, 80, 68, 70]);
    expect(await WindowsSavePdf.save(bytes, 'default.pdf', choosePath: (_) async => null), isNull);
    expect(await File(path).exists(), false);
    expect(await WindowsSavePdf.save(bytes, 'default.pdf', choosePath: (_) async => path), path);
    expect(await File(path).readAsBytes(), bytes);
  });
  test('failed write propagates failure instead of returning a saved path', () async {
    final dir = await Directory.systemTemp.createTemp('saarthi_pdf_failure');
    addTearDown(() => dir.delete(recursive: true));
    await expectLater(WindowsSavePdf.save(Uint8List(1), 'default.pdf',
      choosePath: (_) async => '${dir.path}/missing/failed.pdf'), throwsA(isA<FileSystemException>()));
  });
}
