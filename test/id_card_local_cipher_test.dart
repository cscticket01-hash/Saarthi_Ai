import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../lib/id_card_local_cipher.dart';
void main(){
  final key=Uint8List.fromList(List.filled(32,7));
  test('authenticated randomized envelope binds school purpose and key',()async{
    final a=IdCardLocalCipher('A',key),raw=Uint8List.fromList(utf8.encode('sensitive original QR/photo'));
    final sealed=await a.seal(raw,'draft');
    expect(utf8.decode(sealed),isNot(contains('sensitive')));
    expect(await a.open(sealed,'draft',maxBytes:100),raw);
    expect(await a.seal(raw,'draft'),isNot(sealed));
    await expectLater(a.open(sealed,'bulk',maxBytes:100),throwsFormatException);
    await expectLater(IdCardLocalCipher('B',key).open(sealed,'draft',maxBytes:100),throwsFormatException);
    await expectLater(IdCardLocalCipher('A',Uint8List(32)).open(sealed,'draft',maxBytes:100),throwsFormatException);
    final changed=Map<String,dynamic>.from(jsonDecode(utf8.decode(sealed)) as Map)..['mac']=base64Encode(List.filled(16,0));
    await expectLater(a.open(Uint8List.fromList(utf8.encode(jsonEncode(changed))),'draft',maxBytes:100),throwsFormatException);
  });
  test('legacy JSON is explicit and budgets checked',()async{
    final cipher=IdCardLocalCipher('A',key);
    await expectLater(cipher.open(Uint8List.fromList(utf8.encode('{"draft":{}}')),'draft',maxBytes:100),throwsA(isA<IdCardLegacyPlaintextException>()));
    final sealed=await cipher.seal(Uint8List(200),'draft');
    await expectLater(cipher.open(sealed,'draft',maxBytes:100),throwsFormatException);
  });
}
