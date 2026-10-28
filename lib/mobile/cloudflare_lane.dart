import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// A short-lived school/person capability issued by the existing broker.
/// No Firebase tokens, service-account keys or Cloudflare API tokens enter apps.
class CloudflareLane {
  const CloudflareLane._(this.endpoint, this.grant, this.schoolId, this.sessionHash, this.expiresAt);
  final Uri endpoint;
  final String grant, schoolId, sessionHash;
  final int expiresAt;
  static CloudflareLane? parse(Map<String, dynamic> value, String school, String session) {
    try {
      final endpoint = Uri.parse(value['endpoint'] as String);
      if (endpoint.scheme != 'https' || endpoint.host != 'vidya-saarthi-sync.vidya-saarthi-cscticket01.workers.dev' ||
          endpoint.path != '/mobile' || endpoint.hasQuery || endpoint.hasFragment || endpoint.userInfo.isNotEmpty || endpoint.hasPort && endpoint.port != 443 ||
          value['schoolId'] != school || value['grant'] is! String || (value['grant'] as String).length > 12000 || value['expiresAt'] is! int) return null;
      final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize((value['grant'] as String).split('.').first)))) as Map;
      final sessionHash = sha256.convert(utf8.encode(session)).toString();
      if (claims['schoolId'] != school || claims['sessionHash'] != sessionHash || claims['expiresAt'] != value['expiresAt']) return null;
      return CloudflareLane._(endpoint, value['grant'] as String, school, sessionHash, value['expiresAt'] as int);
    } catch (_) { return null; }
  }
  Map<String, dynamic> toJson() => {'endpoint': endpoint.toString(), 'grant': grant, 'schoolId': schoolId, 'expiresAt': expiresAt};
  bool validFor(String school, String session) => schoolId == school &&
      sessionHash == sha256.convert(utf8.encode(session)).toString() && expiresAt > DateTime.now().millisecondsSinceEpoch;
  Future<http.Response> send(http.Client client, String action, Map<String, dynamic> request) => client.post(endpoint,
    headers: {'Content-Type': 'application/json'}, body: jsonEncode({'schoolId': schoolId, 'grant': grant, 'request': {...request, 'action': action}}))
      .timeout(const Duration(seconds: 20));
}
