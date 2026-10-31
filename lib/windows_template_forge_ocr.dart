import 'dart:convert';
import 'dart:io';

import 'windows_template_import_engine.dart';

/// Offline-only OCR. Does not send school images or student records to cloud AI.
class TemplateForgeOfflineOcr {
  static Future<String> recognize(SchoolTemplateDraft draft, {
    String executable = 'tesseract',
  }) async {
    final dir = await Directory.systemTemp.createTemp('vs-template-ocr-');
    final path = dir.path + Platform.pathSeparator + 'input.png';
    try {
      await File(path).writeAsBytes(draft.png, flush: true);
      late Process process;
      try {
        process = await Process.start(executable,
          [path, 'stdout', '-l', 'eng', '--psm', '11', 'tsv'],
          runInShell: false);
      } on ProcessException {
        throw const FormatException(
          'Offline OCR is not installed; existing templates were preserved.');
      }
      final output = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode.timeout(
        const Duration(seconds: 25), onTimeout: () {
          process.kill();
          return -1;
        });
      final tsv = await output;
      await stderr;
      if (code != 0 || tsv.length > 250000) {
        throw const FormatException('OCR failed or exceeded safe output limits.');
      }
      return tsv;
    } finally {
      try { await dir.delete(recursive:true); } catch (_) {}
    }
  }
}
