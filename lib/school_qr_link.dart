import 'dart:convert';
import 'platform/platform_config.dart';

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
  static SchoolLink parse(String raw) {
    final d = jsonDecode(raw);
    if (d is! Map || d['app'] != 'VIDYA_SAARTHI' || d['v'] != 2)
      throw const FormatException(
          'Scan a current Vidya Saarthi student or teacher ID card.');
    if(d['managed']==true){
      final id=d['schoolId']?.toString()??'',endpoint=d['centralEndpoint']?.toString()??'';
      const allowed=String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL', defaultValue:'https://saarthi-oauth-staging.onrender.com/school-cloud');
      final role=d['type']?.toString()??'',person=d['personId']?.toString()??'',token=d['linkToken']?.toString()??'';
      if(!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(id)||endpoint!=allowed||!{'student','teacher'}.contains(role)||person.isEmpty||person.length>200||person.contains('/')||token.length<20)throw const FormatException('Invalid managed school ID card');
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
      throw const FormatException(
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

