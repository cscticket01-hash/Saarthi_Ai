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
  factory SchoolTemplateField.fromJson(Map<String,dynamic> v) {
    final field=SchoolTemplateField(
      key:v['key']?.toString()??'',
      x:(v['x'] as num).toDouble(),y:(v['y'] as num).toDouble(),
      width:(v['width'] as num).toDouble(),
      size:(v['size'] as num).toDouble(),mask:v['mask']==true);
    return field;
  }
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
    if (!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(schoolId)) {
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
      // Honour phone-camera EXIF orientation before A4 validation.
      // The original file hash remains unchanged for audit/reimport.
      final oriented=img.bakeOrientation(decoded);
      imageBytes=Uint8List.fromList(img.encodePng(oriented));
    }
    if(imageBytes.length>maxPngBytes) {
      throw const FormatException('Rendered page exceeds 24 MB.');
    }
    final decoded=img.decodePng(imageBytes);
    if(decoded==null || decoded.width<80 || decoded.height<80 ||
      decoded.width*decoded.height>maxPixels) {
      throw const FormatException('Template page too small or too large.');
    }
    final aspect=decoded.width/decoded.height;
    if ((aspect - 210/297).abs() > .075) {
      throw const FormatException('An A4 portrait source is required.');
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

  /// Imported documents do not invent school data. Do not print an overlay
  /// if its matching record value is missing or cannot fit its OCR box.
  static void validatePreviewRecord(
    SchoolTemplateDraft draft,Map<String,dynamic> record,
  ) {
    final keys=<String>{};
    for(final field in draft.fields){
      field.validate(draft.kind);
      if(!keys.add(field.key)){
        throw FormatException('Ambiguous duplicate field: '+field.key);
      }
      final value=valueFor(field.key,record);
      if(value.isEmpty){
        throw FormatException('Missing record value for '+field.key);
      }
      final approxWidth=value.runes.length * field.size * .58;
      if(approxWidth>field.width){
        throw FormatException('Text may be cut off: '+field.key+
          '. Use a clearer source document with wider value boxes.');
      }
    }
    if(draft.kind==SchoolTemplateKind.receipt &&
       record['feeItems'] is Map && record['totalAmount'] is num){
      final fees=record['feeItems'] as Map;
      num sum=0;
      for(final amount in fees.values){
        if(amount is! num || !amount.isFinite || amount<0){
          throw const FormatException('Invalid receipt fee amount.');
        }
        sum+=amount;
      }
      if(fees.isNotEmpty && (sum-(record['totalAmount'] as num)).abs()>.011){
        throw const FormatException('Receipt total does not match fee items.');
      }
    }
    if(draft.kind==SchoolTemplateKind.payslip){
      for(final key in const ['basicPaise','allowancePaise','deductionPaise',
        'bonusPaise','overtimePaise','netPaise','paidPaise']){
        final raw=record[key];
        if(raw!=null && (raw is! int || raw<0)){
          throw FormatException('Invalid salary value: '+key);
        }
      }
      if(record['netPaise'] is int){
        final net=record['netPaise'] as int;
        final hasComponents=record['basicPaise'] is int &&
          record['allowancePaise'] is int &&
          record['deductionPaise'] is int;
        if(hasComponents){
          final expected=(record['basicPaise'] as int)+
            (record['allowancePaise'] as int)+
            (record['bonusPaise'] as int? ??0)+
            (record['overtimePaise'] as int? ??0)-
            (record['deductionPaise'] as int);
          if(expected!=net)throw const FormatException('Salary components do not match net pay.');
        }
        if((record['paidPaise'] as int? ??0)>net){
          throw const FormatException('Paid salary exceeds net salary.');
        }
      }
    }
  }

  static Future<Uint8List> previewPdf(
    SchoolTemplateDraft draft,Map<String,dynamic> record) async {
    verifySchool(draft.schoolId);
    if(draft.fields.length>35) throw const FormatException('Too many fields.');
    validatePreviewRecord(draft,record);
    final normal=pw.Font.ttf(await rootBundle.load('assets/id_card_regular.ttf'));
    // Generated documents print at real ISO A4; the imported page is
    // admitted by the automatic pipeline only if its aspect ratio is A4.
    final width=PdfPageFormat.a4.width,height=PdfPageFormat.a4.height;
    final background=pw.MemoryImage(draft.png);
    final pdf=pw.Document();
    pdf.addPage(pw.Page(
      pageFormat:PdfPageFormat.a4,margin:pw.EdgeInsets.zero,
      build:(_)=>pw.Stack(children:[
        // Give the stack the exact source page dimensions. Positioned-only
        // stacks have no intrinsic size in the PDF widget layout engine.
        pw.SizedBox(width:width,height:height),
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

  static Future<List<SchoolTemplateDraft>> loadLocalDrafts({
    required SchoolTemplateKind kind, required String schoolId,
  }) async {
    verifySchool(schoolId);
    final root = await getApplicationSupportDirectory();
    final scope = sha256.convert(utf8.encode(schoolId)).toString().substring(0, 32);
    final folder = Directory(root.path + Platform.pathSeparator + 'template_drafts' +
      Platform.pathSeparator + scope + Platform.pathSeparator + kind.name);
    if (!await folder.exists()) return [];
    final entries = await folder.list(followLinks: false).toList();
    final manifests = entries.whereType<File>()
      .where((f) => f.path.endsWith('.json')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    final drafts = <SchoolTemplateDraft>[];
    for (final manifest in manifests.take(30)) {
      try {
        final meta = jsonDecode(await manifest.readAsString());
        if (meta is! Map<String, dynamic> || meta['version'] != 1 ||
            meta['approved'] != false || meta['schoolId'] != schoolId ||
            meta['kind'] != kind.name) continue;
        final hash = meta['sourceHash']?.toString() ?? '';
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) continue;
        final raster = File(manifest.path.substring(0, manifest.path.length - 5) + '.png');
        if (!await raster.exists()) continue;
        final imageBytes = await raster.readAsBytes();
        if (imageBytes.length > maxPngBytes) continue;
        final decoded = img.decodePng(imageBytes);
        if (decoded == null || decoded.width != meta['width'] ||
            decoded.height != meta['height'] ||
            decoded.width * decoded.height > maxPixels) continue;
        final rawFields = meta['fields'];
        if (rawFields is! List || rawFields.length > 35) continue;
        final fields = <SchoolTemplateField>[];
        for (final raw in rawFields) {
          if (raw is! Map<String, dynamic>) throw const FormatException('Invalid field');
          final field = SchoolTemplateField.fromJson(raw);
          field.validate(kind);
          fields.add(field);
        }
        drafts.add(SchoolTemplateDraft(kind: kind, schoolId: schoolId,
          filename: meta['filename']?.toString() ?? 'Imported template',
          sourceHash: hash, png: Uint8List.fromList(imageBytes),
          width: decoded.width, height: decoded.height, fields: fields));
      } catch (_) {
        // A corrupt local draft must never hide other previously saved versions.
      }
    }
    return drafts;
  }

  /// Local school-scoped DRAFT ONLY; never replaces approved school templates.
  static Future<void> saveLocalDraft(SchoolTemplateDraft draft, {
    required String Function() currentSchoolId,
  }) async {
    verifySchool(draft.schoolId);
    if (draft.fields.isEmpty || draft.fields.length > 35) {
      throw StateError('Automatic field recognition is incomplete.');
    }
    for (final field in draft.fields) field.validate(draft.kind);
    if (currentSchoolId() != draft.schoolId) {
      throw StateError('School changed before template save.');
    }
    final root = await getApplicationSupportDirectory();
    final scope = sha256.convert(utf8.encode(draft.schoolId)).toString().substring(0, 32);
    final folder = Directory(root.path + Platform.pathSeparator + 'template_drafts' +
      Platform.pathSeparator + scope + Platform.pathSeparator + draft.kind.name);
    await folder.create(recursive: true);
    if (currentSchoolId() != draft.schoolId) throw StateError('School changed.');
    final base = folder.path + Platform.pathSeparator + draft.sourceHash + '-' +
      DateTime.now().toUtc().microsecondsSinceEpoch.toString();
    final tmpPng = File('$base.png.tmp');
    final tmpJson = File('$base.json.tmp');
    final metadata = {
      'version': 1, 'approved': false, 'schoolId': draft.schoolId,
      'kind': draft.kind.name, 'filename': draft.filename,
      'sourceHash': draft.sourceHash, 'width': draft.width,
      'height': draft.height,
      'fields': draft.fields.map((f) => f.toJson()).toList(),
    };
    try {
      await tmpPng.writeAsBytes(draft.png, flush: true);
      await tmpJson.writeAsString(jsonEncode(metadata), flush: true);
      if (currentSchoolId() != draft.schoolId) {
        throw StateError('School switched before template save.');
      }
      await tmpPng.rename('$base.png');
      await tmpJson.rename('$base.json');
    } finally {
      if (await tmpPng.exists()) await tmpPng.delete();
      if (await tmpJson.exists()) await tmpJson.delete();
    }
  }
}
