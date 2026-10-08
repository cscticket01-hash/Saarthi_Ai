import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
class ManagedDeveloperService {
  static const endpoint = String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL');
  static Future<Map<String,dynamic>> call(String action, Map<String,dynamic> body) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Developer login required');
    if (endpoint.isEmpty) throw StateError('Managed account server is not configured in this review build');
    final response = await http.post(Uri.parse(endpoint),headers:{'Content-Type':'application/json','Authorization':'Bearer ${await user.getIdToken()}'},body:jsonEncode({'action':'developer/managed/$action',...body})).timeout(const Duration(seconds:180));
    final result = jsonDecode(response.body);
    if(response.statusCode != 200 || result is! Map || result['success'] != true) throw StateError(result is Map ? result['message']?.toString() ?? 'Developer operation failed' : 'Invalid server response');
    return Map<String,dynamic>.from(result);
  }
}
