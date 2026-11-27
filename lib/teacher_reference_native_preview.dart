import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw show TextAlign;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:xml/xml.dart';
import 'id_card_manifest.dart';
import 'teacher_reference_layout.dart';

Color _color(PdfColor value) => Color.fromARGB(255,(value.red*255).round(),
  (value.green*255).round(),(value.blue*255).round());

/// Preview-only geometry. Legacy printing continues using the exact CR80 pair
/// renderer; this manifest is never sent to the PDF or publication engine.
IdCardManifest teacherReferencePreviewGeometry(int i) {
  final landscape = i == 2;
  final w = landscape ? 480.0 : 306.0, h = landscape ? 300.0 : 486.0;
  final mm = landscape ? 85.6 : 54.0;
  return IdCardManifest.fromJson({
    'version':1,'id':'legacy-teacher-native-$i','canvasWidth':w,'canvasHeight':h,
    'printWidthMm':mm,'printHeightMm':mm*h/w,
    'regions':[for(final side in ['front','back'])
      {'key':'previewGeometry','side':side,'kind':'text','x':0,'y':0,'width':1,'height':1}],
  });
}

({Widget front,Widget back}) teacherReferenceNativeSides(int i, Map<String,dynamic> data,
    Map<String,Uint8List> images,String qr) {
  Widget label(String value,double size,PdfColor color,bool heavy,pw.TextAlign align,
      {int maxLines=3}) => LayoutBuilder(builder:(context,bounds) {
    final alignment = align == pw.TextAlign.center ? Alignment.center : Alignment.topLeft;
    final textAlign = align == pw.TextAlign.center ? TextAlign.center : TextAlign.left;
    return Align(alignment:alignment,child:FittedBox(fit:BoxFit.scaleDown,alignment:alignment,
      child: SizedBox(width:bounds.maxWidth,child:Text(value,maxLines:maxLines,
        overflow:TextOverflow.ellipsis,textAlign:textAlign,
        style:TextStyle(fontSize:size,color:_color(color),
          fontWeight:heavy?FontWeight.bold:FontWeight.normal,height:1.1)))));
  });
  Widget image(Uint8List? bytes,String placeholder,bool cover) => bytes==null
    ? cover ? Center(child:Text(placeholder,style:const TextStyle(fontSize:11,color:Colors.grey)))
      : const SizedBox.shrink()
    : Image.memory(bytes,fit:cover?BoxFit.cover:BoxFit.contain,
        alignment:cover?const Alignment(0,-.3):Alignment.center);
  final sides = buildTeacherReferenceLayers<Widget>(
    i:i,data:data,embeddedPhoto:images['photo'],embeddedLogo:images['logo'],
    printSignature:images['signature'],
    position:(x,y,w,h,child,_)=>Positioned(left:x,top:y,width:w,height:h,child:ClipRect(child:child)),
    text:label,image:image,
    artwork:(source,w,h)=>CustomPaint(size:Size(w??0,h??0),painter:_TeacherArtPainter(source)),
    circle:(child,color,width)=>Container(decoration:BoxDecoration(shape:BoxShape.circle,
      border:Border.all(color:_color(color),width:width)),child:ClipOval(child:child)),
    bordered:(child,color)=>Container(decoration:BoxDecoration(border:Border.all(color:_color(color))),child:child),
    badge:(child,color)=>Container(decoration:BoxDecoration(color:_color(color),
      borderRadius:BorderRadius.circular(15)),child:child),
    rotateSchool:(child)=>RotatedBox(quarterTurns:3,child:child),
    paragraph:(s,size,color,lines)=>label(s,size,color,false,pw.TextAlign.left,maxLines:lines),
    grid:(rows,font,rowHeight,firstHeader)=>Table(border:TableBorder.all(width:.5,color:Colors.black),
      children:[for(var n=0;n<rows.length;n++)TableRow(
        decoration:BoxDecoration(color:n==0&&firstHeader?Colors.grey.shade800:
          n.isEven?Colors.grey.shade100:Colors.white),
        children:[for(final cell in rows[n])SizedBox(height:rowHeight,
          child:Padding(padding:const EdgeInsets.symmetric(horizontal:4,vertical:2),
            child:label(cell,font,n==0&&firstHeader?PdfColors.white:PdfColors.black,
              n==0&&firstHeader,pw.TextAlign.left)))])]),
    qrCode:(_)=>qr.isEmpty?const SizedBox.shrink():
      QrImageView(data:qr,padding:const EdgeInsets.all(4),backgroundColor:Colors.white),
  );
  Widget side(List<Widget> layers)=>SizedBox(width:sides.width,height:sides.height,
    child:Stack(fit:StackFit.expand,clipBehavior:Clip.hardEdge,children:layers));
  return (front:side(sides.front),back:side(sides.back));
}

/// Only the fixed, trusted vector commands in the bundled teacher artwork are
/// supported. No network, script, external SVG or PDF engine is involved.
class _TeacherArtPainter extends CustomPainter {
  _TeacherArtPainter(this.source):document=XmlDocument.parse(source);
  final String source;
  final XmlDocument document;
  Color _parse(String value) {
    if(value=='white')return Colors.white;
    if(value=='black')return Colors.black;
    return Color(0xff000000|int.parse(value.substring(1),radix:16));
  }
  Path _path(String d) {
    final tokens=RegExp(r'[MLHVQZ]|-?\d+(?:\.\d+)?').allMatches(d).map((m)=>m.group(0)!).toList();
    final path=Path(); var index=0; var x=0.0,y=0.0,startX=0.0,startY=0.0;
    double n()=>double.parse(tokens[index++]);
    while(index<tokens.length) {
      switch(tokens[index++]) {
        case 'M': x=n();y=n();startX=x;startY=y;path.moveTo(x,y);break;
        case 'L': x=n();y=n();path.lineTo(x,y);break;
        case 'H': x=n();path.lineTo(x,y);break;
        case 'V': y=n();path.lineTo(x,y);break;
        case 'Q': final a=n(),b=n();x=n();y=n();path.quadraticBezierTo(a,b,x,y);break;
        case 'Z': path.close();x=startX;y=startY;break;
        default: throw const FormatException('Unsupported bundled teacher artwork command');
      }
    }
    return path;
  }
  @override
  void paint(Canvas canvas,Size size) {
    final root=document.rootElement;
    final w=double.parse(root.getAttribute('width')!),h=double.parse(root.getAttribute('height')!);
    canvas.save();canvas.scale(size.width/w,size.height/h);
    for(final element in root.childElements) {
      double number(String name)=>double.tryParse(element.getAttribute(name)??'')??0;
      final path=element.name.local=='rect'?(Path()..addRect(Rect.fromLTWH(
        number('x'),number('y'),number('width'),number('height')))):
        _path(element.getAttribute('d')!);
      final fill=element.getAttribute('fill')??'black';
      if(fill!='none')canvas.drawPath(path,Paint()..color=_parse(fill));
      final stroke=element.getAttribute('stroke');
      if(stroke!=null&&stroke!='none')canvas.drawPath(path,Paint()
        ..color=_parse(stroke)..style=PaintingStyle.stroke..strokeWidth=number('stroke-width'));
    }
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant _TeacherArtPainter oldDelegate)=>oldDelegate.source!=source;
}
