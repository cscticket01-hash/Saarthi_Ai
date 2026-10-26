import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'id_card_bulk_engine.dart';
import 'id_card_local_cipher.dart';

/// Crash-durable, school-local bulk job snapshots and completed PDF exports.
///
/// Recovery is conservative: interrupted jobs rerender the EXACT saved
/// immutable selection from the beginning; it never pretends partially
/// generated sheets were safely committed. This is durable job RESUME, not
/// incremental per-page checkpoint/skip. No cloud or printer side effects.
/// Private person/QR/photo snapshots and internal completed PDFs use school-bound
/// authenticated encryption with an OS credential-store key.
class IdCardBulkJobStore {
  IdCardBulkJobStore({
    required this.rootPath,
    required this.schoolId,
    this.keyProvider,
  }) {
    if (rootPath.trim().isEmpty || schoolId.trim().isEmpty) {
      throw ArgumentError('School and protected local directory required');
    }
  }
  final IdCardKeyProvider? keyProvider;
  Future<Uint8List>? _key;
  Future<Uint8List> get key => _key ??= (keyProvider?.call() ?? IdCardLocalCipher.schoolKey(schoolId));
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
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    await _serial(jobId, () => Isolate.run(() => _withJobLock(storageRoot, boundSchool, jobId, (meta, pdf) async {
      if (meta.existsSync()) {
        final old = await _decode(_boundedText(meta), boundSchool, jobId, secret);
        if (old['fingerprint'] != plan.selectionFingerprint) {
          throw StateError('Existing bulk job cannot change its selection');
        }
        return;
      }
      final state = <String, dynamic>{
        'version': 1,
        'schoolId': boundSchool,
        'jobId': jobId,
        'fingerprint': plan.selectionFingerprint,
        'status': 'pending',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'selection': jsonDecode(raw),
      };
      await _writeProtected(meta, jsonEncode(state), boundSchool, secret);
    })));
  }

  /// Returns a verified plan for a pending or finished job. A changed school,
  /// missing file, corrupt JSON or selection drift fails closed.
  Future<IdCardBulkPlan> resumePlan(String jobId) async {
    _requireJobId(jobId);
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    final snapshot = await _serial(jobId, () => Isolate.run(
      () => _withJobLock(storageRoot, boundSchool, jobId, (meta, pdf) async {
        if (!meta.existsSync()) throw StateError('Bulk job not found');
        return (await _decode(_boundedText(meta), boundSchool, jobId, secret))['selection'];
      }),
    ));
    final plan = IdCardBulkPlan.fromDurableSnapshot(
      Map<String, dynamic>.from(snapshot as Map),
    );
    if (plan.students.first.schoolId != boundSchool) {
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
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
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
    await _serial(jobId, () => Isolate.run(() => _withJobLock(storageRoot, boundSchool, jobId, (meta, pdf) async {
      final state = await _decode(_boundedText(meta), boundSchool, jobId, secret);
      if (state['fingerprint'] != plan.selectionFingerprint) {
        throw StateError('Bulk job changed before export commit');
      }
      if (state['status'] == 'complete') {
        final previous = await _readVerifiedPdf(pdf, state, boundSchool, secret);
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
      _writeBytesAtomically(pdf, await IdCardLocalCipher(boundSchool, secret).seal(bytes, 'bulk-pdf:$jobId'));
      await _writeProtected(meta, jsonEncode({
        ...state,
        'status': 'complete',
        'pdfSha256': hash,
        'pdfBytes': bytes.length,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      }), boundSchool, secret);
    })));
    final committed = await readCompletedPdf(jobId);
    if (committed == null) throw StateError('Bulk export not committed');
    return IdCardBulkResult(committed, plan.selectionFingerprint, plan.manifest);
  }

  Future<Uint8List?> readCompletedPdf(String jobId) async {
    _requireJobId(jobId);
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    return _serial(jobId, () => Isolate.run(
      () => _withJobLock(storageRoot, boundSchool, jobId, (meta, pdf) async {
        if (!meta.existsSync()) return null;
        final state = await _decode(_boundedText(meta), boundSchool, jobId, secret);
        if (state['status'] != 'complete') return null;
        final bytes = await _readVerifiedPdf(pdf, state, boundSchool, secret);
        if (bytes == null) throw StateError('Completed PDF integrity check failed');
        return bytes;
      }),
    ));
  }
  /// The UI may list bounded protected checkpoints without exposing person
  /// snapshots or QR credentials. Invalid files fail visibly, never disappear.
  Future<List<Map<String, dynamic>>> listJobs() async {
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    return Isolate.run(() async {
      final dir = Directory(storageRoot);
      if (!dir.existsSync()) return <Map<String, dynamic>>[];
      final files = dir.listSync(followLinks: false).whereType<File>()
          .where((f) => f.path.endsWith('.json')).toList();
      if (files.length > 500) throw StateError('Bulk job inventory requires review');
      final jobs = <Map<String, dynamic>>[];
      for (final file in files) {
        if(file.lengthSync()>((IdCardBulkJobStore.maxSnapshotBytes + 4096)*4~/3)+4096)throw const FormatException('Bulk inventory exceeds budget');
        Uint8List raw;var legacy = false;
        try { raw = await IdCardLocalCipher(boundSchool, secret).open(file.readAsBytesSync(), 'bulk-job', maxBytes: maxSnapshotBytes + 4096); }
        on IdCardLegacyPlaintextException { raw = file.readAsBytesSync();legacy = true; }
        final value = jsonDecode(utf8.decode(raw));
        if (value is! Map || value['jobId'] is! String) throw const FormatException('Invalid protected bulk inventory');
        final jobId = value['jobId'] as String;
        _requireJobId(jobId);
        if (!file.path.endsWith('${_jobStem(boundSchool, jobId)}.json')) throw const FormatException('Bulk inventory identity mismatch');
        final state = _decodePlain(utf8.decode(raw), boundSchool, jobId);
        jobs.add({'jobId': jobId, 'status': state['status'], 'protection': legacy ? 'legacy-needs-review' : 'protected', 'fingerprint': state['fingerprint'],
          'createdAt': state['createdAt'], 'count': (state['selection']['students'] as List).length});
      }
      return jobs;
    });
  }

  Future<int> migrateLegacy(String jobId, {required bool confirmed}) async {
    _requireJobId(jobId);
    if (!confirmed) throw StateError('Confirm protected bulk job migration');
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    return _serial(jobId, () => Isolate.run(() => _withJobLock(storageRoot, boundSchool, jobId, (meta, pdf) async {
      if (!meta.existsSync()) throw StateError('Bulk job not found');
      final cipher = IdCardLocalCipher(boundSchool, secret);
      final inventory=Directory(storageRoot).listSync(followLinks:false);
      if(inventory.any((f)=>f is Link && (f.path.startsWith(meta.path)||f.path.startsWith(pdf.path))))throw StateError('Linked bulk revision requires review');
      final files = inventory.whereType<File>()
          .where((f) => f.path == meta.path || f.path.startsWith('${meta.path}.previous.') ||
            f.path == pdf.path || f.path.startsWith('${pdf.path}.orphan.') || f.path.startsWith('${pdf.path}.previous.')).toList();
      if (files.length > 500) throw StateError('Bulk recovery inventory requires review');
      var changed = 0;
      for (final file in files) {
        final isMeta = file.path.startsWith(meta.path);
        final purpose = isMeta ? 'bulk-job' : 'bulk-pdf:$jobId';
        if(FileSystemEntity.isLinkSync(file.path)||file.lengthSync()>((IdCardBulkJobStore.maxSnapshotBytes + 4096)*4~/3)+4096)throw StateError('Unsafe ID revision');
        final bytes = file.readAsBytesSync();
        if (isMeta) {
          try { await cipher.open(bytes, purpose, maxBytes: maxSnapshotBytes + 4096); continue; }
          on IdCardLegacyPlaintextException { /* Confirmed legacy migration. */ }
          _decodePlain(utf8.decode(bytes), boundSchool, jobId);
        } else {
          if (!(bytes.length >= 4 && bytes[0] == 37 && bytes[1] == 80 && bytes[2] == 68 && bytes[3] == 70)) {
            await cipher.open(bytes, purpose, maxBytes: 64 * 1024 * 1024); continue;
          }
          if (bytes.length > 64 * 1024 * 1024) throw const FormatException('Legacy PDF exceeds budget');
        }
        final sealed = await cipher.seal(bytes, purpose);
        final temp = File('${file.path}.migration.$pid.${DateTime.now().microsecondsSinceEpoch}');
        temp.writeAsBytesSync(sealed, flush: true);
        temp.renameSync(file.path);
        changed++;
      }
      return changed;
    })));
  }
}

void _requireJobId(String id) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
    throw const FormatException('Invalid bulk job identity');
  }
}

String _jobStem(String school, String jobId) =>
    sha256.convert(utf8.encode('$school/$jobId')).toString();

Future<T> _withJobLock<T>(
  String rootPath,
  String school,
  String jobId,
  Future<T> Function(File meta, File pdf) callback,
) async {
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
      return await callback(meta, pdf);
    } finally {
      lock.unlockSync();
    }
  } finally {
    lock.closeSync();
  }
}

Future<Map<String, dynamic>> _decode(String sealed, String school, String jobId, Uint8List secret) async {
  final source = utf8.decode(await IdCardLocalCipher(school, secret).open(Uint8List.fromList(utf8.encode(sealed)), 'bulk-job', maxBytes: IdCardBulkJobStore.maxSnapshotBytes + 4096));
  return _decodePlain(source, school, jobId);
}

Map<String, dynamic> _decodePlain(String source, String school, String jobId) {
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

Future<Uint8List?> _readVerifiedPdf(File pdf, Map<String, dynamic> state, String school, Uint8List secret) async {
  if (!pdf.existsSync() || state['pdfSha256'] is! String ||
      state['pdfBytes'] is! int || (state['pdfBytes'] as int) > 64 * 1024 * 1024) {
    return null;
  }
  Uint8List bytes;
  try { bytes = await IdCardLocalCipher(school, secret).open(pdf.readAsBytesSync(), 'bulk-pdf:${state['jobId']}', maxBytes: 64 * 1024 * 1024); } catch (_) { return null; }
  if (bytes.length != state['pdfBytes'] ||
      sha256.convert(bytes).toString() != state['pdfSha256']) return null;
  return bytes;
}

Future<void> _writeProtected(File target, String content, String school, Uint8List secret) async =>
    _writeBytesAtomically(target, await IdCardLocalCipher(school, secret).seal(Uint8List.fromList(utf8.encode(content)), 'bulk-job'));

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

String _boundedText(File file) {
  if(FileSystemEntity.isLinkSync(file.path))throw StateError('Linked ID storage is unsafe');
  final budget=((IdCardBulkJobStore.maxSnapshotBytes + 4096)*4~/3)+4096;
  if(file.lengthSync()>budget)throw const FormatException('Protected ID file exceeds size budget');
  return file.readAsStringSync();
}
