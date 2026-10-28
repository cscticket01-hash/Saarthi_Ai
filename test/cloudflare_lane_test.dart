import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/mobile/cloudflare_lane.dart';
void main() {
 const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 Map<String, dynamic> grant({String endpoint = 'https://vidya-saarthi-sync.vidya-saarthi-cscticket01.workers.dev/mobile', String session = 'session', String tenant = school, int? expires}) {
  final until = expires ?? DateTime.now().millisecondsSinceEpoch + 60000;
  final value = base64Url.encode(utf8.encode(jsonEncode({'schoolId': tenant, 'sessionHash': sha256.convert(utf8.encode(session)).toString(), 'expiresAt': until}))).replaceAll('=', '');
  return {'endpoint': endpoint, 'schoolId': tenant, 'expiresAt': until, 'grant': '$value.signature-verified-by-worker'};
 }
 test('only the configured Cloudflare endpoint and same school/session can use the lane', () {
  final lane = CloudflareLane.parse(grant(), school, 'session');
  expect(lane, isNotNull);expect(lane!.validFor(school, 'session'), isTrue);
  expect(lane.validFor(school, 'other-session'), isFalse);
  expect(CloudflareLane.parse(grant(tenant: 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'), school, 'session'), isNull);
  for (final endpoint in ['https://attacker.invalid/mobile', 'http://vidya-saarthi-sync.vidya-saarthi-cscticket01.workers.dev/mobile', 'https://vidya-saarthi-sync.vidya-saarthi-cscticket01.workers.dev/mobile?token=1']) {
    expect(CloudflareLane.parse(grant(endpoint: endpoint), school, 'session'), isNull);
  }
 });
 test('expired grants cannot bypass broker renewal and cached grants retain identity checks', () {
  final data = grant(expires: DateTime.now().millisecondsSinceEpoch - 1);
  expect(CloudflareLane.parse(data, school, 'session')!.validFor(school, 'session'), isFalse);
  final lane = CloudflareLane.parse(grant(), school, 'session')!;
  expect(CloudflareLane.parse(lane.toJson(), school, 'session')!.validFor(school, 'session'), isTrue);
 });
}
