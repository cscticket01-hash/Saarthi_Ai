import 'dart:convert';
import 'platform/platform_config.dart';

class SchoolQrException extends FormatException {
  const SchoolQrException(String message, [this.code = 'MALFORMED_ID']) : super(message);
  final String code;
}

class SchoolLink {
  const SchoolLink(
      {required this.projectId,
      required this.scriptUrl,
      required this.role,
      required this.personId,
      required this.linkToken,
      required this.rawQr,this.managed=false,this.schoolId='',this.endpoint=''});
  final String projectId, scriptUrl, role, personId, linkToken, rawQr;
  final bool managed;final String schoolId,endpoint;
  /// Windows and Android use this exact versioned envelope.
  static String encode(Map<String, dynamic> fields) {
    final raw = jsonEncode({...fields, 'app': 'VIDYA_SAARTHI', 'v': 2});
    parse(raw);
    return raw;
  }
  /// Compact managed identity only; DOB/password and server lease verification
  /// remain mandatory. No names, location, Drive URL or Firebase config in QR.
  static String encodeCompact(Map<String, dynamic> fields) {
    final checked = parse(jsonEncode({...fields, 'app':'VIDYA_SAARTHI','v':2}));
    if (!checked.managed) return encode(fields);
    final person = base64Url.encode(utf8.encode(checked.personId)).replaceAll('=', '');
    if (!RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(checked.linkToken)) {
      // Previously issued v2 tokens remain valid; compact VS3 has stricter
      // representation limits. Preserve identity/token with the v2 envelope.
      return encode({'managed':true,'schoolId':checked.schoolId,
        'centralEndpoint':checked.endpoint,'type':checked.role,
        'personId':checked.personId,'linkToken':checked.linkToken});
    }
    return 'VS3|${checked.schoolId.substring(3)}|${checked.role == 'student' ? 's' : 't'}|$person|${checked.linkToken}';
  }
  static int detectVersion(String raw) {
    final value = raw.trim();
    if (value.startsWith('VS3|')) return 3;
    if (RegExp(r'^VS[0-9]+\|').hasMatch(value)) {
      throw const SchoolQrException('Unsupported ID QR version. Update the app or ask the school to regenerate the card.');
    }
    if (!value.startsWith('{')) throw const SchoolQrException('Scan a Vidya Saarthi student or teacher ID card.');
    try {
      final data = jsonDecode(value);
      if (data is Map && data['v'] == 2) return 2;
    } catch (_) {}
    throw const SchoolQrException('Invalid or unsupported school ID QR.');
  }
  static SchoolLink parse(String raw) {
    if (raw.length > 8192) throw const SchoolQrException('QR payload exceeds safety limit.');
    final value = raw.trim();
    detectVersion(value);
    try {
      return _parse(value);
    } on SchoolQrException {
      rethrow;
    } on FormatException {
      throw const SchoolQrException('Invalid school ID QR. Scan the original card or ask the school to regenerate it.');
    } on RangeError {
      throw const SchoolQrException('Incomplete school ID QR. Scan the original card again.');
    } on TypeError {
      throw const SchoolQrException('Invalid school ID QR fields.');
    }
  }
  static SchoolLink _parse(String raw) {
    if (raw.length > 8192) throw const SchoolQrException('QR payload exceeds safety limit.');
    if (raw.startsWith('VS3|')) {
      final parts = raw.split('|');
      if (parts.length != 5 || !{'s','t'}.contains(parts[2]) ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(parts[1]) ||
          !RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(parts[4])) {
        throw const SchoolQrException('Invalid compact school ID.');
      }
      String person;
      try { person = utf8.decode(base64Url.decode(base64Url.normalize(parts[3])), allowMalformed:false); }
      catch (_) { throw const SchoolQrException('Invalid compact person ID.'); }
      const endpoint = String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL', defaultValue:'https://saarthi-oauth-staging.onrender.com/school-cloud');
      final validated = parse(jsonEncode({'app':'VIDYA_SAARTHI','v':2,'managed':true,
        'schoolId':'vs-${parts[1]}','centralEndpoint':endpoint,'type':parts[2]=='s'?'student':'teacher',
        'personId':person,'linkToken':parts[4]}));
      return SchoolLink(projectId:validated.projectId,scriptUrl:'',role:validated.role,
        personId:person,linkToken:validated.linkToken,rawQr:raw,managed:true,
        schoolId:validated.schoolId,endpoint:validated.endpoint);
    }
    final d = jsonDecode(raw);
    if (d is! Map || d['app'] != 'VIDYA_SAARTHI' || d['v'] != 2)
      throw const SchoolQrException(
          'Scan a current Vidya Saarthi student or teacher ID card.');
    if(d['managed']==true){
      final id=d['schoolId']?.toString()??'',endpoint=d['centralEndpoint']?.toString()??'';
      const allowed=String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL', defaultValue:'https://saarthi-oauth-staging.onrender.com/school-cloud');
      final role=d['type']?.toString()??'',person=d['personId']?.toString()??'',token=d['linkToken']?.toString()??'';
      if (role == 'school') throw const SchoolQrException('Scan a student or teacher ID card. A school setup QR cannot be used for attendance.', 'WRONG_QR_KIND');
      if (endpoint != allowed) throw const SchoolQrException('This card belongs to a different server environment. Use the app supplied by the issuing school; do not replace the card.', 'SERVER_ENVIRONMENT_MISMATCH');
      if(!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(id)||!{'student','teacher'}.contains(role)||person.isEmpty||person.length>200||person.contains('/')||token.length<20)throw const SchoolQrException('Invalid managed school ID card');
      return SchoolLink(projectId:id,scriptUrl:'',role:role,personId:person,linkToken:token,rawQr:raw,managed:true,schoolId:id,endpoint:endpoint);
    }
    Map config = {};
    try {
      final rawConfig = d['firebaseLink']?.toString() ?? '{}';
      final uri = Uri.tryParse(rawConfig);
      if (uri?.scheme == 'vidyasaarthi' && uri?.host == 'firebase') {
        config = jsonDecode(utf8.decode(base64Url
            .decode(base64Url.normalize(uri!.queryParameters['config']!))));
      } else {
        config = jsonDecode(rawConfig);
      }
    } catch (_) {
      final text = d['firebaseLink']?.toString() ?? '';
      final start = text.indexOf('{'), end = text.lastIndexOf('}');
      if (start >= 0 && end > start)
        config = jsonDecode(text.substring(start, end + 1));
    }
    final project =
        (d['firebaseProjectId'] ?? config['projectId'] ?? '').toString();
    final role = d['type']?.toString() ?? '';
    final token = d['linkToken']?.toString() ?? '';
    final person = d['personId']?.toString() ?? '';
    final url = Uri.tryParse(d['googleScriptUrl']?.toString() ?? '');
    if (project == platformProjectId || !RegExp(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$').hasMatch(project) ||
        !{'student', 'teacher'}.contains(role) ||
        token.length < 20 ||
        person.isEmpty || person.length > 200 || person.contains('/') ||
        url == null ||
        url.scheme != 'https' ||
        url.host != 'script.google.com' ||
        url.userInfo.isNotEmpty ||
        !RegExp(r'^/macros/s/[A-Za-z0-9_-]+/exec$').hasMatch(url.path) ||
        url.hasQuery ||
        url.hasFragment)
      throw const SchoolQrException(
          'This QR has incomplete or invalid school connections. Ask the school to regenerate it.');
    return SchoolLink(
        projectId: project,
        scriptUrl: url.toString(),
        role: role,
        personId: person,
        linkToken: token,
        rawQr: raw);
  }
}


/// Pause camera events immediately, including invalid codes, until explicit retry.
class SchoolQrCapture {
  bool paused = false;
  SchoolLink? capture(String raw) {
    if (paused) return null;
    paused = true;
    return SchoolLink.parse(raw);
  }
  void retry() => paused = false;
}
