import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import '../lib/windows_template_import_engine.dart';
import '../lib/windows_template_forge_auto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final school='vs-1234567890abcdefgh';
  final png=Uint8List.fromList(img.encodePng(img.Image(width:160,height:220)));

  String sampleOcr(List<String> lines) {
    final tsv=StringBuffer('level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n');
    for(var i=0;i<lines.length;i++) {
      final words=lines[i].split(' ');
      var left=100;
      for(var j=0;j<words.length;j++) {
        final token=words[j];
        tsv.writeln([
          '5','1','1','1',(i+1).toString(),(j+1).toString(),
          left.toString(),(95+i*150).toString(),'75','30','96.1',token
        ].join('\t'));
        left+=95;
      }
    }
    return tsv.toString();
  }

  test('automatic OCR maps receipt labels without manual coordinates',() async {
    final original=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'sample.png',bytes:png);
    final result=TemplateForgeAutoMapper.detect(original,sampleOcr([
      'Receipt No VS001','Student Name Alice','Total Amount 500',
    ]));
    expect(result.detected,containsAll(['receiptNo','studentName','totalAmount']));
    expect(result.missing,isEmpty);
    expect(result.draft.fields,everyElement(isA<SchoolTemplateField>()));
    expect(result.safeToActivate,isFalse,
      reason:'Receipt fee-item repeated rows need reconstruction');
    expect(original.fields,isEmpty,reason:'Source page remains unchanged');
  });

  test('automatic OCR never invents unknown grades or activates ambiguous scans',() async {
    final source=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.reportCard,schoolId:school,
      filename:'sample.png',bytes:png);
    final result=TemplateForgeAutoMapper.detect(source,sampleOcr([
      'Student Name Anu','Class Seven','Exam Name Final',
    ]));
    expect(result.missing,isEmpty);
    expect(result.safeToActivate,isFalse,
      reason:'Subject and marks table is not reconstructed');
    final duplicate=TemplateForgeAutoMapper.detect(source,sampleOcr([
      'Student Name Anu','Student Name Ravi','Class Seven','Exam Name Final',
    ]));
    expect(duplicate.warnings,contains('Repeated ambiguous field: studentName'));
    expect(duplicate.safeToActivate,isFalse);
  });

  test('offline OCR ignores forged low confidence and out-of-page words',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.payslip,schoolId:school,
      filename:'sample.png',bytes:png);
    final words=sampleOcr(['Staff Name Mira','Month October','Net Salary 25000'])
      .replaceFirst('\t96.1\tMira','\t20\tMira');
    final result=TemplateForgeAutoMapper.detect(draft,words);
    expect(result.safeToActivate,isFalse);
    expect(result.warnings,isNotEmpty);
    expect(result.detected,containsAll(['name','month','netPaise']));
  });

  test('all 3 template types import same page via one shared engine',() async {
    for(final kind in SchoolTemplateKind.values) {
      final draft=await SchoolTemplateImportEngine.importBytes(
        kind:kind,schoolId:school,filename:'sample.png',bytes:png);
      expect(draft.kind,kind);
      expect(draft.width,160);
      expect(draft.height,220);
      expect(draft.fields,isEmpty,
        reason:'Do not guess data fields from a raster document');
      expect(draft.sourceHash,hasLength(64));
      expect(draft.schoolId,school);
    }
  });

  test('disguised input, oversized and foreign school are rejected',() async {
    await expectLater(SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'fake.pdf',bytes:png),throwsFormatException);
    await expectLater(SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:'../other',
      filename:'sample.png',bytes:png),throwsStateError);
    await expectLater(SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'../secret.png',bytes:png),throwsFormatException);
  });

  test('report card cannot bind unrelated payroll data or invalid coordinates',(){
    expect(()=>const SchoolTemplateField(
      key:'netPaise',x:.2,y:.2).validate(SchoolTemplateKind.reportCard),
      throwsFormatException);
    expect(()=>const SchoolTemplateField(
      key:'studentName',x:.9,y:.2,width:.5).validate(SchoolTemplateKind.reportCard),
      throwsFormatException);
    expect(()=>const SchoolTemplateField(
      key:'studentName',x:.4,y:.2,width:.3).validate(SchoolTemplateKind.reportCard),
      returnsNormally);
  });

  test('template data values derive from the record, not the scanned source',(){
    expect(SchoolTemplateImportEngine.valueFor('studentName',{'name':'Sample Student'}),
      'Sample Student');
    expect(SchoolTemplateImportEngine.valueFor('netPaise',{'netPaise':12345}),
      'Rs 123.45');
    expect(SchoolTemplateImportEngine.valueFor('studentName',{}),'');
    expect(SchoolTemplateImportEngine.valueFor('feeItems',{'feeItems':{'A':100}}),'');
  });

  test('read-only PDF draft preview renders an actual PDF with mapped sample text',() async {
    final imported=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'sample.png',bytes:png);
    final mapped=imported.copyWith(fields:[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.2,mask:true),
    ]);
    final pdf=await SchoolTemplateImportEngine.previewPdf(
      mapped,{'receiptNo':'VS-100'});
    expect(String.fromCharCodes(pdf.take(5)),'%PDF-');
    expect(imported.fields,isEmpty,
      reason:'Preview cannot publish or mutate the source draft');
  });
}
