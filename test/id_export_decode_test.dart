import 'dart:io';
import '../lib/qr_authentication_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/id_card_engine.dart';
void main(){
 final directory=Directory('build/id-final-rasters');
 test('production offline ZXing decoder reads every composed final 300 DPI ID export',(){
  expect(directory.existsSync(),true,reason:'CI must raster final exported PDFs first');
  final files=directory.listSync().whereType<File>().where((f)=>f.path.endsWith('.png')).toList();
  expect(files.length,greaterThanOrEqualTo(13));
  for(final file in files){
    final raw=IdCardEngine.decodeFinalRaster(file.readAsBytesSync());
    final credential=QrAuthenticationEngine.decode(raw,expectedSchool:'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    expect(credential.managed,true,reason:file.path);
    expect(credential.personId,isNotEmpty,reason:file.path);
    expect(credential.linkToken,'x'*48,reason:file.path);
    QrAuthenticationEngine.validateSession(credential,{'expiresAt':2000,'sessionToken':'server-verified-test','projectId':credential.projectId,'schoolId':credential.schoolId,'person':{'personId':credential.personId}},now:1000);
   }
 });
}
