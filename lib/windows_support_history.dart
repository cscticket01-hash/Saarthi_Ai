import 'complaint_retention.dart';
import 'dart:async';
import 'notice_time.dart';
import 'dart:math';

import 'package:flutter/material.dart';

import 'windows_appearance.dart';
import 'windows_local_firestore.dart' as local;
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';

class SchoolSupportClient {
  final String _profile = local.FirebaseFirestore.instance.activeProfileId;
  String? _school, _uid;
  static final _flushing = <String>{};
  static const _queue = '_windows_support_outbox';
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
    final saved = await CentralSchoolCloud.saved();
    if (local.FirebaseFirestore.instance.activeProfileId != _profile ||
        saved['managed'] != true ||
        local
                .FirebaseFirestore
                .instance
                .activeProfileIdentity['schoolSyncId'] !=
            saved['schoolId'] ||
        (_school != null &&
            (_school != saved['schoolId'] || _uid != saved['uid'])))
      throw StateError('School account changed. Reopen complaint history.');
    _school ??= saved['schoolId']?.toString();
    _uid ??= saved['uid']?.toString();
    if (_school == null || _uid == null)
      throw StateError('School login required');
  }

  Future<Map<String, dynamic>> call(
    String action,
    Map<String, dynamic> body,
  ) async {
    await _bind();
    final out = await ManagedSchoolSession.callForSchool(_school, action, body);
    await _bind();
    if (out['success'] != true || out['schoolId'] != _school)
      throw StateError('Complaint response could not be verified.');
    return out;
  }

  // Persist immutable requests before network admission; internal collections
  // do not enter ordinary school record synchronization.
  Future<String> enqueue(String message, String version, {String? complaintId}) async {
    await _bind();
    final text = message.trim();
    if (text.length < (complaintId == null ? 10 : 3) || text.length > 3000) {
      throw StateError('Invalid complaint or reply length.');
    }
    final id = complaintId == null ? '${_school}_${randomId()}'
        : '${DateTime.now().millisecondsSinceEpoch}_${randomId()}';
    final ref = local.FirebaseFirestore.instance.collection(_queue).doc(id);
    await local.WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() => ref.set({
      'id': id, 'schoolId': _school, 'uid': _uid, 'complaintId': complaintId ?? id,
      'message': text, 'version': version, 'kind': complaintId == null ? 'create' : 'reply',
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
        final out = await call(create ? 'managed/support/create' : 'managed/support/reply', {
          'complaintId': row['complaintId'],
          if (!create) 'messageId': id,
          'message': row['message'],
          if (create) 'version': row['version'],
        });
        if (out['complaintId'] != row['complaintId'] || !create && out['messageId'] != id) {
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

  Future<bool> send(String message, String version) async {
    final id = await enqueue(message, version);
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
        if (!more) rows.clear();
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
              subtitle: Text(q['delivery'] == 'failed' ? 'Failed — retained locally' : 'Pending — saved locally'),
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
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        WindowsComplaintThread(client: client, complaint: r),
                  ),
                ),
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
    if (!widget.client.current)
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
