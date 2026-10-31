import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// One school-scoped engine for fee receipts, report cards and staff payslips.
/// Raster background stays unchanged; only mapped overlay fields are editable.
/// Arbitrary raster text/table extraction is NOT claimed.
enum SchoolTemplateKind { receipt, reportCard, payslip }
extension SchoolTemplateKindInfo on SchoolTemplateKind {
  String get title => switch(this) {
    SchoolTemplateKind.receipt => 'Fee receipt',
    SchoolTemplateKind.reportCard => 'Report card',
    SchoolTemplateKind.payslip => 'Staff payslip',
  };
  List<String> get fields => switch(this) {
    SchoolTemplateKind.receipt => const ['schoolName','receiptNo','studentName','class',
      'rollNo','dateText','paymentMode','totalAmount','principalName'],
    SchoolTemplateKind.reportCard => const ['schoolName','studentName','class',
      'rollNo','examName','academicSession','totalMarks','percentage','result','dateText'],
    SchoolTemplateKind.payslip => const ['schoolName','name','employeeId','role','month',
      'basicPaise','allowancePaise','deductionPaise','netPaise',
      'paidPaise','status','dateText'],
  };
}

class SchoolTemplateField {
  const SchoolTemplateField({required this.key,required this.x,required this.y,
    this.width=.3,this.size=.018,this.mask=false});
  final String key;
  final double x,y,width,size;
  final bool mask;
  void validate(SchoolTemplateKind kind) {
    if (!kind.fields.contains(key)) throw const FormatException('Unknown data field.');
    if (![x,y,width,size].every((v)=>v.isFinite) ||
      x<0 || x>1 || y<0 || y>1 || width<=0 || x+width>1.001 ||
      size<.005 || size>.1) {
      throw const FormatException('Field outside template page.');
    }
  }
  SchoolTemplateField copyWith({double? x,double? y,double? width,
    double? size,bool? mask}) => SchoolTemplateField(
    key:key,x:x??this.x,y:y??this.y,width:width??this.width,
    size:size??this.size,mask:mask??this.mask);
  Map<String,dynamic> toJson()=>{'key':key,'x':x,'y':y,
    'width':width,'size':size,'mask':mask};
}

class SchoolTemplateDraft {
  const SchoolTemplateDraft({required this.kind,required this.schoolId,
    required this.filename,required this.sourceHash,required this.png,
    required this.width,required this.height,this.fields=const []});
  final SchoolTemplateKind kind;
  final String schoolId,filename,sourceHash;
  final Uint8List png;
  final int width,height;
  final List<SchoolTemplateField> fields;
  SchoolTemplateDraft copyWith({List<SchoolTemplateField>? fields}) =>
    SchoolTemplateDraft(kind:kind,schoolId:schoolId,filename:filename,
      sourceHash:sourceHash,png:png,width:width,height:height,
      fields:fields??this.fields);
}

class SchoolTemplateImportEngine {
  static const maxSourceBytes=16*1024*1024;
  static const maxPngBytes=24*1024*1024;
  static const maxPixels=12000000;
  static bool isPdf(Uint8List b)=>b.length>5 &&
    String.fromCharCodes(b.take(5))=='%PDF-';
  static bool isPng(Uint8List b)=>b.length>8 &&
    b[0]==137 && b[1]==80 && b[2]==78 && b[3]==71 && b[4]==13 && b[5]==10;
  static bool isJpeg(Uint8List b)=>b.length>3 &&
    b[0]==255 && b[1]==216 && b[2]==255;
  static String verifySchool(String schoolId) {
    if(!RegExp(r'^vs-[a-zA-Z0-9_-]{8,120}$').hasMatch(schoolId)) {
      throw StateError('Verified school identity required.');
    }
    return schoolId;
  }

  static Future<SchoolTemplateDraft> importBytes({
    required SchoolTemplateKind kind,required String schoolId,
    required String filename,required Uint8List bytes,
    Future<Uint8List> Function(Uint8List)? pdfRasterizer,
  }) async {
    verifySchool(schoolId);
    if(bytes.isEmpty || bytes.length>maxSourceBytes) {
      throw const FormatException('Empty file or larger than 16 MB.');
    }
    if(filename.isEmpty || filename.length>180 ||
      filename.contains('/') || filename.contains('\\')) {
      throw const FormatException('Invalid file name.');
    }
    final ext=filename.split('.').last.toLowerCase();
    if(!['pdf','png','jpg','jpeg'].contains(ext) ||
      (ext=='pdf'&&!isPdf(bytes)) || (ext=='png'&&!isPng(bytes)) ||
      (['jpg','jpeg'].contains(ext)&&!isJpeg(bytes))) {
      throw const FormatException('Please select a genuine PDF, PNG or JPG.');
    }
    Uint8List imageBytes;
    if(ext=='pdf') {
      try {
        if(pdfRasterizer!=null) {
          imageBytes=await pdfRasterizer(bytes);
        } else {
          final first=await Printing.raster(bytes,pages:[0],dpi:110).first;
          imageBytes=await first.toPng();
        }
      } catch (_) {
        throw const FormatException('Cannot render page 1. Encrypted/damaged PDF?');
      }
    } else {
      final decoded=img.decodeImage(bytes);
      if(decoded==null || decoded.width*decoded.height>maxPixels) {
        throw const FormatException('Image invalid or larger than 12 megapixels.');
      }
      imageBytes=Uint8List.fromList(img.encodePng(decoded));
    }
    if(imageBytes.length>maxPngBytes) {
      throw const FormatException('Rendered page exceeds 24 MB.');
    }
    final decoded=img.decodePng(imageBytes);
    if(decoded==null || decoded.width<80 || decoded.height<80 ||
      decoded.width*decoded.height>maxPixels) {
      throw const FormatException('Template page too small or too large.');
    }
    return SchoolTemplateDraft(kind:kind,schoolId:schoolId,filename:filename,
      sourceHash:sha256.convert(bytes).toString(),png:imageBytes,
      width:decoded.width,height:decoded.height);
  }

  static String valueFor(String key,Map<String,dynamic> record) {
    final value=record[key] ?? (key=='studentName'?record['name']:null);
    if(value==null || value is List || value is Map) return '';
    if(key.endsWith('Paise')&&value is num) {
      return 'Rs '+(value/100).toStringAsFixed(2);
    }
    final text=value.toString().trim();
    return text.length>150?text.substring(0,150):text;
  }

  static Future<Uint8List> previewPdf(
    SchoolTemplateDraft draft,Map<String,dynamic> record) async {
    verifySchool(draft.schoolId);
    if(draft.fields.length>35) throw const FormatException('Too many fields.');
    for(final f in draft.fields) f.validate(draft.kind);
    final normal=pw.Font.ttf(await rootBundle.load('assets/id_card_regular.ttf'));
    final width=draft.width*.5,height=draft.height*.5;
    final background=pw.MemoryImage(draft.png);
    final pdf=pw.Document();
    pdf.addPage(pw.Page(
      pageFormat:PdfPageFormat(width,height),margin:pw.EdgeInsets.zero,
      build:(_)=>pw.Stack(children:[
        pw.Positioned(left:0,top:0,
          child:pw.Image(background,width:width,height:height,fit:pw.BoxFit.fill)),
        for(final f in draft.fields)
          pw.Positioned(left:f.x*width,top:f.y*height,
            child:pw.Container(width:f.width*width,
              color:f.mask?PdfColors.white:null,
              child:pw.Text(valueFor(f.key,record),
                maxLines:1,overflow:pw.TextOverflow.clip,
                style:pw.TextStyle(font:normal,fontSize:f.size*width,
                  color:PdfColors.black)))),
      ]),
    ));
    return pdf.save();
  }

  /// Local and school-scoped DRAFT ONLY. Does not overwrite selected templates,
  /// upload to other PCs, clear queues, or change backend/Firestore rules.
  static Future<void> saveLocalDraft(SchoolTemplateDraft draft,
      {required String Function() currentSchoolId}) async {
    verifySchool(draft.schoolId);
    if(draft.fields.isEmpty || draft.fields.length>35) {
      throw StateError('Review and map 1-35 fields first.');
    }
    for(final f in draft.fields) f.validate(draft.kind);
    if(currentSchoolId()!=draft.schoolId) throw StateError('School changed.');
    final root=await getApplicationSupportDirectory();
    final scope=sha256.convert(utf8.encode(draft.schoolId)).toString().substring(0,32);
    final folder=Directory(root.path+Platform.pathSeparator+'template_drafts'+
      Platform.pathSeparator+scope+Platform.pathSeparator+draft.kind.name);
    await folder.create(recursive:true);
    if(currentSchoolId()!=draft.schoolId) throw StateError('School changed.');
    final base=folder.path+Platform.pathSeparator+draft.sourceHash;
    final tmpImage=File(base+'.png.tmp'),tmpJson=File(base+'.json.tmp');
    final metadata={'version':1,'approved':false,'schoolId':draft.schoolId,
      'kind':draft.kind.name,'filename':draft.filename,
      'sourceHash':draft.sourceHash,'width':draft.width,'height':draft.height,
      'fields':draft.fields.map((f)=>f.toJson()).toList()};
    try {
      await tmpImage.writeAsBytes(draft.png,flush:true);
      await tmpJson.writeAsString(jsonEncode(metadata),flush:true);
      if(currentSchoolId()!=draft.schoolId) throw StateError('School switched.');
      final image=File(base+'.png'),manifest=File(base+'.json');
      if(await image.exists()) await image.delete();
      await tmpImage.rename(image.path);
      if(await manifest.exists()) await manifest.delete();
      await tmpJson.rename(manifest.path);
    } finally {
      if(await tmpImage.exists()) await tmpImage.delete();
      if(await tmpJson.exists()) await tmpJson.delete();
    }
  }
}
