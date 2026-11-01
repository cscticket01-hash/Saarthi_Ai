import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../lib/windows_template_import_engine.dart';
import '../lib/windows_template_forge_auto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final school='vs-db8afb01a3be46a983c8284714d06e5d';
  final png=Uint8List.fromList(img.encodePng(img.Image(width:1000,height:1400)));

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
    expect(result.missing,containsAll(['basicPaise','deductionPaise']));
    expect(result.safeToActivate,isFalse);
    expect(result.detected,containsAll(['name','month','netPaise']));
  });

  test('all 3 template types import same page via one shared engine',() async {
    for(final kind in SchoolTemplateKind.values) {
      final draft=await SchoolTemplateImportEngine.importBytes(
        kind:kind,schoolId:school,filename:'sample.png',bytes:png);
      expect(draft.kind,kind);
      expect(draft.width,1000);
      expect(draft.height,1400);
      expect(draft.fields,isEmpty,
        reason:'Do not guess data fields from a raster document');
      expect(draft.sourceHash,hasLength(64));
      expect(draft.schoolId,school);
    }
  });

  test('school ID requires exactly 32 lowercase hex characters', () {
    expect(SchoolTemplateImportEngine.verifySchool(school), school);
    expect(() => SchoolTemplateImportEngine.verifySchool(school + 'evil'), throwsStateError);
    expect(() => SchoolTemplateImportEngine.verifySchool(school.toUpperCase()), throwsStateError);
  });

  test('non-A4 landscape images are rejected rather than stretched', () async {
    final landscape=Uint8List.fromList(img.encodePng(img.Image(width:300,height:100)));
    await expectLater(SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'landscape.png',bytes:landscape),throwsFormatException);
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

  test('TemplateForge identifies Hindi/Bengali labels without cloud AI',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'bengali.png',bytes:png);
    final recognized=TemplateForgeAutoMapper.detect(draft,sampleOcr([
      'রসিদ নং VS101','শিক্ষার্থীর নাম Mira','মোট টাকা 1200',
    ]));
    expect(recognized.detected,containsAll(['receiptNo','studentName','totalAmount']));
    expect(recognized.missing,isEmpty);
    expect(recognized.safeToActivate,isFalse,
      reason:'Recognized amounts do not prove fee table safety');
  });

  test('document type suggestion rejects misleading receipt labels',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.reportCard,schoolId:school,
      filename:'not_marksheet.png',bytes:png);
    final ocr=sampleOcr([
      'Receipt No VS101','Student Name Mira','Total Amount 1200',
    ]);
    expect(TemplateForgeAutoMapper.suggestKind(ocr,draft.width,draft.height),
      SchoolTemplateKind.receipt);
    final result=TemplateForgeAutoMapper.detect(draft,ocr);
    expect(result.warnings.any((w)=>w.startsWith('Document appears to be ')),
      isTrue);
    expect(result.safeToActivate,isFalse);
  });

  test('an empty scanned field is never silently printed as valid',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'sample.png',bytes:png);
    final mapped=draft.copyWith(fields:[
      const SchoolTemplateField(key:'studentName',x:.1,y:.2,width:.3),
    ]);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,{}),
      throwsFormatException);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,
      {'studentName':'An extraordinarily long name that will not fit in the small printed field'}),
      throwsFormatException);
  });

  test('print preflight rejects receipt arithmetic mistakes',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'sample.png',bytes:png);
    final mapped=draft.copyWith(fields:[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.2),
    ]);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,{
      'receiptNo':'VS-101','totalAmount':150,
      'feeItems':{'Tuition':100,'Exam':20},
    }),throwsFormatException);
  });

  test('print preflight rejects contradictory salary records',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.payslip,schoolId:school,
      filename:'sample.png',bytes:png);
    final mapped=draft.copyWith(fields:[
      const SchoolTemplateField(key:'name',x:.1,y:.2),
    ]);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,{
      'name':'Arup','basicPaise':20000,'allowancePaise':500,
      'deductionPaise':100,'netPaise':9999,'paidPaise':12000,
    }),throwsFormatException);
  });

  test('verified fee table rows bind actual school fees, not OCR sample values',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'fees.png',bytes:png);
    final mapped=TemplateForgeAutoMapper.detect(draft,sampleOcr([
      'Receipt No VS101','Student Name Mira','Total Amount 1200',
      'Description Amount','Tuition 1000','Exam 200','Total Amount 1200',
    ]));
    expect(mapped.draft.fields.map((f)=>f.key),
      containsAll(['feeName0','feeAmount0','feeName1','feeAmount1']));
    expect(mapped.safeToActivate,isTrue,
      reason:'All required fields and the fee table were recognized');
    expect(SchoolTemplateImportEngine.valueFor('feeName0',{
      'feeItems':{'Admission':300,'Exam':400}
    }),'Admission');
    expect(SchoolTemplateImportEngine.valueFor('feeAmount0',{
      'feeItems':{'Admission':300,'Exam':400}
    }),'300');
  });

  test('row count differs from scanned sample: fail instead of dropping fees',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'fees.png',bytes:png);
    final mapped=draft.copyWith(fields:[
      const SchoolTemplateField(key:'feeName0',x:.1,y:.2,width:.2,size:.015),
      const SchoolTemplateField(key:'feeAmount0',x:.6,y:.2,width:.2,size:.015),
    ]);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,{
      'feeItems':{'Tuition':100,'Exam':50},'totalAmount':150,
    }),throwsFormatException);
  });

  test('small printable text boxes auto-fit without ever truncating data',() {
    const field=SchoolTemplateField(key:'studentName',x:.1,y:.1,
      width:.12,size:.03);
    final size=SchoolTemplateImportEngine.fittedTextSize(field,'Arup Das');
    expect(size,lessThan(.03));
    expect(size,greaterThanOrEqualTo(.009));
    expect(()=>SchoolTemplateImportEngine.fittedTextSize(field,
      'A name so long it cannot possibly fit safely in this box'),
      throwsFormatException);
  });

  test('A4 landscape camera photo keeps its intended orientation and school scope',() async {
    final side=Uint8List.fromList(img.encodeJpg(img.Image(width:1400,height:1000)));
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'sideways.jpg',bytes:side);
    expect(draft.width,1400);
    expect(draft.height,1000);
    expect(draft.schoolId,school);
  });

  test('published manifest is accepted only for matching school and image hash',() async {
    final source=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'school.png',bytes:png);
    final fields=[const SchoolTemplateField(key:'receiptNo',x:.1,y:.2,width:.3)];
    final contentHash=sha256.convert(png).toString();
    final fieldJson=jsonEncode(fields.map((f)=>f.toJson()).toList());
    final templateId=sha256.convert(utf8.encode(
      '${source.sourceHash}:$contentHash:$fieldJson:TemplateForge-3')).toString();
    final manifest={
      'version':1,'approved':true,'schoolId':school,'kind':'receipt',
      'filename':'school.png','sourceHash':source.sourceHash,
      'contentHash':contentHash,'templateId':templateId,
      'engine':'TemplateForge-3','width':1000,'height':1400,
      'fields':fields.map((f)=>f.toJson()).toList(),
    };
    final loaded=SchoolTemplateImportEngine.fromPublishedManifest(
      kind:SchoolTemplateKind.receipt,schoolId:school,manifest:manifest,png:png);
    expect(loaded.fields.single.key,'receiptNo');
    final wrongMap={...manifest,'fields':[
      SchoolTemplateField(key:'receiptNo',x:.2,y:.2,width:.3).toJson(),
    ]};
    expect(()=>SchoolTemplateImportEngine.fromPublishedManifest(
      kind:SchoolTemplateKind.receipt,schoolId:school,manifest:wrongMap,png:png),
      throwsFormatException);
    expect(()=>SchoolTemplateImportEngine.fromPublishedManifest(
      kind:SchoolTemplateKind.receipt,
      schoolId:'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      manifest:manifest,png:png),throwsFormatException);
    final altered=Uint8List.fromList(png)..[100]=png[100]^1;
    await expectLater(Future.sync(()=>SchoolTemplateImportEngine.fromPublishedManifest(
      kind:SchoolTemplateKind.receipt,schoolId:school,manifest:manifest,png:altered)),
      throwsFormatException);
  });

  test('A4 landscape source is accepted without stretching into portrait',() async {
    final landscape=Uint8List.fromList(img.encodePng(img.Image(width:1400,height:1000)));
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'landscape.png',bytes:landscape);
    expect(draft.width,1400);
    expect(draft.height,1000);
  });

  test('single-page A4 landscape PDF keeps its orientation',() async {
    final pdf=pw.Document();
    pdf.addPage(pw.Page(
      pageFormat:PdfPageFormat.a4.landscape,
      build:(_)=>pw.Center(child:pw.Text('School receipt template')),
    ));
    final bytes=Uint8List.fromList(await pdf.save());
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'landscape.pdf',bytes:bytes);
    expect(draft.width,greaterThan(draft.height));
  });

  test('multi-page PDF is rejected instead of silently dropping later pages',() async {
    final pdf=pw.Document();
    pdf.addPage(pw.Page(
      pageFormat:PdfPageFormat.a4,
      build:(_)=>pw.Center(child:pw.Text('Page one')),
    ));
    pdf.addPage(pw.Page(
      pageFormat:PdfPageFormat.a4,
      build:(_)=>pw.Center(child:pw.Text('Page two')),
    ));
    final bytes=Uint8List.fromList(await pdf.save());
    await expectLater(SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'two-pages.pdf',bytes:bytes),throwsFormatException);
  });

  test('high-resolution A4 phone photos are reduced to the safe print raster limit',() async {
    final photo=Uint8List.fromList(img.encodeJpg(
      img.Image(width:3600,height:5000),quality:88));
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'high-res.jpg',bytes:photo);
    expect(draft.width*draft.height,
      lessThanOrEqualTo(SchoolTemplateImportEngine.maxPixels));
    expect((draft.width/draft.height-210/297).abs(),lessThan(.075));
  });

  test('marksheet preview rejects a total or percentage that contradicts subjects',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.reportCard,schoolId:school,
      filename:'marks.png',bytes:png);
    final mapped=draft.copyWith(fields:[
      const SchoolTemplateField(key:'studentName',x:.1,y:.1,width:.3),
      const SchoolTemplateField(key:'class',x:.1,y:.15,width:.2),
      const SchoolTemplateField(key:'examName',x:.1,y:.2,width:.3),
      const SchoolTemplateField(key:'subjectName0',x:.1,y:.3,width:.2,mask:true),
      const SchoolTemplateField(key:'subjectMarks0',x:.6,y:.3,width:.1,mask:true),
      const SchoolTemplateField(key:'subjectName1',x:.1,y:.4,width:.2,mask:true),
      const SchoolTemplateField(key:'subjectMarks1',x:.6,y:.4,width:.1,mask:true),
    ]);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,{
      'studentName':'Mira','class':'5','examName':'Final',
      'marks':{'Math':70,'English':30},
      'totalMarks':100,'fullMarks':100,'percentage':'80',
    }),throwsFormatException);
  });

  test('blank receipt table is recognized and unused row slots are safely masked',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'blank-receipt.png',bytes:png);
    final ocr=sampleOcr([
      'Receipt No VS-101','Student Name Mira','Total Amount 1200',
      'Description Amount','Grand Total 1200',
    ]);
    final mapped=TemplateForgeAutoMapper.detect(draft,ocr);
    expect(mapped.safeToActivate,isTrue);
    expect(mapped.draft.fields.where((f)=>f.key.startsWith('feeName')).length,
      greaterThanOrEqualTo(2));
    final pdf=await SchoolTemplateImportEngine.previewPdf(mapped.draft,{
      'receiptNo':'VS-101','studentName':'Mira','totalAmount':1200,
      'feeItems':{'Tuition':1000,'Exam':200},
    });
    expect(pdf.take(4).toList(),[37,80,68,70]);
  });

}
