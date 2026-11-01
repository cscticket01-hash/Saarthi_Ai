import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'windows_template_forge_photo.dart';

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
  List<String> get fields {
    final base=switch(this) {
    SchoolTemplateKind.receipt => const ['schoolName','receiptNo','studentName','class',
      'rollNo','dateText','paymentMode','totalAmount','principalName'],
    SchoolTemplateKind.reportCard => const ['schoolName','studentName','class',
      'rollNo','examName','academicSession','totalMarks','percentage','result','dateText'],
    SchoolTemplateKind.payslip => const ['schoolName','name','employeeId','role','month',
      'basicPaise','allowancePaise','deductionPaise','netPaise',
      'paidPaise','status','dateText'],
    };
    return [
    ...base,
    if(this==SchoolTemplateKind.receipt)
      for(var i=0;i<SchoolTemplateImportEngine.maxTableRows;i++) ...['feeName$i','feeAmount$i'],
    if(this==SchoolTemplateKind.reportCard)
      for(var i=0;i<SchoolTemplateImportEngine.maxTableRows;i++) ...['subjectName$i','subjectMarks$i'],
    ];
  }
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

/// Verified OCR/geometry evidence for an image or QR placeholder.
/// The page border is scanned; a plain OCR label is never accepted as a slot.
class ForgeVisualSlot {
  const ForgeVisualSlot({
    required this.role,required this.x,required this.y,
    required this.width,required this.height,
  });
  static const roles={'studentPhoto','schoolLogo','signature','seal','qrCode'};
  final String role;
  final double x,y,width,height;
  void validate(){
    if(!roles.contains(role) ||
      ![x,y,width,height].every((v)=>v.isFinite) ||
      x<0||y<0||width<.06||height<.04||
      x+width>1||y+height>1||width>.50||height>.48){
      throw const FormatException('Unverified visual slot geometry.');
    }
  }
  Map<String,dynamic> toJson()=>{'role':role,'x':x,'y':y,
    'width':width,'height':height};
  factory ForgeVisualSlot.fromJson(Map<String,dynamic> m){
    final slot=ForgeVisualSlot(
      role:m['role']?.toString()??'',
      x:(m['x'] as num).toDouble(),y:(m['y'] as num).toDouble(),
      width:(m['width'] as num).toDouble(),
      height:(m['height'] as num).toDouble());
    slot.validate();
    return slot;
  }
}

class SchoolTemplateDraft {
  const SchoolTemplateDraft({required this.kind,required this.schoolId,
    required this.filename,required this.sourceHash,required this.png,
    required this.width,required this.height,this.fields=const [],
    this.visualSlots=const []});
  final SchoolTemplateKind kind;
  final String schoolId,filename,sourceHash;
  final Uint8List png;
  final int width,height;
  final List<SchoolTemplateField> fields;
  final List<ForgeVisualSlot> visualSlots;
  SchoolTemplateDraft copyWith({
    List<SchoolTemplateField>? fields,List<ForgeVisualSlot>? visualSlots,
  }) =>
    SchoolTemplateDraft(kind:kind,schoolId:schoolId,filename:filename,
      sourceHash:sourceHash,png:png,width:width,height:height,
      fields:fields??this.fields,visualSlots:visualSlots??this.visualSlots);
}

class SchoolTemplateImportEngine {
  static const maxSourceBytes=16*1024*1024;
  static const maxPngBytes=18*1024*1024;
  static const maxPixels=12000000;
  static const maxTableRows=12;
  static const maxFields=45;
  static const requiredFields=<SchoolTemplateKind,List<String>>{
    SchoolTemplateKind.receipt:['receiptNo','studentName','totalAmount'],
    SchoolTemplateKind.reportCard:['studentName','class','examName'],
    SchoolTemplateKind.payslip:['name','month','basicPaise','allowancePaise',
      'deductionPaise','netPaise'],
  };

  static void validateFieldSet(
    SchoolTemplateKind kind,Iterable<SchoolTemplateField> fields,
  ) {
    final list=fields.toList();
    final keys=list.map((f)=>f.key).toSet();
    if(list.isEmpty || list.length>maxFields || keys.length!=list.length ||
      !(requiredFields[kind]??const <String>[]).every(keys.contains)){
      throw const FormatException('Template is missing required unique fields.');
    }
    final namePrefix=kind==SchoolTemplateKind.receipt?'feeName':
      kind==SchoolTemplateKind.reportCard?'subjectName':'';
    final valuePrefix=kind==SchoolTemplateKind.receipt?'feeAmount':
      kind==SchoolTemplateKind.reportCard?'subjectMarks':'';
    if(namePrefix.isNotEmpty){
      var sawGap=false;
      var count=0;
      for(var i=0;i<maxTableRows;i++){
        final hasName=keys.contains(namePrefix+i.toString());
        final hasValue=keys.contains(valuePrefix+i.toString());
        if(hasName!=hasValue){
          throw const FormatException('Template table row has an incomplete field pair.');
        }
        if(!hasName){
          sawGap=true;
        }else{
          if(sawGap)throw const FormatException('Template table row slots are not contiguous.');
          count++;
        }
      }
      if(count==0){
        throw const FormatException('Template has no verified table row.');
      }
    }
    for(var i=0;i<list.length;i++){
      for(var j=i+1;j<list.length;j++){
        final a=list[i],b=list[j];
        if(a.mask && b.mask &&
          a.x<b.x+b.width && b.x<a.x+a.width &&
          a.y<b.y+b.size*1.8 && b.y<a.y+a.size*1.8){
          throw const FormatException('Template has overlapping masked fields.');
        }
      }
    }
  }

  static void validateDraft(SchoolTemplateDraft draft) {
    verifySchool(draft.schoolId);
    if(draft.png.isEmpty || draft.png.length>maxPngBytes ||
      draft.width<80 || draft.height<80 ||
      draft.width*draft.height>maxPixels){
      throw const FormatException('Template raster is outside safe limits.');
    }
    if(draft.filename.isEmpty || draft.filename.length>180 ||
      draft.filename.contains('/') || draft.filename.contains('\\')){
      throw const FormatException('Template filename is invalid.');
    }
    if(draft.sourceHash.length!=64 ||
      !RegExp(r'^[a-f0-9]{64}').hasMatch(draft.sourceHash)){
      throw const FormatException('Template source hash is invalid.');
    }
    final decoded=img.decodePng(draft.png);
    if(decoded==null || decoded.width!=draft.width ||
      decoded.height!=draft.height){
      throw const FormatException('Template raster dimensions do not match.');
    }
    final ratio=decoded.width/decoded.height;
    if((ratio-210/297).abs()>.075 && (ratio-297/210).abs()>.075){
      throw const FormatException('Template raster is not A4.');
    }
    validateFieldSet(draft.kind,draft.fields);
    for(final field in draft.fields)field.validate(draft.kind);
    if(draft.visualSlots.length>5 ||
      draft.visualSlots.map((s)=>s.role).toSet().length!=draft.visualSlots.length){
      throw const FormatException('Ambiguous visual slots.');
    }
    for(var i=0;i<draft.visualSlots.length;i++){
      final slot=draft.visualSlots[i];
      slot.validate();
      if(slot.role=='qrCode'){
        final aspect=(slot.width*draft.width/draft.height)/slot.height;
        if(aspect<.85||aspect>1.15){
          throw const FormatException('QR placeholder must be square on A4.');
        }
      }
      if(draft.fields.any((f)=>
        f.x<slot.x+slot.width && slot.x<f.x+f.width &&
        f.y<slot.y+slot.height && slot.y<f.y+f.size*1.8)){
        throw const FormatException('Visual slot overlaps a data field.');
      }
      for(var j=i+1;j<draft.visualSlots.length;j++){
        final other=draft.visualSlots[j];
        if(slot.x<other.x+other.width &&
          other.x<slot.x+slot.width &&
          slot.y<other.y+other.height &&
          other.y<slot.y+slot.height){
          throw const FormatException('Visual placeholders overlap.');
        }
      }
    }
  }

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
    Future<List<Uint8List>> Function(Uint8List)? pdfPagesRasterizer,
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
        // A school template is one physical A4 sheet. The native raster
        // plugin is unavailable in headless Flutter unit tests, so tests
        // inject a page rasterizer. Production always uses Printing.raster.
        // Read at most two pages: a second page means fail closed rather
        // than quietly dropping school marks or fee details.
        final pages=pdfPagesRasterizer!=null
          ?await pdfPagesRasterizer(bytes)
          :await Printing.raster(bytes,dpi:110)
            .take(2).asyncMap((page)=>page.toPng()).toList()
            .timeout(const Duration(seconds:30));
        if(pages.length!=1){
          throw const FormatException(
            'Upload a single-page A4 PDF template. Multi-page PDFs are not silently truncated.');
        }
        imageBytes=pages.single;
      } catch (error) {
        if(error is FormatException)rethrow;
        throw const FormatException('Cannot render the single A4 PDF page. Encrypted/damaged PDF?');
      }
    } else {
      final decoded=img.decodeImage(bytes);
      if(decoded==null) {
        throw const FormatException('Unsupported or damaged image.');
      }
      // Honour EXIF orientation. High-resolution phone photos are reduced to
      // a print-safe 12 MP raster instead of being rejected unnecessarily.
      final oriented=img.bakeOrientation(decoded);
      final pixels=oriented.width*oriented.height;
      final normalized=pixels>maxPixels
        ?img.copyResize(oriented,
          width:(oriented.width*math.sqrt(maxPixels/pixels)).round(),
          height:(oriented.height*math.sqrt(maxPixels/pixels)).round(),
          interpolation:img.Interpolation.average)
        :oriented;
      // The camera frame may itself have an A4 aspect even while the
      // actual paper occupies only its center. Rectify whenever a clearly
      // bounded A4 page is evidenced by dark surroundings; clean full-bleed
      // A4 scans keep their original pixels and orientation unchanged.
      final corrected=TemplateForgePhotoNormalizer.rectifyVerifiedA4(
        normalized);
      imageBytes=Uint8List.fromList(
        img.encodePng(corrected??normalized));
    }
    if(imageBytes.length>maxPngBytes) {
      throw const FormatException('Rendered page exceeds 18 MB.');
    }
    final decoded=img.decodePng(imageBytes);
    if(decoded==null || decoded.width<80 || decoded.height<80 ||
      decoded.width*decoded.height>maxPixels) {
      throw const FormatException('Template page too small or too large.');
    }
    final aspect=decoded.width/decoded.height;
    final portrait=(aspect-210/297).abs()<=.075;
    final landscape=(aspect-297/210).abs()<=.075;
    if(!portrait&&!landscape){
      throw const FormatException('An A4 portrait or landscape source is required.');
    }
    return SchoolTemplateDraft(kind:kind,schoolId:schoolId,filename:filename,
      sourceHash:sha256.convert(bytes).toString(),png:imageBytes,
      width:decoded.width,height:decoded.height);
  }

  static String valueFor(String key,Map<String,dynamic> record) {
    final rowKey=RegExp(r'^(feeName|feeAmount|subjectName|subjectMarks)(1[01]|[0-9])$').firstMatch(key);
    if(rowKey!=null){
      final items=rowKey.group(1)!.startsWith('fee')?record['feeItems']:record['marks'];
      if(items is! Map || items.length>maxTableRows)return '';
      final index=int.parse(rowKey.group(2)!);
      if(index>=items.length)return '';
      final entry=items.entries.elementAt(index);
      final value=rowKey.group(1)!.endsWith('Name')?entry.key:entry.value;
      if(value is! String && value is! num)return '';
      return value.toString().trim();
    }
    final fallback=<String,List<String>>{
      'studentName':['name','fullName'],
      'name':['employeeName','staffName','fullName'],
      'class':['studentClass','grade'],
      'rollNo':['roll','rollNumber'],
      'receiptNo':['receiptNumber','receiptId'],
      'totalAmount':['amount','installmentAmount','paidAmount'],
      'dateText':['date','paymentDate','createdAtText'],
      'paymentMode':['mode','method'],
      'examName':['exam','examination'],
      'academicSession':['session','year'],
      'employeeId':['staffId','teacherId'],
      'role':['designation','position'],
      'month':['salaryMonth','period'],
    };
    dynamic value=record[key];
    if(value==null){
      for(final alias in fallback[key]??const <String>[]){
        if(record[alias]!=null){value=record[alias];break;}
      }
    }
    if(value==null || value is List || value is Map) return '';
    if(key.endsWith('Paise')&&value is num) {
      return 'Rs '+(value/100).toStringAsFixed(2);
    }
    final text=value.toString().trim();
    return text.length>150?'':text;
  }

  static double fittedTextSize(
    SchoolTemplateField field,String text,{double? pageWidth,double? pageHeight}
  ) {
    if(text.isEmpty)throw FormatException('Missing field: '+field.key);
    final width=pageWidth??PdfPageFormat.a4.width;
    final height=pageHeight??PdfPageFormat.a4.height;
    final availableWidth=field.width*width;
    final maximumFont=field.size*height;
    final estimated=availableWidth/(text.runes.length*.62);
    if(estimated<5.5){
      throw FormatException('Text does not fit legibly: '+field.key);
    }
    return estimated<maximumFont?estimated:maximumFont;
  }

  /// Imported documents do not invent school data. Do not print an overlay
  /// if its matching record value is missing or cannot fit its OCR box.
  static void validatePreviewRecord(
    SchoolTemplateDraft draft,Map<String,dynamic> record,
  ) {
    validateFieldSet(draft.kind,draft.fields);
    final keys=<String>{};
    for(final field in draft.fields){
      field.validate(draft.kind);
      if(!keys.add(field.key)){
        throw FormatException('Ambiguous duplicate field: '+field.key);
      }
      final value=valueFor(field.key,record);
      if(value.isEmpty){
        final rowKey=RegExp(
          r'^(feeName|feeAmount|subjectName|subjectMarks)(1[01]|[0-9])$',
        ).firstMatch(field.key);
        if(rowKey!=null){
          final rows=rowKey.group(1)!.startsWith('fee')
            ?record['feeItems']:record['marks'];
          final index=int.parse(rowKey.group(2)!);
          // Unused pre-detected row slots are intentionally white-masked.
          if(rows is Map && index>=rows.length)continue;
        }
        throw FormatException('Missing record value for '+field.key);
      }
      final pageFormat=draft.width>draft.height
        ?PdfPageFormat.a4.landscape:PdfPageFormat.a4;
      fittedTextSize(field,value,
        pageWidth:pageFormat.width,pageHeight:pageFormat.height);
    }

    // Records may contain fewer rows than the scanned page. The unused
    // slots are masked in the PDF. Overflow is rejected, never clipped.
    for(final pair in [
      ('feeName',record['feeItems']),
      ('subjectName',record['marks']),
    ]){
      if(pair.$2 is Map && draft.fields.any((f)=>f.key.startsWith(pair.$1))){
        final available=draft.fields.where((f)=>f.key.startsWith(pair.$1)).length;
        if((pair.$2 as Map).length>available){
          throw FormatException('More rows than the scanned table can safely hold: '+pair.$1);
        }
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

    if(draft.kind==SchoolTemplateKind.reportCard &&
      record['marks'] is Map && record['totalMarks'] is num){
      final marks=record['marks'] as Map;
      if(draft.fields.any((f)=>f.key.startsWith('subjectMarks'))){
        if(marks.values.any((v)=>v is! num || !v.isFinite || v<0)){
          throw const FormatException('Subject marks must be numeric for this scanned table.');
        }
        final total=marks.values.fold<num>(0,(sum,v)=>sum+(v as num));
        if((total-(record['totalMarks'] as num)).abs()>.01){
          throw const FormatException('Marksheet total does not match the subject marks.');
        }
        final full=record['fullMarks'];
        final percentage=double.tryParse(record['percentage']?.toString()??'');
        if(full is num && full>0 && percentage!=null && marks.isNotEmpty){
          final perSubject=(total/(full*marks.length)*100-percentage).abs();
          final overall=(total/full*100-percentage).abs();
          if(perSubject>1.0 && overall>1.0){
            throw const FormatException('Marksheet percentage does not match marks and full marks.');
          }
        }
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
          if(expected!=net){
            throw const FormatException('Salary components do not match net pay.');
          }
        }
        if((record['paidPaise'] as int? ??0)>net){
          throw const FormatException('Paid salary exceeds net salary.');
        }
      }
    }
  }

  static pw.Widget _renderField(
    SchoolTemplateField field,Map<String,dynamic> record,
    pw.Font font,double pageWidth,double pageHeight,
  ) {
    final value=valueFor(field.key,record);
    return pw.Positioned(
      left:field.x*pageWidth,top:field.y*pageHeight,
      child:pw.Container(
        width:field.width*pageWidth,height:field.size*pageHeight*1.8,
        color:field.mask?PdfColors.white:null,
        child:value.isEmpty?null:pw.Text(value,
          maxLines:1,overflow:pw.TextOverflow.clip,
          style:pw.TextStyle(font:font,
            fontSize:fittedTextSize(field,value,pageWidth:pageWidth,pageHeight:pageHeight),
            color:PdfColors.black)),
      ),
    );
  }

  /// Refuse missing/foreign image assets: a previous person's face or
  /// signature must never survive as the background of a new document.
  static void validateVisualAssets(
    SchoolTemplateDraft draft,Map<String,dynamic> record,
    Map<String,Uint8List> visualAssets,
  ){
    for(final slot in draft.visualSlots){
      if(slot.role=='qrCode'){
        final data=(record['qr']??record['qrText'])?.toString().trim()??'';
        if(data.isEmpty||data.length>1024){
          throw const FormatException('Verified record QR value is missing.');
        }
        continue;
      }
      final bytes=visualAssets[slot.role];
      if(bytes==null||bytes.isEmpty||bytes.length>4*1024*1024){
        throw FormatException('Required school image is missing: '+slot.role);
      }
      final decoded=img.decodeImage(bytes);
      if(decoded==null||decoded.width*decoded.height>5000000){
        throw FormatException('School image is invalid or oversized: '+slot.role);
      }
    }
  }

  static pw.Widget _renderVisualSlot(
    ForgeVisualSlot slot,Map<String,dynamic> record,
    Map<String,Uint8List> visualAssets,double pageWidth,double pageHeight,
  ){
    final qr=(record['qr']??record['qrText'])?.toString().trim()??'';
    return pw.Positioned(
      left:slot.x*pageWidth+1,top:slot.y*pageHeight+1,
      child:pw.Container(
        width:slot.width*pageWidth-2,
        height:slot.height*pageHeight-2,
        color:PdfColors.white,
        child:pw.Padding(
          padding:pw.EdgeInsets.all(1),
          child:slot.role=='qrCode'
            ?pw.BarcodeWidget(barcode:pw.Barcode.qrCode(),
              data:qr,drawText:false)
            :pw.Image(pw.MemoryImage(visualAssets[slot.role]!),
              fit:pw.BoxFit.contain),
        ),
      ),
    );
  }

  static Future<Uint8List> previewPdf(
    SchoolTemplateDraft draft,Map<String,dynamic> record,{
    Map<String,Uint8List> visualAssets=const {},
  }) async {
    validateDraft(draft);
    validatePreviewRecord(draft,record);
    validateVisualAssets(draft,record,visualAssets);
    final normal=pw.Font.ttf(await rootBundle.load('assets/id_card_regular.ttf'));
    // Generated documents print at real ISO A4; the imported page is
    // admitted by the automatic pipeline only if its aspect ratio is A4.
    final pageFormat=draft.width>draft.height
      ?PdfPageFormat.a4.landscape:PdfPageFormat.a4;
    final width=pageFormat.width,height=pageFormat.height;
    final background=pw.MemoryImage(draft.png);
    final pdf=pw.Document();
    pdf.addPage(pw.Page(
      pageFormat:pageFormat,margin:pw.EdgeInsets.zero,
      build:(_)=>pw.Stack(children:[
        // Give the stack the exact source page dimensions. Positioned-only
        // stacks have no intrinsic size in the PDF widget layout engine.
        pw.SizedBox(width:width,height:height),
        pw.Positioned(left:0,top:0,
          child:pw.Image(background,width:width,height:height,fit:pw.BoxFit.fill)),
        for(final f in draft.fields)
          _renderField(f,record,normal,width,height),
        for(final slot in draft.visualSlots)
          _renderVisualSlot(slot,record,visualAssets,width,height),
      ]),
    ));
    return pdf.save();
  }

  /// Rebuild a published template only after school scope, hash, dimensions,
  /// and field manifest all pass validation.
  static SchoolTemplateDraft fromPublishedManifest({
    required SchoolTemplateKind kind,
    required String schoolId,
    required Map<String,dynamic> manifest,
    required Uint8List png,
  }) {
    verifySchool(schoolId);
    if (manifest['version'] != 1 || manifest['approved'] != true ||
        manifest['schoolId'] != schoolId || manifest['kind'] != kind.name ||
        manifest['contentHash'] is! String ||
        sha256.convert(png).toString() != manifest['contentHash']) {
      throw const FormatException('Published template identity or content hash is invalid.');
    }
    if (png.isEmpty || png.length > maxPngBytes) {
      throw const FormatException('Published template image exceeds safe limits.');
    }
    final decoded = img.decodePng(png);
    if (decoded == null || decoded.width != manifest['width'] ||
        decoded.height != manifest['height'] ||
        decoded.width * decoded.height > maxPixels) {
      throw const FormatException('Published template dimensions are invalid.');
    }
    final ratio = decoded.width / decoded.height;
    if ((ratio - 210 / 297).abs() > .075 &&
        (ratio - 297 / 210).abs() > .075) {
      throw const FormatException('Published template is not A4.');
    }
    final raw = manifest['fields'];
    if (raw is! List || raw.isEmpty || raw.length > maxFields) {
      throw const FormatException('Published template field manifest is invalid.');
    }
    final fields = <SchoolTemplateField>[];
    final keys = <String>{};
    for (final item in raw) {
      if (item is! Map) {
        throw const FormatException('Published template field is invalid.');
      }
      final field = SchoolTemplateField.fromJson(Map<String,dynamic>.from(item));
      field.validate(kind);
      if (!keys.add(field.key)) {
        throw const FormatException('Published template has duplicate fields.');
      }
      fields.add(field);
    }
    validateFieldSet(kind,fields);
    final rawVisual=manifest['visualSlots']??const [];
    if(rawVisual is! List || rawVisual.length>5){
      throw const FormatException('Published visual slot manifest is invalid.');
    }
    final visualSlots=<ForgeVisualSlot>[];
    for(final raw in rawVisual){
      if(raw is! Map)throw const FormatException('Invalid visual slot.');
      visualSlots.add(ForgeVisualSlot.fromJson(Map<String,dynamic>.from(raw)));
    }
    final sourceHash = manifest['sourceHash']?.toString() ?? '';
    if (sourceHash.length != 64 ||
        !RegExp(r'^[a-f0-9]{64}').hasMatch(sourceHash)) {
      throw const FormatException('Published template source hash is invalid.');
    }
    final templateId = manifest['templateId']?.toString();
    if (templateId != null) {
      final engine = manifest['engine']?.toString() ?? '';
      final identity = sourceHash + ':' + manifest['contentHash'].toString() +
        ':' + jsonEncode(fields.map((f)=>f.toJson()).toList()) +
        (visualSlots.isEmpty?'':':'+jsonEncode(
          visualSlots.map((v)=>v.toJson()).toList())) + ':' + engine;
      final expected = sha256.convert(utf8.encode(identity)).toString();
      if (templateId.length != 64 ||
          !RegExp(r'^[a-f0-9]{64}').hasMatch(templateId) ||
          templateId != expected) {
        throw const FormatException('Published template field-map identity is invalid.');
      }
    }
    final published=SchoolTemplateDraft(
      kind: kind, schoolId: schoolId,
      filename: manifest['filename']?.toString() ?? 'School template',
      sourceHash: sourceHash, png: Uint8List.fromList(png),
      width: decoded.width, height: decoded.height, fields: fields,
      visualSlots:visualSlots,
    );
    validateDraft(published);
    return published;
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
        if(meta['contentHash']!=null &&
          meta['contentHash']!=sha256.convert(imageBytes).toString())continue;
        final decoded = img.decodePng(imageBytes);
        if (decoded == null || decoded.width != meta['width'] ||
            decoded.height != meta['height'] ||
            decoded.width * decoded.height > maxPixels) continue;
        final rawFields = meta['fields'];
        if (rawFields is! List || rawFields.length > maxFields) continue;
        final fields = <SchoolTemplateField>[];
        for (final raw in rawFields) {
          if (raw is! Map<String, dynamic>) throw const FormatException('Invalid field');
          final field = SchoolTemplateField.fromJson(raw);
          field.validate(kind);
          fields.add(field);
        }
        final rawVisual=meta['visualSlots']??const [];
        if(rawVisual is! List || rawVisual.length>5)continue;
        final slots=<ForgeVisualSlot>[];
        for(final raw in rawVisual){
          if(raw is! Map)throw const FormatException('Invalid visual slot');
          slots.add(ForgeVisualSlot.fromJson(Map<String,dynamic>.from(raw)));
        }
        final candidate=SchoolTemplateDraft(kind: kind, schoolId: schoolId,
          filename: meta['filename']?.toString() ?? 'Imported template',
          sourceHash: hash, png: Uint8List.fromList(imageBytes),
          width: decoded.width, height: decoded.height, fields: fields,
          visualSlots:slots);
        validateDraft(candidate);
        drafts.add(candidate);
      } catch (_) {
        // A corrupt local draft must never hide other previously saved versions.
      }
    }
    return drafts;
  }

  /// Stable across retries: the same source, OCR fields and verified image
  /// geometry are one draft, not a new duplicate on every upload attempt.
  static String localDraftIdentity(SchoolTemplateDraft draft){
    final digest=sha256.convert(draft.png).toString();
    final map=jsonEncode([
      draft.schoolId,draft.kind.name,draft.sourceHash,digest,
      draft.fields.map((f)=>f.toJson()).toList(),
      draft.visualSlots.map((slot)=>slot.toJson()).toList(),
    ]);
    return sha256.convert(utf8.encode(map)).toString();
  }

  /// Local school-scoped DRAFT ONLY; never replaces approved school templates.
  static Future<void> saveLocalDraft(SchoolTemplateDraft draft, {
    required String Function() currentSchoolId,
  }) async {
    verifySchool(draft.schoolId);
    validateDraft(draft);
    if (currentSchoolId() != draft.schoolId) {
      throw StateError('School changed before template save.');
    }
    final root = await getApplicationSupportDirectory();
    final scope = sha256.convert(utf8.encode(draft.schoolId)).toString().substring(0, 32);
    final folder = Directory(root.path + Platform.pathSeparator + 'template_drafts' +
      Platform.pathSeparator + scope + Platform.pathSeparator + draft.kind.name);
    await folder.create(recursive: true);
    if (currentSchoolId() != draft.schoolId) throw StateError('School changed.');
    final identity=localDraftIdentity(draft);
    final contentHash=sha256.convert(draft.png).toString();
    final base = folder.path + Platform.pathSeparator + draft.sourceHash + '-' +
      identity.substring(0,24);
    final finalPng=File('$base.png'),finalJson=File('$base.json');
    if(await finalPng.exists() && await finalJson.exists()){
      try{
        final raw=jsonDecode(await finalJson.readAsString());
        final pngHash=sha256.convert(await finalPng.readAsBytes()).toString();
        if(raw is Map && raw['draftIdentity']==identity &&
            raw['contentHash']==pngHash && pngHash==contentHash){
          return; // Verified idempotent save.
        }
      }catch(_){}
      throw StateError('Existing same-version school draft failed integrity verification.');
    }
    final attempt=DateTime.now().toUtc().microsecondsSinceEpoch.toString();
    final tmpPng = File('$base.$attempt.png.tmp');
    final tmpJson = File('$base.$attempt.json.tmp');
    final metadata = {
      'version': 1, 'approved': false, 'schoolId': draft.schoolId,
      'kind': draft.kind.name, 'filename': draft.filename,
      'sourceHash': draft.sourceHash, 'width': draft.width,
      'height': draft.height, 'contentHash':contentHash,
      'draftIdentity':identity,
      'fields': draft.fields.map((f) => f.toJson()).toList(),
      if(draft.visualSlots.isNotEmpty)
        'visualSlots':draft.visualSlots.map((s)=>s.toJson()).toList(),
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
