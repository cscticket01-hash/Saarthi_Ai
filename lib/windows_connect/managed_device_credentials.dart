import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../windows_secure_storage.dart';

class ManagedDeviceCredentials {
  static const key = 'vidya_saarthi_pc_device_v1';
  static const leasePublicKey = String.fromEnvironment('SAARTHI_DEVICE_LEASE_PUBLIC_KEY');
  static Future<Map<String,String>> proof({String? accountUid, String endpoint=const String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL')}) => WindowsSecureStorage.run(() async {
    const storage = FlutterSecureStorage();
    final raw = await storage.read(key: key);
    final uid=accountUid;
    if(uid==null || !RegExp(r'^[A-Za-z0-9:_-]{1,200}$').hasMatch(uid)) throw StateError('Verified school account UID required for PC credential.');
    final uri=Uri.tryParse(endpoint);
    if(uri==null || uri.scheme!='https' || uri.host.isEmpty) throw StateError('Secure PC endpoint required.');
    final scope=sha256.convert(utf8.encode('$endpoint\n$uid')).toString();
    var changed=raw==null;
    Map<String,dynamic> value;
    if(raw!=null) {
      final decoded=jsonDecode(raw);
      if(decoded is! Map || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(decoded['deviceId']?.toString() ?? '')) throw StateError('PC credential storage is invalid. Existing data is retained.');
      value=Map<String,dynamic>.from(decoded);
    } else {
      final random=Random.secure();
      value={'deviceId':base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256))).replaceAll('=', '')};
    }
    if(value.containsKey('accounts') && value['accounts'] is! Map) throw StateError('School PC credential map is invalid. Existing data is retained.');
    final credentials=value['accounts'] is Map ? Map<String,dynamic>.from(value['accounts'] as Map) : <String,dynamic>{};
    // Upgrade the original single-account proof once, retaining its server proof.
    if(credentials.isEmpty && value['credential'] is String) { credentials[scope]=value['credential']; changed=true; }
    if(!credentials.containsKey(scope)) {
      changed=true;
      final random=Random.secure();
      credentials[scope]=base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
    }
    final credential=credentials[scope];
    if(credential is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(credential)) throw StateError('School PC credential is invalid.');
    value.remove('credential');
    value['accounts']=credentials;
    if(changed) await storage.write(key:key,value:jsonEncode(value));
    return {'deviceId':value['deviceId'] as String,'credential':credential};
  });
  static Future<void> rotateRevokedCredential({required String accountUid, required String endpoint}) => WindowsSecureStorage.run(() async {
    const storage=FlutterSecureStorage();
    final raw=await storage.read(key:key);
    if(raw==null) throw StateError('PC identity missing.');
    final value=jsonDecode(raw) as Map;
    final random=Random.secure();
    final accounts=Map<String,dynamic>.from(value['accounts'] as Map);
    final scope=sha256.convert(utf8.encode('$endpoint\n$accountUid')).toString();
    if(!accounts.containsKey(scope)) throw StateError('School PC credential missing.');
    accounts[scope]=base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
    value['accounts']=accounts;
    await storage.write(key:key,value:jsonEncode(value));
  });
  static Future<Map<String,String>> headers({required String accountUid, required String endpoint}) async {
    final value=await proof(accountUid:accountUid,endpoint:endpoint);
    return {'X-Vidya-Device-Id':value['deviceId']!, 'X-Vidya-Device-Credential':value['credential']!};
  }
  static Future<String> identity({required String accountUid, String endpoint=const String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL')}) async => sha256.convert(utf8.encode((await proof(accountUid:accountUid,endpoint:endpoint))['deviceId']!)).toString();
  static Future<String> generationHash(String schoolId, {required String accountUid, required int authorizedAt, String endpoint=const String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL')}) async {
    final credentialHash=sha256.convert(utf8.encode('$schoolId\n${(await proof(accountUid:accountUid,endpoint:endpoint))['credential']}')).toString();
    return sha256.convert(utf8.encode('$credentialHash\n$authorizedAt')).toString();
  }

  /// An opaque token or a key returned beside it never grants offline access.
  static Future<bool> verifyLease(String token, {required String schoolId, required String uid,
      required String deviceIdentity, required String generationHash, required int now,
      String publicKey=leasePublicKey}) async {
    try {
      if(token.length>4096 || publicKey.isEmpty || now<0 || now>9007199254740991) return false;
      final parts=token.split('.');
      if(parts.length!=2 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(parts[0]) || !RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(parts[1])) return false;
      final payloadBytes=base64Url.decode(base64Url.normalize(parts[0]));
      final signatureBytes=base64Url.decode(base64Url.normalize(parts[1]));
      final keyBytes=base64Url.decode(base64Url.normalize(publicKey));
      if(keyBytes.length!=32 || signatureBytes.length!=64) return false;
      final verified=await Ed25519().verify(utf8.encode(parts[0]),signature:Signature(signatureBytes,publicKey:SimplePublicKey(keyBytes,type:KeyPairType.ed25519)));
      if(!verified) return false;
      final payload=jsonDecode(utf8.decode(payloadBytes));
      if(payload is! Map || payload['version']!=1 || payload['purpose']!='vidya-pc-offline' || payload['schoolId']!=schoolId ||
          payload['uid']!=uid || payload['deviceIdentity']!=deviceIdentity || payload['generationHash']!=generationHash) return false;
      final issued=payload['issuedAt'], expiry=payload['expiresAt'];
      return issued is int && expiry is int && issued<=9007199254740991 && expiry<=9007199254740991 && issued>=0 && issued<=now && expiry>now && expiry>issued && expiry-issued<=900000;
    } catch(_) { return false; }
  }
}

/// Only the exact central HTTPS endpoint receives PC credentials; Google and
/// redirect destinations never receive them. Callers retain their normal client.
class ManagedDeviceClient extends http.BaseClient {
  ManagedDeviceClient(this.inner, this.endpoint, {this.accountUid});
  final http.Client inner;
  final String endpoint;
  final String? accountUid;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if(request.url.toString()==endpoint && request.url.scheme=='https') {
      request.followRedirects=false;
      final uid=accountUid;
      if(uid==null) throw StateError('Verified school account required for PC request.');
      request.headers.addAll(await ManagedDeviceCredentials.headers(accountUid:uid,endpoint:endpoint));
    }
    return inner.send(request);
  }
  @override
  void close() => inner.close();
}
