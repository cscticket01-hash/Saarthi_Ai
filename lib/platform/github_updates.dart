import 'dart:convert';
import 'package:http/http.dart' as http;

Future<Map<String,dynamic>> latestAndroidUpdate({http.Client? client}) async {
  final transport = client ?? http.Client();
  try {
  // Static release asset: checks do not consume Firebase reads or GitHub API quota.
  try {
    final staticResponse=await transport.get(Uri.parse('https://github.com/cscticket01-hash/Saarthi_Ai/releases/latest/download/android-update.json')).timeout(const Duration(seconds:20));
    if(staticResponse.statusCode==200){
      final data=jsonDecode(staticResponse.body);
      if(data is! Map) throw StateError('Invalid update response');
      final update=Map<String,dynamic>.from(data);
      validateAndroidUpdate(update);
      return {'success':true,'update':update};
    }
  } on Exception { /* The public release index is the existing safe fallback. */ }

  final r = await transport.get(Uri.parse('https://api.github.com/repos/cscticket01-hash/Saarthi_Ai/releases?per_page=100'),
    headers:{'Accept':'application/vnd.github+json','User-Agent':'Vidya-Saarthi'})
    .timeout(const Duration(seconds:20));
  if(r.statusCode != 200) throw StateError('Update service unavailable. Try again later.');
  final releases = jsonDecode(r.body);
  if(releases is! List) throw StateError('Invalid update response');
  final sorted = releases.whereType<Map>().toList()..sort((a,b) {
    int build(Map r)=>int.tryParse(r['tag_name'].toString().split('.').last)??0;
    return build(b).compareTo(build(a));
  });
  for(final release in sorted) {
    final tag=release['tag_name'].toString();
    if(release['draft']==true || release['prerelease']==true || !tag.startsWith('android-v')) continue;
    final version=tag.substring('android-v'.length),build=int.tryParse(version.split('.').last);
    final assets=release['assets'];
    if(build==null||assets is! List) continue;
    for(final asset in assets) {
      if(asset['name'] != 'Vidya-Saarthi-v$version.apk') continue;
      final uri=Uri.tryParse(asset['browser_download_url'].toString());
      if(uri==null||uri.scheme!='https'||uri.host!='github.com'||
        !uri.path.startsWith('/cscticket01-hash/Saarthi_Ai/releases/download/android-v')) continue;
      final update=<String,dynamic>{'versionCode':build,'versionName':version,'apkUrl':uri.toString(),'sha256':asset['digest'],'releaseNotes':release['body']??'','whatsNew':[release['body']??'']};
      validateAndroidUpdate(update);return {'success':true,'update':update};
    }
  }
  throw StateError('No Android update is published yet');
  } finally { if(client == null) transport.close(); }
}

void validateAndroidUpdate(Map<String,dynamic> update) {
  final version=update['versionName']?.toString()??'',build=update['versionCode'];
  final uri=Uri.tryParse(update['apkUrl']?.toString()??'');
  if(!RegExp(r'^1\.0\.[0-9]+$').hasMatch(version)||build is! int||build<=0||
      int.tryParse(version.split('.').last)!=build||uri==null||uri.scheme!='https'||
      uri.host!='github.com'||uri.userInfo.isNotEmpty||uri.hasQuery||uri.hasFragment||
      uri.path!='/cscticket01-hash/Saarthi_Ai/releases/download/android-v$version/Vidya-Saarthi-v$version.apk') {
    throw StateError('Invalid update download address');
  }
  final digest=update['sha256']?.toString();
  if(digest!=null&&!RegExp(r'^(sha256:)?[a-f0-9]{64}$').hasMatch(digest)) throw StateError('Invalid APK digest');
}
