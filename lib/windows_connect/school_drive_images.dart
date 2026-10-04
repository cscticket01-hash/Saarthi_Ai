import 'dart:convert';
import 'managed_school_session.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'central_school_cloud.dart';

String? schoolDriveFileId(String source) {
  final uri = Uri.tryParse(source);
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.host != 'drive.google.com') return null;
  final match = RegExp(r'^/file/d/([A-Za-z0-9_-]{1,200})(?:/view)?$').firstMatch(uri.path);
  final id = match?.group(1) ?? (uri.path == '/uc' ? uri.queryParameters['id'] : null);
  return id != null && RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(id) ? id : null;
}
Future<Uint8List?> schoolImageBytes(String source) async {
  final uri = Uri.tryParse(source);
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) return null;
  final id = schoolDriveFileId(source);
  final connection = await CentralSchoolCloud.saved();
  if (connection.isNotEmpty && id != null) {
    final cloud = CentralSchoolCloud(endpoint:connection['endpoint']);
    try {
      if(connection['managed']==true){final result=await ManagedSchoolSession.call('managed/file/read',{'fileId':id});if((result['mime']?.toString()??'').startsWith('image/'))return Uint8List.fromList(base64Decode(result['base64']));return null;}
      final token = await cloud.googleToken(connection);
      final metadata = await cloud.send('GET',Uri.https('www.googleapis.com','/drive/v3/files/$id',
        {'fields':'id,appProperties,parents,trashed'}),token:token);
      if (metadata['trashed'] == true || metadata['appProperties']?['schoolId'] != connection['schoolId'] ||
          !(metadata['parents'] as List? ?? []).contains(connection['folderId'])) return null;
      final request = http.Request('GET',Uri.https('www.googleapis.com','/drive/v3/files/$id',{'alt':'media'}))
        ..followRedirects=false..headers['Authorization']='Bearer $token';
      final response = await http.Response.fromStream(await cloud.client.send(request).timeout(const Duration(seconds:30)));
      if ((await CentralSchoolCloud.saved())['schoolId'] != connection['schoolId']) return null;
      if (response.statusCode == 200 && (response.headers['content-type'] ?? '').startsWith('image/')) return response.bodyBytes;
    } catch (_) {} finally {cloud.close();}
    return null;
  }
  // Preserve existing external/legacy images without attaching OAuth credentials.
  try {
    final response = await http.get(uri).timeout(const Duration(seconds:15));
    if (response.statusCode == 200 && (response.headers['content-type'] ?? '').startsWith('image/')) return response.bodyBytes;
  } catch (_) {}
  return null;
}
Widget schoolNetworkImage(String source,{double? width,double? height,BoxFit? fit,ImageErrorWidgetBuilder? errorBuilder}) {
  return FutureBuilder<Uint8List?>(future:schoolImageBytes(source),builder:(context,snapshot){
    if (snapshot.connectionState == ConnectionState.done && snapshot.data != null) {
      return Image.memory(snapshot.data!,width:width,height:height,fit:fit,errorBuilder:errorBuilder);
    }
    return SizedBox(width:width,height:height,child:errorBuilder?.call(context,StateError('School image unavailable'),null) ?? const Icon(Icons.image_outlined));
  });
}
