import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import '../lib/windows_template_import_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final school='vs-1234567890abcdefgh';
  final png=Uint8List.fromList(img.encodePng(img.Image(width:160,height:220)));

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
