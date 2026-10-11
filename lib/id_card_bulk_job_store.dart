import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'id_card_bulk_engine.dart';

/// Crash-durable, school-local bulk job snapshots and completed PDF exports.
///
/// Recovery is conservative: interrupted jobs rerender the EXACT saved
/// immutable selection from the beginning; it never pretends partially
/// generated sheets were safely committed. This is durable job RESUME, not
/// incremental per-page checkpoint/skip. No cloud or printer side effects.
/// Contains private person records / QR / photos, stored unencrypted by this
/// class. Host must supply a protected application-specific directory.
class IdCardBulkJobStore {
  IdCardBulkJobStore({
    required this.rootPath,
    required this.schoolId,
  }) {
    if (rootPath.trim().isEmpty || schoolId.trim().isEmpty) {
      throw ArgumentError('School and protected local directory required');
    }
  }
  final String rootPath, schoolId;
  static const maxSnapshotBytes = 190 * 1024 * 1024;

  // File locks on Unix may be shared at process level. Serialize all local
  // journal operations in the originating UI isolate as well.
  static final Map<String, Future<void>> _pending = {};
  Future<T> _serial<T>(String jobId, Future<T> Function() operation) async {
    final key = '${Directory(rootPath).absolute.path}/$schoolId/$jobId';
    final prior = _pending[key] ?? Future<void>.value();
    final work = prior.then((_) => operation());
    final tail = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _pending[key] = tail;
    try {
      return await work;
    } finally {
      if (identical(_pending[key], tail)) _pending.remove(key);
    }
  }

  Future<void> savePending(String jobId, IdCardBulkPlan plan) async {
    _requireJobId(jobId);
    if (plan.students.first.schoolId != schoolId) {
      throw const FormatException('Foreign school bulk job');
    }
    final raw = jsonEncode(plan.durableSnapshot);
    if (utf8.encode(raw).length > maxSnapshotBytes) {
      throw const FormatException('Bulk job exceeds local storage budget');
    }
    await _serial(jobId, () => Isolate.run(() => _withJobLock(rootPath, schoolId, jobId, (meta, pdf) {
      if (meta.existsSync()) {
        final old = _decode(meta.readAsStringSync(), schoolId, jobId);
        if (old['fingerprint'] != plan.selectionFingerprint) {
          throw StateError('Existing bulk job cannot change its selection');
        }
        return;
      }
      final state = <String, dynamic>{
        'version': 1,
        'schoolId': schoolId,
        'jobId': jobId,
        'fingerprint': plan.selectionFingerprint,
        'status': 'pending',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'selection': jsonDecode(raw),
      };
      _writeAtomically(meta, jsonEncode(state));
    })));
  }

  /// Returns a verified plan for a pending or finished job. A changed school,
  /// missing file, corrupt JSON or selection drift fails closed.
  Future<IdCardBulkPlan> resumePlan(String jobId) async {
    _requireJobId(jobId);
    final snapshot = await _serial(jobId, () => Isolate.run(
      () => _withJobLock(rootPath, schoolId, jobId, (meta, pdf) {
        if (!meta.existsSync()) throw StateError('Bulk job not found');
        return _decode(meta.readAsStringSync(), schoolId, jobId)['selection'];
      }),
    ));
    final plan = IdCardBulkPlan.fromDurableSnapshot(
      Map<String, dynamic>.from(snapshot as Map),
    );
    if (plan.students.first.schoolId != schoolId) {
      throw StateError('Foreign school bulk checkpoint');
    }
    return plan;
  }

  /// No partial export is committed if cancellation, render or disk fails.
  /// Completed PDFs are never replaced by a later retry.
  Future<IdCardBulkResult> resumeAndRender(
    String jobId, {
    bool Function()? isCancelled,
    void Function(int completed, int total)? onProgress,
  }) async {
    final plan = await resumePlan(jobId);
    final already = await readCompletedPdf(jobId);
    if (already != null) {
      return IdCardBulkResult(
        already, plan.selectionFingerprint, plan.manifest,
      );
    }
    final rendered = await IdCardBulkEngine.render(
      plan,
      resumeSelectionFingerprint: plan.selectionFingerprint,
      isCancelled: isCancelled,
      onProgress: onProgress,
    );
    final bytes = rendered.pdf;
    final hash = sha256.convert(bytes).toString();
    // Never publish the PDF before its exact source and scope are checked.
    await _serial(jobId, () => Isolate.run(() => _withJobLock(rootPath, schoolId, jobId, (meta, pdf) {
      final state = _decode(meta.readAsStringSync(), schoolId, jobId);
      if (state['fingerprint'] != plan.selectionFingerprint) {
        throw StateError('Bulk job changed before export commit');
      }
      if (state['status'] == 'complete') {
        final previous = _readVerifiedPdf(pdf, state);
        if (previous == null) {
          throw StateError('Completed PDF integrity check failed');
        }
        return;
      }
      // An orphan file can occur after process kill between PDF rename and
      // metadata update; retain it for review, never silently destroy it.
      if (pdf.existsSync()) {
        final orphan = File('${pdf.path}.orphan.${DateTime.now().microsecondsSinceEpoch}');
        pdf.renameSync(orphan.path);
      }
      _writeBytesAtomically(pdf, bytes);
      _writeAtomically(meta, jsonEncode({
        ...state,
        'status': 'complete',
        'pdfSha256': hash,
        'pdfBytes': bytes.length,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      })));
    })));
    final committed = await readCompletedPdf(jobId);
    if (committed == null) throw StateError('Bulk export not committed');
    return IdCardBulkResult(committed, plan.selectionFingerprint, plan.manifest);
  }

  Future<Uint8List?> readCompletedPdf(String jobId) async {
    _requireJobId(jobId);
    return _serial(jobId, () => Isolate.run(
      () => _withJobLock(rootPath, schoolId, jobId, (meta, pdf) {
        if (!meta.existsSync()) return null;
        final state = _decode(meta.readAsStringSync(), schoolId, jobId);
        if (state['status'] != 'complete') return null;
        final bytes = _readVerifiedPdf(pdf, state);
        if (bytes == null) throw StateError('Completed PDF integrity check failed');
        return bytes;
      }),
    ));
  }
}

void _requireJobId(String id) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
    throw const FormatException('Invalid bulk job identity');
  }
}

String _jobStem(String school, String jobId) =>
    sha256.convert(utf8.encode('$school/$jobId')).toString();

T _withJobLock<T>(
  String rootPath,
  String school,
  String jobId,
  T Function(File meta, File pdf) callback,
) {
  final dir = Directory(rootPath)..createSync(recursive: true);
  final prefix = '${dir.path}${Platform.pathSeparator}${_jobStem(school, jobId)}';
  final lockPath = '$prefix.lock';
  if (FileSystemEntity.isLinkSync(lockPath)) {
    throw StateError('Linked bulk lock is unsafe');
  }
  final lock = File(lockPath).openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.exclusive);
    try {
      final meta = File('$prefix.json'), pdf = File('$prefix.pdf');
      if (FileSystemEntity.isLinkSync(meta.path) ||
          FileSystemEntity.isLinkSync(pdf.path)) {
        throw StateError('Linked bulk job is unsafe');
      }
      return callback(meta, pdf);
    } finally {
      lock.unlockSync();
    }
  } finally {
    lock.closeSync();
  }
}

Map<String, dynamic> _decode(String source, String school, String jobId) {
  if (utf8.encode(source).length > IdCardBulkJobStore.maxSnapshotBytes + 4096) {
    throw const FormatException('Bulk job exceeds size budget');
  }
  final value = jsonDecode(source);
  if (value is! Map) throw const FormatException('Bulk job is not an object');
  final state = Map<String, dynamic>.from(value);
  if (state['version'] != 1 ||
      state['schoolId'] != school ||
      state['jobId'] != jobId ||
      !{'pending', 'complete'}.contains(state['status']) ||
      state['selection'] is! Map ||
      state['fingerprint'] is! String) {
    throw const FormatException('Foreign or invalid bulk job');
  }
  final plan = IdCardBulkPlan.fromDurableSnapshot(
    Map<String, dynamic>.from(state['selection'] as Map),
  );
  if (plan.students.first.schoolId != school ||
      state['fingerprint'] != plan.selectionFingerprint) {
    throw const FormatException('Bulk selection integrity failed');
  }
  return state;
}

Uint8List? _readVerifiedPdf(File pdf, Map<String, dynamic> state) {
  if (!pdf.existsSync() || state['pdfSha256'] is! String ||
      state['pdfBytes'] is! int || (state['pdfBytes'] as int) > 64 * 1024 * 1024) {
    return null;
  }
  final bytes = pdf.readAsBytesSync();
  if (bytes.length != state['pdfBytes'] ||
      sha256.convert(bytes).toString() != state['pdfSha256']) return null;
  return bytes;
}

void _writeAtomically(File target, String content) =>
    _writeBytesAtomically(target, Uint8List.fromList(utf8.encode(content)));

void _writeBytesAtomically(File target, Uint8List bytes) {
  final tmp = File('${target.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}');
  File? previous;
  try {
    tmp.writeAsBytesSync(bytes, flush: true);
    if (target.existsSync()) {
      previous = File('${target.path}.previous.$pid.'
          '${DateTime.now().microsecondsSinceEpoch}');
      target.renameSync(previous.path);
    }
    try {
      tmp.renameSync(target.path);
    } catch (_) {
      if (previous != null && !target.existsSync()) {
        previous.renameSync(target.path);
      }
      rethrow;
    }
    // Intentionally retain previous metadata for manual recovery.
  } finally {
    if (tmp.existsSync()) tmp.deleteSync();
  }
}
