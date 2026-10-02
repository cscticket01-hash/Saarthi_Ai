import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'platform_config.dart';

/// Independently verifies the developer-controlled status. A school owns its
/// script, so a script's claimed expiry is never sufficient for Windows access.
class SparkLicenseClient {
  SparkLicenseClient({http.Client? client}) : _client=client ?? http.Client();
  final http.Client _client;
  Future<Map<String,dynamic>> schoolStatus(String project, {String? licenseHash}) async {
    if(!RegExp(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$').hasMatch(project)) throw ArgumentError('Invalid school project');
    final licensed=licenseHash!=null && licenseHash.isNotEmpty;
    if(licensed && !RegExp(r'^[a-f0-9]{64}$').hasMatch(licenseHash)) throw StateError('Invalid licence verification');
    final path=licensed?'platform_license_status/$licenseHash':'platform_school_trials/$project';
    final r=await _client.get(Uri.parse('$platformFirestoreUrl/$path')).timeout(const Duration(seconds:15));
    if(r.statusCode!=200) throw StateError('Developer licence verification unavailable');
    final date=r.headers['date'];
    if(date==null) throw StateError('Licence server time unavailable');
    final now=HttpDate.parse(date).millisecondsSinceEpoch;
    final fields=jsonDecode(r.body)['fields'];
    if(licensed && fields['schoolId']?['stringValue']!=project) throw StateError('Licence belongs to a different school');
    final end=DateTime.parse(licensed?fields['expiresAt']['timestampValue']:fields['createdAt']['timestampValue'])
        .millisecondsSinceEpoch+(licensed?0:5*86400000);
    final revoked=licensed && fields['revoked']?['booleanValue']==true;
    final status=revoked?'blocked':end<=now?'expired':licensed?'licensed':'trial';
    return {'schoolId':project,'serverTime':now,'expiresAt':end,'allowed':!revoked&&end>now,'status':status};
  }
  void close()=>_client.close();
}

/// Immutable server trial. School records and administrator tokens stay local.
class SparkTrialClient {
  static Future<DateTime> deviceTrial(String fingerprint) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      throw ArgumentError('Invalid installation fingerprint');
    }
    final path = 'platform_device_trials/$fingerprint';
    var r = await http.get(Uri.parse('$platformFirestoreUrl/$path'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 404) {
      final auth = await http.post(
        Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$platformApiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'returnSecureToken': true}),
      ).timeout(const Duration(seconds: 15));
      final token = jsonDecode(auth.body)['idToken'];
      if (auth.statusCode != 200 || token == null) {
        throw StateError('Enable Anonymous authentication in the developer Firebase for online trial verification.');
      }
      final name = 'projects/$platformProjectId/databases/(default)/documents/$path';
      final commit = await http.post(Uri.parse('$platformFirestoreUrl:commit'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode({'writes': [{
          'update': {'name': name, 'fields': {}},
          'currentDocument': {'exists': false},
          'updateTransforms': [{'fieldPath': 'createdAt', 'setToServerValue': 'REQUEST_TIME'}],
        },{
          'update': {'name':'projects/$platformProjectId/databases/(default)/documents/platform_trial_claims/${jsonDecode(auth.body)['localId']}',
            'fields':{'target':{'stringValue':path}}},
          'currentDocument':{'exists':false},
          'updateTransforms':[{'fieldPath':'createdAt','setToServerValue':'REQUEST_TIME'}],
        }]}),
      ).timeout(const Duration(seconds: 15));
      if (commit.statusCode != 200 && commit.statusCode != 409) {
        throw StateError('Online trial verification unavailable');
      }
      r = await http.get(Uri.parse('$platformFirestoreUrl/$path'))
          .timeout(const Duration(seconds: 15));
      try {
        await http.post(Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:delete?key=$platformApiKey'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'idToken': token}))
            .timeout(const Duration(seconds: 10));
      } catch (_) {}
    }
    if (r.statusCode != 200) throw StateError('Online trial verification unavailable');
    return DateTime.parse(jsonDecode(r.body)['fields']['createdAt']['timestampValue']).toUtc();
  }
}
