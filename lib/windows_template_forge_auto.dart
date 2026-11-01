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
    SchoolTemplateKind.payslip:['name','month','basicPaise','allowancePaise','deductionPaise','netPaise'],
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

  /// Detects a bounded table region from its header and total-row anchor.
  /// It also creates safe blank row slots when the uploaded A4 design has no
  /// sample values, so schools do not need to fill the template before upload.
  static List<SchoolTemplateField> detectTableRows(
    SchoolTemplateDraft input,List<List<ForgeWord>> lines,List<String> warnings,
  ) {
    final kind=input.kind;
    if(kind==SchoolTemplateKind.payslip)return const [];
    final nameHeaders=kind==SchoolTemplateKind.receipt
      ?const ['description','particulars','fee details','fee head','fee description',
        'item','fee name','বিবরণ','विवरण']
      :const ['subject','subjects','subject name','বিষয়','বিষয়','विषय'];
    final valueHeaders=kind==SchoolTemplateKind.receipt
      ?const ['amount','price','total','value','টাকা','রাশি','राशि']
      :const ['marks','obtained','score','marks obtained','নম্বর','अंक'];
    final headerIndex=lines.indexWhere((line){
      final label=normalized(line.map((w)=>w.text).join(' '));
      return nameHeaders.any(label.contains)&&valueHeaders.any(label.contains);
    });
    if(headerIndex<0){
      warnings.add('Fee/subject table header was not recognized');
      return const [];
    }
    final header=lines[headerIndex];
    ForgeWord? columnWord(List<String> aliases){
      for(final word in header){
        final token=normalized(word.text);
        if(aliases.any((alias)=>token==alias ||
          (alias.contains(' ') && token==alias.split(' ').first))){
          return word;
        }
      }
      return null;
    }
    final nameHeader=columnWord(nameHeaders);
    final valueHeader=columnWord(valueHeaders);
    if(nameHeader==null || valueHeader==null || nameHeader.x>=valueHeader.x){
      warnings.add('Table column positions are ambiguous');
      return const [];
    }
    final headerBottom=header.map((w)=>w.y+w.h).reduce(math.max);
    final headerHeight=header.map((w)=>w.h).reduce(math.max);
    List<ForgeWord>? totalLine;
    double? totalY;
    for(final line in lines.skip(headerIndex+1)){
      final label=normalized(line.map((w)=>w.text).join(' '));
      if(label.startsWith('total') || label.startsWith('grand total') ||
        label.startsWith('net total') || label.startsWith('মোট') ||
        label.startsWith('কুল') || label.startsWith('कुल') ||
        label.startsWith('মুঠ')){
        totalLine=line;
        totalY=line.first.y;
        break;
      }
      if(line.first.y-headerBottom>.55)break;
    }
    final candidates=<List<ForgeWord>>[];
    final numeric=RegExp(r'^[0-9,]+(?:\.[0-9]{1,2})?$');
    for(final line in lines.skip(headerIndex+1)){
      if(totalLine!=null && identical(line,totalLine))break;
      final label=normalized(line.map((w)=>w.text).join(' '));
      if(label.startsWith('grand total') || label.startsWith('net total'))break;
      if(line.first.y-headerBottom>.55)break;
      final last=line.last.text
        .replaceFirst(RegExp(r'^(?:₹|Rs\.?|INR)\s*',caseSensitive:false),'')
        .trim();
      if(line.length<2 || !numeric.hasMatch(last))continue;
      final nameWords=line.sublist(0,line.length-1);
      if(nameWords.isNotEmpty && numeric.hasMatch(nameWords.first.text)
        && nameWords.length>1)nameWords.removeAt(0);
      if(nameWords.isEmpty || nameWords.first.x>=line.last.x)continue;
      candidates.add([...nameWords,line.last]);
    }
    if(candidates.length>8){
      warnings.add('More than eight scanned table rows; cannot safely import');
      return const [];
    }
    final rowTops=candidates.map((row)=>row.first.y).toList()..sort();
    double rowHeight;
    if(rowTops.length>=2){
      final gaps=<double>[
        for(var i=1;i<rowTops.length;i++)rowTops[i]-rowTops[i-1],
      ]..sort();
      rowHeight=gaps[gaps.length~/2];
    }else if(totalY!=null){
      final start=rowTops.isEmpty?headerBottom+headerHeight:rowTops.first;
      rowHeight=(totalY-start)/4;
    }else if(rowTops.isNotEmpty){
      rowHeight=math.max(.03,headerHeight*2.5);
    }else{
      warnings.add('Blank table has no readable total-row boundary');
      return const [];
    }
    rowHeight=rowHeight.clamp(math.max(.022,headerHeight*1.6),.12).toDouble();
    final firstRowY=rowTops.isNotEmpty
      ?rowTops.first
      :headerBottom+rowHeight*.25;
    var rowCount=candidates.isNotEmpty?candidates.length:4;
    if(totalY!=null){
      final available=((totalY-firstRowY)/rowHeight).floor();
      if(available>0)rowCount=math.max(rowCount,available);
    }
    rowCount=rowCount.clamp(1,8);
    if(totalY!=null && firstRowY+(rowCount-1)*rowHeight>=totalY){
      rowCount=math.max(1,((totalY-firstRowY)/rowHeight).floor());
    }
    final output=<SchoolTemplateField>[];
    for(var i=0;i<rowCount;i++){
      final hasSample=i<candidates.length;
      final row=hasSample?candidates[i]:const <ForgeWord>[];
      final amount=hasSample?row.last:valueHeader;
      final name=hasSample?row.first:nameHeader;
      final nameEnd=hasSample?row[row.length-2]:nameHeader;
      final nameX=name.x;
      final amountX=amount.x;
      final nameWidth=hasSample
        ?math.min(nameEnd.x+nameEnd.w-name.x+.004,amountX-nameX-.015)
        :amountX-nameX-.02;
      final amountWidth=hasSample
        ?math.min(amount.w+.008,.98-amountX)
        :math.min(math.max(.09,valueHeader.w+.045),.98-amountX);
      final textHeight=hasSample?name.h:headerHeight*.8;
      final y=hasSample?name.y:firstRowY+i*rowHeight;
      if(nameWidth<=.04 || amountWidth<=.025 ||
        nameX<0 || amountX<0 || y<0 || y>.96 ||
        nameWidth+nameX>1 || amountWidth+amountX>1){
        warnings.add('Unclear table cell geometry at row '+(i+1).toString());
        return const [];
      }
      final mapped=[
        SchoolTemplateField(
          key:kind==SchoolTemplateKind.receipt?'feeName$i':'subjectName$i',
          x:nameX,y:y,width:nameWidth,
          size:textHeight.clamp(.009,.036).toDouble(),mask:true),
        SchoolTemplateField(
          key:kind==SchoolTemplateKind.receipt?'feeAmount$i':'subjectMarks$i',
          x:amountX,y:y,width:amountWidth,
          size:textHeight.clamp(.009,.036).toDouble(),mask:true),
      ];
      for(final field in mapped)field.validate(kind);
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
    final dynamicRows=detectTableRows(input,lines,warnings);
    final overlaps=dynamicRows.any((candidate)=>fields.any((field)=>
      field.mask && candidate.mask &&
      field.x<candidate.x+candidate.width &&
      candidate.x<field.x+field.width &&
      field.y<candidate.y+candidate.size &&
      candidate.y<field.y+field.size));
    if(overlaps){
      warnings.add('Detected table cells overlap another field');
    }else if(fields.length+dynamicRows.length<=35){
      fields.addAll(dynamicRows);
    }else{
      warnings.add('Too many detected fields for a safe import');
    }
    final missing=(required[input.kind]??const <String>[])
      .where((f)=>!found.contains(f)).toList();
    if(input.kind!=SchoolTemplateKind.payslip && dynamicRows.isEmpty){
      warnings.add(input.kind==SchoolTemplateKind.receipt
        ?'No verified fee-item rows found'
        :'No verified subject/marks rows found');
    }
    return ForgeRecognition(input.copyWith(fields:fields),found,missing,warnings);
  }
}
