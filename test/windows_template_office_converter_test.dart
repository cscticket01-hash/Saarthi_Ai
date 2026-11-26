import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:saarthi_ai/windows_template_import_engine.dart';
import 'package:saarthi_ai/windows_template_office_converter.dart';
import 'package:saarthi_ai/windows_template_office_layout.dart';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  const school='vs-db8afb01a3be46a983c8284714d06e5d';

  Uint8List packageBytes({required bool word,bool macro=false,
    bool externalLink=false}){
    final archive=Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml','<Types/>'))
      ..addFile(ArchiveFile.string(
        word?'word/document.xml':'xl/workbook.xml','<root/>'));
    if(macro){
      archive.addFile(ArchiveFile.string(
        word?'word/vbaProject.bin':'xl/vbaProject.bin','macro'));
    }
    if(externalLink){
      archive.addFile(ArchiveFile.string(
        'xl/externalLinks/externalLink1.xml','external'));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Uint8List a4Png(){
    final bitmap=img.Image(width:420,height:594);
    img.fill(bitmap,color:img.ColorRgb8(255,255,255));
    return Uint8List.fromList(img.encodePng(bitmap));
  }

  test('Word and Excel formats recognized with strict package identity',(){
    expect(SchoolTemplateOfficeConverter.supports('paper.DOCX'),isTrue);
    expect(SchoolTemplateOfficeConverter.supports('school.doc'),isTrue);
    expect(SchoolTemplateOfficeConverter.supports('fees.xlsx'),isTrue);
    expect(SchoolTemplateOfficeConverter.supports('fees.xls'),isTrue);
    for(final file in ['school.docm','fees.xlsm','notes.txt','source.pdf']){
      expect(SchoolTemplateOfficeConverter.supports(file),isFalse);
    }
    final word=packageBytes(word:true),book=packageBytes(word:false);
    expect(SchoolTemplateOfficeConverter.validateSource('receipt.docx',word),
      SchoolOfficeKind.word);
    expect(SchoolTemplateOfficeConverter.validateSource('marks.xlsx',book),
      SchoolOfficeKind.spreadsheet);
    expect(()=>SchoolTemplateOfficeConverter.validateSource(
      'spoofed.xlsx',word),throwsFormatException);
    expect(()=>SchoolTemplateOfficeConverter.validateSource(
      'spoofed.docx',book),throwsFormatException);
    expect(()=>SchoolTemplateOfficeConverter.validateSource(
      'fake.docx',Uint8List.fromList('%PDF-fake'.codeUnits)),
      throwsFormatException);
    expect(()=>SchoolTemplateOfficeConverter.validateSource(
      'bad.doc',Uint8List.fromList([80,75,3,4])),
      throwsFormatException);
  });

  test('encrypted and macro-linked spreadsheet packages fail closed',(){
    expect(()=>SchoolTemplateOfficeConverter.validateSource(
      'unsafe.xlsx',packageBytes(word:false,macro:true)),
      throwsFormatException);
    expect(()=>SchoolTemplateOfficeConverter.validateSource(
      'linked.xlsx',packageBytes(word:false,externalLink:true)),
      throwsFormatException);
    expect(()=>SchoolTemplateOfficeConverter.validateSource(
      '../another-school.docx',packageBytes(word:true)),
      throwsFormatException);
  });

  test('DOCX and XLSX keep the original source SHA, then reuse the A4 PDF engine',() async {
    for(final file in ['source.docx','source.xlsx']){
      final original=packageBytes(word:file.endsWith('docx'));
      var conversions=0,rasters=0;
      final draft=await SchoolTemplateImportEngine.importBytes(
        kind:SchoolTemplateKind.receipt,schoolId:school,
        filename:file,bytes:original,
        officePdfConverter:(name,bytes)async{
          conversions++;
          expect(name,file);
          expect(bytes,original);
          return Uint8List.fromList('%PDF-1.4 fake unit test'.codeUnits);
        },
        pdfPagesRasterizer:(pdf)async{
          rasters++;
          expect(SchoolTemplateOfficeConverter.isPdf(pdf),isTrue);
          return [a4Png()];
        });
      expect(conversions,1);
      expect(rasters,1);
      expect(draft.filename,file);
      expect(draft.sourceHash,sha256.convert(original).toString());
      expect(draft.width/draft.height,closeTo(210/297,.005));
    }
  });

  test('legacy OLE Word/Excel signature is checked before conversion',() async {
    final ole=Uint8List.fromList([
      0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1,0,0,0,0,
    ]);
    for(final file in ['old.doc','old.xls']){
      expect(SchoolTemplateOfficeConverter.validateSource(file,ole),
        file.endsWith('.doc')?SchoolOfficeKind.word:
          SchoolOfficeKind.spreadsheet);
    }
  });

  Uint8List nativeDocx({String student='{{studentName}}',String title='Fee Receipt',bool merged=false}){
    final rows=[
      ['Receipt No','{{receiptNo}}'],
      ['Student Name',student],
      ['Particulars','Amount'],
      ['{{feeName0}}','{{feeAmount0}}'],
      ['Total Amount','{{totalAmount}}'],
    ];
    String para(String value)=>'<w:p><w:r><w:t>$value</w:t></w:r></w:p>';
    final body='<w:p><w:r><w:t>$title</w:t></w:r></w:p><w:tbl><w:tblGrid>'
      '<w:gridCol w:w="4500"/><w:gridCol w:w="4500"/></w:tblGrid>'
      +(merged?'<w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr>'+para('Fee Receipt')+'</w:tc></w:tr>':'')
      +rows.map((row)=>'<w:tr>'+row.map((v)=>'<w:tc>'+para(v)+'</w:tc>').join()+'</w:tr>').join()
      +'</w:tbl><w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
      '<w:pgMar w:top="720" w:bottom="720" w:left="720" w:right="720"/></w:sectPr>';
    final archive=Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml','<Types/>'))
      ..addFile(ArchiveFile.string('word/document.xml','<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$body</w:body></w:document>'));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
  Uint8List nativeXlsx({String student='',bool formula=false}){
    final rows=[
      ['Receipt No','{{receiptNo}}'],
      ['Student Name',student],
      ['Particulars','Amount'],
      ['',''],
      ['Total Amount','{{totalAmount}}'],
    ];
    final sheet='<worksheet><cols><col min="1" max="2" width="35"/></cols><sheetData>'
      +List.generate(rows.length,(i)=>'<row r="${i+1}" ht="30">'+
        List.generate(2,(j)=>'<c r="${j==0?'A':'B'}${i+1}" t="inlineStr"><is><t>${rows[i][j]}</t></is>'
          +(formula&&i==1&&j==1?'<f>1+1</f>':'')+'</c>').join()+'</row>').join()
      +'</sheetData><pageMargins left="0.5" right="0.5" top="0.5" bottom="0.5"/><pageSetup paperSize="9"/></worksheet>';
    final archive=Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml','<Types/>'))
      ..addFile(ArchiveFile.string('xl/workbook.xml','<workbook><sheets><sheet name="Receipt" sheetId="1"/></sheets></workbook>'))
      ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml',sheet));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
  test('native Word and Excel layouts reuse existing renderer without Office executables',()async{
    for(final entry in {'blank.docx':nativeDocx(),'merged.docx':nativeDocx(merged:true),'blank.xlsx':nativeXlsx()}.entries){
      var rasterCalls=0;
      final draft=await SchoolTemplateOfficeLayout.importSource(
        kind:SchoolTemplateKind.receipt,schoolId:school,filename:entry.key,bytes:entry.value,
        pdfPagesRasterizer:(pdf)async{
          rasterCalls++;
          expect(SchoolTemplateOfficeConverter.isPdf(pdf),isTrue);
          return [a4Png()];
        });
      expect(rasterCalls,1);
      expect(draft.sourceHash,sha256.convert(entry.value).toString());
      expect(draft.fields.map((f)=>f.key),containsAll(['receiptNo','studentName','totalAmount','feeName0','feeAmount0']));
      final output=await SchoolTemplateImportEngine.previewPdf(draft,{
        'receiptNo':'VS-TEST','studentName':'Synthetic Student',
        'feeItems':{'Fee':100},'totalAmount':100,
      });
      expect(SchoolTemplateOfficeConverter.isPdf(output),isTrue);
    }
  });
  test('native import rejects wrong category, old populated data and formulas',() {
    var rasterCalls=0;
    Future<SchoolTemplateDraft> run(String filename,Uint8List bytes,SchoolTemplateKind kind)=>
      SchoolTemplateOfficeLayout.importSource(kind:kind,schoolId:school,filename:filename,bytes:bytes,
        pdfPagesRasterizer:(_) async{rasterCalls++;return [a4Png()];});
    // Validate real import entry point, not an isolated helper. Invalid
    // source must fail before any asynchronous font loading or rendering.
    void rejected(String file,Uint8List bytes,SchoolTemplateKind kind) {
      expect(()=>run(file,bytes,kind),throwsFormatException,
        reason:'Invalid source must be rejected: $file');
    }
    rejected('wrong.docx',nativeDocx(title:'Report Card'),SchoolTemplateKind.receipt);
    rejected('wrong.docx',nativeDocx(),SchoolTemplateKind.reportCard);
    rejected('filled.docx',nativeDocx(student:'Old Student'),SchoolTemplateKind.receipt);
    rejected('formula.xlsx',nativeXlsx(formula:true),SchoolTemplateKind.receipt);
    rejected('literal.docx',nativeDocx(title:'Unverified personal data'),SchoolTemplateKind.receipt);
    for(final file in ['old.doc','old.xls','source.pdf','photo.png','source.docm','source.xlsm']){
      rejected(file,nativeDocx(),SchoolTemplateKind.receipt);
    }
    expect(rasterCalls,0);
  });

  test('multiple pages and failed conversions cannot publish a template',() async {
    final word=packageBytes(word:true);
    Future<SchoolTemplateDraft> open(List<Uint8List> pages)=> 
      SchoolTemplateImportEngine.importBytes(
        kind:SchoolTemplateKind.reportCard,schoolId:school,
        filename:'two-pages.docx',bytes:word,
        officePdfConverter:(_,__)async=>
          Uint8List.fromList('%PDF-1.4 mock'.codeUnits),
        pdfPagesRasterizer:(_)async=>pages);
    await expectLater(open([a4Png(),a4Png()]),throwsFormatException);
    await expectLater(SchoolTemplateImportEngine.importBytes(
      kind:SchoolTemplateKind.receipt,schoolId:school,
      filename:'not-pdf.xlsx',bytes:packageBytes(word:false),
      officePdfConverter:(_,__)async=>Uint8List.fromList([1,2,3]),
      pdfPagesRasterizer:(_)async=>[a4Png()]),throwsFormatException);
  });
}
