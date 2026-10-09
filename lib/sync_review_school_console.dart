import 'dart:math';
import 'package:flutter/material.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_connect/central_school_cloud.dart';

/// An isolated review UI using the existing authenticated school protocol.
/// Only synthetic notices in the registered TEST school may be created here.
class SyncReviewSchoolConsole extends StatefulWidget {
  const SyncReviewSchoolConsole({super.key});
  @override
  State<SyncReviewSchoolConsole> createState() =>
      _SyncReviewSchoolConsoleState();
}

class _SyncReviewSchoolConsoleState extends State<SyncReviewSchoolConsole> {
  static const school = 'vs-db8afb01a3be46a983c8284714d06e5d';
  static const endpoint =
      'https://saarthi-sync-v2-test.onrender.com/school-cloud';
  static const enabled = bool.fromEnvironment('SAARTHI_SYNC_REVIEW_WEB');
  final email = TextEditingController(),
      password = TextEditingController(),
      noticeId = TextEditingController(),
      title = TextEditingController();
  final records = <String, Map<String, dynamic>>{};
  String revision = '', status = 'TEST school login required';
  String? operationId;
  Map<String, dynamic>? pendingPayload;
  String? pendingId;
  bool logged = false, busy = false;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    noticeId.dispose();
    title.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() task) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (!enabled || CentralSchoolCloud.apiUrl != endpoint)
        throw StateError('Isolated TEST build required');
      await task();
    } catch (_) {
      if (mounted)
        setState(() => status =
            'Verification failed. Retry with the same TEST record; no ACK claimed.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    final reply =
        await ManagedSchoolSession.callForSchool(school, 'managed/changes', {
      'collections': ['school_notices'],
      'knownRevisions': {'school_notices': revision}
    });
    if (reply['schoolId'] != school || reply['syncProtocol'] != 2)
      throw StateError('Foreign protocol response');
    final group = Map<String, dynamic>.from(
        (reply['changes'] as Map)['school_notices'] as Map);
    final rows = Map<String, dynamic>.from(group['records'] as Map);
    if (rows.values.any((r) => r is! Map || r['schoolId'] != school))
      throw StateError('Foreign record');
    if (group['unchanged'] != true) {
      records.clear();
      for (final row in rows.entries) {
        if (row.value['syntheticTest'] == true &&
            row.value['_syncDeleted'] != true)
          records[row.key] = Map<String, dynamic>.from(row.value as Map);
      }
    }
    revision = group['collectionRevision'] as String;
    if (mounted) setState(() => status = 'Cloud records verified');
  }

  Future<void> login() async {
    final session = await ManagedSchoolSession.login(email.text, password.text,
        endpoint: endpoint);
    password.clear();
    if (session['schoolId'] != school || session['storageReady'] != true) {
      await ManagedSchoolSession.logout();
      throw StateError('Registered TEST identity required');
    }
    logged = true;
    await refresh();
  }

  Future<void> publish() async {
    if (!logged ||
        !RegExp(r'^synthetic-web-notice-[0-9]+$').hasMatch(noticeId.text) ||
        !title.text.startsWith('Synthetic website exchange ') ||
        title.text.length > 200)
      throw StateError('Synthetic TEST notice required');
    operationId ??=
        'web-review-${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    pendingPayload ??= {
      'schoolId': school,
      'syntheticTest': true,
      'title': title.text,
      'timestamp': DateTime.now().millisecondsSinceEpoch
    };
    pendingId ??= noticeId.text;
    if (pendingId != noticeId.text || pendingPayload!['title'] != title.text)
      throw StateError('Retry unchanged pending TEST operation');
    final ack =
        await ManagedSchoolSession.callForSchool(school, 'managed/records', {
      'operation': 'write',
      'collection': 'school_notices',
      'id': noticeId.text,
      'syncProtocol': 2,
      'operationId': operationId,
      'expectedRecordRevision': '',
      'data': pendingPayload
    });
    if (ack['schoolId'] != school ||
        ack['syncProtocol'] != 2 ||
        (ack['recordRevision']?.toString() ?? '').isEmpty)
      throw StateError('Verified ACK required');
    await refresh();
    if (records[noticeId.text]?['title'] != title.text)
      throw StateError('Readback mismatch');
    setState(() => status = 'Website ACK and readback verified');
  }

  Widget input(TextEditingController control, String label,
          {bool secret = false}) =>
      TextField(
          controller: control,
          obscureText: secret,
          decoration: InputDecoration(labelText: label));
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('TEST Sync V2 — School Records Review')),
      body: !enabled
          ? const Center(child: Text('Isolated TEST review build only'))
          : SingleChildScrollView(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(status),
                        if (busy) const LinearProgressIndicator(),
                        if (!logged) ...[
                          input(email, 'TEST email'),
                          input(password, 'TEST password', secret: true),
                          ElevatedButton(
                              onPressed: busy ? null : () => run(login),
                              child: const Text('Connect TEST school'))
                        ] else ...[
                          const Text('Registered school: TEST Sync V2'),
                          input(noticeId, 'Synthetic notice ID'),
                          input(title, 'Synthetic notice title'),
                          ElevatedButton(
                              onPressed: busy ? null : () => run(publish),
                              child: const Text('Publish TEST notice')),
                          OutlinedButton(
                              onPressed: busy ? null : () => run(refresh),
                              child: const Text('Refresh cloud records')),
                          for (final row in records.entries)
                            Text('${row.key} | ${row.value['title']}'),
                        ],
                      ]))));
}
