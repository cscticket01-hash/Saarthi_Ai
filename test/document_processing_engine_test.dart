import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/document_processing_engine.dart';

void main() {
  test('neutral text keeps readable processed pixels with a smaller lossless grayscale container', () {
    final image=img.Image(width:1000,height:1400);
    img.fill(image,color:img.ColorRgb8(255,255,255));
    for(var row=60;row<1300;row+=42)img.drawString(image,'School record - marks 0123456789',font:img.arial24,x:35,y:row,color:img.ColorRgb8(20,20,20));
    final source=Uint8List.fromList(img.encodePng(image));
    final result=DocumentProcessingEngine.process({'bytes':source});
    final output=result['optimized'] as Uint8List;
    expect(result['mimeType'],'image/png');expect(output.length,lessThan(source.length));
    final restored=img.decodeImage(output)!;
    expect(restored.width,1000);expect(restored.height,1400);
    expect(restored.getPixel(900,1300).r,255);
  });
  test('80 KB target reports real source/output sizes without changing source bytes', () {
    final image=img.Image(width:200,height:300);
    img.fill(image,color:img.ColorRgb8(255,255,255));
    final source=Uint8List.fromList(img.encodePng(image));
    final original=List<int>.from(source);
    final result=DocumentProcessingEngine.process({'bytes':source});
    expect(result['targetBytes'],80*1024);
    expect(result['originalBytes'],source.length);
    expect(result['actualBytes'],(result['optimized'] as Uint8List).length);
    expect(source,original);
  });
  test('eight encoded text scans produce measurable optimized bytes without forcing unreadable target',()async {
    final measurements=<Map<String,dynamic>>[];
    for(var n=0;n<8;n++) {
      final image=img.Image(width:1000,height:1400);img.fill(image,color:img.ColorRgb8(255,255,255));
      for(var row=60;row<1300;row+=42) img.drawString(image,'School record ${n+1} - Name, date and marks 0123456789',font:img.arial24,x:35,y:row,color:img.ColorRgb8(20,20,20));
      final source=Uint8List.fromList(n.isEven?img.encodePng(image):img.encodeJpg(image,quality:98));
      final result=DocumentProcessingEngine.process({'bytes':source});final optimized=result['optimized'] as Uint8List;
      expect(result['actualBytes'],optimized.length);expect(img.decodeImage(optimized),isNotNull);
      expect((result['quality'] as int),greaterThanOrEqualTo(78));
      measurements.add({'sourceBytes':source.length,'optimizedBytes':optimized.length,'savingsPercent':100*(1-optimized.length/source.length),'targetMet':result['targetMet']});
    }
    final total=measurements.fold<int>(0,(sum,row)=>sum+(row['optimizedBytes'] as int));
    final originalTotal=measurements.fold<int>(0,(sum,row)=>sum+(row['sourceBytes'] as int));
    final report={'documents':measurements,'originalTotal':originalTotal,'optimizedTotal':total,'savingsPercent':100*(1-total/originalTotal),'targetBytes':DocumentProcessingEngine.setTarget,
      'status':total<=DocumentProcessingEngine.setTarget?'Optimized':'Readability Protected','representativeInput':'Generated text scan containers, not a real school upload'};
    final output=File('build/document-measurements.json');await output.parent.create(recursive:true);await output.writeAsString(jsonEncode(report));
    print('MEASURE document set '+jsonEncode(report));
  });
  test('disconnected bright objects do not pull paper corners; competing pages are preserved', () {
    final image = img.Image(width: 600, height: 800);
    img.fill(image, color: img.ColorRgb8(45, 45, 45));
    img.fillRect(image, x1: 80, y1: 90, x2: 520, y2: 700, color: img.ColorRgb8(250, 250, 250));
    img.fillRect(image, x1: 2, y1: 2, x2: 28, y2: 30, color: img.ColorRgb8(255, 255, 255));
    final bytes = Uint8List.fromList(img.encodePng(image));
    final before = List<int>.from(bytes);
    final result = DocumentProcessingEngine.process({'bytes': bytes});
    expect(result['perspectiveCorrected'], true);
    expect(result['width'], lessThan(500));
    expect(bytes, before);
    final competing = img.Image(width: 600, height: 800);
    img.fill(competing, color: img.ColorRgb8(45, 45, 45));
    img.fillRect(competing, x1: 30, y1: 40, x2: 265, y2: 760, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(competing, x1: 335, y1: 40, x2: 570, y2: 760, color: img.ColorRgb8(255, 255, 255));
    expect(DocumentProcessingEngine.process({'bytes': Uint8List.fromList(img.encodePng(competing))})['perspectiveCorrected'], false);
  });
  test('truncated real PNG/JPEG containers are rejected before decoding', () {
    final image = img.Image(width: 20, height: 30);
    for (final bytes in [img.encodePng(image), img.encodeJpg(image)]) {
      final truncated = Uint8List.fromList(bytes.sublist(0, bytes.length - 4));
      final original = List<int>.from(truncated);
      expect(() => DocumentProcessingEngine.process({'bytes': truncated}), throwsFormatException);
      expect(truncated, original);
    }
  });

  test('quality floor wins over an impossible byte target; original bytes remain unchanged', () {
    final image = img.Image(width: 600, height: 800);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 80; y < 700; y += 24)
      img.drawLine(
        image,
        x1: 40,
        y1: y,
        x2: 540,
        y2: y,
        color: img.ColorRgb8(20, 20, 20),
        thickness: 2,
      );
    final bytes = Uint8List.fromList(img.encodePng(image)),
        original = List<int>.from(img.encodePng(image));
    final result = DocumentProcessingEngine.process({
      'bytes': bytes,
      'targetBytes': 1,
    });
    expect(bytes, original);
    expect(result['targetMet'], false);
    expect(result['actualBytes'], (result['optimized'] as Uint8List).length);
    final decoded = img.decodeImage(result['optimized'] as Uint8List)!;
    expect(decoded.width, 600);
    expect(decoded.height, 800);
    expect(result['perspectiveCorrected'], false);
    expect(decoded.getPixel(200, 210).r, greaterThan(230));
    expect(decoded.getPixel(200, 200).r, lessThan(60));
  });
  test(
    'confident paper boundary is cropped; ambiguous scans retain full content',
    () {
      final image = img.Image(width: 600, height: 800);
      img.fill(image, color: img.ColorRgb8(50, 50, 50));
      img.fillRect(
        image,
        x1: 40,
        y1: 60,
        x2: 560,
        y2: 740,
        color: img.ColorRgb8(255, 255, 255),
      );
      img.drawLine(
        image,
        x1: 100,
        y1: 200,
        x2: 500,
        y2: 200,
        color: img.ColorRgb8(0, 0, 0),
        thickness: 3,
      );
      final result = DocumentProcessingEngine.process({
        'bytes': Uint8List.fromList(img.encodePng(image)),
      });
      expect(result['perspectiveCorrected'], true);
      expect(result['width'], lessThan(600));
      expect(result['height'], lessThan(800));
    },
  );
  test('text projection straightens a confidently skewed scan without deleting its source', () {
    final image = img.Image(width: 600, height: 800);
    image.backgroundColor = img.ColorRgb8(255, 255, 255);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 100; y < 700; y += 32)
      img.drawLine(
        image,
        x1: 70,
        y1: y,
        x2: 520,
        y2: y,
        color: img.ColorRgb8(20, 20, 20),
        thickness: 2,
      );
    final tilted = img.copyRotate(
      image,
      angle: 3,
      interpolation: img.Interpolation.linear,
    );
    final bytes = Uint8List.fromList(img.encodePng(tilted));
    final result = DocumentProcessingEngine.process({'bytes': bytes});
    expect(result['deskewDegrees'], closeTo(3, 1));
    expect(img.decodeImage(result['optimized'] as Uint8List), isNotNull);
  });
  test(
    'transparent PNG/PDF raster paper stays white with readable black text',
    () {
      final image = img.Image(width: 600, height: 800, numChannels: 4);
      img.drawLine(
        image,
        x1: 40,
        y1: 200,
        x2: 540,
        y2: 200,
        color: img.ColorRgba8(0, 0, 0, 255),
        thickness: 2,
      );
      final result = DocumentProcessingEngine.process({
        'bytes': Uint8List.fromList(img.encodePng(image)),
      });
      final decoded = img.decodeImage(result['optimized'] as Uint8List)!;
      expect(decoded.getPixel(200, 210).r, greaterThan(230));
      expect(decoded.getPixel(200, 200).r, lessThan(60));
    },
  );
  test('EXIF rotated JPEG is oriented before optimization', () {
    final image = img.Image(width: 320, height: 480);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    image.exif.imageIfd.orientation = 6;
    final result = DocumentProcessingEngine.process({
      'bytes': Uint8List.fromList(img.encodeJpg(image)),
    });
    expect(result['width'], 480);
    expect(result['height'], 320);
  });
  test(
    'angled document with surrounding background is rectified conservatively',
    () {
      final image = img.Image(width: 600, height: 800);
      img.fill(image, color: img.ColorRgb8(45, 45, 45));
      img.fillPolygon(
        image,
        vertices: [
          img.Point(80, 70),
          img.Point(550, 115),
          img.Point(515, 735),
          img.Point(45, 690),
        ],
        color: img.ColorRgb8(255, 255, 255),
      );
      final result = DocumentProcessingEngine.process({
        'bytes': Uint8List.fromList(img.encodePng(image)),
      });
      expect(result['perspectiveCorrected'], true);
      expect(img.decodeImage(result['optimized'] as Uint8List), isNotNull);
    },
  );
  test('eight dense text scans report total target honestly and retain readable copies', () {
    var total = 0;
    var originalTotal = 0;
    for (var n = 0; n < 8; n++) {
      final image = img.Image(width: 600, height: 800);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      for (var y = 80; y < 720; y += 24)
        img.drawLine(
          image,
          x1: 40,
          y1: y,
          x2: 550 - n * 10,
          y2: y,
          color: img.ColorRgb8(20, 20, 20),
          thickness: 2,
        );
      final bytes = Uint8List.fromList(img.encodePng(image));
      originalTotal += bytes.length;
      final original = List<int>.from(bytes);
      final result = DocumentProcessingEngine.process({'bytes': bytes});
      final optimized = result['optimized'] as Uint8List;
      total += optimized.length;
      print('MEASURE scan $n: original=${bytes.length} optimized=${optimized.length} savings=${(100*(1-optimized.length/bytes.length)).toStringAsFixed(1)}%');
      expect(
        result['targetMet'],
        optimized.length <= DocumentProcessingEngine.setTarget ~/ 8,
      );
      final readable = img.decodeImage(optimized)!;
      expect(readable.getPixel(200, 80).r, lessThan(70));
      expect(readable.getPixel(200, 90).r, greaterThan(220));
      expect(bytes, original);
      expect((result['highQuality'] as Uint8List).length, greaterThan(0));
      expect(result['quality'], greaterThanOrEqualTo(78));
    }
    print('MEASURE 8 documents original=$originalTotal optimized=$total target=${DocumentProcessingEngine.setTarget} achieved=${total<=DocumentProcessingEngine.setTarget}');
    expect(
      total,
      greaterThan(0),
    ); // Best effort: never sacrifice readability to force 300 KB.
  });
  test(
    'large scan retains readable resolution and obeys decoded safety limit',
    () {
      final image = img.Image(width: 2300, height: 3000);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      final result = DocumentProcessingEngine.process({
        'bytes': Uint8List.fromList(img.encodeJpg(image)),
      });
      final optimized = img.decodeImage(result['optimized'] as Uint8List)!;
      expect(optimized.height, inInclusiveRange(1600, 2200));
      expect(result['height'], 2200);
    },
  );
  test(
    'invalid input is rejected rather than creating a pretend processed scan',
    () {
      expect(
        () => DocumentProcessingEngine.process({
          'bytes': Uint8List.fromList([1, 2, 3]),
        }),
        throwsFormatException,
      );
    },
  );
  test('line scan uses smaller processed lossless PNG instead of expanding to JPEG', () {
    final image=img.Image(width:600,height:800);
    img.fill(image,color:img.ColorRgb8(255,255,255));
    for(var y=80;y<720;y+=24) img.drawLine(image,x1:40,y1:y,x2:550,y2:y,color:img.ColorRgb8(20,20,20),thickness:2);
    final source=Uint8List.fromList(img.encodePng(image));
    final result=DocumentProcessingEngine.process({'bytes':source});
    expect(result['mimeType'],'image/png');
    expect((result['optimized'] as Uint8List).length,lessThan(10000));
    expect(result['targetMet'],true);
    final output=img.decodePng(result['optimized'] as Uint8List)!;
    expect(output.getPixel(200,80).r,lessThan(70));
    expect(output.getPixel(200,90).r,greaterThan(220));
    expect(result['width'],output.width);expect(result['height'],output.height);
  });

}
