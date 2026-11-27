import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';
import 'package:saarthi_ai/id_card_manifest.dart';
import 'package:saarthi_ai/global_id_card_review.dart';
void main(){
  test('only a decoded QR candidate gets the QR role, not its sample contents',(){
    final code=QrImage(QrCode.fromData(data:'synthetic-example',errorCorrectLevel:QrErrorCorrectLevel.M));
    final size=(code.moduleCount+8)*8;
    final source=img.Image(width:size,height:size,numChannels:4);
    img.fill(source,color:img.ColorRgba8(255,255,255,255));
    for(var y=0;y<code.moduleCount;y++)for(var x=0;x<code.moduleCount;x++)if(code.isDark(y,x)){
      img.fillRect(source,x1:(x+4)*8,y1:(y+4)*8,x2:(x+5)*8-1,y2:(y+5)*8-1,color:img.ColorRgba8(0,0,0,255));
    }
    final row=<String,dynamic>{'side':'front','key':'','kind':'image','x':0,'y':0,'width':size,'height':size};
    GlobalIdCardReview.suggestQr([{'side':'front','canvasWidth':size,'canvasHeight':size}],[row],{'front':Uint8List.fromList(img.encodePng(source))});
    expect(row['key'],'qr');expect(row.values.contains('synthetic-example'),false);
  });
  final manifest=IdCardManifest.fromJson({'version':1,'id':'gid-test','canvasWidth':200,'canvasHeight':100,
    'printWidthMm':100,'printHeightMm':50,'regions':[{'key':'name','side':'front','kind':'text','x':40,'y':20,'width':60,'height':20}]});
  test('smooth gradient cleanup is explicit and preserves exterior pixels',(){
    final source=img.Image(width:400,height:200,numChannels:4);
    for(final p in source){p..r=(p.x*.4).round()..g=(p.y*.5).round()..b=100..a=255;}
    final expected=source.getPixel(100,50).r.toInt();
    img.fillRect(source,x1:90,y1:45,x2:180,y2:70,color:img.ColorRgba8(255,255,255,255));
    final bytes=Uint8List.fromList(img.encodePng(source));
    expect(()=>GlobalIdCardReview.cleanFlatRegions(bytes,manifest,'front'),throwsFormatException);
    final cleaned=img.decodePng(GlobalIdCardReview.cleanFlatRegions(bytes,manifest,'front',allowSmoothGradient:true))!;
    expect(cleaned.getPixel(100,50).r,closeTo(expected,1));
    expect(cleaned.getPixel(5,5).r,source.getPixel(5,5).r);
    source.setPixelRgba(78,38,255,255,255,255);
    expect(()=>GlobalIdCardReview.cleanFlatRegions(Uint8List.fromList(img.encodePng(source)),manifest,'front',allowSmoothGradient:true),throwsFormatException);
  });
  test('flat sample region is removed without changing original or other artwork',(){
    final source=img.Image(width:400,height:200,numChannels:4);
    img.fill(source,color:img.ColorRgba8(255,255,255,255));
    img.fillRect(source,x1:90,y1:45,x2:180,y2:70,color:img.ColorRgba8(20,30,40,255));
    source.setPixelRgba(5,5,70,80,90,255);
    final bytes=Uint8List.fromList(img.encodePng(source)),copy=Uint8List.fromList(bytes);
    final result=img.decodePng(GlobalIdCardReview.cleanFlatRegions(bytes,manifest,'front'))!;
    expect(result.getPixel(100,50).r,255);expect(result.getPixel(5,5).r,70);expect(bytes,copy);
    source.setPixelRgba(78,38,0,0,0,255);
    expect(()=>GlobalIdCardReview.cleanFlatRegions(Uint8List.fromList(img.encodePng(source)),manifest,'front'),throwsFormatException);
  });
}
