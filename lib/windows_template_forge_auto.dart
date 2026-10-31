import 'dart:convert';
import 'dart:math' as math;
import 'windows_template_import_engine.dart';

class ForgeWord {
  const ForgeWord(this.text,this.x,this.y,this.w,this.h,this.confidence);
  final String text;
  final double x,y,w,h,confidence;
}

class ForgeRecognition {
  const ForgeRecognition(this.draft,this.detected,this.missing,this.warnings);
  final SchoolTemplateDraft draft;
  final List<String> detected,missing,warnings;
  bool get safeToActivate => missing.isEmpty && warnings.isEmpty;
}

/// Conservative automatic field locator. Never silently infers marks or money.
class TemplateForgeAutoMapper {
  static const aliases=<String,List<String>>{
    'studentName':['student name','name of student'],
    'name':['employee name','staff name','name of employee'],
    'receiptNo':['receipt no','receipt number','receipt id'],
    'rollNo':['roll no','roll number'],
    'class':['class','grade'],
    'dateText':['date of issue','payment date','date'],
    'totalAmount':['total amount','amount paid','total paid'],
    'paymentMode':['payment mode','mode of payment'],
    'examName':['exam name','examination'],
    'academicSession':['academic session','session'],
    'totalMarks':['total marks'],
    'percentage':['percentage'],
    'result':['result'],
    'employeeId':['employee id','staff id'],
    'role':['designation'],
    'month':['salary month','month'],
    'basicPaise':['basic salary','basic pay'],
    'allowancePaise':['allowances','allowance'],
    'deductionPaise':['deductions','deduction'],
    'netPaise':['net salary','net pay'],
    'paidPaise':['salary paid'],
    'status':['payment status'],
  };
  static const required=<SchoolTemplateKind,List<String>>{
    SchoolTemplateKind.receipt:['receiptNo','studentName','totalAmount'],
    SchoolTemplateKind.reportCard:['studentName','class','examName'],
    SchoolTemplateKind.payslip:['name','month','netPaise'],
  };
  static String normalized(String value)=>value.toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9 ]'),' ')
    .replaceAll(RegExp(r'\s+'),' ').trim();

  static List<List<ForgeWord>> parseTsv(String tsv,int width,int height) {
    if(width<=0||height<=0||tsv.length>250000) {
      throw const FormatException('Invalid OCR page.');
    }
    final grouped=<String,List<ForgeWord>>{};
    for(final raw in const LineSplitter().convert(tsv).skip(1)) {
      final c=raw.split('\t');
      if(c.length<12||c[0]!='5')continue;
      final conf=double.tryParse(c[10])??0;
      final left=double.tryParse(c[6]),top=double.tryParse(c[7]);
      final w=double.tryParse(c[8]),h=double.tryParse(c[9]);
      final word=c.sublist(11).join('\t').trim();
      if(conf<70||left==null||top==null||w==null||h==null||
        word.isEmpty||![conf,left,top,w,h].every((v)=>v.isFinite)||
        left<0||top<0||w<=0||h<=0||left+w>width||top+h>height)continue;
      final group=[c[1],c[2],c[3],c[4]].join(':');
      (grouped[group]??=[]).add(ForgeWord(word,left/width,top/height,w/width,h/height,conf));
    }
    return grouped.values.map((words)=>words..sort((a,b)=>a.x.compareTo(b.x)))
      .where((x)=>x.isNotEmpty).toList();
  }

  static ForgeRecognition detect(SchoolTemplateDraft input,String tsv) {
    final lines=parseTsv(tsv,input.width,input.height);
    final fields=<SchoolTemplateField>[],found=<String>[],warnings=<String>[];
    for(final key in input.kind.fields){
      final names=aliases[key]??const <String>[];
      final hits=<({List<ForgeWord> words,String alias})>[];
      for(final words in lines){
        final text=normalized(words.map((w)=>w.text).join(' '));
        for(final a in names){
          if(text==a||text.startsWith(a+' ')){
            hits.add((words:words,alias:a));
            break;
          }
        }
      }
      if(hits.length>1){warnings.add('Repeated ambiguous field: '+key);continue;}
      if(hits.isEmpty)continue;
      final hit=hits.single;
      final labelWords=hit.alias.split(' ').length;
      if(hit.words.length<labelWords)continue;
      final endLabel=hit.words[labelWords-1];
      final trailing=hit.words.skip(labelWords)
        .where((w)=>normalized(w.text).isNotEmpty).toList();
      final x=trailing.isEmpty?endLabel.x+endLabel.w+.015:trailing.first.x;
      final y=hit.words.first.y;
      final w=math.min(.42,.98-x);
      if(x<0||x>=.92||y<0||y>=.96||w<.08){
        warnings.add('Field outside printable area: '+key);continue;
      }
      final size=hit.words.first.h.clamp(.009,.036).toDouble();
      final field=SchoolTemplateField(key:key,x:x,y:y,width:w,size:size,
        mask:trailing.isNotEmpty);
      field.validate(input.kind);
      fields.add(field);found.add(key);
    }
    final missing=(required[input.kind]??const <String>[])
      .where((f)=>!found.contains(f)).toList();
    // Complex rows must be rebuilt as dynamic repeated tables before use.
    final tableWarning=switch(input.kind){
      SchoolTemplateKind.receipt=>'Fee-item rows not automatically reconstructed',
      SchoolTemplateKind.reportCard=>'Subject/marks rows not automatically reconstructed',
      SchoolTemplateKind.payslip=>'Earnings/deductions rows not automatically reconstructed',
    };
    warnings.add(tableWarning);
    return ForgeRecognition(input.copyWith(fields:fields),found,missing,warnings);
  }
}
