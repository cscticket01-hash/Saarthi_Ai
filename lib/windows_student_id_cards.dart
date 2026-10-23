import 'dart:typed_data';
import 'id_card_catalog.dart';
import 'id_card_engine.dart';

const studentIdTemplateId = 'student-maroon-gold-v1';
const windowsStudentIdNames = <String>[];
// Legacy stored indexes remain readable but can no longer select retired art.
int windowsStudentIdIndex(dynamic value) => 0;

Future<Uint8List> renderWindowsStudentId({
  required int template,
  required Map<String, dynamic> data,
  String qr = '',
  Uint8List? photo,
  Uint8List? logo,
  Uint8List? signature,
}) async {
  final entry = await IdCardCatalog.find(studentIdTemplateId);
  return IdCardEngine.render(await entry.manifest(), data, qr: qr,
    backgrounds: await entry.backgrounds(), images: {
      if(photo!=null) 'photo':photo,
      if(logo!=null) 'logo':logo,
      if(signature!=null) 'signature':signature,
    });
}
