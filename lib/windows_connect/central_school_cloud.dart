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
Map<String, dynamic> managedSessionConfiguration(Map<String, dynamic> session,
    String schoolId, String uid) {
  if (session['success'] != true || session['schoolId'] != schoolId ||
      session['uid'] != uid || session['projectId'] != platformProjectId ||
      session['storageReady'] is! bool) {
    throw StateError('School session identity verification failed.');
  }
  final script = session['scriptUrl']?.toString() ?? '';
  if (session['storageReady'] == true &&
      !RegExp(r'^https://script\.google\.com/macros/s/[A-Za-z0-9_-]{10,300}/exec$').hasMatch(script)) {
    throw StateError('Saved school storage configuration is invalid.');
  }
  return {'scriptUrl': session['storageReady'] == true ? script : '',
    'storageReady': session['storageReady']};
}

Map<String, dynamic> centralSchoolData(Map<String, dynamic> data, String schoolId) {
  if (!validSchoolId(schoolId)) throw StateError('Invalid school identity.');
  Object? scrub(Object? value) {
    if (value is Map) {
      final result = <String,dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final normalized = key.toLowerCase();
        if (normalized.contains('password') ||
          (normalized.contains('token') && normalized != 'mobilelinktoken') || normalized.endsWith('base64') ||
          {'private_key','client_secret','localpath'}.contains(normalized) ||
          (entry.value is String && (entry.value as String).startsWith('data:'))) continue;
        result[key] = scrub(entry.value);
      }
      return result;
    }
    if (value is List) return value.map(scrub).toList();
    return value;
  }
  final result = scrub(data) as Map<String,dynamic>;
  result['schoolId'] = schoolId;
  return result;
}

/// New central connection is stored separately from legacy links/authentication.
/// Disconnecting it restores the existing installation without deleting data.
class CentralSchoolCloud {
  CentralSchoolCloud({http.Client? client, this.endpoint = apiUrl,
    this.expectedSchoolId, this.storage = const FlutterSecureStorage()}) : client = client ?? http.Client();
  static const apiUrl = String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL');
  static const key = 'vidya_saarthi_central_school_v2';
  static Future<void> _pendingSessionWrite = Future<void>.value();
  static Future<void> updateSession(String schoolId, Map<String,dynamic> updates, {String? expectedUid}) {
    final next = _pendingSessionWrite.catchError((_) {}).then((_) async {
      final current = await saved();
      if (current['schoolId'] != schoolId || expectedUid != null && current['uid'] != expectedUid) throw StateError('School connection changed.');
      current.addAll(updates);
      await const FlutterSecureStorage().write(key:key,value:jsonEncode(current));
    });
    _pendingSessionWrite = next;
    return next;
  }
  final String endpoint;
  final String? expectedSchoolId;
  final FlutterSecureStorage storage;
  final http.Client client;
  bool cancelled = false;
  String? _diagnosticToken;
  String? _diagnosticSchool;
  static const _reasons = {'SERVICE_DISABLED','ACCESS_TOKEN_SCOPE_INSUFFICIENT',
    'API_KEY_SERVICE_BLOCKED','API_KEY_HTTP_REFERRER_BLOCKED','API_KEY_IP_ADDRESS_BLOCKED',
    'PERMISSION_DENIED','UNAUTHENTICATED','RATE_LIMIT_EXCEEDED','RESOURCE_EXHAUSTED',
    'accessNotConfigured','insufficientPermissions','forbidden'};
  String _stage(String method, Uri uri) {
    if (uri.host == 'identitytoolkit.googleapis.com') return 'firebase_login';
    if (uri.host == 'securetoken.googleapis.com') return 'firebase_refresh';
    if (uri.host == 'firestore.googleapis.com') return 'firestore_verify';
    if (uri.host == 'www.googleapis.com' && uri.path.startsWith('/upload/')) return 'drive_upload';
    if (uri.host == 'www.googleapis.com' && uri.path.startsWith('/drive/v3/files')) {
      return method == 'POST' ? 'drive_create' : uri.path == '/drive/v3/files' ? 'drive_list' : 'drive_read';
    }
    return 'school_cloud';
  }
  Future<void> _reportFailure(String stage, int status, String reason) async {
    if (_diagnosticToken == null || _diagnosticSchool == null || stage == 'school_cloud') return;
    try {
      // Allowlisted diagnostic metadata only. No upstream body, file ID, key or Google token.
      final request = http.Request('POST',Uri.parse(endpoint))..followRedirects=false;
      request.headers.addAll({'Content-Type':'application/json','Authorization':'Bearer $_diagnosticToken'});
      request.body=jsonEncode({'action':'setup/diagnostic','schoolId':_diagnosticSchool,
        'stage':stage,'httpStatus':status,'reason':reason});
      final response = await client.send(request).timeout(const Duration(seconds:5));
      await response.stream.drain<void>().timeout(const Duration(seconds:5));
    } catch (_) { /* Never replace the original setup failure. */ }
  }

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
      final stage = _stage(method, uri);
      Map errorBody = {};
      try { final parsed = jsonDecode(response.body); if (parsed is Map) errorBody = parsed; } catch (_) {}
      final error = errorBody['error'];
      String reason = 'UNKNOWN';
      if (error is Map) {
        final details = error['details'];
        final errors = error['errors'];
        final candidates = [error['status'], if (details is List) ...details.whereType<Map>().map((d)=>d['reason']),
          if (errors is List) ...errors.whereType<Map>().map((d)=>d['reason'])];
        for (final candidate in candidates.reversed) { if (_reasons.contains(candidate)) { reason = candidate; break; } }
      }
      await _reportFailure(stage, response.statusCode, reason);
      final labels = {'firebase_login':'Firebase sign-in', 'firebase_refresh':'Firebase refresh',
        'firestore_verify':'Firestore verification', 'drive_list':'Google Drive folder search',
        'drive_create':'Google Drive folder creation', 'drive_read':'Google Drive access',
        'drive_upload':'Google Drive upload', 'school_cloud':'Central school API'};
      String detail = reason == 'UNKNOWN' ? '' : ' [$reason]';
      // Server messages are accepted only from the configured central endpoint,
      // and only when they exactly match a fixed, non-secret public explanation.
      const publicMessages = {'School membership is inactive','Another school is not accessible',
        'Legacy school administrator proof is required','Legacy school is already assigned to another tenant',
        'Drive must belong to the same school Google account','School Drive folder is not accessible',
        'Drive ownership or school marker is invalid','Verify the existing installation trial first',
        'Update and prepare the managed Apps Script for this School ID',
        'Script is not prepared for this school',
        'Developer must connect this school Apps Script first',
        'Existing storage retained. Developer must approve replacing this school Drive connection'};
      if (uri.toString() == endpoint && publicMessages.contains(errorBody['message'])) detail = ' ${errorBody['message']}.';
      final action = uri.toString() == endpoint && body is Map ? body['action'] : null;
      final actionLabel = {'onboard':'onboarding','status':'identity verification','migration/import':'legacy migration',
        'drive/link':'Drive ownership verification','profile/initialize':'school profile setup'}[action];
      final endpointLabel = labels[stage]! + (actionLabel == null ? '' : ' ($actionLabel)');
      final help = {'SERVICE_DISABLED':'The developer must enable this API in the OAuth project; school data is retained.',
        'accessNotConfigured':'The developer must enable Google Drive API in the OAuth project; school data is retained.',
        'ACCESS_TOKEN_SCOPE_INSUFFICIENT':'Reconnect the same Google account and allow Drive permission.',
        'insufficientPermissions':'Reconnect the same Google account and allow Drive permission.'}[reason] ??
        (response.statusCode == 401 ? 'Reconnect the same school Google account.' : 'Retry the same school; existing data is retained.');
      final reference = errorBody['requestId'];
      final ref = reference is String && RegExp(r'^[a-f0-9-]{36}$').hasMatch(reference) && uri.toString() == endpoint ? ' Ref: $reference.' : '';
      throw StateError('$endpointLabel failed (HTTP ${response.statusCode}).$detail $help$ref');
    }
    if (response.body.isEmpty) return {};
    final value = jsonDecode(response.body);
    if (value is! Map) throw StateError('Invalid school cloud response.');
    return Map<String, dynamic>.from(value);
  }
  Future<Map<String, dynamic>> api(Map<String, dynamic> body, {String? token}) async {
    if(expectedSchoolId!=null&&(await saved())['schoolId']!=expectedSchoolId)throw StateError('School changed during operation.');
    if (!validEndpoint(endpoint)) throw StateError('Developer must configure the central school cloud service. Schools do not need Firebase configuration.');
    return send('POST', Uri.parse(endpoint), token:token, body:body);
  }
  Future<Map<String, dynamic>> connect(GoogleSetupAccount account, String name, {Map<String,dynamic>? migration, void Function(String stage)? progress}) async {
    final old = await saved();
    final result = await api({'action':'onboard', 'schoolName':name,
      'googleAccessToken':account.accessToken, if (old.isNotEmpty) 'expectedSchoolId':old['schoolId']});
    final school = result['schoolId']?.toString() ?? '';
    if (!validSchoolId(school) || result['projectId'] != platformProjectId ||
        result['email'] != account.email || result['customToken'] is! String ||
        result['uid'] is! String || (result['uid'] as String).isEmpty ||
        (old.isNotEmpty && old['schoolId'] != school)) throw StateError('School cloud identity verification failed.');
    final auth = await send('POST', Uri.https('identitytoolkit.googleapis.com', '/v1/accounts:signInWithCustomToken', {'key':platformApiKey}),
      body:{'token':result['customToken'], 'returnSecureToken':true});
    if (auth['idToken'] is! String || auth['refreshToken'] is! String ||
        (auth['idToken'] as String).isEmpty || (auth['refreshToken'] as String).isEmpty) throw StateError('School Firebase login failed.');
    // The official custom-token response has no localId. Bind the session to
    // the UID verified from this ID token by the authenticated central API.
    final verified = await api({'action':'status', 'schoolId':school}, token:auth['idToken']);
    if (verified['uid'] != result['uid'] || verified['schoolId'] != school ||
        verified['projectId'] != platformProjectId ||
        (auth['localId'] != null && auth['localId'] != verified['uid'])) throw StateError('School Firebase identity verification failed.');
    _diagnosticToken = auth['idToken']; _diagnosticSchool = school;
    // Also verify deployed security rules allow this tenant before saving.
    await send('GET', Uri.parse('$platformFirestoreUrl/schools/$school/school_config?pageSize=1'), token:auth['idToken']);
    progress?.call('firebase');
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
    progress?.call('drive');
    final connection = <String,dynamic>{'schemaVersion':2, 'projectId':platformProjectId,
      'schoolId':school, 'schoolName':name, 'uid':verified['uid'], 'email':account.email,
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
      final session = await cloud.api({'action':data['managed']==true?'managed/session':'status', 'schoolId':data['schoolId']}, token:response['id_token']);
      final configuration = data['managed'] == true
          ? managedSessionConfiguration(session, data['schoolId'], data['uid']) : <String,dynamic>{};
      await updateSession(data['schoolId'], {...configuration,
        'firebaseRefreshToken':response['refresh_token'] ?? data['firebaseRefreshToken']},
        expectedUid: data['uid']);
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
    if(expectedSchoolId!=null&&data['schoolId']!=expectedSchoolId)throw StateError('School changed before upload.');
    if(data['managed']==true) return api({'action':'managed/file/upload','schoolId':data['schoolId'],'name':name,'mime':mime,'base64':raw.contains(',')?raw.split(',').last:raw},token:await firebaseToken());
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
  Future<void> backup() async {
    final connection = await saved();
    if (connection.isEmpty) throw StateError('Connect school cloud first.');
    if(connection['managed']==true){await api({'action':'managed/backup','schoolId':connection['schoolId']},token:await firebaseToken());return;}
    final token = await firebaseToken();
    final records = <String,dynamic>{};
    for (final collection in ['students_directory','teachers_directory','attendance_records',
      'teacher_attendance','school_config','school_settings','school_notices','fee_payments',
      'fee_ledger','fee_settings','school_expenses','school_calendar','exam_results','teacher_salary',
      'documents','exams','exam_center_results']) {
      final documents = <dynamic>[];
      String? page;
      do {
        final result = await send('GET',Uri.parse('$platformFirestoreUrl/${tenantCollectionPath(connection['schoolId'],collection)}')
          .replace(queryParameters:{'pageSize':'500',if(page != null) 'pageToken':page}),token:token);
        documents.addAll(result['documents'] as List? ?? []);
        final next=result['nextPageToken']?.toString();
        if (next != null && next == page) throw StateError('Repeated backup page.');
        page=next;
      } while(page != null && page.isNotEmpty);
      records[collection]=documents;
    }
    if ((await saved())['schoolId'] != connection['schoolId']) throw StateError('School changed during backup.');
    final at=DateTime.now().toUtc();
    final contents=jsonEncode({'schemaVersion':2,'schoolId':connection['schoolId'],'createdAt':at.toIso8601String(),'firestoreDocuments':records});
    final file=await upload('School_Backup_${at.millisecondsSinceEpoch}.json','application/json',base64Encode(utf8.encode(contents)));
    await send('PATCH',Uri.parse('$platformFirestoreUrl/schools/${connection['schoolId']}/backups/${at.millisecondsSinceEpoch}'),token:token,body:{'fields':{
      'schoolId':{'stringValue':connection['schoolId']},'fileId':{'stringValue':file['fileId']},
      'fileUrl':{'stringValue':file['fileUrl']},'createdAt':{'timestampValue':at.toIso8601String()}}});
  }
  void close() { cancelled=true; client.close(); }
}
