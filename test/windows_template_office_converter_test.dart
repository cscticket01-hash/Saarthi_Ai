import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:saarthi_ai/windows_template_import_engine.dart';
import 'package:saarthi_ai/windows_template_office_converter.dart';

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
