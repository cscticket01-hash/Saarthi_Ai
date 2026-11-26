import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:xml/xml.dart';
import 'windows_template_import_engine.dart';
import 'windows_template_office_converter.dart';
import 'windows_template_forge_auto.dart';

// Structured OpenXML adapter for existing TemplateForge. This deliberately
// accepts a bounded layout subset, not arbitrary Word/Excel documents.
class _Cell {
  _Cell(this.text,this.width,this.height,{this.bold=false,this.ink='000000',
    this.fill,this.size=11,this.align='left',this.border=false});
  String text;
  final double width,height,size;
  final bool bold,border;
  final String ink,align;
  final String? fill;
}
class _Page {
  _Page(this.format,this.margin,this.rows);
  final PdfPageFormat format;
  final double margin;
  final List<List<_Cell>> rows;
}
class SchoolTemplateOfficeLayout {
  static Iterable<XmlElement> _children(XmlElement e,String name)=>
    e.childElements.where((n)=>n.name.local==name);
  static XmlElement? _child(XmlElement? e,String name)=>e==null?null:_children(e,name).firstOrNull;
  static Iterable<XmlElement> _all(XmlNode n,String name)=>
    n.descendants.whereType<XmlElement>().where((x)=>x.name.local==name);
  static String? _attr(XmlElement? e,String name)=>e?.attributes.where((a)=>a.name.local==name).firstOrNull?.value;
  static double _num(String? v,double fallback)=>v==null?fallback:
    (double.tryParse(v)??(throw const FormatException('Invalid Office numeric property.')));
  static Never _reject(String message)=>throw FormatException(message);
  static String? _color(String? s){
    if(s==null||s=='auto')return null;
    if(s.length==8)s=s.substring(2);
    if(!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(s))_reject('Unsupported Office colour.');
    return s;
  }
  static Map<String,XmlDocument> _open(String filename,Uint8List bytes){
    SchoolTemplateOfficeConverter.validateNativeSource(filename,bytes);
    final archive=ZipDecoder().decodeBytes(bytes,verify:true);
    final docs=<String,XmlDocument>{};
    var total=0;
    for(final file in archive.files){
      if(!file.isFile)continue;
      final name=file.name.toLowerCase();
      if(name.contains('/embeddings/')||name.contains('/activex/')||
          name.contains('/externallinks/')||name.contains('/drawings/')||
          name.contains('/media/')||name.contains('/charts/')||
          name.contains('/pivot')||name.contains('comments')||
          name.contains('customxml/'))_reject('Remove embedded objects, pictures, charts, comments and links. Use blank data/image placeholders.');
      total+=file.size;
      if(total>SchoolTemplateOfficeConverter.maxExtractedOfficeBytes)_reject('Expanded Office package exceeds limit.');
      if(!name.endsWith('.xml')&&!name.endsWith('.rels'))continue;
      if(file.size>4*1024*1024)_reject('Office XML exceeds safe size.');
      final xml=utf8.decode(file.content);
      if(RegExp(r'<!\s*(DOCTYPE|ENTITY)',caseSensitive:false).hasMatch(xml))_reject('Unsafe Office XML.');
      final doc=XmlDocument.parse(xml);
      for(final rel in _all(doc,'Relationship')){
        if((_attr(rel,'TargetMode')??'').toLowerCase()=='external')_reject('External Office relationships are not supported.');
      }
      docs[file.name]=doc;
    }
    return docs;
  }
  static PdfPageFormat _paper(double width,double height){
    for(final f in [PdfPageFormat.a4,PdfPageFormat.legal,PdfPageFormat.a4.landscape,PdfPageFormat.legal.landscape]){
      if((f.width-width).abs()<3&&(f.height-height).abs()<3)return f;
    }
    return _reject('Only A4 / Legal portrait or landscape layouts are supported.');
  }
  static _Cell _wordCell(XmlElement p,double width,double height,{bool border=false,String? fill}){
    final runs=_children(p,'r').where((r)=>_all(r,'t').isNotEmpty).toList();
    final props=runs.map((r)=>_child(r,'rPr')).toList();
    if(props.map((r)=>r?.toXmlString()??'').toSet().length>1)_reject('Use one text style per cell or paragraph.');
    final r=props.firstOrNull;
    final size=_num(_attr(_child(r,'sz'),'val'),22)/2;
    final ink=_color(_attr(_child(r,'color'),'val'))??'000000';
    final bold=_child(r,'b')!=null&&_attr(_child(r,'b'),'val')!='0';
    final align=_attr(_child(_child(p,'pPr'),'jc'),'val')??'left';
    return _Cell(_all(p,'t').map((t)=>t.innerText).join(),width,math.max(height,size*1.8+6),bold:bold,ink:ink,fill:fill,size:size,align:align,border:border);
  }
  static _Page _word(Map<String,XmlDocument> docs){
    final root=docs['word/document.xml']?.rootElement??_reject('Missing Word document.');
    if(['drawing','pict','object','altChunk','fldSimple','instrText','hyperlink','sdt','del','ins','vMerge','footnoteReference','endnoteReference','br','tab'].any((n)=>_all(root,n).isNotEmpty))
      _reject('Unsupported Word drawing, field, merge, page break or tracked change. Use a simple blank form.');
    if(docs.keys.any((p)=>RegExp(r'^word/(header|footer|footnotes|endnotes)').hasMatch(p)))_reject('Move headers and footers into the document body.');
    final body=_child(root,'body')??_reject('Missing Word body.');
    final sections=_all(body,'sectPr').toList();
    if(sections.length!=1)_reject('Only one explicit Word page section is supported.');
    final section=sections.single;
    final pg=_child(section,'pgSz')??_reject('Set Word page size to A4 or Legal.');
    final format=_paper(_num(_attr(pg,'w'),0)/20,_num(_attr(pg,'h'),0)/20);
    final marginValues=['top','bottom','left','right'].map((k)=>_num(_attr(_child(section,'pgMar'),k),720)/20).toList();
    if(marginValues.any((x)=>(x-marginValues.first).abs()>0.1))_reject('Use equal page margins.');
    final margin=marginValues.first, width=format.width-2*margin;
    final rows=<List<_Cell>>[];
    for(final element in body.childElements){
      if(element.name.local=='sectPr')continue;
      if(element.name.local=='p'){
        rows.add([_wordCell(element,width,22)]);
      }else if(element.name.local=='tbl'){
        final grid=_child(element,'tblGrid')??_reject('Word table needs fixed column widths.');
        final widths=_children(grid,'gridCol').map((x)=>_num(_attr(x,'w'),0)/20).toList();
        if(widths.isEmpty||widths.length>12||widths.any((w)=>w<24)||
          widths.fold<double>(0,(a,b)=>a+b)>width+1)_reject('Word table exceeds printable width.');
        for(final tr in _children(element,'tr')){
          final cells=_children(tr,'tc').toList();
          final row=<_Cell>[];
          var gridIndex=0;
          final height=_num(_attr(_child(_child(tr,'trPr'),'trHeight'),'val'),480)/20;
          for(var col=0;col<cells.length;col++){
            final ps=_children(cells[col],'p').toList();
            if(ps.length!=1||_children(cells[col],'tbl').isNotEmpty)_reject('Only one paragraph per table cell is supported.');
            final fill=_color(_attr(_child(_child(cells[col],'tcPr'),'shd'),'fill'));
            final span=int.tryParse(_attr(_child(_child(cells[col],'tcPr'),'gridSpan'),'val')??'1')??0;
            if(span<1||gridIndex+span>widths.length)_reject('Invalid horizontal Word cell merge.');
            final mergedWidth=widths.skip(gridIndex).take(span).fold<double>(0,(a,b)=>a+b);
            row.add(_wordCell(ps.single,mergedWidth,height,border:true,fill:fill));
            gridIndex+=span;
          }
          if(gridIndex!=widths.length)_reject('Word table grid does not match its cells.');
          rows.add(row);
        }
      }else{_reject('Unsupported Word body element.');}
    }
    return _Page(format,margin,rows);
  }
  static int _column(String address){
    final m=RegExp(r'^([A-Z]{1,3})([1-9][0-9]*)$').firstMatch(address);
    if(m==null)_reject('Invalid Excel cell address.');
    var col=0;
    for(final c in m.group(1)!.codeUnits){col=col*26+c-64;}
    return col;
  }
  static _Page _sheet(Map<String,XmlDocument> docs){
    final book=docs['xl/workbook.xml']??_reject('Missing Excel workbook.');
    final sheets=_all(book,'sheet').toList();
    if(sheets.length!=1||(_attr(sheets.single,'state')??'visible')!='visible')_reject('Use exactly one visible template sheet.');
    if(_all(book,'definedName').isNotEmpty)_reject('Remove Excel named ranges / print titles.');
    final source=docs.entries.where((e)=>RegExp(r'^xl/worksheets/sheet[0-9]+\.xml$').hasMatch(e.key)).toList();
    if(source.length!=1)_reject('Ambiguous worksheet identity.');
    final sheet=source.single.value.rootElement;
    if(['f','conditionalFormatting','drawing','legacyDrawing','hyperlink','tablePart','autoFilter','rowBreaks','colBreaks'].any((n)=>_all(sheet,n).isNotEmpty))_reject('Remove merged cells, formulas, drawings, conditional rules and page breaks.');
    final setup=_child(sheet,'pageSetup');
    final stock=_attr(setup,'paperSize')??'9';
    final base=stock=='9'?PdfPageFormat.a4:stock=='5'?PdfPageFormat.legal:_reject('Choose A4 or Legal Excel paper.');
    final format=_attr(setup,'orientation')=='landscape'?base.landscape:base;
    final ms=['top','bottom','left','right'].map((k)=>_num(_attr(_child(sheet,'pageMargins'),k),.5)*72).toList();
    if(ms.any((m)=>(m-ms.first).abs()>.1))_reject('Use equal Excel print margins.');
    final margin=ms.first;
    final sharedDoc=docs['xl/sharedStrings.xml'];
    final shared=sharedDoc==null?<String>[]:_all(sharedDoc,'si').map((s){
      if(_all(s,'r').isNotEmpty)_reject('Excel rich text cells are unsupported.');
      return _all(s,'t').map((t)=>t.innerText).join();
    }).toList();
    final styleDoc=docs['xl/styles.xml'];
    List<XmlElement> group(String parent,String child){
      final p=styleDoc==null?null:_all(styleDoc,parent).firstOrNull;
      return p==null?[]:_children(p,child).toList();
    }
    final xfs=group('cellXfs','xf'),fonts=group('fonts','font'),fills=group('fills','fill'),borders=group('borders','border');
    XmlElement? get(List<XmlElement> list,String? id){
      final n=int.tryParse(id??'0')??-1;
      if(list.isEmpty&&n==0)return null;
      if(n<0||n>=list.length)_reject('Invalid Excel style reference.');
      return list[n];
    }
    final grid=<int,Map<int,XmlElement>>{};
    final rowHeights=<int,double>{};
    var lastCol=0,lastRow=0;
    for(final row in _all(sheet,'row')){
      if(_attr(row,'hidden')=='1')_reject('Hidden Excel rows are unsupported.');
      final n=int.tryParse(_attr(row,'r')??'')??0;
      if(n<1||n>60||grid.containsKey(n))_reject('Excel template must fit within 60 rows.');
      final values=<int,XmlElement>{};
      for(final c in _children(row,'c')){
        final a=_attr(c,'r')??'', col=_column(a);
        if(col>12||values.containsKey(col)||int.parse(RegExp(r'[0-9]+$').firstMatch(a)!.group(0)!)!=n)_reject('Invalid cell geometry.');
        values[col]=c;lastCol=math.max(lastCol,col);
      }
      grid[n]=values;lastRow=math.max(lastRow,n);
      rowHeights[n]=_num(_attr(row,'ht'),26);
    }
    if(lastRow==0||lastCol==0)_reject('Excel worksheet is empty.');
    final cols=<int,double>{};
    for(final col in _all(sheet,'col')){
      final min=int.tryParse(_attr(col,'min')??'')??0,max=int.tryParse(_attr(col,'max')??'')??0;
      if(min<1||max<min||_attr(col,'hidden')=='1')_reject('Unsupported Excel column range.');
      final w=_num(_attr(col,'width'),8.43)*5.25+3.75;
      for(var i=min;i<=math.min(max,lastCol);i++){cols[i]=w;}
    }
    final mergeWidths=<int,Map<int,int>>{};
    final covered=<int,Set<int>>{};
    for(final merge in _all(sheet,'mergeCell')){
      final range=(_attr(merge,'ref')??'').split(':');
      if(range.length!=2)_reject('Invalid Excel merge range.');
      final a=_column(range.first),b=_column(range.last);
      final first=int.parse(RegExp(r'[0-9]+$').firstMatch(range.first)!.group(0)!);
      final last=int.parse(RegExp(r'[0-9]+$').firstMatch(range.last)!.group(0)!);
      if(first!=last||first<1||first>lastRow||a>=b||b>lastCol)_reject('Only horizontal Excel merges within the existing grid are supported.');
      final used=covered.putIfAbsent(first,()=> <int>{});
      for(var c=a;c<=b;c++){
        if(!used.add(c))_reject('Overlapping Excel merges.');
        if(c>a){
          final hidden=grid[first]?[c];
          if(hidden!=null && (_all(hidden,'t').any((n)=>n.innerText.trim().isNotEmpty)||
            (_child(hidden,'v')?.innerText.trim()??'').isNotEmpty))
            _reject('Merged Excel cell contains hidden data.');
        }
      }
      mergeWidths.putIfAbsent(first,()=> <int,int>{})[a]=b-a+1;
    }
    final widths=[for(var i=1;i<=lastCol;i++)cols[i]??48.0];
    if(widths.fold<double>(0,(a,b)=>a+b)>format.width-2*margin)_reject('Set column widths to fit the printed page.');
    final rows=<List<_Cell>>[];
    for(var n=1;n<=lastRow;n++){
      final height=rowHeights[n]??26.0;
      final out=<_Cell>[];
      for(var c=1;c<=lastCol;c++){
        final span=mergeWidths[n]?[c]??1;
        final cell=grid[n]?[c];
        final type=_attr(cell,'t')??'n';
        String value='';
        if(cell!=null){
          final raw=_child(cell,'v')?.innerText??'';
          if(type=='s'){
            final pos=int.tryParse(raw)??-1;
            if(pos<0||pos>=shared.length)_reject('Invalid Excel shared string.');
            value=shared[pos];
          }else if(type=='inlineStr'){if(_all(cell,'r').isNotEmpty)_reject('Rich text cells are unsupported.');value=_all(cell,'t').map((t)=>t.innerText).join();}
          else if(type=='str'||type=='n'){value=raw;}else{_reject('Unsupported Excel value type.');}
        }
        final xf=get(xfs,_attr(cell,'s'));
        final font=get(fonts,_attr(xf,'fontId'));
        final pattern=_child(get(fills,_attr(xf,'fillId')),'patternFill');
        final border=get(borders,_attr(xf,'borderId'));
        if(pattern!=null&&!['none','gray125','solid',null].contains(_attr(pattern,'patternType')))_reject('Unsupported Excel fill.');
        final alignment=_child(xf,'alignment');
        final align=_attr(alignment,'horizontal')??'left';
        if(_attr(alignment,'wrapText')=='1'||(_attr(alignment,'textRotation')!=null&&_attr(alignment,'textRotation')!='0'))_reject('Wrapped or rotated Excel text is unsupported.');
        if(_attr(xf,'numFmtId')!=null&&_attr(xf,'numFmtId')!='0')_reject('Use plain Excel text / general cells; live amounts come from Saarthi.');
        final width=widths.skip(c-1).take(span).fold<double>(0,(a,b)=>a+b);
        out.add(_Cell(value,width,height,bold:_child(font,'b')!=null,
          ink:_color(_attr(_child(font,'color'),'rgb'))??'000000',fill:_color(_attr(_child(pattern,'fgColor'),'rgb')),
          size:_num(_attr(_child(font,'sz'),'val'),11),align:align=='general'?'left':align,
          border:border!=null&&border.childElements.any((b)=>_attr(b,'style')!=null)));
        c+=span-1;
      }
      rows.add(out);
    }
    return _Page(format,margin,rows);
  }
  static Future<SchoolTemplateDraft> importSource({
    required SchoolTemplateKind kind,required String schoolId,required String filename,required Uint8List bytes,
    Future<List<Uint8List>> Function(Uint8List)? pdfPagesRasterizer,
  }) {
    SchoolTemplateImportEngine.verifySchool(schoolId);
    final docs=_open(filename,bytes);
    final page=filename.toLowerCase().endsWith('.docx')?_word(docs):_sheet(docs);
    if(page.margin<12||page.margin>100||page.rows.isEmpty||page.rows.length>60)_reject('Unsupported page margins or row count.');
    final format=page.format;
    final fields=<SchoolTemplateField>[],slots=<ForgeVisualSlot>[];
    // All source validation is synchronous and precedes asset loading.
    // Invalid sources never reach the asynchronous renderer or rasterizer.
    final widgets=<pw.Widget Function(pw.Font,pw.Font,List<pw.Font>)>[];
    final token=RegExp(r'^\{\{([A-Za-z][A-Za-z0-9]*)\}\}$');
    final nameHeaders=kind==SchoolTemplateKind.receipt
      ?const ['particulars','description','fee details','fee head','fee name','বিবরণ','विवरण']
      :const ['subject','subjects','subject name','বিষয়','विषय'];
    final amountHeaders=kind==SchoolTemplateKind.receipt
      ?const ['amount','fee amount','price','राशि','টাকা']
      :const ['marks','marks obtained','obtained','score','নম্বর','अंक'];
    if(kind!=SchoolTemplateKind.payslip){
      var tableCount=0;
      for(var index=0;index<page.rows.length;index++){
        final row=page.rows[index];
        final names=<int>[],amounts=<int>[];
        for(var col=0;col<row.length;col++){
          final label=TemplateForgeAutoMapper.normalized(row[col].text);
          if(nameHeaders.contains(label))names.add(col);
          if(amountHeaders.contains(label))amounts.add(col);
        }
        if(names.isEmpty||amounts.isEmpty)continue;
        if(names.length!=1||amounts.length!=1||names.single>=amounts.single||++tableCount>1)
          _reject('Ambiguous fee or marks table.');
        final a=names.single,b=amounts.single;
        var count=0;
        for(var next=index+1;next<page.rows.length;next++){
          final cells=page.rows[next];
          if(cells.length!=row.length||cells.any((c)=>c.text.trim().isNotEmpty))break;
          if(count>=SchoolTemplateImportEngine.maxTableRows)_reject('Too many source table rows.');
          cells[a].text='{{'+(kind==SchoolTemplateKind.receipt?'feeName':'subjectName')+'$count}}';
          cells[b].text='{{'+(kind==SchoolTemplateKind.receipt?'feeAmount':'subjectMarks')+'$count}}';
          count++;
        }
      }
    }
    final foreign=SchoolTemplateKind.values.where((k)=>k!=kind).expand((k)=>SchoolTemplateImportEngine.requiredFields[k]!).where((k)=>!kind.fields.contains(k)).toSet();
    final aliases=TemplateForgeAutoMapper.aliases;
    // Avoid persisting unclassified literal names, identifiers or amounts.
    // School-specific text belongs in verified dynamic fields.
    final safeLiterals=<String>{
      ...kind.fields.expand((k)=>aliases[k]??const <String>[]),
      ...nameHeaders,...amountHeaders,
      'fee receipt','school receipt','payment receipt','report card','marksheet',
      'mark sheet','progress report','salary slip','staff payslip','pay slip','payslip',
      'fee particulars','serial no','sl no','sr no','description','amount',
      'subject','subjects','marks','maximum marks','obtained marks',
      'authorized signature','principal signature','school seal','school logo',
      'student photo','signature','seal','date','total','grand total',
    }.map(TemplateForgeAutoMapper.normalized).toSet();
    var y=page.margin;
    for(final row in page.rows){
      if(row.isEmpty)continue;
      final h=row.map((c)=>c.height).reduce(math.max);
      if(!h.isFinite||h<14||y+h>format.height-page.margin)_reject('Source does not fit on one page.');
      for(var index=0;index<row.length;index++){
        final cell=row[index],text=cell.text.trim();
        if(text.isEmpty||token.hasMatch(text))continue;
        final label=TemplateForgeAutoMapper.normalized(text);
        final headings=<SchoolTemplateKind,List<String>>{
          SchoolTemplateKind.receipt:['fee receipt','school receipt','payment receipt'],
          SchoolTemplateKind.reportCard:['report card','marksheet','mark sheet','progress report'],
          SchoolTemplateKind.payslip:['salary slip','staff payslip','pay slip','payslip'],
        };
        for(final other in headings.entries){
          if(other.key!=kind && other.value.any((v)=>label==v||label.startsWith(v+' ')))
            _reject('Selected category does not match the document heading.');
        }
        for(final key in foreign){
          if((aliases[key]??const <String>[]).any((a)=>label==a||label.startsWith(a+' ')))_reject('Document contains fields belonging to another template category.');
        }
        final matches=kind.fields.where((k)=>(aliases[k]??const <String>[]).contains(label)).toList();
        if(matches.length==1&&index+1<row.length){
          final next=row[index+1];
          if(next.text.trim().isEmpty){next.text='{{'+matches.single+'}}';}
          else if(!token.hasMatch(next.text.trim()))_reject('Upload a blank form; a known data field contains an old value.');
          else if(token.firstMatch(next.text.trim())!.group(1)!=matches.single)_reject('Label and field placeholder do not match.');
        }
      }
      var x=page.margin;
      for(final cell in row){
        if(!cell.width.isFinite||cell.width<15||x+cell.width>format.width-page.margin+1||
          !cell.size.isFinite||cell.size<6||cell.size>36||!['left','center','right'].contains(cell.align))
          _reject('Unsupported cell size or alignment.');
        final value=cell.text.trim(),match=token.firstMatch(cell.text.trim());
        if(value.contains('{{')&&match==null)_reject('Use one complete field placeholder per cell.');
        if(match==null&&value.isNotEmpty&&!safeLiterals.contains(TemplateForgeAutoMapper.normalized(value)))
          _reject('Unverified static text: use a recognized label or a dynamic school field. Remove old personal data.');
        if(match==null&&RegExp(r'[\r\n\t]').hasMatch(value))_reject('Multiline cell text is unsupported.');
        if(match==null&&kind.fields.any((k)=>(aliases[k]??const <String>[]).any((a)=>TemplateForgeAutoMapper.normalized(value).startsWith(a+' '))))
          _reject('Use a blank cell or an explicit field placeholder instead of prefilled personal data.');
        if(match==null&&value.isNotEmpty&&(value.runes.length*cell.size*.62>cell.width-6||cell.size*1.6>h-4))
          _reject('Static text does not fit its source cell. Enlarge the source cell.');
        // Capture immutable coordinates before the loop advances.
        final left=x,top=y;
        widgets.add((normal,bold,fallback)=>pw.Positioned(left:left,top:top,
          child:pw.Container(width:cell.width,height:h,
          decoration:pw.BoxDecoration(color:cell.fill==null?PdfColors.white:PdfColor.fromHex('#'+cell.fill!),border:cell.border?pw.Border.all(color:PdfColors.black,width:.5):null),
          padding:const pw.EdgeInsets.all(3),
          child:match!=null||value.isEmpty?null:pw.Text(value,maxLines:1,
            style:pw.TextStyle(font:cell.bold?bold:normal,fontFallback:fallback,fontSize:cell.size,color:PdfColor.fromHex('#'+cell.ink)),
            textAlign:cell.align=='center'?pw.TextAlign.center:cell.align=='right'?pw.TextAlign.right:pw.TextAlign.left))));
        if(match!=null){
          final key=match.group(1)!;
          if(ForgeVisualSlot.roles.contains(key)){
            slots.add(ForgeVisualSlot(role:key,x:(x+3)/format.width,y:(y+3)/format.height,width:(cell.width-6)/format.width,height:(h-6)/format.height));
          }else{
            if(!kind.fields.contains(key))_reject('Template type mismatch or unknown field: '+key);
            if(cell.size*1.8>h-6)_reject('Field height is too small.');
            fields.add(SchoolTemplateField(key:key,x:(x+3)/format.width,y:(y+3)/format.height,
              width:(cell.width-6)/format.width,size:cell.size/format.height,ink:cell.ink,bold:cell.bold,alignment:cell.align));
          }
        }
        x+=cell.width;
      }
      y+=h;
    }
    SchoolTemplateImportEngine.validateFieldSet(kind,fields);
    return _renderValidated(kind:kind,schoolId:schoolId,filename:filename,
      sourceHash:sha256.convert(bytes).toString(),format:format,fields:fields,slots:slots,
      widgets:widgets,pdfPagesRasterizer:pdfPagesRasterizer);
  }

  static Future<SchoolTemplateDraft> _renderValidated({
    required SchoolTemplateKind kind,required String schoolId,required String filename,
    required String sourceHash,required PdfPageFormat format,
    required List<SchoolTemplateField> fields,required List<ForgeVisualSlot> slots,
    required List<pw.Widget Function(pw.Font,pw.Font,List<pw.Font>)> widgets,
    Future<List<Uint8List>> Function(Uint8List)? pdfPagesRasterizer,
  }) async {
    final normal=pw.Font.ttf(await rootBundle.load('assets/id_card_regular.ttf'));
    final bold=pw.Font.ttf(await rootBundle.load('assets/id_card_bold.ttf'));
    final fallback=<pw.Font>[
      pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSansDevanagari[wdth,wght].ttf')),
      pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSansBengali[wdth,wght].ttf')),
    ];
    final pdf=pw.Document();
    pdf.addPage(pw.Page(pageFormat:format,margin:pw.EdgeInsets.zero,build:(_)=>pw.Stack(children:[
      pw.SizedBox(width:format.width,height:format.height),
      for(final widget in widgets)widget(normal,bold,fallback),
    ])));
    final raster=await SchoolTemplateImportEngine.importBytes(kind:kind,schoolId:schoolId,filename:'native.pdf',
      bytes:await pdf.save(),pdfPagesRasterizer:pdfPagesRasterizer??(bytes) =>
        Printing.raster(bytes,dpi:180).take(2).asyncMap((page)=>page.toPng()).toList().timeout(const Duration(seconds:30)));
    final draft=SchoolTemplateDraft(kind:kind,schoolId:schoolId,filename:filename,sourceHash:sourceHash,png:raster.png,width:raster.width,height:raster.height,fields:fields,visualSlots:slots);
    SchoolTemplateImportEngine.validateDraft(draft);
    return draft;
  }
}
