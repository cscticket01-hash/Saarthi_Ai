import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:saarthi_ai/id_card_manifest.dart';
import 'package:saarthi_ai/global_id_card_review.dart';
void main(){
  final manifest=IdCardManifest.fromJson({'version':1,'id':'gid-test','canvasWidth':200,'canvasHeight':100,
    'printWidthMm':100,'printHeightMm':50,'regions':[{'key':'name','side':'front','kind':'text','x':40,'y':20,'width':60,'height':20}]});
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
