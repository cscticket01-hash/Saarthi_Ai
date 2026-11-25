import 'complaint_retention.dart';
import 'notice_time.dart';
import 'windows_support_history.dart';
import 'windows_notification_sound.dart';
import 'windows_firebase_sync.dart';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'platform/platform_config.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_local_firestore.dart' as local;

/// Developer messages and verified school complaints. Reads never enter the school sync outbox.
class DeveloperInbox extends ChangeNotifier {
  DeveloperInbox({this.readPage, this.readComplaints, this.playNotificationSound});
  final Future<void> Function()? playNotificationSound;
  bool _soundBaselineEstablished = false;
  final Future<Map<String, dynamic>> Function(String audience, String? cursor)?
  readPage;
  final Future<Map<String, dynamic>> Function(String? cursor)? readComplaints;
  final _db = local.FirebaseFirestore.instance;
  final _client = http.Client();
  final Map<String, String?> _cursors = {};
  List<Map<String, dynamic>> messages = [];
  List<Map<String,dynamic>>? _tickets;
  List<Map<String,dynamic>>? get supportTickets => current ? _tickets : null;
  // Reuse existing ticket counters with the server-confirmed status.
  void acceptResolvedTicket(Map<String,dynamic> row) {
    if (!current || _disposed || row['schoolId'] != _school || row['status'] != 'resolved' || _tickets == null) return;
    _tickets = _tickets!.map((ticket) => ticket['id'] == row['id'] ? row : ticket).toList();
    _notify();
  }
  final Map<String,String> _read = {};
  final Set<String> _pendingRead = {};
  Map<String,Map<String,dynamic>> _complaintPages = {};
  String? _supportCursor;
  Map<String,Map<String,dynamic>> _supportRows = {};
  DateTime? _feedRetryAfter;
  DateTime? _lastSupportPoll;
  int _receiptSweepOffset=0;
  String? _profile, _school, _uid;
  Object? _profileSchool;
  bool _legacyScript=false;
  Future<void> _requireLegacyIdentity() async {
    final remote=await WindowsFirebaseRemote.status();
    if(!current||!remote.authenticated||remote.projectId!=_school||remote.schoolIdentity!=_school||
      sha256.convert(utf8.encode(remote.email.trim().toLowerCase())).toString()!=_uid)throw StateError('School account changed.');
  }
  bool busy = false, _disposed = false, _loaded = false;
  String? error;
  int get unread =>
      !current ? 0 : messages.where((m) => !isRead(m) && !complaintExpired(m)).length;
  bool get hasMore => _cursors.values.any((v) => v != null);
  static String receiptRevision(Map m) => sha256.convert(utf8.encode(jsonEncode(
    kind(m)=='support' && complaintMillis(m['developerUpdatedAt'])>0
      ? [m['key'],m['developerUpdatedAt'],m['developerNote']]
      : [m['key'],m['title'],m['message'],m['status'],m['createdAt']],
  ))).toString();
  bool isRead(Map m) => _read[m['key']] == receiptRevision(m);

  Future<void> _syncReadReceipts() async {
    if(readPage!=null || readComplaints!=null || !current || _disposed) return;
    final support=SchoolSupportClient();
    final rows=messages.where((m)=>!complaintExpired(m)).toList();
    // Each exchange is bounded; recent alerts first, with pending older reads included.
    final candidates=<String,Map<String,dynamic>>{};
    for(final m in rows.where((m)=>_pendingRead.contains(receiptRevision(m)))) {
      candidates[receiptRevision(m)]=m;
    }
    for(final m in rows.take(50)) {candidates[receiptRevision(m)]=m;}
    if(rows.isNotEmpty){
      final start=_receiptSweepOffset%rows.length;
      for(var i=0;i<50&&i<rows.length;i++){final m=rows[(start+i)%rows.length];candidates[receiptRevision(m)]=m;}
      _receiptSweepOffset=(start+50)%rows.length;
    }
    final keys=candidates.keys.toList();
    for(var start=0;start<keys.length;start+=100){
      if(!current||_disposed)return;
      final chunk=keys.skip(start).take(100).toList();
      final marked=chunk.where(_pendingRead.contains).toList();
      final result=await support.call('managed/support/readReceipts',{'keys':chunk,'marked':marked});
      if(!current||_disposed)return;
      final returned=result['read'];
      if(returned is! List || returned.any((r)=>r is! String||!chunk.contains(r)))throw StateError('Invalid read receipt response.');
      for(final key in returned.cast<String>()){
        final row=candidates[key]!;
        if(!messages.any((m)=>m['key']==row['key']&&receiptRevision(m)==key))continue;
        await _db.collection('_windows_developer_inbox_read').doc(row['key'] as String).set({
          'readAt':DateTime.now().millisecondsSinceEpoch,'revision':key,'pending':false,
        });
        if(!current||_disposed)return;
        _read[row['key'] as String]=key;
        _pendingRead.remove(key);
      }
    }
  }
  static String kind(Map row) => row['kind'] == 'support' ? 'support' :
      row['complaintId'] != null ? 'student' : 'announcement';
  int unreadFor(String type) => !current ? 0 : messages.where((m) =>
      kind(m) == type && !isRead(m) && !complaintExpired(m)).length;

  Future<void> flushSupport() async {
    if (_disposed) return;
    try { await SchoolSupportClient().flushPending(); } catch (_) {}
  }
  Future<void> tick() async {
    if (_disposed || !current || busy) return;
    final due=_lastSupportPoll==null||DateTime.now().difference(_lastSupportPoll!)>=const Duration(minutes:1);
    if(due){
      _lastSupportPoll=DateTime.now();
      await Future.wait([refresh(),flushSupport()]);
    }else{
      await refresh(announcementsOnly:true);
    }
  }
  bool get current =>
      _profile == _db.activeProfileId &&
      _profileSchool == _db.activeProfileIdentity['schoolSyncId'];
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      _profile = _db.activeProfileId;
      _profileSchool = _db.activeProfileIdentity['schoolSyncId'];
      _school = _profileSchool?.toString();
      final saved = await CentralSchoolCloud.saved();
      if (!current || _disposed) return;
      _uid = saved['uid']?.toString();
      if(saved.isEmpty&&readPage==null){
        final remote=await WindowsFirebaseRemote.status();
        if(!current||_disposed)return;
        if(remote.authenticated&&remote.schoolIdentity==remote.projectId&&RegExp(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$').hasMatch(remote.projectId)){
          _legacyScript=true;_school=remote.projectId;
          _uid=sha256.convert(utf8.encode(remote.email.trim().toLowerCase())).toString();
        }
      }
      final cached = await _db.collection('_windows_developer_inbox').get();
      if (!current || _disposed) return;
      messages = cached.docs
          .map((d) => d.data())
          .where((m) => m['schoolId'] == _school)
          .toList();
      final read = await _db.collection('_windows_developer_inbox_read').get();
      if (!current || _disposed) return;
      _read.clear();
      for(final d in read.docs){
        final matches=messages.where((m)=>m['key']==d.id);
        if(matches.isEmpty)continue;
        final data=d.data(),revision=receiptRevision(matches.first);
        if(data['revision']!=null&&data['revision']!=revision)continue;
        _read[d.id]=revision;
        if(data['pending']!=false)_pendingRead.add(revision);
      }
      await _purgeExpired();
      _sort();
      _notify();
      await refresh();
    } catch (e) {
      if (!_disposed) {
        error =
            'Developer notifications could not be loaded. Reopen this page.';
        _notify();
      }
    }
  }

  Future<void> _purgeExpired() async {
    final stale = messages.where(complaintExpired).toList();
    for (final row in stale) {
      if (!current || _disposed) return;
      await _db
          .collection('_windows_developer_inbox')
          .doc(row['key'] as String)
          .delete();
      if (!current || _disposed) return;
      await _db
          .collection('_windows_developer_inbox_read')
          .doc(row['key'] as String)
          .delete();
    }
    for(final row in stale){_read.remove(row['key']);_pendingRead.remove(receiptRevision(row));}
    messages.removeWhere(complaintExpired);
  }

  Future<void> resolve(
    Map<String, dynamic> row,
    String status,
    String reply,
  ) async {
    if (!current) throw StateError('School changed.');
    await SchoolSupportClient().call('managed/support/resolve', {
      'complaintId': row['complaintId'],
      'status': status,
      'reply': reply,
    });
    await refresh();
  }

  void _sort() => messages.sort(
    (a, b) => (b['createdAt'] as int).compareTo(a['createdAt'] as int),
  );
  Future<Map<String, dynamic>> _page(String audience, String? cursor) async {
    if (readPage != null) return readPage!(audience, cursor);
    if(_legacyScript){
      await _requireLegacyIdentity();
      final out=await SchoolSupportClient().call('managed/support/announcements',{'audience':audience,if(cursor!=null)'cursor':cursor});
      await _requireLegacyIdentity();
      return out;
    }
    final saved = await CentralSchoolCloud.saved();
    if (!current ||
        saved['schoolId'] != _school ||
        saved['uid'] != _uid ||
        saved.isEmpty)
      throw StateError(
        'Sign in to the current school to read developer notifications.',
      );
    final token = await CentralSchoolCloud.firebaseToken();
    final uri =
        Uri.parse(
          '$platformFirestoreUrl/platform_developer_notifications/$audience/messages',
        ).replace(
          queryParameters: {
            'pageSize': '50',
            'orderBy': 'createdAt desc',
            if (cursor != null) 'pageToken': cursor,
          },
        );
    final response = await _client
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200)
      throw StateError(
        'Developer notifications could not be refreshed. Try again.',
      );
    final result = jsonDecode(response.body);
    if (result is! Map) throw StateError('Invalid notification response.');
    return Map<String, dynamic>.from(result);
  }

  Future<List<Map<String,dynamic>>> _fetchComplaints(SchoolSupportClient support) async {
    if(readComplaints==null && !_legacyScript && (_feedRetryAfter==null||DateTime.now().isAfter(_feedRetryAfter!))){
      try{
        final response=await support.call('managed/support/changes',{
          if(_supportCursor!=null)'cursor':_supportCursor,
        });
        if(response['fallback']!=true){
          final cursor=response['cursor'],reset=response['reset'],rows=response['complaints'],removed=response['removed'];
          if(cursor is! String||!RegExp(r'^[a-f0-9-]{36}:[0-9]{1,15}$').hasMatch(cursor)||
            reset is! bool||rows is! List||removed is! List||(!reset&&_supportCursor==null))throw StateError('Invalid support changes.');
          final merged=reset?<String,Map<String,dynamic>>{}:Map<String,Map<String,dynamic>>.of(_supportRows);
          for(final id in removed){if(id is! String)throw StateError('Invalid removed ticket.');merged.remove(id);}
          for(final raw in rows){
            if(raw is! Map||raw['schoolId']!=_school||raw['id'] is! String)throw StateError('Foreign support ticket.');
            merged[raw['id'] as String]=Map<String,dynamic>.from(raw);
          }
          if(merged.length>500)throw StateError('Support feed exceeds limit.');
          if(!current||_disposed)throw StateError('School changed.');
          _supportRows=merged;_supportCursor=cursor;_complaintPages={};_feedRetryAfter=null;
          return merged.values.toList();
        }
      }catch(_){/* older server or lost listener; use authoritative paginated list */}
      _supportCursor=null;_supportRows={};
      _feedRetryAfter=DateTime.now().add(const Duration(minutes:5));
    }
    final result=<Map<String,dynamic>>[];
    final nextPages=<String,Map<String,dynamic>>{};
    final seen=<String>{};
    String? cursor;
    do{
      final pageKey=cursor??'';
      if(!seen.add(pageKey))throw StateError('Repeated ticket cursor.');
      final previousPage=_complaintPages[pageKey];
      final revision=previousPage?['revision'];
      final out=readComplaints!=null?await readComplaints!(cursor):await support.call('managed/support/list',{
        if(cursor!=null)'cursor':cursor,
        if(revision is String)'ifRevision':revision,
      });
      if(!current||_disposed)throw StateError('School changed.');
      final pageRows=out['unchanged']==true ? (previousPage?['complaints']) : out['complaints'];
      if(pageRows is! List)throw StateError('Invalid conditional ticket response.');
      if(out['unchanged']==true && (out['revision']!=(previousPage?['revision']) || out['cursor']!=(previousPage?['cursor'])))throw StateError('Ticket revision mismatch.');
      nextPages[pageKey]={'complaints':pageRows,'revision':out['revision'],'cursor':out['cursor']};
      for(final raw in pageRows){
        if(raw is! Map||raw['schoolId']!=_school||raw['id'] is! String)throw StateError('Foreign support ticket.');
        result.add(Map<String,dynamic>.from(raw));
      }
      cursor=out['cursor'] as String?;
    }while(cursor!=null);
    _complaintPages=nextPages;
    return result;
  }

  Future<void> refresh({bool more = false, bool announcementsOnly = false}) async {
    if (busy || !current || _disposed || _school == null || _school!.isEmpty)
      return;
    busy = true;
    error = null;
    _notify();
    try {
      final updates = <Map<String, dynamic>>[];
      final next = <String, String?>{};
      for (final audience in ['all', _school!]) {
        if (more && _loaded && _cursors[audience] == null) continue;
        final page = await _page(audience, more ? _cursors[audience] : null);
        if (!current || _disposed) return;
        final saved = await CentralSchoolCloud.saved();
        if(_legacyScript)await _requireLegacyIdentity();
        if (readPage == null && !_legacyScript &&
            (saved['uid'] != _uid || saved['schoolId'] != _school))
          throw StateError('School account changed. Reopen notifications.');
        final docs = page['documents'] ?? [];
        if (docs is! List) throw StateError('Invalid notification page.');
        for (final doc in docs) {
          final fields = doc is Map ? doc['fields'] : null;
          final name = doc is Map ? doc['name'] : null;
          final prefix =
              'projects/$platformProjectId/databases/(default)/documents/platform_developer_notifications/$audience/messages/';
          if (fields is! Map || name is! String || !name.startsWith(prefix))
            throw StateError('Notification identity mismatch.');
          final id = name.substring(prefix.length);
          final title = fields['title']?['stringValue'];
          final message = fields['message']?['stringValue'];
          final created = DateTime.tryParse(
            fields['createdAt']?['timestampValue']?.toString() ?? '',
          );
          if (id.isEmpty ||
              id.contains('/') ||
              title is! String ||
              title.isEmpty ||
              title.length > 160 ||
              message is! String ||
              message.isEmpty ||
              message.length > 5000 ||
              created == null ||
              fields['audience']?['stringValue'] != audience)
            throw StateError('Invalid developer notification.');
          updates.add({
            'key': '$audience--$id',
            'schoolId': _school,
            'audience': audience,
            'title': title,
            'message': message,
            'createdAt': created.millisecondsSinceEpoch,
          });
        }
        final cursor = page['nextPageToken'];
        if (cursor != null && (cursor is! String || cursor.isEmpty))
          throw StateError('Invalid notification cursor.');
        next[audience] = cursor as String?;
      }
      if (!current || _disposed) return;
      if ((readPage == null || readComplaints != null) && !more && !announcementsOnly) {
        final support = SchoolSupportClient();
        final tickets = <Map<String,dynamic>>[];
        final complaintRows=await _fetchComplaints(support);
        if(_legacyScript)await _requireLegacyIdentity();
        if(!current||_disposed)return;
        for(final row in complaintRows){
            if (row['schoolId'] != _school)
              throw StateError('Complaint school mismatch.');
            if (complaintExpired(row)) continue;
            if (row['audience'] != 'school') {
              tickets.add(row);
              final note = row['developerNote']?.toString().trim() ?? '';
              final status = row['status']?.toString() ?? 'open';
              if (note.isEmpty && status == 'open') continue;
              updates.add({
                ...row,
                'key': 'support--${row['id']}',
                'complaintId': row['id'],
                'kind': 'support',
                'title': 'Support • $status',
                'message': note.isNotEmpty ? note : 'Ticket status: $status',
                'ticketMessage': row['message'],
                'createdAt': complaintMillis(row['developerUpdatedAt']) > 0
                  ? complaintMillis(row['developerUpdatedAt'])
                  : complaintMillis(row['updatedAt']) > 0
                    ? complaintMillis(row['updatedAt']) : complaintMillis(row['createdAt']),
              });
              continue;
            }
            updates.add({
              ...row,
              'key': 'complaint--${row['id']}',
              'complaintId': row['id'],
              'title':
                  '${row['studentName']} • Class ${row['studentClass']} • ${row['status']}',
              'message':
                  '${row['message']}\n\nClass: ${row['studentClass']} • Roll: ${row['rollNo']}\nDevice (reported): ${row['device']}\nDevice ID: ${row['deviceId']}\nApp: ${row['version']}',
            });
        }
        if (!current || _disposed) return;
        _tickets = tickets..sort((a,b) => complaintMillis(b['createdAt']).compareTo(complaintMillis(a['createdAt'])));
        final live = updates.map((row) => row['key']).toSet();
        for (final row
            in messages
                .where(
                  (row) =>
                      row['complaintId'] != null && !live.contains(row['key']),
                )
                .toList()) {
          if (!current || _disposed) return;
          await _db
              .collection('_windows_developer_inbox')
              .doc(row['key'] as String)
              .delete();
          if (!current || _disposed) return;
          await _db
              .collection('_windows_developer_inbox_read')
              .doc(row['key'] as String)
              .delete();
          messages.remove(row);
          _read.remove(row['key']);
          _pendingRead.remove(receiptRevision(row));
        }
      }
      await _purgeExpired();
      if (!current || _disposed) return;
      final existing = {for (final m in messages) m['key']: m};
      final changed = updates
          .where(
            (m) =>
                existing[m['key']] == null ||
                m.entries.any((e) => existing[m['key']]![e.key] != e.value),
          )
          .toList();
      if (changed.isNotEmpty) {
        final batch = _db.batch();
        for (final m in changed) {
          batch.set(
            _db.collection('_windows_developer_inbox').doc(m['key'] as String),
            m,
          );
        }
        await batch.commit();
        if (!current || _disposed) return;
        for (final m in changed) {
          final previous = existing[m['key']];
          if (previous == null) continue;
          final changedContent=receiptRevision(previous)!=receiptRevision(m);
          if (changedContent && _read.containsKey(m['key'])) {
            if (!current || _disposed) return;
            await _db.collection('_windows_developer_inbox_read').doc(m['key'] as String).delete();
            _read.remove(m['key']);
            _pendingRead.remove(receiptRevision(previous));
          }
        }
      }
      if (!current || _disposed) return;
      final merged = {
        for (final m in messages) m['key']: m,
        for (final m in updates) m['key']: m,
      };
      messages = merged.values.toList();
      // Restart pagination at the fresh head; cached messages deduplicate by ID.
      _cursors.addAll(next);
      _loaded = true;
      _sort();
      final changedRevisions = changed.where((m) =>
        existing[m['key']] == null || receiptRevision(existing[m['key']]!) != receiptRevision(m)).toList();
      if(!announcementsOnly) {
        try{await _syncReadReceipts();}catch(_){/* retain local read receipts for retry */}
      }
      if (!current || _disposed) return;
      final shouldSound = _soundBaselineEstablished && !more &&
        changedRevisions.any((m) => !complaintExpired(m) && !isRead(m));
      if (!more) _soundBaselineEstablished = true;
      if (shouldSound) {
        final player = playNotificationSound ?? (readPage == null && readComplaints == null ? WindowsNotificationSound.playIfEnabled : null);
        if (player != null) unawaited(_playQuietly(player));
      }
    } catch (e) {
      if (current && !_disposed)
        error = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _playQuietly(Future<void> Function() player) async {
    try { await player(); } catch (_) { /* audio must never block notification delivery */ }
  }

  Future<void> markAllLoadedRead() async {
    for (final row in List<Map<String,dynamic>>.of(messages)) {
      if (!current || _disposed) return;
      if (!complaintExpired(row)) await markRead(row, sync: false);
    }
    if (current && !_disposed) unawaited(_flushReadQuietly());
  }

  Future<void> _flushReadQuietly() async {
    try { await _syncReadReceipts(); } catch (_) { /* durable local receipt retained */ }
    _notify();
  }

  Future<void> markRead(Map<String, dynamic> message, {bool sync = true}) async {
    if (!current ||
        _disposed ||
        isRead(message) ||
        !messages.any((m) => m['key'] == message['key'] && receiptRevision(m)==receiptRevision(message)))
      return;
    try {
      await _db
          .collection('_windows_developer_inbox_read')
          .doc(message['key'] as String)
          .set({'readAt': DateTime.now().millisecondsSinceEpoch,'revision':receiptRevision(message),'pending':true});
      if (!current || _disposed) return;
      _read[message['key'] as String]=receiptRevision(message);
      _pendingRead.add(receiptRevision(message));
      _notify();
      if (sync) await _flushReadQuietly();
    } catch (_) {
      if (current && !_disposed) {
        error = 'Read status could not be saved. Try again.';
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }
}

class DeveloperInboxScreen extends StatefulWidget {
  const DeveloperInboxScreen({super.key, required this.inbox});
  final DeveloperInbox inbox;
  @override
  State<DeveloperInboxScreen> createState() => _DeveloperInboxScreenState();
}

class _DeveloperInboxScreenState extends State<DeveloperInboxScreen> {
  String _tab = 'announcement';
  DeveloperInbox get inbox => widget.inbox;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: inbox,
    builder: (context, _) {
      final visible = inbox.messages.where((m) => DeveloperInbox.kind(m) == _tab && !complaintExpired(m)).toList();
      return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            tooltip: 'Mark all loaded notifications as read',
            onPressed: inbox.unread == 0 ? null : () => inbox.markAllLoadedRead(),
            icon: const Icon(Icons.done_all),
          ),
          IconButton(
            tooltip: 'Notification sound settings',
            onPressed: () => showDialog<void>(context: context, builder: (ctx) => const AlertDialog(title: Text('Notification sound'), content: SizedBox(width: 380, child: WindowsNotificationSoundCard()))),
            icon: const Icon(Icons.volume_up_outlined),
          ),
          IconButton(
            tooltip: 'Refresh notifications',
            onPressed: inbox.busy ? null : () => inbox.refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !inbox.current
          ? const Center(child: Text('School changed. Reopen this page.'))
          : Column(
              children: [
                Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 8, runSpacing: 6, children: [
                  for (final tab in ['announcement','support','student'])
                    ChoiceChip(selected: _tab == tab,
                      label: Text('${tab == 'announcement' ? 'Announcements' : tab == 'support' ? 'Support Replies' : 'Student Complaints'} (${inbox.unreadFor(tab)})'),
                      onSelected: (_) => setState(() => _tab = tab)),
                ])),
                if (inbox.busy) const LinearProgressIndicator(),
                if (inbox.error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(inbox.error!),
                  ),
                Expanded(
                  child: visible.isEmpty && !(inbox.hasMore && _tab == 'announcement')
                      ? Center(
                          child: Text(
                            inbox.busy
                                ? 'Loading notifications…'
                                : 'No notifications yet.',
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(20),
                          itemCount: visible.length + 1,
                          itemBuilder: (context, index) {
                            if (index == visible.length)
                              return inbox.hasMore && _tab == 'announcement'
                                  ? TextButton(
                                      onPressed: inbox.busy
                                          ? null
                                          : () => inbox.refresh(more: true),
                                      child: const Text(
                                        'Load older notifications',
                                      ),
                                    )
                                  : const SizedBox(height: 20);
                            final m = visible[index], read = inbox.isRead(visible[index]);
                            return Card(
                              child: ListTile(
                                leading: Icon(
                                  read
                                      ? Icons.notifications_none
                                      : Icons.notifications_active,
                                ),
                                title: Text(
                                  m['title'] as String,
                                  style: TextStyle(fontFamily: 'Segoe UI', 
                                    fontWeight: read
                                        ? FontWeight.normal
                                        : FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  '${formatNoticeIst(noticeMillis(m['createdAt']))} • ${DeveloperInbox.kind(m) == 'student' ? 'School complaint' : 'Developer'}',
                                ),
                                trailing: read ? null : const Badge(),
                                onTap: () async {
                                  if (!inbox.current) return;
                                  unawaited(inbox.markRead(m));
                                  if (DeveloperInbox.kind(m) == 'support') {
                                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) =>
                                      WindowsComplaintThread(client: SchoolSupportClient(), onResolved: inbox.acceptResolvedTicket, complaint: {
                                        ...m, 'id': m['complaintId'], 'message': m['ticketMessage'],
                                      })));
                                    return;
                                  }
                                  if (m['complaintId'] != null) {
                                    final reply = TextEditingController(
                                      text: m['schoolReply']?.toString() ?? '',
                                    );
                                    String status =
                                        m['status']?.toString() ?? 'open';
                                    bool saving = false;
                                    String? failure;
                                    await showDialog<void>(
                                      context: context,
                                      barrierDismissible: false,
                                      builder: (ctx) => StatefulBuilder(
                                        builder: (ctx, update) => AlertDialog(
                                          title: Text(m['title'] as String),
                                          content: SizedBox(
                                            width: 520,
                                            child: SingleChildScrollView(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  SelectableText(
                                                    m['message'] as String,
                                                  ),
                                                  DropdownButtonFormField<
                                                    String
                                                  >(
                                                    value: status,
                                                    items: [
                                                      for (final value in [
                                                        'open',
                                                        'in_progress',
                                                        'resolved',
                                                      ])
                                                        DropdownMenuItem(
                                                          value: value,
                                                          child: Text(value),
                                                        ),
                                                    ],
                                                    onChanged: saving
                                                        ? null
                                                        : (value) => update(
                                                            () =>
                                                                status = value!,
                                                          ),
                                                  ),
                                                  TextField(
                                                    controller: reply,
                                                    enabled: !saving,
                                                    maxLength: 3000,
                                                    minLines: 2,
                                                    maxLines: 5,
                                                    decoration:
                                                        const InputDecoration(
                                                          labelText:
                                                              'Reply to student',
                                                        ),
                                                  ),
                                                  if (failure != null)
                                                    Text(failure!),
                                                ],
                                              ),
                                            ),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: saving
                                                  ? null
                                                  : () => Navigator.pop(ctx),
                                              child: const Text('Close'),
                                            ),
                                            FilledButton(
                                              onPressed: saving
                                                  ? null
                                                  : () async {
                                                      update(
                                                        () => saving = true,
                                                      );
                                                      try {
                                                        await inbox.resolve(
                                                          m,
                                                          status,
                                                          reply.text,
                                                        );
                                                        if (ctx.mounted)
                                                          Navigator.pop(ctx);
                                                      } catch (e) {
                                                        if (ctx.mounted)
                                                          update(() {
                                                            saving = false;
                                                            failure = e
                                                                .toString();
                                                          });
                                                      }
                                                    },
                                              child: const Text('Save status'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                    await Future<void>.delayed(
                                      const Duration(milliseconds: 300),
                                    );
                                    reply.dispose();
                                    return;
                                  }
                                  await showDialog<void>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: Text(m['title'] as String),
                                      content: SingleChildScrollView(
                                        child: SelectableText(
                                          m['message'] as String,
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: const Text('Close'),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    ); },
  );
}
