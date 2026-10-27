import 'complaint_retention.dart';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'windows_appearance.dart';
import 'windows_local_firestore.dart' as local;
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';

class SchoolSupportClient {
  final String _profile = local.FirebaseFirestore.instance.activeProfileId;
  String? _school, _uid, _pendingId, _pendingText;
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

  Future<void> send(String message, String version) async {
    await _bind();
    if (_pendingId != null && _pendingText != message)
      throw StateError('Retry the original complaint before editing it.');
    _pendingText = message;
    _pendingId ??= '${_school}_${randomId()}';
    await call('managed/support/create', {
      'complaintId': _pendingId,
      'message': message,
      'version': version,
    });
    _pendingId = null;
    _pendingText = null;
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
        .where((d) => d['schoolId'] == _school && !complaintExpired(d))
        .toList();
  }

  Future<List<Map<String, dynamic>>> refreshAll() async {
    final rows = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final out = await call('managed/support/list', {
        if (cursor != null) 'cursor': cursor,
      });
      rows.addAll(
        (out['complaints'] as List).map(
          (r) => Map<String, dynamic>.from(r as Map),
        ),
      );
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
        if (mounted) setState(() {});
      }
      final items = await client.refreshAll();
      if (!mounted) return;
      setState(() {
        rows.clear();
        for (final r in items) rows[r['id'] as String] = r;
        cursor = null;
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
    final items = rows.values.where((row) => !complaintExpired(row)).toList()
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
            Text(error!, style: TextStyle(color: WindowsAppearance.foreground(Colors.orangeAccent))),
          if (items.isEmpty && !busy)
            const Text('No complaints found for this school.'),
          for (final r in items)
            Card(
              child: ListTile(
                title: Text(r['message']?.toString() ?? ''),
                subtitle: Text(
                  '${_date(r['createdAt'])} • ${r['status'] ?? 'open'}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        _ComplaintThread(client: client, complaint: r),
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
  return at == 0
      ? 'Date unavailable'
      : DateTime.fromMillisecondsSinceEpoch(
          at,
        ).toLocal().toString().split('.').first;
}

class _ComplaintThread extends StatefulWidget {
  const _ComplaintThread({required this.client, required this.complaint});
  final SchoolSupportClient client;
  final Map<String, dynamic> complaint;
  @override
  State<_ComplaintThread> createState() => _ComplaintThreadState();
}

class _ComplaintThreadState extends State<_ComplaintThread> {
  final message = TextEditingController();
  final rows = <String, Map<String, dynamic>>{};
  bool busy = false;
  String? error, cursor, pendingId, pendingText;
  late Map<String, dynamic> complaint;
  @override
  void initState() {
    super.initState();
    complaint = widget.complaint;
    _load();
  }

  @override
  void dispose() {
    message.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    setState(() => busy = true);
    try {
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
    if (pendingText != null && pendingText != text) {
      setState(() => error = 'Retry the original reply before editing.');
      return;
    }
    pendingText = text;
    pendingId ??=
        '${DateTime.now().millisecondsSinceEpoch}_${SchoolSupportClient.randomId()}';
    setState(() => busy = true);
    try {
      await widget.client.call('managed/support/reply', {
        'complaintId': complaint['id'],
        'messageId': pendingId,
        'message': text,
      });
      if (!mounted) return;
      message.clear();
      pendingText = null;
      pendingId = null;
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
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
          Text('${complaint['status']} • ${_date(complaint['createdAt'])}'),
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
            Text(error!, style: TextStyle(color: WindowsAppearance.foreground(Colors.orangeAccent))),
          TextField(
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
