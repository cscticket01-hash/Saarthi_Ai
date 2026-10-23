import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'id_card_layout.dart';

/// The only newly generated report layout. Retained PDFs are never rewritten.
Future<Uint8List> renderMaroonMarksheet(Map<String, dynamic> data, {
  Uint8List? photo, Uint8List? logo, Uint8List? signature, Uint8List? seal,
}) async {
  final regular=pw.Font.ttf(await rootBundle.load('assets/id_card_regular.ttf'));
  final bold=pw.Font.ttf(await rootBundle.load('assets/id_card_bold.ttf'));
  final pdf=pw.Document(theme:pw.ThemeData.withFont(base:regular,bold:bold));
  final maroon=PdfColor.fromHex('#700d20'), gold=PdfColor.fromHex('#ba913b');
  final ivory=PdfColor.fromHex('#fffdf7'), pale=PdfColor.fromHex('#f3e6bc');
  String value(List<String> keys,[String fallback='-']) {
    for(final key in keys){final v=data[key]?.toString().trim()??'';if(v.isNotEmpty&&v!='null')return v;}
    return fallback;
  }
  Map<String,dynamic> map(dynamic raw)=>raw is Map?Map<String,dynamic>.from(raw):{};
  num? number(dynamic raw) {
    final n=raw is num?raw:num.tryParse(raw?.toString()??'');
    return n!=null&&n.isFinite?n:null;
  }
  String format(num? v)=>v==null?'-':v==v.roundToDouble()?v.toInt().toString():v.toStringAsFixed(2);
  final exam=value(['examName','term'],'Examination');
  final termMatch=RegExp(r'\b(?:term|quarter|semester|q)\s*[-:]?\s*([1-4])\b',caseSensitive:false).firstMatch(exam);
  final term=number(data['quarter'])?.toInt()??int.tryParse(termMatch?.group(1)??'');
  var marks=map(data['marks']);
  if(marks.isEmpty&&data['isFinal']!=true){
    if(term==1)marks=map(data['term1Marks']);
    if(term==2)marks=map(data['term2Marks']);
    if(marks.isEmpty&&term!=null) {
      final quarters=map(data['quarterMarks']);
      marks={for(final e in quarters.entries) if(e.value is Map && e.value['q$term']!=null) e.key:e.value['q$term']};
    }
  }
  final entries=marks.entries.toList();
  final subjectGrades=map(data['subjectGrades']);
  num? obtained(dynamic raw)=>number(raw is Map?raw['marks']??raw['obtained']:raw);
  num? full(dynamic raw)=>number(raw is Map?raw['fullMarks']??data['fullMarks']:data['fullMarks']);
  num? pass(dynamic raw)=>number(raw is Map?raw['passMarks']??data['passMarks']:data['passMarks']);
  for(final e in entries) {
    final o=obtained(e.value), f=full(e.value), p=pass(e.value);
    if(o!=null&&o<0 || f!=null&&f<=0 || p!=null&&p<0 || o!=null&&f!=null&&o>f || p!=null&&f!=null&&p>f) {
      throw const FormatException('Invalid marksheet marks or limits.');
    }
  }
  final complete=entries.isNotEmpty&&entries.every((e)=>obtained(e.value)!=null);
  num? sum(num? Function(dynamic) read)=>entries.isNotEmpty&&entries.every((e)=>read(e.value)!=null)?entries.fold<num>(0,(s,e)=>s+read(e.value)!):null;
  final total=sum(obtained), maximum=sum(full), minimum=sum(pass);
  final percentage=total!=null&&maximum!=null&&maximum>0?total/maximum*100:number(data['percentage']);
  final result=value(['result'],complete&&entries.every((e)=>pass(e.value)!=null)?(entries.every((e)=>obtained(e.value)!>=pass(e.value)!)?'PASS':'FAIL'):'-');
  const perPage=6;
  final pageCount=entries.isEmpty?1:(entries.length/perPage).ceil();
  for(var page=0;page<pageCount;page++){
    final rows=entries.skip(page*perPage).take(perPage).toList();
    pw.Widget text(String s,{double size=11,bool heavy=false,PdfColor? color,pw.TextAlign align=pw.TextAlign.left,int lines=2})=>IdCardLayout.text(s,font:heavy?bold:regular,fontSize:size,minFontSize:7,wrap:true,maxLines:lines,overflow:'error',color:color??PdfColors.black,align:align);
    pw.Widget at(double x,double y,double w,double h,pw.Widget child)=>pw.Positioned(left:x,top:y,child:pw.SizedBox(width:w,height:h,child:child));
    pw.Widget image(Uint8List? b)=>b==null?pw.SizedBox():IdCardLayout.image(b);
    pw.Widget box(pw.Widget child,{PdfColor? color})=>pw.Container(padding:const pw.EdgeInsets.all(8),decoration:pw.BoxDecoration(color:color,border:pw.Border.all(color:gold,width:.6)),child:child);
    final cells=<List<String>>[
      ['SUBJECT','FULL MARKS','PASS MARKS','MARKS OBTAINED','GRADE'],
      for(final e in rows)[e.key,format(full(e.value)),format(pass(e.value)),format(obtained(e.value)),(e.value is Map?e.value['grade']:null)?.toString()??subjectGrades[e.key]?.toString()??'-'],
      for(var n=rows.length;n<perPage;n++)['','','','',''],
      [pageCount>1?'TOTAL (all subjects)':'TOTAL',format(maximum),format(minimum),format(total),value(['grade','overallGrade'])],
    ];
    final layers=<pw.Widget>[
      pw.Positioned.fill(child:pw.Container(color:ivory)),
      at(14,14,567.28,813.89,pw.Container(decoration:pw.BoxDecoration(border:pw.Border.all(color:maroon,width:1.5)))),
      at(18,18,559.28,108,pw.Container(decoration:pw.BoxDecoration(color:maroon,border:pw.Border.all(color:gold,width:1)))),
      at(29,30,82,82,image(logo)),
      at(122,31,440,51,text(value(['schoolName'],'School name'),size:26,heavy:true,color:pale,align:pw.TextAlign.center,lines:3)),
      at(122,88,440,27,text(value(['schoolAddress']),size:11,color:PdfColors.white,align:pw.TextAlign.center)),
      at(30,139,535,31,text('STUDENT PROGRESS REPORT',size:23,heavy:true,color:maroon,align:pw.TextAlign.center)),
      at(30,174,535,23,text('$exam • Academic Session ${value(['academicSession','academicYear','session'])}',size:12,align:pw.TextAlign.center)),
      at(30,207,535,148,box(pw.SizedBox())),
      at(449,216,105,130,image(photo)),
      for(final row in <List<String>>[
        ['Student Name',value(['studentName','name'])],
        ["Father's Name",value(['parentName','fatherName'])],
        ['Class',value(['studentClass','class'])],
        ['Section',value(['section'])],
        ['Roll No',value(['rollNo','roll'])],
        ['Student ID',value(['studentUid','studentId'])],
        ['Date of Birth',value(['dob','dateOfBirth'])],
      ].asMap().entries) ...[
        at(40,215+row.key*19,115,18,text('${row.value[0]}:',size:10,heavy:true,color:maroon)),
        at(157,215+row.key*19,280,18,text(row.value[1],size:10)),
      ],
      at(30,368,535,224,pw.Table(columnWidths:{0:const pw.FlexColumnWidth(2.5),1:const pw.FlexColumnWidth(1.2),2:const pw.FlexColumnWidth(1.2),3:const pw.FlexColumnWidth(1.6),4:const pw.FlexColumnWidth(.8)},border:pw.TableBorder.all(color:gold,width:.5),children:[
        for(final row in cells.asMap().entries)pw.TableRow(decoration:pw.BoxDecoration(color:row.key==0?maroon:row.key==cells.length-1?pale:null),children:[
          for(var c=0;c<5;c++)pw.Container(height:27,padding:const pw.EdgeInsets.symmetric(horizontal:6,vertical:3),child:text(row.value[c],size:row.key==0?8:10,heavy:row.key==0||row.key==cells.length-1||c==0,color:row.key==0?PdfColors.white:PdfColors.black,align:c==0?pw.TextAlign.left:pw.TextAlign.center)),
        ]),
      ])),
      at(30,600,535,32,box(text('Percentage: ${percentage==null?'-':'${percentage.toStringAsFixed(2)}%'}       |       Result: $result',size:13,heavy:true,color:maroon,align:pw.TextAlign.center),color:pale)),
      at(30,641,535,32,box(text('Attendance: ${value(['attendance','attendanceText'])}       |       Conduct: ${value(['conduct','behavior'])}',size:10))),
      at(30,683,535,47,box(text("Teacher's Remarks: ${value(['teacherComment','remarks'])}",size:10,lines:3))),
      at(41,746,117,32,image(data['classTeacherSignatureBytes'] is Uint8List?data['classTeacherSignatureBytes']:null)),
      at(194,736,66,55,image(seal)),
      at(298,744,113,34,image(signature)),
      for(final item in <double>[40,298,444])at(item,782,110,1,pw.Container(color:maroon)),
      at(40,787,115,18,text('Class Teacher',size:9,align:pw.TextAlign.center)),
      at(294,787,120,18,text('Principal',size:9,align:pw.TextAlign.center)),
      at(437,787,126,18,text('Parent / Guardian',size:9,align:pw.TextAlign.center)),
      at(30,810,380,12,text('Date of Issue: ${value(['dateText','dateOfIssue'])}',size:8)),
      if(pageCount>1)at(458,810,105,12,text('Page ${page+1} of $pageCount',size:8,align:pw.TextAlign.right)),
    ];
    pdf.addPage(pw.Page(pageFormat:PdfPageFormat.a4,margin:pw.EdgeInsets.zero,build:(_)=>pw.Stack(children:layers)));
  }
  return pdf.save();
}
