import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'platform/platform_config.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_local_firestore.dart' as local;

/// Developer-only published messages. Reads never enter the school sync outbox.
class DeveloperInbox extends ChangeNotifier {
  DeveloperInbox({this.readPage});
  final Future<Map<String, dynamic>> Function(String audience, String? cursor)? readPage;
  final _db = local.FirebaseFirestore.instance;
  final _client = http.Client();
  final Map<String, String?> _cursors = {};
  List<Map<String, dynamic>> messages = [];
  Set<String> _read = {};
  String? _profile, _school, _uid;
  bool busy = false, _disposed = false, _loaded = false;
  String? error;
  int get unread => !current ? 0 : messages.where((m) => !_read.contains(m['key'])).length;
  bool get hasMore => _cursors.values.any((v) => v != null);
  bool isRead(Map m) => _read.contains(m['key']);
  bool get current => _profile == _db.activeProfileId &&
      _school == _db.activeProfileIdentity['schoolSyncId'];
  void _notify() { if (!_disposed) notifyListeners(); }
  Future<void> initialize() async {
    try {
    _profile = _db.activeProfileId;
    _school = _db.activeProfileIdentity['schoolSyncId']?.toString();
    final saved = await CentralSchoolCloud.saved();
    if (!current || _disposed) return;
    _uid = saved['uid']?.toString();
    final cached = await _db.collection('_developer_inbox').get();
    if (!current || _disposed) return;
    messages = cached.docs.map((d) => d.data()).where((m) => m['schoolId'] == _school).toList();
    final read = await _db.collection('_developer_inbox_read').get();
    if (!current || _disposed) return;
    _read = read.docs.map((d) => d.id).toSet();
    _sort(); _notify();
    await refresh();
    } catch (e) { if (!_disposed) { error = 'Developer notifications could not be loaded. Reopen this page.'; _notify(); } }
  }
  void _sort() => messages.sort((a,b) => (b['createdAt'] as int).compareTo(a['createdAt'] as int));
  Future<Map<String,dynamic>> _page(String audience, String? cursor) async {
    if (readPage != null) return readPage!(audience, cursor);
    final saved = await CentralSchoolCloud.saved();
    if (!current || saved['schoolId'] != _school || saved['uid'] != _uid || saved['managed'] != true)
      throw StateError('Sign in to the current school to read developer notifications.');
    final token = await CentralSchoolCloud.firebaseToken();
    final uri = Uri.parse('$platformFirestoreUrl/platform_developer_notifications/$audience/messages').replace(
      queryParameters: {'pageSize':'50','orderBy':'createdAt desc',if(cursor != null)'pageToken':cursor});
    final response = await _client.get(uri,headers:{'Authorization':'Bearer $token'}).timeout(const Duration(seconds:20));
    if (response.statusCode != 200) throw StateError('Developer notifications could not be refreshed. Try again.');
    final result = jsonDecode(response.body);
    if (result is! Map) throw StateError('Invalid notification response.');
    return Map<String,dynamic>.from(result);
  }
  Future<void> refresh({bool more = false}) async {
    if (busy || !current || _disposed || _school == null || _school!.isEmpty) return;
    busy = true; error = null; _notify();
    try {
      final updates = <Map<String,dynamic>>[];
      final next = <String,String?>{};
      for (final audience in ['all',_school!]) {
        if (more && _loaded && _cursors[audience] == null) continue;
        final page = await _page(audience, more ? _cursors[audience] : null);
        if (!current || _disposed) return;
        final saved = await CentralSchoolCloud.saved();
        if (readPage == null && (saved['uid'] != _uid || saved['schoolId'] != _school))
          throw StateError('School account changed. Reopen notifications.');
        final docs = page['documents'] ?? [];
        if (docs is! List) throw StateError('Invalid notification page.');
        for (final doc in docs) {
          final fields = doc is Map ? doc['fields'] : null;
          final name = doc is Map ? doc['name'] : null;
          final prefix = 'projects/$platformProjectId/databases/(default)/documents/platform_developer_notifications/$audience/messages/';
          if (fields is! Map || name is! String || !name.startsWith(prefix)) throw StateError('Notification identity mismatch.');
          final id = name.substring(prefix.length);
          final title = fields['title']?['stringValue'];
          final message = fields['message']?['stringValue'];
          final created = DateTime.tryParse(fields['createdAt']?['timestampValue']?.toString() ?? '');
          if (id.isEmpty || id.contains('/') || title is! String || title.isEmpty || title.length > 160 ||
              message is! String || message.isEmpty || message.length > 5000 || created == null ||
              fields['audience']?['stringValue'] != audience) throw StateError('Invalid developer notification.');
          updates.add({'key':'$audience--$id','schoolId':_school,'audience':audience,
            'title':title,'message':message,'createdAt':created.millisecondsSinceEpoch});
        }
        final cursor = page['nextPageToken'];
        if (cursor != null && (cursor is! String || cursor.isEmpty)) throw StateError('Invalid notification cursor.');
        next[audience] = cursor as String?;
      }
      if (!current || _disposed) return;
      final existing = {for (final m in messages) m['key']: m};
      final changed = updates.where((m) => existing[m['key']] == null ||
        m.entries.any((e) => existing[m['key']]![e.key] != e.value)).toList();
      if (changed.isNotEmpty) {
        final batch = _db.batch();
        for (final m in changed) { batch.set(_db.collection('_developer_inbox').doc(m['key'] as String),m); }
        await batch.commit();
      }
      if (!current || _disposed) return;
      final merged = {for(final m in messages) m['key']:m,for(final m in updates)m['key']:m};
      messages = merged.values.toList();
      // Restart pagination at the fresh head; cached messages deduplicate by ID.
      _cursors.addAll(next);
      _loaded = true; _sort();
    } catch (e) { if (current && !_disposed) error = e.toString().replaceFirst('Bad state: ', ''); }
    finally { busy = false; _notify(); }
  }
  Future<void> markRead(Map<String,dynamic> message) async {
    if (!current || _disposed || !messages.any((m) => m['key'] == message['key'])) return;
    try {
      await _db.collection('_developer_inbox_read').doc(message['key'] as String).set({'readAt':DateTime.now().millisecondsSinceEpoch});
      if (!current || _disposed) return;
      _read.add(message['key'] as String); _notify();
    } catch (_) { if (current && !_disposed) { error = 'Read status could not be saved. Try again.'; _notify(); } }
  }
  @override void dispose() { _disposed = true; _client.close(); super.dispose(); }
}

class DeveloperInboxScreen extends StatelessWidget {
  const DeveloperInboxScreen({super.key,required this.inbox});
  final DeveloperInbox inbox;
  @override Widget build(BuildContext context) => AnimatedBuilder(animation:inbox,builder:(context,_) => Scaffold(
    appBar:AppBar(title:const Text('Developer notifications'),actions:[IconButton(
      tooltip:'Refresh notifications',onPressed:inbox.busy?null:()=>inbox.refresh(),icon:const Icon(Icons.refresh))]),
    body: !inbox.current ? const Center(child:Text('School changed. Reopen this page.')) : Column(children:[
      if(inbox.busy)const LinearProgressIndicator(),
      if(inbox.error != null)Padding(padding:const EdgeInsets.all(16),child:Text(inbox.error!)),
      Expanded(child:inbox.messages.isEmpty ? Center(child:Text(inbox.busy?'Loading notifications…':'No developer notifications yet.')) : ListView.builder(
        padding:const EdgeInsets.all(20),itemCount:inbox.messages.length+1,itemBuilder:(context,index){
          if(index==inbox.messages.length)return inbox.hasMore ? TextButton(onPressed:inbox.busy?null:()=>inbox.refresh(more:true),child:const Text('Load older notifications')) : const SizedBox(height:20);
          final m=inbox.messages[index],read=inbox.isRead(inbox.messages[index]);
          return Card(child:ListTile(leading:Icon(read?Icons.notifications_none:Icons.notifications_active),
            title:Text(m['title'] as String,style:TextStyle(fontWeight:read?FontWeight.normal:FontWeight.bold)),
            subtitle:Text('${DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int).toLocal()} • Developer'),
            trailing:read?null:const Badge(),onTap:()async{
              await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:Text(m['title'] as String),
                content:SingleChildScrollView(child:SelectableText(m['message'] as String)),
                actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))]));
              await inbox.markRead(m);
            }));
        }))])));
}
