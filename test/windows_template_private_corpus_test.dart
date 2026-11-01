import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_template_import_engine.dart';
import '../lib/windows_template_forge_ocr.dart';
import '../lib/windows_template_forge_auto.dart';
import '../lib/windows_template_forge_visual_slots.dart';

/// Opt-in, *local-only* school document corpus probe. This is deliberately
/// NOT a public CI accuracy PASS: no real school paperwork is in the repo.
///
/// Run on an authorised Windows school TEST PC with consented/redacted files:
/// flutter test test/windows_template_private_corpus_test.dart
///   --dart-define=TEMPLATEFORGE_PRIVATE_CORPUS_DIR=C:\private\test-forms
///
/// No uploads, cloud credentials, filenames, OCR text, photos, field values,
/// signatures or QR contents enter the generated report.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const corpus=String.fromEnvironment('TEMPLATEFORGE_PRIVATE_CORPUS_DIR');
  test('private real school form recognition and fail-closed audit',() async {
    final folder=Directory(corpus);
    if(!await folder.exists()){
      throw StateError('Private corpus directory is not available.');
    }
    final candidates=await folder.list(followLinks:false).where((item)=>
      item is File && !item.path.contains('..')).cast<File>().toList();
    candidates.sort((a,b)=>a.path.compareTo(b.path));
    if(candidates.length>100){
      throw StateError('Split the school corpus into batches of <= 100 files.');
    }
    const school='vs-db8afb01a3be46a983c8284714d06e5d';
    final entries=<Map<String,dynamic>>[];
    var checked=0;
    for(final file in candidates){
      final name=file.uri.pathSegments.last;
      final lower=name.toLowerCase();
      final extension=name.contains('.')?lower.split('.').last:'';
      if(!const ['pdf','png','jpg','jpeg','doc','docx','xls','xlsx']
        .contains(extension))continue;
      final kind=lower.startsWith('receipt_')
        ?SchoolTemplateKind.receipt
        :lower.startsWith('reportcard_')
          ?SchoolTemplateKind.reportCard
          :lower.startsWith('payslip_')
            ?SchoolTemplateKind.payslip:null;
      if(kind==null){
        // Filename classification is deliberately explicit. Never guess
        // whether an unclassified real form is a receipt or marksheet.
        continue;
      }
      checked++;
      final bytes=await file.readAsBytes();
      final digest=sha256.convert(bytes).toString();
      var safe=false;
      var fields=0,verifiedVisualSlots=0;
      var warnings=0,missing=0,unverifiedPhoto=false;
      var state='rejected';
      try{
        final imported=await SchoolTemplateImportEngine.importBytes(
          kind:kind,schoolId:school,filename:name,bytes:bytes);
        final oriented=await TemplateForgeOfflineOcr.normalizeOrientation(
          imported);
        final ocr=await TemplateForgeOfflineOcr.recognize(oriented);
        final r=TemplateForgeAutoMapper.detect(oriented,ocr);
        final labels=TemplateForgeVisualSlots.labelCounts(
          ocr,oriented.width,oriented.height);
        final slots=TemplateForgeVisualSlots.detect(oriented,ocr);
        final visualVerified=labels.isEmpty ||
          (labels.values.every((x)=>x==1)&&slots.length==labels.length);
        unverifiedPhoto=TemplateForgeVisualSlots.hasUnverifiedColorPhoto(
          oriented,visualVerified?slots:const []);
        safe=r.missing.isEmpty && r.warnings.where((w)=>
          w!='Image/QR/signature slot needs verified automatic replacement.'
        ).isEmpty && visualVerified && !unverifiedPhoto &&
          (labels.isEmpty||slots.length==labels.length);
        if(safe){
          SchoolTemplateImportEngine.validateDraft(
            r.draft.copyWith(visualSlots:slots));
          state='geometry-safe-needs-human-review';
        }else{
          state='fail-closed';
        }
        fields=r.draft.fields.length;
        verifiedVisualSlots=slots.length;
        warnings=r.warnings.length;
        missing=r.missing.length;
      }catch(_){
        // No exception message is included: it may contain filenames or
        // sensitive OCR/source contents. A failed import is NOT a pass.
        state='unreadable-or-unsafe';
      }
      entries.add({
        'sourceSha256':digest,
        'type':kind.name,'extension':extension,
        'state':state,'safeGeometryOnly':safe,
        'fieldCount':fields,'verifiedVisualSlots':verifiedVisualSlots,
        'warningCount':warnings,'missingCount':missing,
        'unverifiedColourPhoto':unverifiedPhoto,
      });
    }
    if(checked==0){
      throw StateError(
        'No matching samples. Use receipt_, reportcard_, or payslip_ prefixes.');
    }
    final result={
      'schema':'templateforge-private-corpus-audit-v1',
      'sampleCount':checked,
      'geometryCandidates':entries.where(
        (e)=>e['state']=='geometry-safe-needs-human-review').length,
      'requiresManualVisualApproval':true,
      'physicalPrinterVerified':false,
      'realMultiPcSyncVerified':false,
      'neverClaimUniversalRecognition':true,
      'samples':entries,
    };
    await Directory('build').create(recursive:true);
    await File('build/templateforge_private_corpus_audit.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(result),
        flush:true);
    expect(entries.length,checked);
  },skip:corpus.isEmpty
    ?'Requires opt-in, locally stored, consented real-school corpus.'
    :false);
}
