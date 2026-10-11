import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saarthi_ai/mobile/school_session.dart';
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
  final parts=token.split('.');final tampered='${parts[0]}.${parts[1][0]=='A'?'B':'A'}${parts[1].substring(1)}';
  expect(await check(tampered),isNull);
  expect(await QrCardAuthorization.verifyOffline(token,link,deviceId:'device',sessionToken:'session',now:1500,publicKey:''),isNull);
 });
 test('issued login proof failure rolls back and enforced sessions reject downgrade/missing freshness',() async {
  TestWidgetsFlutterBinding.ensureInitialized();FlutterSecureStorage.setMockInitialValues({});
  final algorithm=Ed25519(),pair=await Ed25519().newKeyPairFromSeed(List<int>.filled(32,2));
  final public=base64Url.encode((await pair.extractPublicKey()).bytes).replaceAll('=','');
  final link=SchoolLink.parse(SchoolLink.encodeIssued(fields));var mode='valid';var failPersist=false;
  final session=SchoolSession(cardPublicKey:public,persistSession:(value)async{if(failPersist)throw StateError('Synthetic persistence failure');await const FlutterSecureStorage().write(key:'vs_mobile_session',value:value);},client:MockClient((request) async {
   final r=(jsonDecode(request.body) as Map)['request'] as Map,at=DateTime.now().millisecondsSinceEpoch;
   String digest(String value)=>sha256.convert(utf8.encode(value)).toString();
   final claims={'version':1,'schoolId':link.schoolId,'role':link.role,'personId':link.personId,'cardIssueId':link.cardIssueId,
    'issuedAt':at-1000,'deviceHash':digest(r['deviceId'] as String),'sessionHash':digest('t'*64),'qrHash':digest('${link.role}/${link.personId}/${link.linkToken}')};
   Future<String> proof(String purpose,int expires) async {final payload=base64Url.encode(utf8.encode(jsonEncode({...claims,'purpose':purpose,'expiresAt':expires}))).replaceAll('=','');final sig=await algorithm.sign(utf8.encode(payload),keyPair:pair);return '$payload.${base64Url.encode(sig.bytes).replaceAll('=','')}';}
   final data=<String,dynamic>{'success':true,'schoolId':link.schoolId,'projectId':link.schoolId,'role':link.role,'personId':link.personId,'person':<String,dynamic>{},'sessionToken':'t'*64,'expiresAt':at+3600000};
   if(mode!='downgrade') data.addAll({'cardReaderEnforced':true,'cardIssueId':link.cardIssueId});
   if(mode!='missing') data.addAll({'cardAuthorizationToken':await proof('card-online-session',at+3600000),'cardOfflineLease':mode=='invalid'?'invalid':await proof('card-offline',at+899000)});
   return http.Response(jsonEncode(data),200);
  }));
  mode='invalid';await expectLater(session.login(link),throwsStateError);expect(session.loggedIn,false);expect(await const FlutterSecureStorage().read(key:'vs_mobile_session'),isNull);
  mode='valid';await session.login(link);expect(session.cachedAccessAllowed,true);
  mode='downgrade';await expectLater(session.schoolCall('mobile_refresh',{}),throwsStateError);
  mode='missing';await expectLater(session.schoolCall('mobile_refresh',{}),throwsStateError);
  await session.clear();mode='valid';failPersist=true;await expectLater(session.login(link),throwsStateError);expect(session.loggedIn,false);expect(await const FlutterSecureStorage().read(key:'vs_mobile_session'),isNull);
 });

}
