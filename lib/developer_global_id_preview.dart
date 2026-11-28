import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';
import 'id_card_engine.dart';
import 'id_card_manifest.dart';

/// The review uses the real school card PDF renderer with fictional values.
/// No school identity, real login QR, source sample photo or credential is used.
class DeveloperGlobalIdPreview {
  static const qr = 'SAARTHI-DEMO-NOT-A-LOGIN';
  static Map<String,dynamic> demoData(String kind) => {
    'name': kind == 'studentId' ? 'Demo Student' : 'Demo Staff',
    'schoolName':'Example School','schoolAddress':'Sample School Road',
    'schoolLocation':'Example Town','schoolEmail':'demo@example.invalid',
    'schoolContactNo':'0000000000','parentName':'Demo Guardian',
    'dob':'01/01/2010','class':'VIII','section':'A','rollNo':'012',
    'contact':'0000000000','address':'Example Road, Sample Town',
    'pinCode':'000000','district':'Demo District','state':'Demo State',
    'country':'India','designation':kind=='teacherId'?'Teacher':'Office Staff',
    'subject':'Science','employeeId':'DEMO-001','session':'2026-27',
    'academicSession':'2026-27','bloodGroup':'A+','emergencyContact':'0000000000',
    '_greenBlueVerifiedUid':'DEMO-000001',
  };
  static Map<String,Uint8List> demoImages(){
    final result=<String,Uint8List>{};
    for(final role in ['photo','logo','signature','seal']){
      final canvas=img.Image(width:160,height:160,numChannels:4);
      img.fill(canvas,color:img.ColorRgba8(238,242,247,255));
      final ink=img.ColorRgba8(55,93,134,255);
      if(role=='photo'){
        img.fillCircle(canvas,x:80,y:52,radius:26,color:ink);
        img.fillRect(canvas,x1:40,y1:89,x2:120,y2:148,color:ink);
      }else if(role=='logo'){
        img.fillRect(canvas,x1:35,y1:35,x2:125,y2:125,color:ink);
        img.fillRect(canvas,x1:54,y1:54,x2:106,y2:106,color:img.ColorRgba8(238,242,247,255));
      }else if(role=='seal'){
        img.fillCircle(canvas,x:80,y:80,radius:58,color:ink);
        img.fillCircle(canvas,x:80,y:80,radius:40,color:img.ColorRgba8(238,242,247,255));
      }else{
        // A clearly artificial bar, not an imitation of a person's signature.
        img.fillRect(canvas,x1:18,y1:73,x2:142,y2:86,color:ink);
      }
      result[role]=Uint8List.fromList(img.encodePng(canvas));
    }
    return result;
  }
  static IdCardManifest manifest(Map<String,dynamic> package) =>
    IdCardManifest.fromJson(Map<String,dynamic>.from(package['manifest'] as Map));

  /// Independently decode the printed pixels on each side that has a QR.
  /// The renderer lays out front/back in one physical PDF page, with 8mm gap.
  static void verifyRaster(Uint8List bytes,IdCardManifest m){
    final source=img.decodePng(bytes);
    if(source==null||source.width*source.height>12000000)
      throw const FormatException('Invalid demo print raster.');
    final total=m.hasBack?m.printWidth*2+8:m.printWidth;
    final expectedAspect=total/m.printHeight;
    if((source.width/source.height-expectedAspect).abs()>.035)
      throw const FormatException('Demo print size does not match the manifest.');
    final count=m.hasBack?2:1;
    final faceWidth=math.min(source.width,(source.width*m.printWidth/total).round());
    if(faceWidth<1)throw const FormatException('Invalid card width.');
    for(var i=0;i<count;i++){
      final side=i==0?'front':'back';
      if(!m.regions.any((r)=>r.side==side&&r.kind=='qr'))continue;
      final face=img.copyCrop(source,x:i==0?0:source.width-faceWidth,y:0,width:faceWidth,height:source.height);
      final actual=IdCardEngine.decodeFinalRaster(Uint8List.fromList(img.encodePng(face)));
      if(actual!=qr)throw FormatException('$side demo print QR mismatch.');
    }
  }
  static Future<Uint8List> generate(Map<String,dynamic> package,String kind) async{
    final m=manifest(package);
    final raw=Map<String,dynamic>.from(package['backgrounds'] as Map);
    final backgrounds={for(final e in raw.entries)e.key:base64Decode(e.value as String)};
    final pdf=await IdCardEngine.render(m,demoData(kind),images:demoImages(),qr:qr,backgrounds:backgrounds,printOnly:true);
    Uint8List? result;
    await for(final page in Printing.raster(pdf,dpi:300).timeout(const Duration(seconds:45))){
      if(result!=null)throw const FormatException('Unexpected extra demo print page.');
      result=await page.toPng();
    }
    if(result==null)throw const FormatException('Demo print preview unavailable.');
    verifyRaster(result,m);
    return result;
  }
}
