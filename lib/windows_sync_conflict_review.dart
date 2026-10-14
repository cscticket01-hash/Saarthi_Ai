import 'windows_backend_bridge.dart';
import 'windows_sync_comparison.dart';
import 'school_profile_policy.dart';

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:printing/printing.dart';

import 'package:flutter/material.dart';

import 'windows_local_firestore.dart';
import 'windows_connect/managed_school_session.dart';

// Queue rows may contain DateTime, native objects or circular/large maps.
// Never let diagnostic text throw during AlertDialog.build: on Windows that
// leaves the modal barrier visible with no usable review controls.
// This is a display-only, bounded, redacted preview. It never modifies the
// original queue payload, cloud comparison or revision checks.
String _conflictPreview(Object? original) {
  var remaining = 512;
  Object? normalize(Object? value, int depth) {
    if (--remaining < 0) return "[Preview budget reached]";
    if (value == null || value is bool || value is num) return value;
    if (value is DateTime) return value.toIso8601String();
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is String) {
      return value.length <= 2048
          ? value
          : '${value.substring(0, 2048)} [field preview shortened]';
    }
    if (depth >= 5) return '[Nested preview omitted]';
    if (value is Map) {
      final output = <String, Object?>{};
      var count = 0;
      for (final entry in value.entries) {
        if (count++ >= 40 || remaining <= 0) {
          output['...'] = '[Further fields omitted]';
          break;
        }
        final key = entry.key.toString();
        if (RegExp(
          r'password|secret|token|credential|authorization|private.?key|api.?key',
          caseSensitive: false,
        ).hasMatch(key)) {
          output[key] = '[REDACTED]';
        } else {
          output[key] = normalize(entry.value, depth + 1);
        }
      }
      return output;
    }
    if (value is Iterable) {
      final output = <Object?>[];
      var count = 0;
      for (final entry in value) {
        if (count++ >= 40 || remaining <= 0) {
          output.add('[Further entries omitted]');
          break;
        }
        output.add(normalize(entry, depth + 1));
      }
      return output;
    }
    return '[${value.runtimeType}]';
  }

  try {
    final text = const JsonEncoder.withIndent(
      '  ',
    ).convert(normalize(original, 0));
    return text.length <= 10000
        ? text
        : '${text.substring(0, 10000)}\n[Preview shortened; original preserved]';
  } catch (_) {
    return 'Preview unavailable for this record. Original data remains intact.';
  }
}

/// Operator-initiated own-school review. Opening it never sends a write.
Future<void> showWindowsConflictReview(
  BuildContext context,
  Map<String, dynamic> item, {Future<Map<String,dynamic>> Function(Map<String,dynamic>)? cloudReader, Duration verificationTimeout = const Duration(seconds: 60), Future<Map<String,dynamic>?> Function(String, String)? queueReader}
) => showDialog<void>(context: context, builder: (_) => _ConflictReview(item,cloudReader:cloudReader, verificationTimeout:verificationTimeout, queueReader:queueReader));

class _ConflictReview extends StatefulWidget {
  const _ConflictReview(this.item,{this.cloudReader, required this.verificationTimeout, this.queueReader});
  final Duration verificationTimeout;
  final Future<Map<String,dynamic>?> Function(String, String)? queueReader;
  final Future<Map<String,dynamic>> Function(Map<String,dynamic>)? cloudReader;
  final Map<String, dynamic> item;
  @override
  State<_ConflictReview> createState() => _ConflictReviewState();
}

class _ConflictReviewState extends State<_ConflictReview> {
  final reason = TextEditingController();
  Map<String, dynamic>? remote, expected;
  String? choice;
  String? reviewedLocalHash;
  String comparison = 'not performed';
  String error = '';
  bool busy = false;
  bool verifying = false;
  int verificationGeneration = 0;
  String verificationStage = '';
  List<String> differences = [];
  final db = FirebaseFirestore.instance;
  late final origin = db.activeProfileId;
  bool get document =>
      widget.item['collection'] == 'documents' ||
      widget.item['collection'] == null;
  Future<Map<String, dynamic>> readCloud(Map<String, dynamic> queued) async {
    if (db.activeProfileId != origin ||
        queued['schoolId'] != db.activeProfileIdentity['schoolSyncId'])
      throw StateError('School changed. Reopen review.');
    final reply = await (widget.cloudReader?.call(queued) ?? ManagedSchoolSession.callForSchool(
      queued['schoolId'] as String,
      'managed/records',
      {
        'operation': 'read',
        'collection': queued['collection'] ?? 'documents',
        'syncProtocol': 2,
      },
    ));
    final row =
        (reply['records'] as Map?)?[queued['documentId'] ?? widget.item['id']];
    if (db.activeProfileId != origin ||
        reply['syncProtocol'] != 2 ||
        reply['schoolId'] != queued['schoolId'] ||
        row is! Map ||
        row['schoolId'] != queued['schoolId'] ||
        row['id'] != null &&
            row['id'] != (queued['documentId'] ?? widget.item['id']) ||
        row['documentId'] != null && row['documentId'] != (queued['documentId'] ?? widget.item['id']))
      throw StateError(
        'Same-school cloud version unavailable. Both copies retained.',
      );
    return {
      ...Map<String, dynamic>.from(row),
      'id': queued['documentId'] ?? widget.item['id'],
    };
  }

  Future<void> verify() async {
    if (busy) return;
    final generation = ++verificationGeneration;
    void guard() {
      if (!mounted || generation != verificationGeneration || db.activeProfileId != origin)
        throw StateError('Verification cancelled or school changed. Originals retained.');
    }
    void stage(String value) { guard(); setState(() => verificationStage = value); }
    setState(() {
      busy = true; verifying = true; error = ''; remote = null; expected = null;
      comparison = 'not performed'; choice = null; reviewedLocalHash = null;
      differences = []; verificationStage = 'Reading local pending record';
    });
    try {
      final result = await (() async {
        final queue = widget.item['_queueCollection'] ?? '_windows_firebase_outbox';
        if (!{'_windows_document_outbox','_windows_firebase_outbox'}.contains(queue))
          throw StateError('Invalid queue.');
        final id = widget.item['id'] as String;
        final current = widget.queueReader != null
          ? await widget.queueReader!(queue, id)
          : (await db.collection(queue).doc(id).get()).data();
        guard();
        if (current == null || current['syncState'] != 'conflict')
          throw StateError('Pending version changed. Reopen Sync details.');
        stage('Reading authenticated cloud version');
        final cloud = await readCloud(current);
        guard();
        stage('Reading local file and comparing content');
        final proof = document && queue == '_windows_document_outbox'
          ? await WindowsBackendBridge.documentReviewPayload(id, current) : null;
        guard();
        final compared = proof != null
          ? identicalDocumentPayload(proof, cloud) ? 'identical' : 'differs (revision order unknown)'
          : compareSyncVersions(current, cloud);
        return {'current':current, 'cloud':cloud, 'proof':proof, 'comparison':compared};
      })().timeout(widget.verificationTimeout);
      guard();
      final proof = result['proof'] as Map?;
      setState(() {
        expected = Map<String,dynamic>.from(result['current'] as Map);
        remote = Map<String,dynamic>.from(result['cloud'] as Map);
        reviewedLocalHash = proof?['contentHash'] as String?;
        comparison = result['comparison'] as String;
        differences = proof == null ? [] : documentDifferenceFields(proof, remote!);
      });
    } on TimeoutException {
      if (mounted && generation == verificationGeneration)
        setState(() => error = 'Cloud verification timed out during $verificationStage. No data was changed. Retry verification.');
    } catch (e) {
      if (mounted && generation == verificationGeneration)
        setState(() => error = '$verificationStage: $e');
    } finally {
      if (mounted && generation == verificationGeneration) {
        verificationGeneration++; // Late read completions cannot alter this review.
        setState(() { busy = false; verifying = false; });
      }
    }
  }

  Future<void> alreadySynced() async {
    setState(() => busy = true);
    try {
      final queued = expected!;
      if (document) {
        if (widget.item['_queueCollection'] != '_windows_document_outbox')
          throw StateError('File owner verification required.');
        await WindowsBackendBridge.recordVerifiedDocumentReview(
          widget.item['id'] as String,
          queued,
        );
        if (mounted) Navigator.pop(context);
        return;
      }
      if (queued['operation'] == 'delete')
        throw StateError('Owner verification required.');
      if (queued['collection'] == 'school_config' &&
          queued['documentId'] == 'school_profile_cache') {
        requireSchoolProfile(queued['data'] as Map);
      }
      final fresh = await readCloud(queued);
      if (compareSyncVersions(queued, fresh) != 'identical' ||
          fresh['_syncRevision'] is! String ||
          (fresh['_syncRevision'] as String).isEmpty) {
        throw StateError(
          'Cloud payload changed or has no durable revision. Both copies retained.',
        );
      }
      // Readback receipt, not a claim that this client's operation ran.
      await db
          .collection('_windows_sync_conflict_history')
          .doc(queued['operationId'] as String)
          .set({
            ...queued,
            'verifiedCloud': fresh,
            'resolution': 'identical authenticated readback',
          });
      await db.acknowledgeOutbox(
        db
            .collection('_windows_firebase_outbox')
            .doc(widget.item['id'] as String),
        queued,
        revision: fresh['_syncRevision'] as String,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> previewDocument(bool cloud) async {
    setState(() => busy = true);
    try {
      final source = cloud
          ? ({...remote!}
              ..remove('localPath')
              ..remove('originalPath'))
          : expected!;
      final bytes = cloud
          ? await WindowsBackendBridge.documentBytes(source)
          : await File(
              (source['optimizedPath'] ?? source['localPath']) as String,
            ).readAsBytes();
      if (db.activeProfileId != origin)
        throw StateError('School changed. Reopen review.');
      if (bytes.length > 20 * 1024 * 1024 ||
          source['mimeType'] != 'application/pdf') {
        throw StateError(
          'Inline review supports PDF files up to 20 MB. Originals retained.',
        );
      }
      if (mounted)
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(cloud ? 'Cloud PDF' : 'Local PDF'),
            content: SizedBox(
              width: 700,
              height: 550,
              child: PdfPreview(
                build: (_) => bytes,
                allowPrinting: false,
                allowSharing: false,
                canChangeOrientation: false,
                canChangePageFormat: false,
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
          document && choice == 'cloud'
              ? 'Keep the verified cloud version on this PC and archive this exact local conflict. Both originals remain retained; no upload will occur.'
              : 'You selected the $choice version. A new revision-checked operation will be queued. The original conflict and both versions are retained. This is not a cloud acknowledgment.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              document && choice == 'cloud'
                  ? 'Keep verified cloud copy'
                  : 'Queue reviewed version',
            ),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => busy = true);
    try {
      final fresh = await readCloud(expected!);
      if (jsonEncode(fresh) != jsonEncode(remote))
        throw StateError('Cloud version changed. Verify both versions again.');
      if (document) {
        if (widget.item['_queueCollection'] != '_windows_document_outbox') {
          throw StateError('Document owner queue required.');
        }
        await WindowsBackendBridge.resolveReviewedDocument(
          id: widget.item['id'] as String,
          expected: expected!,
          reviewedCloud: fresh,
          choice: choice!,
          reason: reason.text,
          reviewedLocalHash: reviewedLocalHash!,
        );
      } else
        await db.enqueueReviewedConflict(
          queueId: widget.item['id'] as String,
          expected: expected!,
          remote: fresh,
          choice: choice!,
          reason: reason.text,
        );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    verificationGeneration++;
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    title: const Text('Review sync conflict'),
    content: SizedBox(
      width: (MediaQuery.sizeOf(context).width - 72)
          .clamp(160.0, 760.0)
          .toDouble(),
      height: (MediaQuery.sizeOf(context).height - 220)
          .clamp(160.0, 560.0)
          .toDouble(),
      child: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          Text(
            busy
                ? '$verificationStage… Originals retained.'
                : error.isNotEmpty
                ? 'Cloud verification failed'
                : remote == null
                ? 'Cloud verification: not performed'
                : 'Cloud verification: $comparison. Authenticated read; checked again before resolution',
          ),
          if (error.isNotEmpty)
            SelectableText(error, style: const TextStyle(color: Colors.orange)),
          if (differences.isNotEmpty) Text('Differing fields: ${differences.join(', ')}'),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'No version is selected automatically. Financial records need an explicit operator decision. Originals remain retained.',
                  ),
                  const SizedBox(height: 12),
                  const Text('Local pending version'),
                  SelectableText(
                    _conflictPreview(
                      expected?['data'] ?? widget.item['data'] ?? widget.item,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (remote != null) ...[
                    Text(
                      'Operation identity: local ${expected?['operationId'] ?? expected?['documentRevision'] ?? 'unknown'} / cloud ${remote?['_syncOperationId'] ?? remote?['documentRevision'] ?? 'unknown'}',
                    ),
                    Text(
                      'Record revision: base ${expected?['baseCloudRevision'] ?? 'unknown'} / cloud ${remote?['_syncRevision'] ?? 'unknown'}',
                    ),
                    if (expected?['data'] is Map)
                      Text(
                        'Payload hash: local ${syncPayloadHash(expected!['data'] as Map)} / cloud ${syncPayloadHash(remote!)}',
                      ),
                    SelectableText(_conflictPreview(remote)),
                  ],
                  if (document)
                    const Text(
                      'Local choice queues a new revision-checked upload. Cloud choice verifies and retains cloud bytes locally. Both originals and the review history are retained.',
                    ),
                  if (document && remote != null)
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: busy ? null : () => previewDocument(false),
                          child: const Text('Preview local PDF'),
                        ),
                        OutlinedButton(
                          onPressed: busy ? null : () => previewDocument(true),
                          child: const Text('Preview cloud PDF'),
                        ),
                      ],
                    ),
                  if (remote != null &&
                      (!document ||
                          widget.item['_queueCollection'] ==
                              '_windows_document_outbox') &&
                      expected?['deleted'] != true &&
                      expected?['operation'] != 'delete') ...[
                    RadioListTile<String>(
                      title: const Text('Use local version'),
                      value: 'local',
                      groupValue: choice,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => choice = v),
                    ),
                    RadioListTile<String>(
                      title: const Text('Use cloud version'),
                      value: 'cloud',
                      groupValue: choice,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => choice = v),
                    ),
                    TextField(
                      controller: reason,
                      maxLength: 1000,
                      decoration: const InputDecoration(
                        labelText: 'Reason for your decision',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy && !verifying ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      OutlinedButton(
        onPressed: busy ? null : verify,
        child: Text(busy ? 'Verifying…' : 'Verify cloud version'),
      ),
      if (comparison == 'identical' &&
          (!document ||
              widget.item['_queueCollection'] == '_windows_document_outbox'))
        FilledButton(
          onPressed: busy ? null : alreadySynced,
          child: const Text('Record already synced'),
        ),
      if (!document ||
          widget.item['_queueCollection'] == '_windows_document_outbox' &&
              expected?['deleted'] != true)
        FilledButton(
          onPressed:
              busy ||
                  remote == null ||
                  choice == null ||
                  reason.text.trim().isEmpty
              ? null
              : commit,
          child: const Text('Review and queue'),
        ),
    ],
  );
}
