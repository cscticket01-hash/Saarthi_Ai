import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../lib/windows_template_import_engine.dart';
import '../lib/windows_template_forge_auto.dart';
import '../lib/windows_template_forge_visual_slots.dart';
import '../lib/windows_template_forge_ocr.dart';

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

  test('automatic school draft identity is idempotent but changes on edits',() async {
    final imported=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'draft-idempotence.png',bytes:png);
    final fields=[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.08,width:.2),
      const SchoolTemplateField(key:'studentName',x:.1,y:.16,width:.3),
      const SchoolTemplateField(key:'totalAmount',x:.6,y:.85,width:.2),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.4,width:.3),
      const SchoolTemplateField(key:'feeAmount0',x:.6,y:.4,width:.2),
    ];
    final draft=imported.copyWith(fields:fields);
    final identity=SchoolTemplateImportEngine.localDraftIdentity(draft);
    expect(identity,hasLength(64));
    expect(SchoolTemplateImportEngine.localDraftIdentity(
      imported.copyWith(fields:[...fields])),identity);
    final adjusted=imported.copyWith(fields:[
      ...fields.take(1),fields[1].copyWith(x:.12),...fields.skip(2),
    ]);
    expect(SchoolTemplateImportEngine.localDraftIdentity(adjusted),
      isNot(identity));
    final withVisual=imported.copyWith(fields:fields,visualSlots:[
      const ForgeVisualSlot(role:'studentPhoto',
        x:.78,y:.1,width:.15,height:.18),
    ]);
    expect(SchoolTemplateImportEngine.localDraftIdentity(withVisual),
      isNot(identity));
  });

  test('Legal-size portrait and landscape retain physical 8.5 × 14 inch print geometry',() async {
    final legal=Uint8List.fromList(img.encodePng(
      img.Image(width:612,height:1008)));
    final landscape=Uint8List.fromList(img.encodePng(
      img.Image(width:1008,height:612)));
    final portrait=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'legal-receipt.png',bytes:legal);
    final side=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'legal-landscape.png',bytes:landscape);
    expect(SchoolTemplateImportEngine.pageFormatForDimensions(
      portrait.width,portrait.height).width,PdfPageFormat.legal.width);
    expect(SchoolTemplateImportEngine.pageFormatForDimensions(
      side.width,side.height).width,PdfPageFormat.legal.landscape.width);
    expect((PdfPageFormat.legal.height/PdfPageFormat.inch-14).abs(),
      lessThan(.001));
    final fields=[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.1,width:.3),
      const SchoolTemplateField(key:'studentName',x:.1,y:.2,width:.3),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.42,width:.3),
      const SchoolTemplateField(key:'feeAmount0',x:.62,y:.42,width:.25),
      const SchoolTemplateField(key:'totalAmount',x:.62,y:.82,width:.2),
    ];
    final record={'receiptNo':'LEGAL-01','studentName':'Mira',
      'feeItems':{'Tuition':300},'totalAmount':300};
    for(final source in [portrait,side]){
      final draft=source.copyWith(fields:fields);
      expect(()=>SchoolTemplateImportEngine.validateDraft(draft),
        returnsNormally);
      final pdf=await SchoolTemplateImportEngine.previewPdf(draft,record);
      expect(pdf.take(5).toList(),[37,80,68,70,45]);
    }
    expect(()=>SchoolTemplateImportEngine.pageFormatForDimensions(
      900,900),throwsFormatException);
  });

  test('Legal-size paper on a dark phone background is cropped safely',() async {
    final camera=img.Image(width:1100,height:1100);
    img.fill(camera,color:img.ColorRgb8(20,20,20));
    img.fillRect(camera,x1:240,y1:55,x2:840,y2:1045,
      color:img.ColorRgb8(255,255,255));
    final photo=Uint8List.fromList(img.encodePng(camera));
    final source=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'phone-legal.png',bytes:photo);
    final format=SchoolTemplateImportEngine.pageFormatForDimensions(
      source.width,source.height);
    expect(format.width,PdfPageFormat.legal.width);
    expect(source.sourceHash,sha256.convert(photo).toString());
  });

  test('school receipt PDF embeds Indic fallback fonts for Bengali and Hindi',() async {
    final imported=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'indic-fee-receipt.png',bytes:png);
    final draft=imported.copyWith(fields:[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.08,width:.3),
      const SchoolTemplateField(key:'studentName',x:.1,y:.16,width:.5),
      const SchoolTemplateField(key:'totalAmount',x:.7,y:.88,width:.2),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.45,width:.4),
      const SchoolTemplateField(key:'feeAmount0',x:.7,y:.45,width:.2),
    ]);
    for(final studentName in ['অর্ণব','आरव','অসমীয়া']){
      final pdf=await SchoolTemplateImportEngine.previewPdf(draft,{
        'receiptNo':'VS-IND-001','studentName':studentName,
        'feeItems':{'Tuition':100},'totalAmount':100,
      });
      expect(pdf.take(5).toList(),[37,80,68,70,45]);
    }
  });

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
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.1,width:.3),
      const SchoolTemplateField(key:'studentName',x:.1,y:.2,width:.3),
      const SchoolTemplateField(key:'totalAmount',x:.6,y:.8,width:.2),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.5,width:.3,mask:true),
      const SchoolTemplateField(key:'feeAmount0',x:.6,y:.5,width:.15,mask:true),
    ]);
    final pdf=await SchoolTemplateImportEngine.previewPdf(mapped,{
      'receiptNo':'VS-100','studentName':'Mira','totalAmount':100,
      'feeItems':{'Tuition':100},
    });
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

  test('detected old photo or signature never silently transfers to another record',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'old-receipt.png',bytes:png);
    final result=TemplateForgeAutoMapper.detect(draft,sampleOcr([
      'Receipt No VS-101','Student Name Mira',
      'Description Amount','Tuition 1000','Total Amount 1000',
      'Student Photo','Principal Signature',
    ]));
    expect(result.warnings,
      contains('Image/QR/signature slot needs verified automatic replacement.'));
    expect(result.safeToActivate,isFalse);
  });

  test('visual planner only recognizes verified bordered photo placeholders',() async {
    final canvas=img.Image(width:1000,height:1400);
    img.fill(canvas,color:img.ColorRgb8(255,255,255));
    img.drawRect(canvas,x1:60,y1:50,x2:300,y2:250,
      color:img.ColorRgb8(0,0,0),thickness:3);
    final source=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'photo-box.png',
      bytes:Uint8List.fromList(img.encodePng(canvas)));
    final candidates=TemplateForgeVisualSlots.detect(
      source,sampleOcr(['PHOTO']));
    expect(candidates,hasLength(1));
    expect(candidates.single.role,'studentPhoto');
    expect(candidates.single.x,closeTo(.06,.015));
    expect(candidates.single.width,closeTo(.24,.015));
    // A real A4 print often places PHOTO as a caption just under the
    // portrait border rather than as text inside the box.
    final captionBelow=sampleOcr(['PHOTO'])
      .replaceFirst('\t95\t','\t290\t');
    final belowSlots=TemplateForgeVisualSlots.detect(source,captionBelow);
    expect(belowSlots,hasLength(1));
    expect(belowSlots.single.role,'studentPhoto');
    final empty=img.Image(width:1000,height:1400);
    img.fill(empty,color:img.ColorRgb8(255,255,255));
    final borderless=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'no-border.png',
      bytes:Uint8List.fromList(img.encodePng(empty)));
    expect(TemplateForgeVisualSlots.detect(borderless,sampleOcr(['PHOTO'])),
      isEmpty,reason:'OCR labels alone must never invent a photo location');
  });

  test('visually open photo border is rejected before reuse',() async {
    final canvas=img.Image(width:1000,height:1400);
    img.fill(canvas,color:img.ColorRgb8(255,255,255));
    img.drawRect(canvas,x1:60,y1:50,x2:300,y2:250,
      color:img.ColorRgb8(0,0,0),thickness:3);
    img.fillRect(canvas,x1:146,y1:49,x2:156,y2:53,
      color:img.ColorRgb8(255,255,255));
    img.fillRect(canvas,x1:146,y1:247,x2:156,y2:251,
      color:img.ColorRgb8(255,255,255));
    final source=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'broken-border.png',
      bytes:Uint8List.fromList(img.encodePng(canvas)));
    expect(TemplateForgeVisualSlots.detect(
      source,sampleOcr(['PHOTO'])),isEmpty,
      reason:'Broken rectangle must not authorize old-image masking');
  });

  test('unlabelled colour portrait alarms but simple form highlights do not',() async {
    final page=img.Image(width:1000,height:1400);
    img.fill(page,color:img.ColorRgb8(255,255,255));
    // An anonymized, synthetic multicolour photograph-like block.
    for(var y=75;y<360;y+=11){
      for(var x=700;x<940;x+=11){
        final color=switch((x*7+y*11)%3){
          0=>img.ColorRgb8(230,55,40),
          1=>img.ColorRgb8(35,210,65),
          _=>img.ColorRgb8(40,80,230),
        };
        img.fillRect(page,x1:x,y1:y,x2:x+10,y2:y+10,
          color:color);
      }
    }
    final source=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'anonymized-photo.png',
      bytes:Uint8List.fromList(img.encodePng(page)));
    expect(TemplateForgeVisualSlots.hasUnverifiedColorPhoto(
      source,const []),isTrue,
      reason:'Never silently reuse an obvious unlabelled student photo');
    expect(TemplateForgeVisualSlots.hasUnverifiedColorPhoto(
      source,[const ForgeVisualSlot(role:'studentPhoto',
        x:.69,y:.04,width:.27,height:.25)]),isFalse,
      reason:'A verified replacement rectangle may cover the old photo');
    // The SAME real detector must also reject a stray portrait at the
    // bottom of a Legal or A4 school document, beyond the old 3/4-page scan.
    img.fillRect(page,x1:699,y1:74,x2:946,y2:365,
      color:img.ColorRgb8(255,255,255));
    for(var y=1050;y<1320;y+=11){
      for(var x=700;x<940;x+=11){
        final color=switch((x*7+y*11)%3){
          0=>img.ColorRgb8(230,55,40),
          1=>img.ColorRgb8(35,210,65),
          _=>img.ColorRgb8(40,80,230),
        };
        img.fillRect(page,x1:x,y1:y,x2:x+10,y2:y+10,
          color:color);
      }
    }
    final lower=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'bottom-photo.png',
      bytes:Uint8List.fromList(img.encodePng(page)));
    expect(TemplateForgeVisualSlots.hasUnverifiedColorPhoto(
      lower,const []),isTrue,
      reason:'Bottom-page old portraits must be blocked too');
    final clean=img.Image(width:1000,height:1400);
    img.fill(clean,color:img.ColorRgb8(255,255,255));
    img.fillRect(clean,x1:60,y1:70,x2:935,y2:95,
      color:img.ColorRgb8(25,85,210));
    final cleanDraft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'clean-letterhead.png',
      bytes:Uint8List.fromList(img.encodePng(clean)));
    expect(TemplateForgeVisualSlots.hasUnverifiedColorPhoto(
      cleanDraft,const []),isFalse);
  });

  test('visual planner refuses duplicate ambiguous photo labels',() async {
    final canvas=img.Image(width:1000,height:1400);
    img.fill(canvas,color:img.ColorRgb8(255,255,255));
    img.drawRect(canvas,x1:60,y1:50,x2:300,y2:250,
      color:img.ColorRgb8(0,0,0),thickness:3);
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'duplicate-photo.png',
      bytes:Uint8List.fromList(img.encodePng(canvas)));
    expect(TemplateForgeVisualSlots.detect(
      draft,sampleOcr(['PHOTO','PHOTO'])),isEmpty);
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
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.1,width:.3),
      const SchoolTemplateField(key:'studentName',x:.1,y:.2,width:.12,size:.03),
      const SchoolTemplateField(key:'totalAmount',x:.6,y:.8,width:.2),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.5,width:.3,mask:true),
      const SchoolTemplateField(key:'feeAmount0',x:.6,y:.5,width:.15,mask:true),
    ]);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,{
      'receiptNo':'VS-1','totalAmount':100,'feeItems':{'Tuition':100},
    }),throwsFormatException);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,{
      'receiptNo':'VS-1',
      'studentName':'An extraordinarily long name that will not fit in the small printed field',
      'totalAmount':100,'feeItems':{'Tuition':100},
    }),throwsFormatException);
  });

  test('print preflight rejects receipt arithmetic mistakes',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'sample.png',bytes:png);
    final mapped=draft.copyWith(fields:[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.1,width:.3),
      const SchoolTemplateField(key:'studentName',x:.1,y:.2,width:.3),
      const SchoolTemplateField(key:'totalAmount',x:.6,y:.8,width:.2),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.5,width:.3,mask:true),
      const SchoolTemplateField(key:'feeAmount0',x:.6,y:.5,width:.15,mask:true),
    ]);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,{
      'receiptNo':'VS-101','studentName':'Mira','totalAmount':150,
      'feeItems':{'Tuition':100},
    }),throwsFormatException);
  });

  test('print preflight rejects contradictory salary records',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.payslip,schoolId:school,
      filename:'sample.png',bytes:png);
    final mapped=draft.copyWith(fields:[
      const SchoolTemplateField(key:'name',x:.1,y:.1,width:.3),
      const SchoolTemplateField(key:'month',x:.6,y:.1,width:.2),
      const SchoolTemplateField(key:'basicPaise',x:.1,y:.3,width:.2),
      const SchoolTemplateField(key:'allowancePaise',x:.1,y:.4,width:.2),
      const SchoolTemplateField(key:'deductionPaise',x:.1,y:.5,width:.2),
      const SchoolTemplateField(key:'netPaise',x:.1,y:.6,width:.2),
    ]);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,{
      'name':'Arup','month':'2026-10','basicPaise':20000,'allowancePaise':500,
      'deductionPaise':100,'netPaise':9999,'paidPaise':12000,
    }),throwsFormatException);
  });

  test('OCR block order does not reshuffle the printed fee rows',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'rows.png',bytes:png);
    final tsv=sampleOcr([
      'Receipt No VS101','Student Name Mira','Description Amount',
      'Tuition 1000','Exam 200','Total Amount 1200',
    ]);
    final records=tsv.trimRight().split('\n');
    final shuffled=[records.first,...records.skip(1).toList().reversed].join('\n');
    final mapped=TemplateForgeAutoMapper.detect(draft,shuffled);
    expect(mapped.safeToActivate,isTrue);
    final row0=mapped.draft.fields.firstWhere((f)=>f.key=='feeName0');
    final row1=mapped.draft.fields.firstWhere((f)=>f.key=='feeName1');
    expect(row0.y,lessThan(row1.y));
  });

  test('verified fee table rows bind actual school fees, not OCR sample values',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'fees.png',bytes:png);
    final mapped=TemplateForgeAutoMapper.detect(draft,sampleOcr([
      'Receipt No VS101','Student Name Mira',
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

  test('twelve-row field mapping preserves additional real fee and subject rows',() async {
    final receipt=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'twelve-fee-rows.png',bytes:png);
    final mapped=receipt.copyWith(fields:[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.08,width:.2),
      const SchoolTemplateField(key:'studentName',x:.1,y:.14,width:.3),
      const SchoolTemplateField(key:'totalAmount',x:.6,y:.88,width:.2),
      for(var i=0;i<12;i++) ...[
        SchoolTemplateField(key:'feeName$i',x:.1,y:.24+i*.05,
          width:.35,size:.015,mask:true),
        SchoolTemplateField(key:'feeAmount$i',x:.65,y:.24+i*.05,
          width:.18,size:.015,mask:true),
      ],
    ]);
    final items=<String,int>{
      for(var i=0;i<12;i++) 'Tuition $i':100,
    };
    final record=<String,dynamic>{
      'receiptNo':'VS-12','studentName':'Mira',
      'totalAmount':1200,'feeItems':items,
    };
    expect(()=>SchoolTemplateImportEngine.validatePreviewRecord(mapped,record),
      returnsNormally);
    expect(SchoolTemplateImportEngine.valueFor('feeName11',record),'Tuition 11');
    expect(SchoolTemplateImportEngine.valueFor('feeAmount11',record),'100');
    final overflow={...record,'totalAmount':1300,
      'feeItems':<String,int>{
        for(var i=0;i<13;i++) 'Tuition $i':100,
      }};
    expect(SchoolTemplateImportEngine.continuationRows(mapped,overflow),
      hasLength(1));
    expect(()=>SchoolTemplateImportEngine.validatePreviewRecord(mapped,overflow),
      returnsNormally);
    final extended=await SchoolTemplateImportEngine.previewPdf(mapped,overflow);
    expect(extended.take(5).toList(),[37,80,68,70,45]);
    final report=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.reportCard,schoolId:school,
      filename:'twelve-subjects.png',bytes:png);
    final marksDraft=report.copyWith(fields:[
      const SchoolTemplateField(key:'studentName',x:.1,y:.08,width:.3),
      const SchoolTemplateField(key:'class',x:.1,y:.14,width:.3),
      const SchoolTemplateField(key:'examName',x:.6,y:.14,width:.3),
      for(var i=0;i<12;i++) ...[
        SchoolTemplateField(key:'subjectName$i',x:.1,y:.24+i*.05,
          width:.35,size:.015,mask:true),
        SchoolTemplateField(key:'subjectMarks$i',x:.65,y:.24+i*.05,
          width:.18,size:.015,mask:true),
      ],
    ]);
    final marks={
      for(var i=0;i<12;i++) 'Subject $i':40,
    };
    final marksRecord=<String,dynamic>{
      'studentName':'Mira','class':'5','examName':'Final',
      'marks':marks,'totalMarks':480,'fullMarks':100,'percentage':'40',
    };
    expect(()=>SchoolTemplateImportEngine.validatePreviewRecord(
      marksDraft,marksRecord),returnsNormally);
    expect(SchoolTemplateImportEngine.valueFor('subjectName11',marksRecord),
      'Subject 11');
  });

  test('row count differs from scanned sample: fail instead of dropping fees',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'fees.png',bytes:png);
    final mapped=draft.copyWith(fields:[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.1,width:.3),
      const SchoolTemplateField(key:'studentName',x:.1,y:.15,width:.3),
      const SchoolTemplateField(key:'totalAmount',x:.6,y:.8,width:.2),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.3,width:.2,size:.015,mask:true),
      const SchoolTemplateField(key:'feeAmount0',x:.6,y:.3,width:.2,size:.015,mask:true),
    ]);
    final record={'receiptNo':'VS-101','studentName':'Mira',
      'feeItems':{'Tuition':100,'Exam':50},'totalAmount':150};
    expect(SchoolTemplateImportEngine.continuationRows(mapped,record),
      hasLength(1));
    final generated=await SchoolTemplateImportEngine.previewPdf(mapped,record);
    expect(generated.take(5).toList(),[37,80,68,70,45]);
  });

  test('bounded multi-page A4 continuation prints complete school rows',() async {
    final original=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'many-fees.png',bytes:png);
    final draft=original.copyWith(fields:[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.08,width:.3),
      const SchoolTemplateField(key:'studentName',x:.1,y:.15,width:.3),
      const SchoolTemplateField(key:'totalAmount',x:.65,y:.84,width:.2),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.4,width:.3),
      const SchoolTemplateField(key:'feeAmount0',x:.65,y:.4,width:.2),
    ]);
    final record={'receiptNo':'VS-52','studentName':'Mira',
      'feeItems':{for(var i=0;i<52;i++) 'Fee $i':100},
      'totalAmount':5200};
    expect(SchoolTemplateImportEngine.continuationRows(draft,record),
      hasLength(51));
    final bytes=await SchoolTemplateImportEngine.previewPdf(draft,record);
    expect(bytes.take(5).toList(),[37,80,68,70,45]);
    final tooMany={'receiptNo':'VS-250','studentName':'Mira',
      'feeItems':{for(var i=0;i<250;i++) 'Fee $i':1},
      'totalAmount':250};
    expect(()=>SchoolTemplateImportEngine.validatePreviewRecord(draft,tooMany),
      throwsFormatException);
    final badAmount={'receiptNo':'VS-BAD','studentName':'Mira',
      'feeItems':{'Tuition':100,'Exam':-10},'totalAmount':90};
    expect(()=>SchoolTemplateImportEngine.validatePreviewRecord(draft,badAmount),
      throwsFormatException);
  });

  test('faint photo OCR retry enhances only the temporary raster',(){
    final source=img.Image(width:100,height:140);
    img.fill(source,color:img.ColorRgb8(188,188,188));
    img.fillRect(source,x1:10,y1:20,x2:90,y2:40,
      color:img.ColorRgb8(113,113,113));
    final enhanced=TemplateForgeOfflineOcr.recognitionRaster(
      source,enhanced:true);
    final before=source.getPixel(10,20).r.toInt();
    final after=enhanced.getPixel(10,20).r.toInt();
    expect(after,lessThan(before));
    expect(source.getPixel(10,20).r.toInt(),before,
      reason:'Original school artwork cannot be altered by OCR preprocessing');
  });

  test('small printable text boxes auto-fit without ever truncating data',() {
    const field=SchoolTemplateField(key:'studentName',x:.1,y:.1,
      width:.12,size:.03);
    final size=SchoolTemplateImportEngine.fittedTextSize(field,'Arup Das');
    expect(size,lessThan(PdfPageFormat.a4.height*.03));
    expect(size,greaterThanOrEqualTo(5.5));
    expect(()=>SchoolTemplateImportEngine.fittedTextSize(field,
      'A name so long it cannot possibly fit safely in this box'),
      throwsFormatException);
  });

  test('A4-looking camera canvas still crops verified landscape page edges',() async {
    final camera=img.Image(width:1400,height:1000);
    img.fill(camera,color:img.ColorRgb8(15,15,15));
    img.fillRect(camera,x1:80,y1:60,x2:1320,y2:940,
      color:img.ColorRgb8(255,255,255));
    final raw=Uint8List.fromList(img.encodePng(camera));
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'camera-landscape.png',bytes:raw);
    expect((draft.width/draft.height-297/210).abs(),lessThan(.075));
    final corrected=img.decodePng(draft.png)!;
    final upper=corrected.getPixel(0,0);
    expect(upper.r+upper.g+upper.b,greaterThan(570),
      reason:'The dark camera background must not survive onto an A4 print');
    expect(draft.sourceHash,sha256.convert(raw).toString());
  });

  test('high-confidence page on dark camera background is automatically rectified',() async {
    final camera=img.Image(width:1000,height:1000);
    img.fill(camera,color:img.ColorRgb8(20,20,20));
    img.fillRect(camera,x1:180,y1:50,x2:820,y2:950,
      color:img.ColorRgb8(255,255,255));
    final bytes=Uint8List.fromList(img.encodeJpg(camera,quality:95));
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'camera.jpg',bytes:bytes);
    expect((draft.width/draft.height-210/297).abs(),lessThan(.075));
    expect(draft.sourceHash,sha256.convert(bytes).toString(),
      reason:'Rectification must not change the original source identity');
    final unrecognizable=Uint8List.fromList(img.encodePng(
      img.Image(width:1000,height:1000)));
    await expectLater(SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'uncertain.png',bytes:unrecognizable),throwsFormatException);
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

  test('verified photo and QR slots require live assets and print safely',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'verified-photo-qr.png',bytes:png);
    final mapped=draft.copyWith(fields:[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.1,width:.3),
      const SchoolTemplateField(key:'studentName',x:.1,y:.2,width:.3),
      const SchoolTemplateField(key:'totalAmount',x:.6,y:.8,width:.2),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.5,width:.3,mask:true),
      const SchoolTemplateField(key:'feeAmount0',x:.6,y:.5,width:.15,mask:true),
    ],visualSlots:[
      const ForgeVisualSlot(role:'studentPhoto',x:.78,y:.07,width:.15,height:.18),
      const ForgeVisualSlot(role:'qrCode',x:.79,y:.3,width:.13,height:.092),
    ]);
    final record=<String,dynamic>{
      'receiptNo':'VS-55','studentName':'Mira','totalAmount':100,
      'feeItems':{'Tuition':100},'qr':'https://school.example/record/55',
    };
    expect(()=>SchoolTemplateImportEngine.validateDraft(mapped),returnsNormally);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,record),
      throwsFormatException,
      reason:'Old source portrait must not be used without a new one');
    final output=await SchoolTemplateImportEngine.previewPdf(mapped,record,
      visualAssets:{'studentPhoto':png});
    expect(output.take(5).toList(),[37,80,68,70,45]);
    await expectLater(SchoolTemplateImportEngine.previewPdf(mapped,{
      ...record,'qr':'',
    },visualAssets:{'studentPhoto':png}),throwsFormatException);
  });

  test('published visual slots are signed into template version identity',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'published-visual.png',bytes:png);
    final fields=[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.1,width:.3),
      const SchoolTemplateField(key:'studentName',x:.1,y:.2,width:.3),
      const SchoolTemplateField(key:'totalAmount',x:.6,y:.8,width:.2),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.5,width:.3,mask:true),
      const SchoolTemplateField(key:'feeAmount0',x:.6,y:.5,width:.15,mask:true),
    ];
    const slots=[
      ForgeVisualSlot(role:'studentPhoto',x:.78,y:.07,width:.15,height:.18),
    ];
    final hash=sha256.convert(png).toString();
    final serialized=jsonEncode(fields.map((f)=>f.toJson()).toList());
    final visuals=jsonEncode(slots.map((s)=>s.toJson()).toList());
    final id=sha256.convert(utf8.encode(
      '${draft.sourceHash}:$hash:$serialized:$visuals:TemplateForge-3')).toString();
    final manifest={
      'version':1,'approved':true,'schoolId':school,'kind':'receipt',
      'sourceHash':draft.sourceHash,'filename':'published-visual.png',
      'contentHash':hash,'width':1000,'height':1400,'engine':'TemplateForge-3',
      'fields':fields.map((f)=>f.toJson()).toList(),
      'visualSlots':slots.map((s)=>s.toJson()).toList(),
      'templateId':id,
    };
    final restored=SchoolTemplateImportEngine.fromPublishedManifest(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      manifest:manifest,png:png);
    expect(restored.visualSlots.single.role,'studentPhoto');
    expect(()=>SchoolTemplateImportEngine.fromPublishedManifest(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      manifest:{...manifest,'visualSlots':[
        {'role':'studentPhoto','x':.58,'y':.07,'width':.15,'height':.18},
      ]},png:png),throwsFormatException);
  });

  test('published manifest is accepted only for matching school and image hash',() async {
    final source=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'school.png',bytes:png);
    final fields=[
      const SchoolTemplateField(key:'receiptNo',x:.1,y:.2,width:.3),
      const SchoolTemplateField(key:'studentName',x:.1,y:.25,width:.3),
      const SchoolTemplateField(key:'totalAmount',x:.6,y:.8,width:.2),
      const SchoolTemplateField(key:'feeName0',x:.1,y:.5,width:.3,mask:true),
      const SchoolTemplateField(key:'feeAmount0',x:.6,y:.5,width:.15,mask:true),
    ];
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
    expect(loaded.fields.map((f)=>f.key),contains('receiptNo'));
    final wrongFields=fields.map((f)=>f.toJson()).toList();
    wrongFields[0]=SchoolTemplateField(key:'receiptNo',x:.2,y:.2,width:.3).toJson();
    final wrongMap={...manifest,'fields':wrongFields};
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
      filename:'landscape.pdf',bytes:bytes,
      // Headless Flutter tests have no native Printing.raster plugin.
      // The production path still uses the Windows PDF rasterizer.
      pdfPagesRasterizer:(source) async {
        expect(source,orderedEquals(bytes));
        return [Uint8List.fromList(img.encodePng(
          img.Image(width:1400,height:1000)))];
      });
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
      filename:'two-pages.pdf',bytes:bytes,
      pdfPagesRasterizer:(source) async {
        expect(source,orderedEquals(bytes));
        // The page-count guard must refuse both pages, never use only page one.
        return [png,png];
      }),throwsFormatException);
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
      'Receipt No VS-101','Student Name Mira',
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

  test('blank marksheet table maps subject slots and validates the real record',() async {
    final draft=await SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.reportCard,schoolId:school,
      filename:'blank-marksheet.png',bytes:png);
    final ocr=sampleOcr([
      'Student Name Mira','Class 5','Exam Name Final',
      'Subject Marks','Total Marks 262',
    ]);
    final mapped=TemplateForgeAutoMapper.detect(draft,ocr);
    expect(mapped.safeToActivate,isTrue);
    expect(mapped.draft.fields.where((f)=>f.key.startsWith('subjectName')).length,
      greaterThanOrEqualTo(3));
    final pdf=await SchoolTemplateImportEngine.previewPdf(mapped.draft,{
      'studentName':'Mira','class':'5','examName':'Final',
      'marks':{'English':84,'Mathematics':91,'Science':87},
      'totalMarks':262,'fullMarks':100,'percentage':'87.3',
    });
    expect(pdf.take(4).toList(),[37,80,68,70]);
  });

}
