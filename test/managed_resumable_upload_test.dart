import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_connect/managed_resumable_upload.dart';

void main() {
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final bytes = Uint8List.fromList(List.filled(700000, 65));
  final digest = sha256.convert(bytes).toString();
  Map<String,dynamic> reply(int offset, {bool committed = false}) => {
    'schoolId':school,'uploadResumableVersion':1,'uploadKey':'original-key',
    'sha256':digest,'sizeBytes':bytes.length,'offset':offset,
    'committed':committed,if(committed)'fileId':'verified-file',
  };
  test('owner resumes provider prefix after uncertain chunk response and lost final ACK', () async {
    var offset = 0, writes = 0, fail = true;
    Future<Map<String,dynamic>> request(Map<String,dynamic> body) async {
      expect(body['uploadKey'],'original-key');expect(body['sha256'],digest);
      if(body['operation']=='begin') return reply(offset,committed:offset==bytes.length);
      expect(body['offset'],offset);
      final chunk=base64Decode(body['base64']);
      expect(sha256.convert(chunk).toString(),body['chunkSha256']);
      offset+=chunk.length;writes++;
      if(fail){fail=false;throw StateError('response lost after provider commit');}
      return reply(offset,committed:offset==bytes.length);
    }
    Future<Map<String,dynamic>> run()=>uploadManagedChunks(schoolId:school,uploadKey:'original-key',name:'file.pdf',mime:'application/pdf',bytes:bytes,request:request);
    await expectLater(run(),throwsStateError);
    expect(offset,524288);expect(writes,1);
    expect((await run())['fileId'],'verified-file');expect(writes,2);
    expect((await run())['fileId'],'verified-file');expect(writes,2);
  });
  test('foreign, corrupt and metadata-only completion cannot certify upload', () async {
    for(final changed in [{'schoolId':'foreign'},{'sha256':'0'*64},{'offset':1,'committed':true,'fileId':'file'},{'offset':bytes.length,'committed':false}]){
      await expectLater(uploadManagedChunks(schoolId:school,uploadKey:'original-key',name:'file.pdf',mime:'application/pdf',bytes:bytes,request:(_)async=>{...reply(0),...changed}),throwsStateError);
    }
  });
  test('no-progress provider response stops this attempt without replay loop', () async {
    var sends=0;
    await expectLater(uploadManagedChunks(schoolId:school,uploadKey:'original-key',name:'file.pdf',mime:'application/pdf',bytes:bytes,request:(_)async{ sends++;return reply(0);}),throwsA(isA<Exception>()));
    expect(sends,2);
  });
}
