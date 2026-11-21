import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
class ManagedDeveloperService {
  static http.Client? _transport;
  static String? _uid;
  static const endpoint = String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL');
  static Future<Map<String,dynamic>> call(String action, Map<String,dynamic> body) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Developer login required');
    if (endpoint.isEmpty) throw StateError('Managed account server is not configured in this review build');
    if(_transport==null||_uid!=user.uid){_transport?.close();_transport=http.Client();_uid=user.uid;}
    final response = await _transport!.post(Uri.parse(endpoint),headers:{'Content-Type':'application/json','Authorization':'Bearer ${await user.getIdToken()}'},body:jsonEncode({'action':'developer/managed/$action',...body})).timeout(const Duration(seconds:180));
    final result = jsonDecode(response.body);
    if(response.statusCode != 200 || result is! Map || result['success'] != true) throw StateError(result is Map ? result['message']?.toString() ?? 'Developer operation failed' : 'Invalid server response');
    return Map<String,dynamic>.from(result);
  }
}
