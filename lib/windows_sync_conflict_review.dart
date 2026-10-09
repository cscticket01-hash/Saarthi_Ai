import 'dart:convert';
import 'package:flutter/material.dart';
import 'windows_local_firestore.dart';
import 'windows_connect/managed_school_session.dart';

/// Operator-initiated own-school review. Opening it never sends a write.
Future<void> showWindowsConflictReview(
        BuildContext context, Map<String, dynamic> item) =>
    showDialog<void>(context: context, builder: (_) => _ConflictReview(item));

class _ConflictReview extends StatefulWidget {
  const _ConflictReview(this.item);
  final Map<String, dynamic> item;
  @override
  State<_ConflictReview> createState() => _ConflictReviewState();
}

class _ConflictReviewState extends State<_ConflictReview> {
  final reason = TextEditingController();
  Map<String, dynamic>? remote, expected;
  String? choice;
  String error = '';
  bool busy = false;
  final db = FirebaseFirestore.instance;
  late final origin = db.activeProfileId;
  bool get document =>
      widget.item['collection'] == 'documents' ||
      widget.item['collection'] == null;
  Future<Map<String, dynamic>> readCloud(Map<String, dynamic> queued) async {
    if (db.activeProfileId != origin ||
        queued['schoolId'] != db.activeProfileIdentity['schoolSyncId'])
      throw StateError('School changed. Reopen review.');
    final reply = await ManagedSchoolSession.callForSchool(
        queued['schoolId'] as String, 'managed/records', {
      'operation': 'read',
      'collection': queued['collection'] ?? 'documents',
      'syncProtocol': 2
    });
    final row =
        (reply['records'] as Map?)?[queued['documentId'] ?? widget.item['id']];
    if (db.activeProfileId != origin ||
        reply['schoolId'] != queued['schoolId'] ||
        row is! Map ||
        row['schoolId'] != queued['schoolId'] ||
        row['id'] != null &&
            row['id'] != (queued['documentId'] ?? widget.item['id']))
      throw StateError(
          'Same-school cloud version unavailable. Both copies retained.');
    return {
      ...Map<String, dynamic>.from(row),
      'id': queued['documentId'] ?? widget.item['id']
    };
  }

  Future<void> verify() async {
    setState(() {
      busy = true;
      error = '';
      remote = null;
      choice = null;
    });
    try {
      final queue =
          widget.item['_queueCollection'] ?? '_windows_firebase_outbox';
      if (!{'_windows_document_outbox', '_windows_firebase_outbox'}
          .contains(queue)) throw StateError('Invalid queue.');
      final current =
          (await db.collection(queue).doc(widget.item['id'] as String).get())
              .data();
      if (current == null || current['syncState'] != 'conflict')
        throw StateError('Pending version changed. Reopen Sync details.');
      final cloud = await readCloud(current);
      if (mounted)
        setState(() {
          expected = current;
          remote = cloud;
        });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> commit() async {
    final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Confirm reviewed version'),
                content: Text(
                    'You selected the $choice version. A new revision-checked operation will be queued. The original conflict and both versions are retained. This is not a cloud acknowledgment.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Queue reviewed version'))
                ]));
    if (accepted != true || !mounted) return;
    setState(() => busy = true);
    try {
      final fresh = await readCloud(expected!);
      if (jsonEncode(fresh) != jsonEncode(remote))
        throw StateError('Cloud version changed. Verify both versions again.');
      await db.enqueueReviewedConflict(
          queueId: widget.item['id'] as String,
          expected: expected!,
          remote: fresh,
          choice: choice!,
          reason: reason.text);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Review sync conflict'),
          content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text(
                        'No version is selected automatically. Financial records need an explicit operator decision. Originals remain retained.'),
                    const SizedBox(height: 12),
                    const Text('Local pending version'),
                    SelectableText(const JsonEncoder.withIndent('  ').convert(
                        expected?['data'] ??
                            widget.item['data'] ??
                            widget.item)),
                    const SizedBox(height: 12),
                    Text(remote == null
                        ? 'Cloud verification: not performed'
                        : 'Cloud verification: authenticated read; checked again before queuing'),
                    if (remote != null)
                      SelectableText(
                          const JsonEncoder.withIndent('  ').convert(remote)),
                    if (document)
                      const Text(
                          'Document conflicts require comparing original files. This screen does not replace files or resolve their conflict.'),
                    if (remote != null &&
                        !document &&
                        expected?['operation'] != 'delete') ...[
                      RadioListTile<String>(
                          title: const Text('Use local version'),
                          value: 'local',
                          groupValue: choice,
                          onChanged:
                              busy ? null : (v) => setState(() => choice = v)),
                      RadioListTile<String>(
                          title: const Text('Use cloud version'),
                          value: 'cloud',
                          groupValue: choice,
                          onChanged:
                              busy ? null : (v) => setState(() => choice = v)),
                      TextField(
                          controller: reason,
                          maxLength: 1000,
                          decoration: const InputDecoration(
                              labelText: 'Reason for your decision'),
                          onChanged: (_) => setState(() {})),
                    ],
                    if (error.isNotEmpty)
                      Text(error, style: const TextStyle(color: Colors.orange)),
                  ]))),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('Close')),
            OutlinedButton(
                onPressed: busy ? null : verify,
                child: const Text('Verify cloud version')),
            if (!document)
              FilledButton(
                  onPressed: busy ||
                          remote == null ||
                          choice == null ||
                          reason.text.trim().isEmpty
                      ? null
                      : commit,
                  child: const Text('Review and queue'))
          ]);
}
