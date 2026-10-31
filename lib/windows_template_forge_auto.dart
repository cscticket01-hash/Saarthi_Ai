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
    'schoolName':['school name','name of school','विद्यालय का नाम','স্কুলের নাম','বিদ্যালয়ৰ নাম'],
    'studentName':['student name','name of student','name of pupil','विद्यार्थी का नाम','छात्र का नाम','শিক্ষার্থীর নাম','ছাত্রের নাম','ছাত্ৰৰ নাম'],
    'name':['employee name','staff name','name of employee','कर्मचारी का नाम','কর্মচারীর নাম','কৰ্মচাৰীৰ নাম'],
    'receiptNo':['receipt no','receipt number','receipt id','रसीद संख्या','রসিদ নং','ৰচিদ নং'],
    'rollNo':['roll no','roll number','रोल नंबर','রোল নম্বর','ৰোল নং'],
    'class':['class','grade','कक्षा','শ্রেণি','শ্রেণী','শ্ৰেণী'],
    'dateText':['date of issue','payment date','date','दिनांक','तारीख','তারিখ','তাৰিখ'],
    'totalAmount':['total amount','amount paid','total paid','कुल राशि','মোট টাকা','মোট পরিমাণ','মুঠ ধন'],
    'paymentMode':['payment mode','mode of payment','भुगतान का तरीका','পেমেন্ট পদ্ধতি'],
    'examName':['exam name','examination','परीक्षा का नाम','পরীক্ষার নাম','পৰীক্ষাৰ নাম'],
    'academicSession':['academic session','session','शैक्षणिक सत्र','শিক্ষাবর্ষ','শিক্ষাবৰ্ষ'],
    'totalMarks':['total marks','कुल अंक','মোট নম্বর','মুঠ নম্বৰ'],
    'percentage':['percentage','प्रतिशत','শতাংশ','শতকৰা'],
    'result':['result','परिणाम','ফলাফল'],
    'employeeId':['employee id','staff id','कर्मचारी आईडी','কর্মচারী আইডি'],
    'role':['designation','job title','पदनाम','পদবি','পদবী'],
    'month':['salary month','month','महीना','মাস','মাহ'],
    'basicPaise':['basic salary','basic pay','मूल वेतन','মূল বেতন','মূল দৰমহা'],
    'allowancePaise':['allowances','allowance','भत्ता','ভাতা'],
    'deductionPaise':['deductions','deduction','कटौती','কর্তন','কটন'],
    'netPaise':['net salary','net pay','शुद्ध वेतन','নিট বেতন','মুঠ দৰমহা'],
    'paidPaise':['salary paid','amount paid to employee','भुगतान वेतन','প্রদত্ত বেতন'],
    'status':['payment status','भुगतान स्थिति','পেমেন্ট স্ট্যাটাস'],
  };
  static const required=<SchoolTemplateKind,List<String>>{
    SchoolTemplateKind.receipt:['receiptNo','studentName','totalAmount'],
    SchoolTemplateKind.reportCard:['studentName','class','examName'],
    SchoolTemplateKind.payslip:['name','month','netPaise'],
  };
  static String normalized(String value)=>value.toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N} ]',unicode:true),' ')
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

  /// Suggest a document type without overriding the user's destination.
  /// Ambiguous scans intentionally return null.
  static SchoolTemplateKind? suggestKind(String tsv,int width,int height) {
    final lines=parseTsv(tsv,width,height);
    final scores=<SchoolTemplateKind,int>{};
    for(final kind in SchoolTemplateKind.values){
      var score=0;
      for(final key in kind.fields){
        final phrases=aliases[key]??const <String>[];
        if(lines.any((line){
          final label=normalized(line.map((w)=>w.text).join(' '));
          return phrases.any((p)=>label==p||label.startsWith(p+' '));
        })) score+=(required[kind]??const <String>[]).contains(key)?3:1;
      }
      scores[kind]=score;
    }
    final ordered=SchoolTemplateKind.values.toList()
      ..sort((a,b)=>scores[b]!.compareTo(scores[a]!));
    return scores[ordered.first]!>=5 &&
      scores[ordered.first]! - scores[ordered[1]]!>=2 ? ordered.first : null;
  }

  /// Import sample rows only when both column headers and OCR values are clear.
  /// Row count is later rechecked against the real school record.
  static List<SchoolTemplateField> detectTableRows(
    SchoolTemplateKind kind,List<List<ForgeWord>> lines,List<String> warnings,
  ) {
    if(kind==SchoolTemplateKind.payslip)return const [];
    final nameHeaders=kind==SchoolTemplateKind.receipt
      ?const ['description','particulars','fee details','fee head','বিবরণ','विवरण']
      :const ['subject','subjects','বিষয়','বিষয়','विषय'];
    final valueHeaders=kind==SchoolTemplateKind.receipt
      ?const ['amount','price','total','টাকা','রাশি','राशि']
      :const ['marks','obtained','score','নম্বর','अंक'];
    final start=lines.indexWhere((line){
      final label=normalized(line.map((w)=>w.text).join(' '));
      return nameHeaders.any(label.contains)&&valueHeaders.any(label.contains);
    });
    if(start<0)return const [];
    final candidates=<List<ForgeWord>>[];
    final numeric=RegExp(r'^[0-9,]+(?:\.[0-9]{1,2})?$');
    for(final line in lines.skip(start+1)){
      final label=normalized(line.map((w)=>w.text).join(' '));
      if(label.startsWith('total ')||label.startsWith('grand total') ||
         label.startsWith('net total')||label.startsWith('মোট ')||
         label.startsWith('कुल '))break;
      if(line.first.y-lines[start].first.y>.42)break;
      final last=line.last.text.replaceAll(RegExp(r'[^0-9.,]'),'');
      if(line.length<2||!numeric.hasMatch(last))continue;
      final nameWords=line.sublist(0,line.length-1);
      if(nameWords.isNotEmpty && numeric.hasMatch(nameWords.first.text)
         && nameWords.length>1)nameWords.removeAt(0);
      if(nameWords.isEmpty || nameWords.first.x>=line.last.x)continue;
      candidates.add([...nameWords,line.last]);
    }
    if(candidates.isEmpty){
      warnings.add('Detected table has no trustworthy data rows');
      return const [];
    }
    if(candidates.length>8){
      warnings.add('More than eight scanned table rows; cannot safely import');
      return const [];
    }
    final output=<SchoolTemplateField>[];
    for(var i=0;i<candidates.length;i++){
      final row=candidates[i];
      final amount=row.last,name=row.first,nameEnd=row[row.length-2];
      final nameWidth=math.min(nameEnd.x+nameEnd.w-name.x+.004,
        amount.x-name.x-.015);
      final amountWidth=math.min(amount.w+.008,.98-amount.x);
      if(nameWidth<=.04 || amountWidth<=.025){
        warnings.add('Unclear table cell positions at row '+(i+1).toString());
        return const [];
      }
      final mapped=[
        SchoolTemplateField(key:kind==SchoolTemplateKind.receipt
            ?'feeName$i':'subjectName$i',x:name.x,y:name.y,
          width:nameWidth,size:name.h.clamp(.009,.036).toDouble(),mask:true),
        SchoolTemplateField(key:kind==SchoolTemplateKind.receipt
            ?'feeAmount$i':'subjectMarks$i',x:amount.x,y:amount.y,
          width:amountWidth,size:amount.h.clamp(.009,.036).toDouble(),mask:true),
      ];
      for(final f in mapped)f.validate(kind);
      output.addAll(mapped);
    }
    return output;
  }

  static ForgeRecognition detect(SchoolTemplateDraft input,String tsv) {
    final lines=parseTsv(tsv,input.width,input.height);
    final fields=<SchoolTemplateField>[],found=<String>[],warnings=<String>[];
    final likely=suggestKind(tsv,input.width,input.height);
    if(likely!=null && likely!=input.kind){
      warnings.add('Document appears to be '+likely.title+', not '+input.kind.title+'.');
    }
    for(final key in input.kind.fields){
      final names=aliases[key]??const <String>[];
      final hits=<({List<ForgeWord> words,String alias})>[];
      for(final words in lines){
        final text=normalized(words.map((w)=>w.text).join(' '));
        final matching=names.where((a)=>text==a||text.startsWith(a+' ')).toList()
          ..sort((a,b)=>b.length.compareTo(a.length));
        if(matching.isNotEmpty)hits.add((words:words,alias:matching.first));
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
      // When OCR finds an existing value, mask ONLY its verified word box.
      // Extending a white rectangle across a whole row could erase unrelated
      // marks, totals, table borders or a second printed label.
      final lastRight=trailing.isEmpty ? x+.3 :
        trailing.last.x+trailing.last.w+.006;
      final w=math.min(trailing.isEmpty ? 0.3 : lastRight-x, .98-x);
      if(x<0||x>=.92||y<0||y>=.96||w<.08){
        warnings.add('Field outside printable area: '+key);continue;
      }
      final size=hit.words.first.h.clamp(.009,.036).toDouble();
      final field=SchoolTemplateField(key:key,x:x,y:y,width:w,size:size,
        mask:trailing.isNotEmpty);
      field.validate(input.kind);
      if(fields.any((f)=>f.mask && field.mask &&
        f.x<field.x+field.width && field.x<f.x+f.width &&
        (f.y-field.y).abs()<.012)){
        warnings.add('Overlapping detected fields: '+key);continue;
      }
      fields.add(field);found.add(key);
    }
    final dynamicRows=detectTableRows(input.kind,lines,warnings);
    if(fields.length+dynamicRows.length<=35)fields.addAll(dynamicRows);
    else warnings.add('Too many detected fields for a safe import');
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
