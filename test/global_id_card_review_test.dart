import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:saarthi_ai/developer_global_id_mapping_tracker.dart';
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
  test('source mask can be separate from enlarged output field',(){
    final source=img.Image(width:400,height:200,numChannels:4);
    img.fill(source,color:img.ColorRgba8(255,255,255,255));
    img.fillRect(source,x1:90,y1:45,x2:180,y2:70,color:img.ColorRgba8(20,30,40,255));
    source.setPixelRgba(250,50,90,100,110,255);
    final bytes=Uint8List.fromList(img.encodePng(source));
    final moved=IdCardManifest.fromJson({'version':1,'id':'gid-test','canvasWidth':200,'canvasHeight':100,
      'printWidthMm':100,'printHeightMm':50,'regions':[{'key':'name','side':'front','kind':'text','x':105,'y':20,'width':80,'height':20}]});
    final masks=[<String,dynamic>{'side':'front','key':'name','x':40,'y':20,'width':60,'height':20}];
    final result=img.decodePng(GlobalIdCardReview.cleanFlatRegions(bytes,moved,'front',sampleMasks:masks))!;
    expect(result.getPixel(100,50).r,255);
    expect(result.getPixel(250,50).r,90);
  });
  test('clean companion preserves complex pattern and rejects exterior artwork changes',(){
    final clean=img.Image(width:400,height:200,numChannels:4);
    for(final p in clean){p..r=(p.x%9)*20..g=(p.y%7)*30..b=100..a=255;}
    final filled=img.Image.from(clean);
    img.fillRect(filled,x1:90,y1:45,x2:180,y2:70,color:img.ColorRgba8(255,255,255,255));
    Uint8List png(img.Image v)=>Uint8List.fromList(img.encodePng(v));
    final masks=[<String,dynamic>{'side':'front','key':'name','x':40,'y':20,'width':60,'height':20}];
    final result=img.decodePng(GlobalIdCardReview.verifyCleanCompanion(png(filled),png(clean),manifest,'front',masks))!;
    expect(result.getPixel(100,50).r,clean.getPixel(100,50).r);
    expect(result.getPixel(5,5).g,filled.getPixel(5,5).g);
    expect(()=>GlobalIdCardReview.verifyCleanCompanion(png(filled),png(filled),manifest,'front',masks),throwsFormatException);
    clean.setPixelRgba(5,5,255,255,255,255);
    expect(()=>GlobalIdCardReview.verifyCleanCompanion(png(filled),png(clean),manifest,'front',masks),throwsFormatException);
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
  test('automatic patterned repair overwrites the full mask and preserves exterior',(){
    final source=img.Image(width:400,height:200,numChannels:4);
    for(final p in source){p..r=(p.x%9)*20..g=(p.y%7)*30..b=100..a=255;}
    img.fillRect(source,x1:90,y1:45,x2:180,y2:70,color:img.ColorRgba8(255,0,255,255));
    final bytes=Uint8List.fromList(img.encodePng(source)),original=Uint8List.fromList(bytes);
    final masks=[<String,dynamic>{'side':'front','key':'name','x':40,'y':20,'width':60,'height':20}];
    final result=img.decodePng(GlobalIdCardReview.reconstructArtwork(bytes,manifest,'front',masks))!;
    for(var y=38;y<82;y++)for(var x=78;x<202;x++)expect(result.getPixel(x,y).b,100);
    expect(result.getPixel(5,5).r,source.getPixel(5,5).r);
    expect(result.getPixel(5,5).g,source.getPixel(5,5).g);
    expect(bytes,original);
  });
  test('automatic repair refuses masked borders and excessive coverage',(){
    final source=img.Image(width:400,height:200,numChannels:4);
    img.fill(source,color:img.ColorRgba8(255,255,255,255));
    final bytes=Uint8List.fromList(img.encodePng(source));
    expect(()=>GlobalIdCardReview.reconstructArtwork(bytes,manifest,'front',[
      {'side':'front','key':'photo','x':0,'y':20,'width':60,'height':20}
    ]),throwsFormatException);
    expect(()=>GlobalIdCardReview.reconstructArtwork(bytes,manifest,'front',[
      {'side':'front','key':'photo','x':10,'y':10,'width':180,'height':80}
    ]),throwsFormatException);
  });

  test('shared detection tracker keeps candidate geometry and does not mutate analysis',(){
    final pages=[<String,dynamic>{'side':'front','candidates':[{'key':'name','side':'front','x':10,'y':20,'width':30,'height':8}]}];
    final slots=GlobalIdCardReview.detectSlots(pages,{});
    expect(slots.single['key'],'name');
    expect(slots.single['sample_x'],10);
    slots.single['x']=42;
    expect((pages.single['candidates'] as List).single['x'],10);
  });

  testWidgets('tracking an approved card shows actual manifest and only a close action',(tester)async{
    final image=img.Image(width:200,height:100,numChannels:4);
    img.fill(image,color:img.ColorRgba8(255,255,255,255));
    final data=<String,dynamic>{'mode':'verified','rasters':{'front':base64Encode(img.encodePng(image))},
      'manifest':{'canvasWidth':200,'canvasHeight':100,'regions':[{'side':'front','key':'name','x':50,'y':20,'width':80,'height':15}]}};
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:DeveloperGlobalIdMappingTracker(
      name:'Synthetic ID',kind:'studentId',data:Future.value(data)))));
    await tester.pumpAndSettle();
    expect(find.text('Track Mapping Data'),findsOneWidget);
    expect(find.text('Approved template mapping • read only'),findsOneWidget);
    expect(find.text('Close'),findsOneWidget);
    expect(find.text('Publish'),findsNothing);
    expect(find.text('Delete'),findsNothing);
    expect(find.text('1 / 14 reference fields located • 0 uncertain candidates'),findsOneWidget);
  });

  test('oval removal masks leave corner decoration untouched',(){
    final source=img.Image(width:400,height:200,numChannels:4);
    img.fill(source,color:img.ColorRgba8(255,255,255,255));
    img.fillCircle(source,x:140,y:60,radius:14,color:img.ColorRgba8(20,30,40,255));
    source.setPixelRgba(84,43,90,100,110,255);
    final masks=[<String,dynamic>{'side':'front','key':'photo','x':40,'y':20,'width':60,'height':20,'oval':true}];
    final result=img.decodePng(GlobalIdCardReview.cleanFlatRegions(Uint8List.fromList(img.encodePng(source)),manifest,'front',sampleMasks:masks))!;
    expect(result.getPixel(140,60).r,255);expect(result.getPixel(84,43).r,90);
  });

}
