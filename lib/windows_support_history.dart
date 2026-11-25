import 'complaint_retention.dart';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as support_crypto;
import 'windows_secure_storage.dart';
import 'notice_time.dart';
import 'dart:math';

import 'package:flutter/material.dart';

import 'windows_appearance.dart';
import 'windows_local_firestore.dart' as local;
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';

class SchoolSupportClient {
  SchoolSupportClient({this.readIdentity, this.request});
  final Future<Map<String,dynamic>> Function()? readIdentity;
  final Future<Map<String,dynamic>> Function(String school, String action, Map<String,dynamic> body)? request;
  final String _profile = local.FirebaseFirestore.instance.activeProfileId;
  String? _school, _uid;
  bool? _managed;
  static final _flushing = <String>{};
  static const _queue = '_windows_support_outbox';
  static final _attachmentKeys = <String,Future<support_crypto.SecretKey>>{};
  static final _attachmentCipher = support_crypto.AesGcm.with256bits();

  Future<support_crypto.SecretKey> _attachmentKey({required bool create}) async {
    await _bind();
    final scope=sha256.convert(utf8.encode(jsonEncode([_profile,_school,_uid]))).toString();
    final name='vs_support_attachment_key_$scope';
    final existing=_attachmentKeys[name];
    if(existing!=null)return existing;
    final future=()async{
      final storage=const WindowsSecureStorage();
      final raw=await storage.read(key:name);
      if(raw!=null){
        final bytes=base64Decode(raw);
        if(bytes.length!=32)throw StateError('Support attachment key is unavailable.');
        return support_crypto.SecretKey(bytes);
      }
      if(!create)throw StateError('Attachment belongs to another PC or local key is unavailable.');
      final key=await _attachmentCipher.newSecretKey();
      await storage.write(key:name,value:base64Encode(await key.extractBytes()));
      return key;
    }();
    _attachmentKeys[name]=future;
    try{return await future;}catch(_){_attachmentKeys.remove(name);rethrow;}
  }

  List<int> _attachmentAad(String id)=>utf8.encode(jsonEncode([_school,_uid,id]));

  Future<Map<String,dynamic>> _sealScreenshot(String id,String screenshot)async{
    final key=await _attachmentKey(create:true);
    final box=await _attachmentCipher.encrypt(utf8.encode(screenshot),secretKey:key,aad:_attachmentAad(id));
    return {'ciphertext':base64Encode(box.cipherText),'nonce':base64Encode(box.nonce),'mac':base64Encode(box.mac.bytes)};
  }

  Future<String?> _openQueuedScreenshot(Map<String,dynamic> row)async{
    final raw=row['sealedScreenshot'];
    if(raw==null)return row['screenshot'] as String?; // pre-release draft compatibility
    if(raw is! Map)throw StateError('Invalid queued screenshot.');
    final key=await _attachmentKey(create:false);
    final box=support_crypto.SecretBox(base64Decode(raw['ciphertext'] as String),
      nonce:base64Decode(raw['nonce'] as String),mac:support_crypto.Mac(base64Decode(raw['mac'] as String)));
    return utf8.decode(await _attachmentCipher.decrypt(box,secretKey:key,aad:_attachmentAad(row['id'] as String)));
  }
  static String randomId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  bool get current =>
      _profile == local.FirebaseFirestore.instance.activeProfileId &&
      (_school == null ||
          _school ==
              local
                  .FirebaseFirestore
                  .instance
                  .activeProfileIdentity['schoolSyncId']);
  Future<void> _bind() async {
    final saved = await (readIdentity ?? CentralSchoolCloud.saved)();
    if (local.FirebaseFirestore.instance.activeProfileId != _profile ||
        saved.isEmpty ||
        local
                .FirebaseFirestore
                .instance
                .activeProfileIdentity['schoolSyncId'] !=
            saved['schoolId'] ||
        (_school != null &&
            (_school != saved['schoolId'] || _uid != saved['uid'] || _managed != (saved['managed'] == true))))
      throw StateError('School account changed. Reopen complaint history.');
    _school ??= saved['schoolId']?.toString();
    _uid ??= saved['uid']?.toString();
    _managed ??= saved['managed'] == true;
    if (_school == null || _uid == null)
      throw StateError('School login required');
  }

  Future<Map<String, dynamic>> call(
    String action,
    Map<String, dynamic> body,
  ) async {
    await _bind();
    final Map<String,dynamic> out;
    if (request != null) {
      out = await request!(_school!, action, body);
    } else if (_managed == true) {
      out = await ManagedSchoolSession.callForSchool(_school, action, body);
    } else {
      final saved = await CentralSchoolCloud.saved();
      await _bind();
      final cloud = CentralSchoolCloud(endpoint: saved['endpoint'].toString(), expectedSchoolId: _school);
      try {
        final token = await CentralSchoolCloud.firebaseToken();
        await _bind();
        out = await cloud.api({'action':action.replaceFirst('managed/',''),'schoolId':_school,...body}, token:token);
      } finally { cloud.close(); }
    }
    await _bind();
    if (out['success'] != true || out['schoolId'] != _school)
      throw StateError('Complaint response could not be verified.');
    return out;
  }

  // Persist immutable requests before network admission; internal collections
  // do not enter ordinary school record synchronization.
  Future<String> enqueue(String message, String version, {String? complaintId, String? screenshot}) async {
    await _bind();
    final text = message.trim();
    if (text.length < (complaintId == null ? 10 : 3) || text.length > 3000) {
      throw StateError('Invalid complaint or reply length.');
    }
    if (screenshot != null && (complaintId != null || screenshot.length > 131072)) throw StateError('Invalid screenshot size.');
    final id = complaintId == null ? '${_school}_${randomId()}'
        : '${DateTime.now().millisecondsSinceEpoch}_${randomId()}';
    final sealed=screenshot==null?null:await _sealScreenshot(id,screenshot);
    await _bind();
    final ref = local.FirebaseFirestore.instance.collection(_queue).doc(id);
    await local.WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() => ref.set({
      'id': id, 'schoolId': _school, 'uid': _uid, 'complaintId': complaintId ?? id,
      'message': text, 'version': version, 'kind': complaintId == null ? 'create' : 'reply',
      if (sealed != null) 'sealedScreenshot': sealed,
      'createdAt': DateTime.now().millisecondsSinceEpoch, 'delivery': 'pending',
    }));
    await _bind();
    return id;
  }

  Future<List<Map<String,dynamic>>> pending() async {
    await _bind();
    final snapshot = await local.FirebaseFirestore.instance.collection(_queue).get();
    await _bind();
    return snapshot.docs.map((d) => d.data()).where((r) =>
      r['schoolId'] == _school && r['uid'] == _uid && r['id'] is String &&
      r['message'] is String && (r['kind'] == 'create' || r['kind'] == 'reply')).toList()
      ..sort((a,b) => _at(a['createdAt']).compareTo(_at(b['createdAt'])));
  }

  // One request per pass; ambiguous delivery retries the original identity.
  Future<void> flushPending({bool retryFailed = false}) async {
    await _bind();
    final scope = '$_profile:$_school:$_uid';
    if (!_flushing.add(scope)) return;
    try {
      final eligible = (await pending()).where((r) =>
        r['delivery'] == 'pending' || retryFailed && r['delivery'] == 'failed');
      if (eligible.isEmpty) return;
      final row = eligible.first;
      final id = row['id'] as String;
      final ref = local.FirebaseFirestore.instance.collection(_queue).doc(id);
      await _bind();
      try {
        final create = row['kind'] == 'create';
        String? screenshot;
        try{ screenshot=await _openQueuedScreenshot(row); }catch(_){
          await _bind();
          await local.WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>ref.set({'delivery':'failed','attachmentUnavailable':true},const local.SetOptions(merge:true)));
          return;
        }
        final out = await call(create ? (screenshot == null ? 'managed/support/create' : 'managed/support/createWithScreenshot') : 'managed/support/reply', {
          'complaintId': row['complaintId'],
          if (!create) 'messageId': id,
          'message': row['message'],
          if (create) 'version': row['version'],
          if (create && screenshot != null) 'screenshot': screenshot,
        });
        if (out['complaintId'] != row['complaintId'] || !create && out['messageId'] != id || screenshot != null && out['screenshotSha256'] != sha256.convert(base64Decode(screenshot)).toString()) {
          throw StateError('Complaint receipt identity could not be verified.');
        }
        await _bind();
        await local.WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(ref.delete);
      } catch (e) {
        await _bind();
        final rejected = e is CentralCloudException && {400,404,409,413,422}.contains(e.status);
        await local.WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() =>
          ref.set({'delivery': rejected ? 'failed' : 'pending',
            'lastAttemptAt': DateTime.now().millisecondsSinceEpoch},
            const local.SetOptions(merge: true)));
      }
    } finally { _flushing.remove(scope); }
  }

  Future<bool> send(String message, String version, {String? screenshot}) async {
    final id = await enqueue(message, version, screenshot: screenshot);
    await flushPending();
    return !(await pending()).any((r) => r['id'] == id);
  }

  Future<bool> sendReply(String complaintId, String message) async {
    final id = await enqueue(message, '', complaintId: complaintId);
    await flushPending();
    return !(await pending()).any((r) => r['id'] == id);
  }

  static bool developerTicket(Map row) => row['audience'] != 'school';

  Future<Map<String,dynamic>> page({String? cursor}) async {
    final out = await call('managed/support/list', {if (cursor != null) 'cursor': cursor});
    final rows = (out['complaints'] as List).map((r) =>
      Map<String,dynamic>.from(r as Map)).where(developerTicket).toList();
    await cache(rows);
    return {'rows': rows, 'cursor': out['cursor']};
  }

  Future<List<Map<String, dynamic>>> cached() async {
    await _bind();
    final snapshot = await local.FirebaseFirestore.instance
        .collection('_windows_support_history')
        .get();
    await _bind();
    for (final doc in snapshot.docs) {
      await _bind();
      if (complaintExpired(doc.data()))
        await local.FirebaseFirestore.instance
            .collection('_windows_support_history')
            .doc(doc.id)
            .delete();
    }
    return snapshot.docs
        .map((d) => d.data())
        .where((d) => d['schoolId'] == _school && developerTicket(d) && !complaintExpired(d))
        .toList();
  }

  Future<List<Map<String, dynamic>>> refreshAll() async {
    final rows = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final out = await call('managed/support/list', {
        if (cursor != null) 'cursor': cursor,
      });
      rows.addAll((out['complaints'] as List).map((r) => Map<String,dynamic>.from(r as Map)).where(developerTicket));
      cursor = out['cursor'] as String?;
    } while (cursor != null);
    final ids = rows.map((r) => r['id']).toSet();
    for (final old in await cached()) {
      await _bind();
      if (!ids.contains(old['id']))
        await local.FirebaseFirestore.instance
            .collection('_windows_support_history')
            .doc(old['id'] as String)
            .delete();
    }
    await cache(rows);
    return rows;
  }

  Future<void> cache(List<Map<String, dynamic>> rows) async {
    await _bind();
    for (final row in rows) {
      if (complaintExpired(row)) continue;
      if (row['schoolId'] != _school || row['id'] is! String)
        throw StateError('Complaint school mismatch');
      await local.FirebaseFirestore.instance
          .collection('_windows_support_history')
          .doc(row['id'] as String)
          .set(row);
      await _bind();
    }
  }
}

class WindowsComplaintHistory extends StatefulWidget {
  const WindowsComplaintHistory({super.key});
  @override
  State<WindowsComplaintHistory> createState() =>
      _WindowsComplaintHistoryState();
}

class _WindowsComplaintHistoryState extends State<WindowsComplaintHistory> {
  final client = SchoolSupportClient();
  final rows = <String, Map<String, dynamic>>{};
  bool busy = false;
  String? error, cursor;
  List<Map<String,dynamic>> queued = [];
  String filter = 'all', search = '';
  @override
  void initState() {
    super.initState();
    _load(initial: true);
  }

  Future<void> _load({bool more = false, bool initial = false}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (initial) {
        for (final r in await client.cached()) rows[r['id'] as String] = r;
        queued = await client.pending();
        if (mounted) setState(() {});
      }
      final localQueue = await client.pending();
      if (mounted) setState(() => queued = localQueue);
      final page = await client.page(cursor: more ? cursor : null);
      if (!mounted) return;
      setState(() {
        if (!more && page['cursor'] == null) rows.clear();
        for (final r in page['rows'] as List<Map<String,dynamic>>) rows[r['id'] as String] = r;
        cursor = page['cursor'] as String?;
        error = null;
      });
    } catch (e) {
      if (mounted)
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    if (!client.current)
      return const Scaffold(
        body: Center(child: Text('School changed. Reopen complaint history.')),
      );
    final items = rows.values.where((row) => !complaintExpired(row) && (filter == 'all' || row['status'] == filter) && '${row['id']} ${row['message']}'.toLowerCase().contains(search.toLowerCase())).toList()
      ..sort((a, b) => _at(b['createdAt']).compareTo(_at(a['createdAt'])));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Complaint history'),
        actions: [
          IconButton(
            onPressed: busy ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(error!, style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.orangeAccent))),
          TextField(onChanged: (v) => setState(() => search = v),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Search loaded tickets')),
          Wrap(spacing: 8, children: [
            for (final status in ['all','open','in_progress','resolved'])
              ChoiceChip(label: Text(status.replaceAll('_',' ')), selected: filter == status,
                onSelected: (_) => setState(() => filter = status)),
          ]),
          if (queued.isNotEmpty) ...[
            TextButton.icon(onPressed: busy ? null : () async {
              try { await client.flushPending(retryFailed: true); } catch (_) {}
              if (mounted) await _load();
            }, icon: const Icon(Icons.refresh), label: const Text('Retry pending support messages')),
            for (final q in queued) Card(child: ListTile(
              leading: Icon(q['delivery'] == 'failed' ? Icons.error_outline : Icons.schedule),
              title: Text(q['message'].toString()),
              subtitle: Text(q['attachmentUnavailable']==true?'Failed — screenshot key unavailable on this PC':q['delivery'] == 'failed' ? 'Failed — retained locally' : 'Pending — saved locally'),
            )),
          ],
          if (items.isEmpty && queued.isEmpty && !busy)
            const Text('No matching complaints found for this school.'),
          for (final r in items)
            Card(
              child: ListTile(
                title: Text(r['message']?.toString() ?? ''),
                subtitle: Text(
                  'Ticket ${r['id']}\n${_date(r['createdAt'])} • ${r['status'] ?? 'open'}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.push(context, MaterialPageRoute(
                    builder: (_) => WindowsComplaintThread(client: client, complaint: r)));
                  if (mounted) await _load();
                },
              ),
            ),
          if (cursor != null)
            TextButton(
              onPressed: busy ? null : () => _load(more: true),
              child: const Text('Load more complaints'),
            ),
        ],
      ),
    );
  }
}

int _at(dynamic value) => value is num
    ? value.toInt()
    : DateTime.tryParse(value?.toString() ?? '')?.millisecondsSinceEpoch ?? 0;
String _date(dynamic value) {
  final at = _at(value);
  return formatNoticeIst(noticeMillis(at));
}

class WindowsComplaintThread extends StatefulWidget {
  const WindowsComplaintThread({super.key, required this.client, required this.complaint});
  final SchoolSupportClient client;
  final Map<String, dynamic> complaint;
  @override
  State<WindowsComplaintThread> createState() => WindowsComplaintThreadState();
}

class WindowsComplaintThreadState extends State<WindowsComplaintThread> {
  final message = TextEditingController();
  final rows = <String, Map<String, dynamic>>{};
  bool busy = false;
  String? error, cursor;
  Timer? _poll;
  List<Map<String,dynamic>> queued = [];
  late Map<String, dynamic> complaint;
  @override
  void initState() {
    super.initState();
    complaint = widget.complaint;
    _load();
    _poll = Timer.periodic(const Duration(minutes: 1), (_) { if (mounted && !busy) unawaited(_load()); });
  }

  @override
  void dispose() {
    _poll?.cancel();
    message.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final localQueue = await widget.client.pending();
      if (mounted) setState(() => queued = localQueue.where((r) => r['kind'] == 'reply' && r['complaintId'] == complaint['id']).toList());
      if (complaint['schoolId'] != local.FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] || !SchoolSupportClient.developerTicket(complaint)) throw StateError('School ticket identity mismatch.');
      final out = await widget.client.call('managed/support/thread', {
        'complaintId': complaint['id'],
        if (more && cursor != null) 'cursor': cursor,
      });
      if (!mounted) return;
      setState(() {
        complaint = Map<String, dynamic>.from(out['complaint']);
        for (final r in out['messages'] as List)
          rows[r['id'] as String] = Map<String, dynamic>.from(r);
        cursor = out['cursor'] as String?;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _openScreenshot() async {
    try {
      final out = await widget.client.call('managed/support/attachment', {'complaintId':complaint['id']});
      final encoded = out['screenshot'];
      if (encoded is! String || encoded.length > 131072 || out['complaintId'] != complaint['id']) throw StateError('Invalid screenshot');
      final bytes = base64Decode(encoded);
      if (sha256.convert(bytes).toString() != out['screenshotSha256']) throw StateError('Screenshot verification failed.');
      if (!mounted || !widget.client.current) return;
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Ticket screenshot'),
        content:SizedBox(width:700,child:Image.memory(bytes,fit:BoxFit.contain,errorBuilder:(_,__,___)=>const Text('Screenshot could not be displayed.'))),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))],
      ));
    } catch (_) { if(mounted) setState(()=>error='Screenshot unavailable. Try again.'); }
  }

  Future<void> _send() async {
    final text = message.text.trim();
    if (text.length < 3) return;
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      final sent = await widget.client.sendReply(complaint['id'] as String, text);
      if (!mounted) return;
      if (message.text.trim() == text) message.clear();
      if (!sent) error = 'Reply saved locally. Delivery is pending.';
    } catch (_) {
      if (mounted) error = 'Could not save the reply. Your text is retained.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    if (!widget.client.current || complaint['schoolId'] != local.FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'])
      return const Scaffold(
        body: Center(child: Text('School changed. Reopen complaint history.')),
      );
    final items = rows.values.where((row) => !complaintExpired(row)).toList()
      ..sort((a, b) => _at(a['createdAt']).compareTo(_at(b['createdAt'])));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Complaint conversation'),
        actions: [
          IconButton(
            onPressed: busy ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Ticket ${complaint['id']}'),
          if (complaint['hasScreenshot'] == true) TextButton.icon(onPressed: busy ? null : _openScreenshot, icon:const Icon(Icons.image_outlined),label:const Text('View screenshot')),
          Text('${complaint['status']} • ${_date(complaint['createdAt'])}'),
          if (complaint['status'] == 'resolved') const Text('Sending another reply will reopen this ticket.'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(complaint['message']?.toString() ?? ''),
            ),
          ),
          if (complaint['supportHistoryVersion'] != 1 &&
              (complaint['developerNote']?.toString() ?? '').isNotEmpty)
            ListTile(
              title: const Text('Developer'),
              subtitle: SelectableText(complaint['developerNote'].toString()),
            ),
          for (final r in items)
            Card(
              child: ListTile(
                title: Text(
                  '${r['role'] == 'developer' ? 'Developer' : 'School'} • ${_date(r['createdAt'])}',
                ),
                subtitle: SelectableText(r['message']?.toString() ?? ''),
              ),
            ),
          if (cursor != null)
            TextButton(
              onPressed: busy ? null : () => _load(more: true),
              child: const Text('Load more messages'),
            ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(error!, style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.orangeAccent))),
          for (final q in queued) Card(child: ListTile(title: Text(q['message'].toString()), subtitle: Text(q['delivery'] == 'failed' ? 'Failed — retained locally' : 'Pending — saved locally'))),
          TextField(
            enabled: !busy,
            controller: message,
            maxLength: 3000,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(labelText: 'Reply to developer'),
          ),
          FilledButton(
            onPressed: busy ? null : _send,
            child: const Text('Send reply'),
          ),
        ],
      ),
    );
  }
}
