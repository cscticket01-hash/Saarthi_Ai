import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Shared passive progress source for the update screen. Zero means downloading
/// has not begun; null total means byte-percent cannot be established.
class AndroidUpdateTransfer {
  const AndroidUpdateTransfer(this.received, this.total, {this.verified = false});
  final int received;
  final int? total;
  final bool verified;
  double? get fraction => total == null || total! <= 0
    ? null : (received / total!).clamp(0.0, 1.0);
}
final androidUpdateTransfer = ValueNotifier<AndroidUpdateTransfer?>(null);

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

/// Public diagnostics never include provider responses, tokens, or raw exceptions.
String androidUpdateErrorMessage(Object error) {
  if (error is TimeoutException) return 'The update service took too long to respond. Try again later.';
  if (error is SocketException || error is http.ClientException) return 'Unable to reach the update service. Check your connection and try again.';
  if (error is StateError && const {
    'No Android update is published yet', 'No update is published yet.',
    'Update service unavailable. Try again later.', 'Invalid update response',
    'Invalid update download address', 'Invalid APK digest',
    'Update download failed.', 'Update verification failed. Download again.',
  }.contains(error.message)) return error.message.toString();
  return 'Unable to complete the update. Try again later.';
}

/// A failed/stalled download removes only its temporary APK, never school data.
/// The caller retains its busy guard so a second download cannot share this path.
Future<File> downloadAndroidUpdate(Map<String, dynamic> update, File destination, {
  http.Client? client,
  Duration headerTimeout = const Duration(seconds: 20),
  Duration idleTimeout = const Duration(seconds: 30),
  Duration overallTimeout = const Duration(minutes: 15),
  void Function(int bytesReceived, int? bytesTotal)? onProgress,
}) async {
  validateAndroidUpdate(update);
  final transport = client ?? http.Client();
  final partial = File('${destination.path}.part');
  IOSink? sink;
  StreamIterator<List<int>>? chunks;
  try {
    final response = await transport.send(http.Request('GET', Uri.parse(update['apkUrl'] as String)))
        .timeout(headerTimeout);
    if (response.statusCode != 200) throw StateError('Update download failed.');
    sink = partial.openWrite();
    final totalBytes = response.contentLength;
    var receivedBytes = 0;
    onProgress?.call(0, totalBytes);
    chunks = StreamIterator<List<int>>(response.stream);
    final elapsed = Stopwatch()..start();
    while (true) {
      final remaining = overallTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('Update download deadline exceeded');
      final budget = remaining < idleTimeout ? remaining : idleTimeout;
      if (!await chunks.moveNext().timeout(budget)) break;
      sink.add(chunks.current);
      receivedBytes += chunks.current.length;
      onProgress?.call(receivedBytes, totalBytes);
      await sink.flush().timeout(budget);
    }
    await sink.close();
    sink = null;
    final expected = update['sha256']?.toString().replaceFirst('sha256:', '');
    if (expected != null && (await sha256.bind(partial.openRead()).first).toString() != expected) {
      throw StateError('Update verification failed. Download again.');
    }
    onProgress?.call(receivedBytes, totalBytes);
    return await partial.rename(destination.path);
  } finally {
    // Close the download transport to cancel stalled network activity.
    transport.close();
    if (chunks != null) await chunks.cancel();
    if (sink != null) { try { await sink.close(); } catch (_) {} }
    if (await partial.exists()) await partial.delete();
  }
}
