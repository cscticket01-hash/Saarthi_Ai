import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart' as zx;
import 'id_card_manifest.dart';

/// Conservative, review-only raster cleanup. It does not inpaint or invent
/// artwork on gradients/patterns, and never edits the original source bytes.
class GlobalIdCardReview {
  static const imageFields={'photo','logo','signature','seal'};
  static const textFields={'schoolName','schoolAddress','schoolLocation','schoolEmail','schoolContactNo','name','parentName','dob','class','section','rollNo','designation','subject','contact','address','pinCode','district','state','country','session','employeeId','bloodGroup','emergencyContact','academicSession','confirmedUniversalStudentUid'};
  static String kind(String key)=>imageFields.contains(key)?'image':key=='qr'?'qr':'text';
  /// Suggest a QR role only when an actual embedded raster decodes uniquely.
  /// The decoded sample string is never retained, displayed or returned.
  static void suggestQr(List<Map<String,dynamic>> pages,List<Map<String,dynamic>> slots,Map<String,Uint8List> rasters){
    if(slots.any((r)=>r['key']=='qr'))return;
    final detected=<Map<String,dynamic>>[];
    var inspected=0;
    for(final page in pages){
      final side=page['side'],bytes=rasters[side];
      if(bytes==null||bytes.length>8*1024*1024)continue;
      final source=img.decodePng(bytes);
      if(source==null||source.width*source.height>20000000)continue;
      final sx=source.width/(page['canvasWidth'] as num),sy=source.height/(page['canvasHeight'] as num);
      for(final row in slots.where((r)=>r['side']==side&&r['key']==''&&r['kind']=='image')){
        if(inspected>=24)return;
        final w=(row['width'] as num).toDouble(),h=(row['height'] as num).toDouble();
        if(w<=0||h<=0||w/h<.75||w/h>1.33)continue;
        inspected++;
        final x=((row['x'] as num)*sx).floor().clamp(0,source.width-1).toInt();
        final y=((row['y'] as num)*sy).floor().clamp(0,source.height-1).toInt();
        final right=(((row['x'] as num)+w)*sx).ceil().clamp(x+1,source.width).toInt();
        final bottom=(((row['y'] as num)+h)*sy).ceil().clamp(y+1,source.height).toInt();
        if(right-x<40||bottom-y<40)continue;
        try{
          var crop=img.copyCrop(source,x:x,y:y,width:right-x,height:bottom-y);
          final long=math.max(crop.width,crop.height);
          if(long>800)crop=img.copyResize(crop,width:(crop.width*800/long).round(),height:(crop.height*800/long).round(),interpolation:img.Interpolation.nearest);
          final pixels=Int32List(crop.width*crop.height);
          for(final p in crop)pixels[p.y*crop.width+p.x]=(p.r.toInt()<<16)|(p.g.toInt()<<8)|p.b.toInt();
          final decoded=zx.QRCodeReader().decode(zx.BinaryBitmap(zx.HybridBinarizer(zx.RGBLuminanceSource(crop.width,crop.height,pixels))));
          if(decoded.text.isNotEmpty)detected.add(row);
        }catch(_){/* No reliable QR evidence; keep it unclassified. */}
      }
    }
    if(detected.length==1)detected.single['key']='qr';
  }
  static Uint8List cleanFlatRegions(Uint8List bytes,IdCardManifest manifest,String side){
    if(bytes.length>8*1024*1024)throw const FormatException('Source raster is too large.');
    final decoded=img.decodePng(bytes);
    if(decoded==null||decoded.width*decoded.height>20000000||
        (decoded.width/decoded.height-manifest.width/manifest.height).abs()>.01)
      throw const FormatException('Source raster dimensions differ from the template.');
    final source=decoded.convert(format:img.Format.uint8,numChannels:4);
    final output=img.Image.from(source);
    final sx=source.width/manifest.width,sy=source.height/manifest.height;
    for(final r in manifest.regions.where((r)=>r.side==side)){
      // Expand by one pixel to clear edge anti-aliasing, then inspect the
      // untouched exterior ring. Refuse to guess a non-flat background.
      final x0=(r.x*sx).floor()-1,y0=(r.y*sy).floor()-1;
      final x1=((r.x+r.width)*sx).ceil()+1,y1=((r.y+r.height)*sy).ceil()+1;
      if(x0<1||y0<1||x1>=source.width-1||y1>=source.height-1)
        throw FormatException('${r.key}: sample touches the artwork edge; use clean source artwork.');
      final first=source.getPixel(x0-1,y0-1);
      final red=first.r.toInt(),green=first.g.toInt(),blue=first.b.toInt();
      bool flat(int x,int y){
        final p=source.getPixel(x,y);
        return p.a==255&&(p.r-red).abs()<=3&&(p.g-green).abs()<=3&&(p.b-blue).abs()<=3;
      }
      for(var x=x0-1;x<=x1+1;x++){
        if(!flat(x,y0-1)||!flat(x,y1+1))throw FormatException('${r.key}: background is not flat. Use verified clean artwork instead.');
      }
      for(var y=y0;y<=y1;y++){
        if(!flat(x0-1,y)||!flat(x1+1,y))throw FormatException('${r.key}: background is not flat. Use verified clean artwork instead.');
      }
      img.fillRect(output,x1:x0,y1:y0,x2:x1,y2:y1,color:img.ColorRgba8(red,green,blue,255));
    }
    return Uint8List.fromList(img.encodePng(output));
  }
  static Map<String,dynamic> package(String id,List<Map<String,dynamic>> pages,
      List<Map<String,dynamic>> slots,Map<String,Uint8List> rasters){
    if(pages.isEmpty||pages.length>2||slots.length>128)throw const FormatException('Invalid review pages or slot count.');
    final first=pages.first;
    final w=(first['canvasWidth'] as num).toDouble(),h=(first['canvasHeight'] as num).toDouble();
    if(pages.any((p)=>((p['canvasWidth'] as num)-w).abs()>.01||((p['canvasHeight'] as num)-h).abs()>.01))
      throw const FormatException('Front/back page sizes differ.');
    if(slots.any((r)=>r['key']==''))throw const FormatException('Classify each detected image, or explicitly mark it static artwork.');
    final regions=<Map<String,dynamic>>[];
    for(final slot in slots){
      final key=slot['key']?.toString()??'';
      if(key=='__static')continue;
      if(!textFields.contains(key)&&!imageFields.contains(key)&&key!='qr')throw const FormatException('Unknown field.');
      final type=kind(key);
      final font=((slot['fontSize'] as num?)??math.max(6,math.min(72,((slot['height'] as num?)??12)*.8))).toDouble();
      regions.add({'key':key,'side':slot['side'],'kind':type,'x':slot['x'],'y':slot['y'],
        'width':slot['width'],'height':slot['height'],'fontSize':font,'minFontSize':6,
        'textColor':slot['textColor']??'#000000','required':key=='name'||key=='qr',
        'fit':key=='photo'?'cover':'contain','shape':key=='photo'&&slot['oval']==true?'oval':'rect',
        'wrap':type=='text'&&slot['wrap']==true,'maxLines':type=='text'&&slot['wrap']==true?2:1});
    }
    if(!regions.any((r)=>r['key']=='name'&&r['side']=='front')||!regions.any((r)=>r['key']=='qr'))
      throw const FormatException('Map the front name and authentication QR before review.');
    final json=<String,dynamic>{'id':id,'version':1,'canvasWidth':w,'canvasHeight':h,
      'printWidthMm':first['printWidthMm'],'printHeightMm':first['printHeightMm'],'regions':regions};
    final manifest=IdCardManifest.fromJson(json);
    if(manifest.hasBack!=(pages.length==2))throw const FormatException('Map at least one field on each source side.');
    final backgrounds=<String,String>{};
    for(final side in ['front',if(manifest.hasBack)'back']){
      final source=rasters[side];
      if(source==null)throw const FormatException('Source page missing.');
      backgrounds[side]=base64Encode(cleanFlatRegions(source,manifest,side));
    }
    final result=<String,dynamic>{'manifest':json,'backgrounds':backgrounds};
    if(utf8.encode(jsonEncode(result)).length>8*1024*1024)throw const FormatException('Reviewed package exceeds 8 MiB.');
    return result;
  }
}
