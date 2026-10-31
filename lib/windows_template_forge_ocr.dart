import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'windows_template_import_engine.dart';

/// Local-only OCR. Originals and imported artwork are never enhanced/replaced.
/// Recognition uses installed language packs; it never downloads a model.
class TemplateForgeOfflineOcr {
  static const supportedLanguages=['eng','hin','ben','asm'];

  static Future<List<String>> installedLanguages({
    String executable='tesseract',
  }) async {
    try {
      final result=await Process.run(executable,['--list-langs'],
        runInShell:false).timeout(const Duration(seconds:5));
      if(result.exitCode!=0)return const [];
      final available=(result.stdout.toString()+'\n'+result.stderr.toString())
        .split(RegExp(r'\s+')).toSet();
      return supportedLanguages.where(available.contains).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<String> recognize(SchoolTemplateDraft draft, {
    String executable='tesseract',
  }) async {
    final langs=await installedLanguages(executable:executable);
    if(!langs.contains('eng')){
      throw const FormatException(
        'Offline OCR with English traineddata is unavailable. '
        'Install the reviewed OCR runtime; existing templates were preserved.');
    }
    final dir=await Directory.systemTemp.createTemp('vs-template-ocr-');
    final path=dir.path+Platform.pathSeparator+'input.png';
    try {
      // Grayscale is applied only to OCR's temporary input. The original
      // full-colour template is preserved byte-for-byte for document preview.
      final decoded=img.decodePng(draft.png);
      if(decoded==null || decoded.width!=draft.width || decoded.height!=draft.height){
        throw const FormatException('Invalid OCR raster dimensions.');
      }
      await File(path).writeAsBytes(img.encodePng(img.grayscale(decoded)),flush:true);
      late Process process;
      try {
        process=await Process.start(executable,[
          path,'stdout','-l',langs.join('+'),'--psm','11','tsv'
        ],runInShell:false);
      } on ProcessException {
        throw const FormatException('Offline OCR unavailable; original templates preserved.');
      }
      final output=process.stdout.transform(utf8.decoder).join();
      final stderr=process.stderr.transform(utf8.decoder).join();
      final code=await process.exitCode.timeout(
        const Duration(seconds:40),onTimeout:(){
          process.kill();
          return -1;
        });
      final tsv=await output;
      await stderr;
      if(code!=0 || tsv.length>250000){
        throw const FormatException('OCR failed, timed out or exceeded safe output limits.');
      }
      return tsv;
    } finally {
      try { await dir.delete(recursive:true); } catch (_) {}
    }
  }
}
