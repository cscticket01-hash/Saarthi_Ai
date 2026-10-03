import '../windows_local_firestore.dart' show Timestamp;
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../platform/platform_config.dart';
import 'google_authorization.dart';

Object? migrationJsonValue(Object? value) {
  if (value is Timestamp) return {'__vsTimestamp':value.toDate().toUtc().toIso8601String()};
  if (value is DateTime) return {'__vsTimestamp':value.toUtc().toIso8601String()};
  if (value is Map) return value.map((k,v)=>MapEntry(k.toString(),migrationJsonValue(v)));
  if (value is List) return value.map(migrationJsonValue).toList();
  return value;
}
bool validSchoolId(String id) => RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(id);
String tenantCollectionPath(String schoolId, String collection) {
  if (!validSchoolId(schoolId) || !RegExp(r'^[a-z][a-z0-9_]{0,79}$').hasMatch(collection)) {
    throw StateError('Invalid school data path.');
  }
  return 'schools/$schoolId/$collection';
}
Map<String, dynamic> centralSchoolData(Map<String, dynamic> data, String schoolId) {
  if (!validSchoolId(schoolId)) throw StateError('Invalid school identity.');
  final result = Map<String, dynamic>.from(data);
  result.removeWhere((key, _) => key.toLowerCase().contains('password') ||
    key.toLowerCase().contains('token') || key.endsWith('Base64') ||
    {'private_key', 'client_secret', 'localPath'}.contains(key));
  result['schoolId'] = schoolId;
  return result;
}

/// New central connection is stored separately from legacy links/authentication.
/// Disconnecting it restores the existing installation without deleting data.
class CentralSchoolCloud {
  CentralSchoolCloud({http.Client? client, this.endpoint = apiUrl,
    this.storage = const FlutterSecureStorage()}) : client = client ?? http.Client();
  static const apiUrl = String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL');
  static const key = 'vidya_saarthi_central_school_v2';
  static Future<void> _pendingSessionWrite = Future<void>.value();
  static Future<void> updateSession(String schoolId, Map<String,dynamic> updates) {
    final next = _pendingSessionWrite.catchError((_) {}).then((_) async {
      final current = await saved();
      if (current['schoolId'] != schoolId) throw StateError('School connection changed.');
      current.addAll(updates);
      await const FlutterSecureStorage().write(key:key,value:jsonEncode(current));
    });
    _pendingSessionWrite = next;
    return next;
  }
  final String endpoint;
  final FlutterSecureStorage storage;
  final http.Client client;
  bool cancelled = false;
  static bool validEndpoint(String value) {
    final u = Uri.tryParse(value);
    return u != null && u.scheme == 'https' && u.host.isNotEmpty &&
      u.userInfo.isEmpty && !u.hasQuery && !u.hasFragment && (!u.hasPort || u.port == 443);
  }
  static bool get configured => validEndpoint(apiUrl);
  static Future<Map<String, dynamic>> saved() async {
    final raw = await const FlutterSecureStorage().read(key: key);
    if (raw == null) return {};
    final value = jsonDecode(raw);
    if (value is! Map || value['projectId'] != platformProjectId ||
        !validSchoolId(value['schoolId']?.toString() ?? '') || value['firebaseRefreshToken'] is! String ||
        !validEndpoint(value['endpoint']?.toString() ?? '') ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,200}$').hasMatch(value['folderId']?.toString() ?? '')) {
      throw StateError('Saved school cloud identity is invalid. Existing data was retained.');
    }
    return Map<String, dynamic>.from(value);
  }
  void check() { if (cancelled) throw SetupCancelled(); }
  Future<Map<String, dynamic>> send(String method, Uri uri, {String? token, Object? body, String? contentType}) async {
    check();
    final r = http.Request(method, uri)..followRedirects = false;
    if (token != null) r.headers['Authorization'] = 'Bearer $token';
    if (body != null) { r.headers['Content-Type'] = contentType ?? 'application/json'; r.body = body is String ? body : jsonEncode(body); }
    final response = await http.Response.fromStream(await client.send(r).timeout(const Duration(seconds:45)));
    check();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(response.statusCode == 401 ? 'Permission expired. Reconnect the same school Google account.'
        : 'School cloud request failed (HTTP ${response.statusCode}). Retry the same school; existing data is retained.');
    }
    if (response.body.isEmpty) return {};
    final value = jsonDecode(response.body);
    if (value is! Map) throw StateError('Invalid school cloud response.');
    return Map<String, dynamic>.from(value);
  }
  Future<Map<String, dynamic>> api(Map<String, dynamic> body, {String? token}) async {
    if (!validEndpoint(endpoint)) throw StateError('Developer must configure the central school cloud service. Schools do not need Firebase configuration.');
    return send('POST', Uri.parse(endpoint), token:token, body:body);
  }
  Future<Map<String, dynamic>> connect(GoogleSetupAccount account, String name, {Map<String,dynamic>? migration}) async {
    final old = await saved();
    final result = await api({'action':'onboard', 'schoolName':name,
      'googleAccessToken':account.accessToken, if (old.isNotEmpty) 'expectedSchoolId':old['schoolId']});
    final school = result['schoolId']?.toString() ?? '';
    if (!validSchoolId(school) || result['projectId'] != platformProjectId ||
        result['email'] != account.email || result['customToken'] is! String ||
        (old.isNotEmpty && old['schoolId'] != school)) throw StateError('School cloud identity verification failed.');
    final auth = await send('POST', Uri.https('identitytoolkit.googleapis.com', '/v1/accounts:signInWithCustomToken', {'key':platformApiKey}),
      body:{'token':result['customToken'], 'returnSecureToken':true});
    if (auth['idToken'] is! String || auth['refreshToken'] is! String || auth['localId'] is! String) throw StateError('School Firebase login failed.');
    await api({'action':'status', 'schoolId':school}, token:auth['idToken']);
    // Also verify deployed security rules allow this tenant before saving.
    await send('GET', Uri.parse('$platformFirestoreUrl/schools/$school/school_config?pageSize=1'), token:auth['idToken']);
    if (migration != null) {
      final records = migration['records'] as List;
      // Small independently retryable create-only batches. Never overwrite target
      // records or remove source records/files/credentials.
      for (var i=0; i<records.length; i+=10) {
        await api({'action':'migration/import','schoolId':school,
          'sourceProjectId':migration['projectId'],'sourceAdminToken':migration['token'],
          'records':migrationJsonValue(records.sublist(i,(i+10).clamp(0,records.length)))},token:auth['idToken']);
      }
    }
    final folder = await ensureFolder(account.accessToken, school, old['folderId']?.toString());
    await api({'action':'drive/link', 'schoolId':school, 'folderId':folder,
      'googleAccessToken':account.accessToken}, token:auth['idToken']);
    final connection = <String,dynamic>{'schemaVersion':2, 'projectId':platformProjectId,
      'schoolId':school, 'schoolName':name, 'uid':auth['localId'], 'email':account.email,
      'accountSub':account.subject, 'endpoint':endpoint, 'folderId':folder,
      'firebaseRefreshToken':auth['refreshToken'],
      'googleRefreshToken':account.refreshToken.isNotEmpty ? account.refreshToken : old['googleRefreshToken'] ?? '',
      'googleAccessToken':account.accessToken,
      'googleExpiresAt':DateTime.now().millisecondsSinceEpoch + account.expiresIn * 1000};
    // One encrypted write, only after Firebase rules and school-owned Drive verify.
    check(); await storage.write(key:key, value:jsonEncode(connection));
    return connection;
  }
  Future<String> ensureFolder(String token, String school, String? previous) async {
    if (previous != null && previous.isNotEmpty) {
      final folder = await send('GET', Uri.https('www.googleapis.com','/drive/v3/files/$previous',
        {'fields':'id,trashed,appProperties,mimeType'}), token:token);
      if (folder['trashed'] == true || folder['appProperties']?['schoolId'] != school ||
          folder['mimeType'] != 'application/vnd.google-apps.folder') throw StateError('Saved school Drive folder is unavailable. No replacement was created.');
      return previous;
    }
    // Recover an interrupted setup by the server-assigned school marker, not name.
    final matches = <Map>[];
    String? page;
    do {
      final list = await send('GET', Uri.https('www.googleapis.com','/drive/v3/files', {
        'q':"trashed = false and mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='schoolId' and value='$school' }",
        'fields':'files(id),nextPageToken', if (page != null) 'pageToken':page}), token:token);
      matches.addAll((list['files'] as List? ?? []).whereType<Map>());
      final next = list['nextPageToken']?.toString();
      if (next != null && next == page) throw StateError('Repeated Drive page. Setup stopped safely.');
      page = next;
    } while (page != null && page.isNotEmpty);
    if (matches.length > 1) throw StateError('Multiple school Drive folders found. Automatic replacement is blocked.');
    if (matches.isNotEmpty) return matches.single['id'].toString();
    final folder = await send('POST', Uri.https('www.googleapis.com','/drive/v3/files', {'fields':'id'}), token:token,
      body:{'name':'Vidya Saarthi School', 'mimeType':'application/vnd.google-apps.folder', 'appProperties':{'schoolId':school}});
    final id = folder['id']?.toString() ?? '';
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,200}$').hasMatch(id)) throw StateError('Drive folder creation did not return an identifier.');
    return id;
  }
  static Future<String> firebaseToken() async {
    final data = await saved();
    if (data.isEmpty) throw StateError('School cloud is not connected.');
    final cloud = CentralSchoolCloud(endpoint:data['endpoint']);
    try {
      final response = await cloud.send('POST', Uri.https('securetoken.googleapis.com','/v1/token',{'key':platformApiKey}),
        body:'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(data['firebaseRefreshToken'])}', contentType:'application/x-www-form-urlencoded');
      if (response['user_id'] != data['uid'] || response['id_token'] is! String) throw StateError('Firebase school identity changed.');
      await cloud.api({'action':'status', 'schoolId':data['schoolId']}, token:response['id_token']);
      await updateSession(data['schoolId'],{'firebaseRefreshToken':response['refresh_token'] ?? data['firebaseRefreshToken']});
      return response['id_token'];
    } finally { cloud.close(); }
  }
  Future<String> googleToken(Map<String,dynamic> data) async {
    if ((data['googleExpiresAt'] as num? ?? 0) > DateTime.now().millisecondsSinceEpoch + 60000) return data['googleAccessToken'];
    if ((data['googleRefreshToken']?.toString() ?? '').isEmpty || !GoogleAuthorization.validBrokerUrl(GoogleAuthorization.brokerUrl)) throw StateError('Google permission expired. Reconnect the same school account.');
    final refreshed = await send('POST',Uri.parse(GoogleAuthorization.brokerUrl).replace(path:'/oauth/refresh'), body:{'refresh_token':data['googleRefreshToken']});
    if (refreshed['access_token'] is! String || refreshed['expires_in'] is! num) throw StateError('Google session refresh failed.');
    data['googleAccessToken'] = refreshed['access_token'];
    data['googleExpiresAt'] = DateTime.now().millisecondsSinceEpoch + (refreshed['expires_in'] as num).toInt()*1000;
    // Merge only Google session fields so a concurrent Firebase refresh is retained.
    final latest = await saved();
    if (latest['schoolId'] != data['schoolId']) throw StateError('School connection changed. Retry.');
    await updateSession(data['schoolId'],{'googleAccessToken':data['googleAccessToken'],'googleExpiresAt':data['googleExpiresAt']});
    return data['googleAccessToken'];
  }
  Future<Map<String,dynamic>> upload(String name, String mime, String raw) async {
    final data = await saved();
    if (data.isEmpty) throw StateError('School Drive is not connected.');
    final token = await googleToken(data);
    final bytes = base64Decode(raw.contains(',') ? raw.split(',').last : raw);
    if (bytes.isEmpty || bytes.length > 20*1024*1024) throw StateError('School file must be between 1 byte and 20 MB.');
    final boundary = 'vs_${secureSetupToken(18)}';
    final metadata = jsonEncode({'name':name, 'parents':[data['folderId']], 'appProperties':{'schoolId':data['schoolId']}});
    final request = http.Request('POST',Uri.https('www.googleapis.com','/upload/drive/v3/files',{'uploadType':'multipart','fields':'id,webViewLink'}))
      ..followRedirects=false
      ..headers.addAll({'Authorization':'Bearer $token','Content-Type':'multipart/related; boundary=$boundary'})
      ..bodyBytes=[...utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n--$boundary\r\nContent-Type: ${RegExp(r"^[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+$").hasMatch(mime) ? mime : 'application/octet-stream'}\r\n\r\n'),...bytes,...utf8.encode('\r\n--$boundary--\r\n')];
    final response = await http.Response.fromStream(await client.send(request).timeout(const Duration(seconds:90)));
    check();
    if (response.statusCode < 200 || response.statusCode >= 300) throw StateError('School Drive upload failed (HTTP ${response.statusCode}). Existing files were retained.');
    final file = jsonDecode(response.body) as Map;
    return {'fileId':file['id'], 'fileUrl':file['webViewLink'] ?? 'https://drive.google.com/file/d/${file['id']}/view'};
  }
  void close() { cancelled=true; client.close(); }
}
