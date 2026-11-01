import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'windows_template_import_engine.dart';

/// Local-only OCR. Originals and imported artwork are never enhanced/replaced.
/// Recognition uses installed language packs; it never downloads a model.
class TemplateForgeOfflineOcr {
  static const supportedLanguages=['eng','hin','ben','asm'];

  static ({String executable,String? tessdata}) _runtime() {
    final appDir=File(Platform.resolvedExecutable).parent.path;
    final bundled=appDir+Platform.pathSeparator+'ocr'+
      Platform.pathSeparator+'tesseract';
    final bundledExe=bundled+Platform.pathSeparator+'tesseract.exe';
    final bundledData=bundled+Platform.pathSeparator+'tessdata';
    if(File(bundledExe).existsSync() && Directory(bundledData).existsSync()){
      return (executable:bundledExe,tessdata:bundled);
    }
    final programFiles=Platform.environment['ProgramFiles']??r'C:\Program Files';
    final installed=programFiles+Platform.pathSeparator+'Tesseract-OCR';
    final installedExe=installed+Platform.pathSeparator+'tesseract.exe';
    final installedData=installed+Platform.pathSeparator+'tessdata';
    if(File(installedExe).existsSync() && Directory(installedData).existsSync()){
      return (executable:installedExe,tessdata:installed);
    }
    return (executable:'tesseract',tessdata:null);
  }

  static List<String> _arguments(List<String> args,String? tessdata) => [
    if(tessdata!=null)...['--tessdata-dir',tessdata],
    ...args,
  ];

  static Future<List<String>> installedLanguages() async {
    final runtime=_runtime();
    try {
      final result=await Process.run(runtime.executable,
        _arguments(['--list-langs'],runtime.tessdata),
        runInShell:false).timeout(const Duration(seconds:8));
      if(result.exitCode!=0)return const [];
      final available=(result.stdout.toString()+'\n'+result.stderr.toString())
        .split(RegExp(r'\s+')).toSet();
      return supportedLanguages.where(available.contains).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<String> recognize(SchoolTemplateDraft draft) async {
    final runtime=_runtime();
    final langs=await installedLanguages();
    if(!langs.contains('eng')){
      throw const FormatException(
        'The bundled offline OCR runtime is missing. Update Vidya Saarthi before importing a school template.');
    }
    if(!['hin','ben','asm'].every(langs.contains)){
      throw const FormatException(
        'Hindi, Bengali and Assamese OCR language data is incomplete. Template import is blocked safely.');
    }
    final dir=await Directory.systemTemp.createTemp('vs-template-ocr-');
    final path=dir.path+Platform.pathSeparator+'input.png';
    try {
      // Grayscale is applied only to OCR's temporary input. The original
      // full-colour template is preserved byte-for-byte for the print preview.
      final decoded=img.decodePng(draft.png);
      if(decoded==null || decoded.width!=draft.width || decoded.height!=draft.height){
        throw const FormatException('Invalid OCR raster dimensions.');
      }
      await File(path).writeAsBytes(img.encodePng(img.grayscale(decoded)),flush:true);
      late Process process;
      try {
        process=await Process.start(runtime.executable,_arguments([
          path,'stdout','-l',langs.join('+'),'--psm','11','tsv',
        ],runtime.tessdata),runInShell:false);
      } on ProcessException {
        throw const FormatException('Offline OCR runtime could not start; existing school templates were preserved.');
      }
      final output=process.stdout.transform(utf8.decoder).join();
      final stderr=process.stderr.transform(utf8.decoder).join();
      final code=await process.exitCode.timeout(
        const Duration(seconds:45),onTimeout:(){
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
