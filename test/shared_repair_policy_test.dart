import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/shared_repair_policy.dart';

void main(){
  const at=1800000000000,school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late SimpleKeyPair pair;late String public;
  Map<String,dynamic> body({int sequence=1,bool enabled=true})=>{
    'protocol':1,'purpose':'vidya-sync-repair','sequence':sequence,'issuedAt':at,
    'expiresAt':at+86400000,'enabled':enabled,'rules':enabled?[
      {'id':'card-wait','module':'documents','category':'idCardInputs',
        'action':'card_probe_cooldown','value':300,'rolloutPercent':100}]:[],
  };
  Future<Map<String,dynamic>> sign(Map<String,dynamic> data) async {
    final payload=base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=','');
    final signature=await Ed25519().sign(utf8.encode(payload),keyPair:pair);
    return {'keyId':'test-only','payload':payload,'signature':base64Url.encode(signature.bytes).replaceAll('=','')};
  }
  Future<SharedRepairPolicy> check(Map<String,dynamic> e,{int now=at,int previous=0,String? hash})=>
    SharedRepairPolicy.verify(e,trustedKeys:{'test-only':public},now:now,previousSequence:previous,previousHash:hash);
  setUp(()async{pair=await Ed25519().newKeyPairFromSeed(List<int>.filled(32,7));
    public=base64Url.encode((await pair.extractPublicKey()).bytes).replaceAll('=','');});
  test('real Node Ed25519 signature is verified by the Dart receiver',()async{
    final f=jsonDecode(await File('test/fixtures/shared_repair_node_signature.json').readAsString()) as Map;
    final p=await SharedRepairPolicy.verify(Map<String,dynamic>.from(f['envelope']),trustedKeys:{'test-only':f['publicKey']},now:f['now']);
    expect(p.value('card_probe_cooldown',module:'documents',category:'idCardInputs',school:school,now:at),300);
    expect(p.value('card_probe_cooldown',module:'teachers_directory',category:'idCardInputs',school:school,now:at),isNull);
  });
  test('unknown keys, tampering, expiry, rollback and same-sequence equivocation are rejected',()async{
    final e=await sign(body()),p=await check(e);
    await expectLater(check({...e,'keyId':'not-pinned'}),throwsFormatException);
    await expectLater(check({...e,'payload':e['payload']+'A'}),throwsFormatException);
    await expectLater(check(e,now:at+86400000),throwsFormatException);
    await expectLater(check(e,previous:2),throwsFormatException);
    await expectLater(check(e,previous:1,hash:'wrong'),throwsFormatException);
    expect((await check(e,previous:1,hash:p.hash)).sequence,1);
    expect(p.value('card_probe_cooldown',module:'documents',category:'idCardInputs',school:school,now:at+86400000),isNull);
  });
  test('a signed higher-sequence kill switch removes all runtime adjustments',()async{
    final first=await check(await sign(body()));
    final kill=await check(await sign(body(sequence:2,enabled:false)),previous:first.sequence,hash:first.hash);
    expect(kill.enabled,isFalse);expect(kill.rules,isEmpty);
    expect(kill.value('retry_floor',module:'all',category:'timeout',school:school,now:at),isNull);
  });
  test('even valid signatures cannot introduce code, ACK bypass or unsupported parameters',()async{
    for(final action in ['execute_code','clear_queue','skip_auth','accept_unverified_ack']){
      final b=body();(b['rules'] as List).single['action']=action;
      await expectLater(check(await sign(b)),throwsFormatException);
    }
    for(final extra in [{'value':99999},{'url':'https://evil.example'},{'rolloutPercent':101}]){
      final b=body();(b['rules'] as List).single.addAll(extra);
      await expectLater(check(await sign(b)),throwsFormatException);
    }
    await expectLater(check(await sign({...body(),'protocol':2})),throwsFormatException);
    await expectLater(check(await sign({...body(),'issuedAt':at+3600000})),throwsFormatException);
  });
  test('shared observations exclude every school/record/operation/body/error field',(){
    final observations=sharedRepairObservations([{'collection':'teachers_directory','category':'timeout','status':'resolved',
      'schoolId':school,'recordId':'private-person','operationId':'private-operation','password':'private-secret',
      'payload':{'name':'private-name'},'lastError':'private-error'}]);
    expect(observations,[{'module':'teachers_directory','category':'timeout','outcome':'resolved'}]);
    expect(jsonEncode(observations),isNot(contains('private-')));
    expect(sharedRepairObservations([{'collection':'unsupported','category':'timeout','status':'resolved'}]),isEmpty);
  });
  test('cross-school diagnostic fingerprint exports only fixed public enums',(){
    final events=[
      {'collection':'fee_payments','category':'conflict','status':'resolved',
       'failureCode':'RECORD_REVISION_CONFLICT','studentId':'private-id'},
      {'collection':'fee_payments','category':'conflict','status':'reviewRequired',
       'failureCode':'student-name-and-amount'},
    ];
    final safe=sharedRepairObservations(events);
    expect(safe,[
      {'module':'fee_payments','category':'conflict','outcome':'resolved','code':'RECORD_REVISION_CONFLICT'},
      {'module':'fee_payments','category':'conflict','outcome':'detected'},
    ]);
    expect(jsonEncode(safe),isNot(contains('private-id')));
    expect(jsonEncode(safe),isNot(contains('student-name')));
  });
  test('canary assignment is stable and rules remain within declared scope',()async{
    final b=body();(b['rules'] as List).single['rolloutPercent']=25;
    final p=await check(await sign(b));
    int count=0;
    for(var n=0;n<200;n++){
      final s='vs-${n.toRadixString(16).padLeft(32,'0')}';
      final a=p.value('card_probe_cooldown',module:'documents',category:'idCardInputs',school:s,now:at);
      expect(p.value('card_probe_cooldown',module:'documents',category:'idCardInputs',school:s,now:at),a);
      if(a!=null)count++;
    }
    expect(count,greaterThan(0));expect(count,lessThan(200));
  });
}
