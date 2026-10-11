import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/school_qr_link.dart';
import 'package:saarthi_ai/qr_card_authorization.dart';
import 'package:saarthi_ai/qr_authentication_engine.dart';

void main(){
 final fields=<String,dynamic>{'managed':true,'schoolId':'vs-${'a'*32}',
   'centralEndpoint':'https://saarthi-oauth-staging.onrender.com/school-cloud','type':'student',
   'personId':'synthetic-person','linkToken':'s'*43,'cardIssueId':'b'*64};
 test('issued envelope preserves exact issue while legacy v2/VS3 remain unchanged',(){
  final issued=SchoolLink.parse(SchoolLink.encodeIssued(fields));
  expect(SchoolLink.detectVersion(issued.rawQr),4);expect(issued.cardIssueId,fields['cardIssueId']);
  expect(SchoolLink.encodeCompact(fields),issued.rawQr);
  final legacy=Map<String,dynamic>.from(fields)..remove('cardIssueId');
  expect(SchoolLink.detectVersion(SchoolLink.encodeCompact(legacy)),3);
  expect(SchoolLink.parse(SchoolLink.encode(legacy)).cardIssueId,isEmpty);
  expect(()=>SchoolLink.parse('${issued.rawQr.substring(0,issued.rawQr.length-64)}invalid'),throwsFormatException);
 });
 test('issued QR requires exact server issue verification instead of legacy login success',(){
  final link=SchoolLink.parse(SchoolLink.encodeIssued(fields));
  final response=<String,dynamic>{'expiresAt':2000,'sessionToken':'t'*64,'person':<String,dynamic>{},'projectId':link.schoolId,'schoolId':link.schoolId};
  expect(()=>QrAuthenticationEngine.validateSession(link,response,now:1000),throwsStateError);
  expect(()=>QrAuthenticationEngine.validateSession(link,{...response,'cardReaderEnforced':true,'cardIssueId':link.cardIssueId,'cardAuthorizationToken':'receipt','cardOfflineLease':'lease'},now:1000),returnsNormally);
 });
 test('offline lease verifies pinned signature, issue/session/device binding and exact expiry',() async {
  final link=SchoolLink.parse(SchoolLink.encodeIssued(fields)),algorithm=Ed25519();
  final pair=await algorithm.newKeyPairFromSeed(List<int>.filled(32,1));
  final public=base64Url.encode((await pair.extractPublicKey()).bytes).replaceAll('=','');
  String fingerprint(String input)=>sha256.convert(utf8.encode(input)).toString();
  final claims=<String,dynamic>{'version':1,'purpose':'card-offline','schoolId':link.schoolId,'role':link.role,'personId':link.personId,
   'cardIssueId':link.cardIssueId,'issuedAt':1000,'expiresAt':2000,'deviceHash':fingerprint('device'),
   'sessionHash':fingerprint('session'),'qrHash':fingerprint('${link.role}/${link.personId}/${link.linkToken}')};
  Future<String> signed(Map<String,dynamic> value) async {final payload=base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=','');final sig=await algorithm.sign(utf8.encode(payload),keyPair:pair);return '$payload.${base64Url.encode(sig.bytes).replaceAll('=','')}';}
  final token=await signed(claims);
  Future<int?> check(String lease,{int now=1500,String device='device',String session='session',String key=''})=>QrCardAuthorization.verifyOffline(lease,link,deviceId:device,sessionToken:session,now:now,publicKey:key.isEmpty?public:key);
  expect(await check(token),2000);expect(await check(token,now:2000),isNull);
  expect(await check(token,device:'another'),isNull);expect(await check(token,session:'another'),isNull);
  expect(await check(await signed({...claims,'cardIssueId':'c'*64})),isNull);
  expect(await check(await signed({...claims,'expiresAt':902000})),isNull);
  expect(await check('${token.substring(0,token.length-3)}AAA'),isNull);
  expect(await QrCardAuthorization.verifyOffline(token,link,deviceId:'device',sessionToken:'session',now:1500,publicKey:''),isNull);
 });
}
