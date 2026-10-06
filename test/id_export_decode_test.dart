import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/id_card_engine.dart';
void main(){
 final directory=Directory('build/id-final-rasters');
 test('production offline ZXing decoder reads every composed final 300 DPI ID export',(){
  expect(directory.existsSync(),true,reason:'CI must raster final exported PDFs first');
  final files=directory.listSync().whereType<File>().where((f)=>f.path.endsWith('.png')).toList();
  expect(files.length,greaterThanOrEqualTo(13));
  for(final file in files){expect(IdCardEngine.decodeFinalRaster(file.readAsBytesSync()),isNotEmpty,reason:file.path);}
 });
}
