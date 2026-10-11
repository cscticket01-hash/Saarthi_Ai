import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'school_qr_link.dart';

/// Offline card approval is bounded evidence, not a promise of live revocation.
/// Public key comes from reviewed app configuration, never from QR/server JSON.
class QrCardAuthorization {
  static const configuredPublicKey = String.fromEnvironment('SAARTHI_QR_ED25519_PUBLIC_KEY');
  static Future<int?> verifyOffline(String? lease,SchoolLink link,{required String deviceId,required String sessionToken,required int now,String publicKey=configuredPublicKey}) =>
      _verify(lease,link,deviceId:deviceId,sessionToken:sessionToken,now:now,publicKey:publicKey,purpose:'card-offline',maximumDuration:900000);
  static Future<int?> verifyOnline(String? receipt,SchoolLink link,{required String deviceId,required String sessionToken,required int now,String publicKey=configuredPublicKey}) =>
      _verify(receipt,link,deviceId:deviceId,sessionToken:sessionToken,now:now,publicKey:publicKey,purpose:'card-online-session',maximumDuration:30*86400000);
  static Future<int?> _verify(String? lease, SchoolLink link, {
    required String purpose, required int maximumDuration,
    required String deviceId, required String sessionToken, required int now,
    String publicKey = configuredPublicKey,
  }) async {
    if(lease == null || lease.length > 5000 || publicKey.isEmpty) return null;
    try {
      final parts = lease.split('.');
      if(parts.length != 2 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(parts[0]) || !RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(parts[1])) return null;
      final key = base64Url.decode(base64Url.normalize(publicKey));
      if(key.length != 32) return null;
      final signature = Signature(base64Url.decode(base64Url.normalize(parts[1])), publicKey:SimplePublicKey(key,type:KeyPairType.ed25519));
      if(!await Ed25519().verify(utf8.encode(parts[0]), signature:signature)) return null;
      final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))));
      if(claims is! Map) return null;
      final issued = claims['issuedAt'], expires = claims['expiresAt'];
      String fingerprint(String value) => sha256.convert(utf8.encode(value)).toString();
      if(claims['version'] != 1 || claims['purpose'] != purpose || claims['schoolId'] != link.schoolId ||
          claims['role'] != link.role || claims['personId'] != link.personId ||
          claims['cardIssueId'] != (link.cardIssueId.isEmpty ? null : link.cardIssueId) ||
          claims['deviceHash'] != fingerprint(deviceId) || claims['sessionHash'] != fingerprint(sessionToken) ||
          claims['qrHash'] != fingerprint('${link.role}/${link.personId}/${link.linkToken}') ||
          issued is! int || expires is! int || now < issued || now >= expires || expires <= issued || expires-issued > maximumDuration) return null;
      return expires;
    } catch (_) { return null; }
  }
}
