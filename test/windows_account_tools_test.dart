import 'dart:convert';
import 'dart:io';
import 'package:saarthi_ai/windows_connect/managed_school_session.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_connect/managed_device_credentials.dart';
import 'package:saarthi_ai/windows_device_management.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('Actual Node backend lease fixture verifies cross-language signature and generation', () async {
    final fixture=jsonDecode(await File('test/fixtures/managed_device_node_lease.json').readAsString()) as Map;
    final payload=fixture['payload'] as Map;
    FlutterSecureStorage.setMockInitialValues({ManagedDeviceCredentials.key:jsonEncode({'deviceId':fixture['deviceId'],'credential':fixture['credential']})});
    final identity=await ManagedDeviceCredentials.identity(accountUid:payload['uid'],endpoint:fixture['endpoint']);
    final generation=await ManagedDeviceCredentials.generationHash(payload['schoolId'],accountUid:payload['uid'],endpoint:fixture['endpoint'],authorizedAt:fixture['authorizedAt']);
    expect(identity,payload['deviceIdentity']);
    expect(generation,payload['generationHash']);
    expect(await ManagedDeviceCredentials.verifyLease(fixture['token'],schoolId:payload['schoolId'],uid:payload['uid'],deviceIdentity:identity,generationHash:generation,now:fixture['authorizedAt']+1,publicKey:fixture['publicKey']),isTrue);
    expect(await ManagedDeviceCredentials.verifyLease(fixture['token'],schoolId:payload['schoolId'],uid:payload['uid'],deviceIdentity:identity,generationHash:generation,now:payload['expiresAt'],publicKey:fixture['publicKey']),isFalse);
  });
  test('Registration rejects HTTP-success without confirmed PC proof', () {
    expect(()=>ManagedSchoolSession.verifyDeviceRegistration({'success':true},'identity'),throwsStateError);
    expect(()=>ManagedSchoolSession.verifyDeviceRegistration({'success':true,'deviceEnforced':false},'identity'),throwsStateError);
  });
  test('School credential rotation preserves other school and install identity', () async {
    const endpoint='https://test.example/school-cloud';
    final a=await ManagedDeviceCredentials.proof(accountUid:'school-a',endpoint:endpoint);
    final b=await ManagedDeviceCredentials.proof(accountUid:'school-b',endpoint:endpoint);
    expect(a['deviceId'],b['deviceId']);
    expect(a['credential'],isNot(b['credential']));
    expect(a['credential']!.length,43);
    final saved=await const FlutterSecureStorage().read(key:ManagedDeviceCredentials.key);
    expect(saved,contains(a['credential']!));
    await ManagedDeviceCredentials.rotateRevokedCredential(accountUid:'school-a',endpoint:endpoint);
    final nextA=await ManagedDeviceCredentials.proof(accountUid:'school-a',endpoint:endpoint);
    final nextB=await ManagedDeviceCredentials.proof(accountUid:'school-b',endpoint:endpoint);
    expect(nextA['deviceId'],a['deviceId']);
    expect(nextA['credential'],isNot(a['credential']));
    expect(nextB,b);
    final alternate=await ManagedDeviceCredentials.proof(accountUid:'school-b',endpoint:'https://other.example/school-cloud');
    expect(alternate['credential'],isNot(b['credential']));
  });
  test('Device headers go only to exact HTTPS endpoint and prohibit redirects', () async {
    const endpoint='https://test.example/school-cloud';
    final observed=<http.Request>[];
    final client=ManagedDeviceClient(MockClient((r) async {observed.add(r);return http.Response('{}',200);}),endpoint,accountUid:'school-a');
    await client.post(Uri.parse(endpoint));
    await client.post(Uri.parse('https://identitytoolkit.googleapis.com/v1/login'));
    await client.post(Uri.parse('https://test.example/school-cloud/other'));
    expect(observed.first.headers['X-Vidya-Device-Credential'],isNotNull);
    expect(observed.first.followRedirects,isFalse);
    expect(observed[1].headers['X-Vidya-Device-Credential'],isNull);
    expect(observed[2].headers['X-Vidya-Device-Credential'],isNull);
    client.close();
  });
  test('Offline device lease rejects tampering, foreign identities, expiry and unpinned key', () async {
    final algorithm=Ed25519();
    final pair=await algorithm.newKeyPair();
    final public=await pair.extractPublicKey();
    final key=base64UrlEncode(public.bytes).replaceAll('=', '');
    const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final payload={'version':1,'purpose':'vidya-pc-offline','schoolId':school,'uid':'admin','deviceIdentity':'device','generationHash':'generation','issuedAt':1000,'expiresAt':901000};
    Future<String> sign(Map<String,dynamic> body) async {
      final bytes=utf8.encode(jsonEncode(body));
      final signature=await algorithm.sign(utf8.encode(base64UrlEncode(bytes).replaceAll('=', '')),keyPair:pair);
      return '${base64UrlEncode(bytes).replaceAll('=', '')}.${base64UrlEncode(signature.bytes).replaceAll('=', '')}';
    }
    final token=await sign(payload);
    Future<bool> verify(String value,{String tenant=school,String generation='generation',int at=2000,String? pin}) => ManagedDeviceCredentials.verifyLease(value,schoolId:tenant,uid:'admin',deviceIdentity:'device',generationHash:generation,now:at,publicKey:pin??key);
    expect(await verify(token),isTrue);
    expect(await verify(token,tenant:'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),isFalse);
    expect(await verify(token,generation:'old-generation'),isFalse);
    expect(await verify(token,at:901000),isFalse);
    expect(await verify(token,at:999),isFalse);
    expect(await verify(token,pin:''),isFalse);
    expect(await verify(await sign({...payload,'expiresAt':901001})),isFalse);
    expect(await verify(await sign({...payload,'purpose':'another-purpose'})),isFalse);
    final parts=token.split('.');
    final tampered=base64UrlEncode(utf8.encode(jsonEncode({...payload,'uid':'attacker'}))).replaceAll('=', '');
    expect(await verify('$tampered.${parts[1]}'),isFalse);
  });
  test('A recent heartbeat does not claim the device is online', () {
    expect(deviceActivityLabel('recently_seen'), contains('not confirmed'));
    expect(deviceActivityLabel('unknown'), 'Activity unknown');
    expect(deviceActivityLabel('offline'), 'Activity unknown');
    expect(deviceActivityLabel(null), 'Activity unknown');
    expect(deviceActivityLabel('revoked'), 'Revoked');
  });
  test('Missing authorization and heartbeat times remain Unknown', () {
    expect(deviceTimeLabel(null), 'Unknown');
    expect(deviceTimeLabel(0), 'Unknown');
    expect(deviceTimeLabel(-1), 'Unknown');
    expect(deviceTimeLabel('2026-10-11'), 'Unknown');
    expect(deviceTimeLabel(1791690000000), isNot('Unknown'));
  });
}
