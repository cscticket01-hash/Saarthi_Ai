import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'id_card_manifest.dart';

/// File-backed designer drafts for Windows and other dart:io platforms.
/// Callers supply an application-owned directory; this never connects to cloud
/// services or changes an existing school data store.
///
/// The latest committed draft is never silently replaced by an older backup.
/// Backups are retained (not purged) and may be recovered only explicitly.
/// On-disk JSON is integrity-checked, but is NOT encrypted or authenticated.
class IdCardDraftStorageIo {
  IdCardDraftStorageIo({required this.rootPath, required this.schoolId}) {
    if (rootPath.trim().isEmpty || schoolId.trim().isEmpty) {
      throw ArgumentError('School and app-owned storage path required');
    }
  }

  final String rootPath;
  final String schoolId;
  static const int maxBytes = 512 * 1024;

  // Unix file locks can be process-scoped; parallel Isolate.run calls in one
  // app process must ALSO be serialized before crossing isolate boundaries.
  // Share the queue across store instances bound to the same school and path.
  static final Map<String, Future<void>> _pending = {};
  Future<T> _serial<T>(Future<T> Function() operation) async {
    final key = '${Directory(rootPath).absolute.path}/$schoolId';
    final previous = _pending[key] ?? Future<void>.value();
    final task = previous.then((_) => operation());
    final tail = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _pending[key] = tail;
    try {
      return await task;
    } finally {
      if (identical(_pending[key], tail)) _pending.remove(key);
    }
  }

  /// Can be passed directly as the ID designer screen onSave callback.
  /// Saving is performed in an isolate to avoid blocking the Flutter UI.
  Future<void> saveDraft(Map<String, dynamic> draft) async {
    final encoded = jsonEncode(draft);
    if (utf8.encode(encoded).length > maxBytes) {
      throw const FormatException('ID designer draft exceeds 512 KiB');
    }
    await _serial(() => Isolate.run(() => _writeDraft(rootPath, schoolId, encoded)));
  }

  /// A corrupt latest file fails visibly; never silently fall back to stale
  /// design content. Null means no draft was saved for this school.
  Future<Map<String, dynamic>?> loadDraft() =>
      _serial(() => Isolate.run(() => _readDraft(rootPath, schoolId, previous: false)));

  /// Opt-in recovery of the most recent retained previous revision. This
  /// operation does NOT mutate or replace the current draft.
  Future<Map<String, dynamic>?> readPreviousRevision() =>
      _serial(() => Isolate.run(() => _readDraft(rootPath, schoolId, previous: true)));
}

String _draftStem(String schoolId) =>
    sha256.convert(utf8.encode(schoolId)).toString();

void _validateDraft(Map<String, dynamic> draft, String schoolId) {
  if (draft['version'] != 1 ||
      draft['schoolId'] != schoolId ||
      draft['templateVersion'] is! String ||
      (draft['templateVersion'] as String).trim().isEmpty ||
      draft['manifest'] is! Map) {
    throw const FormatException('Invalid or foreign school ID designer draft');
  }
  IdCardManifest.fromJson(
    Map<String, dynamic>.from(draft['manifest'] as Map),
  );
}

Map<String, dynamic> _decodeAndCheck(String json, String schoolId) {
  if (utf8.encode(json).length > IdCardDraftStorageIo.maxBytes + 256) {
    throw const FormatException('Stored designer draft too large');
  }
  final decoded = jsonDecode(json);
  if (decoded is! Map) {
    throw const FormatException('Invalid designer draft envelope');
  }
  final saved = Map<String, dynamic>.from(decoded);
  final payload = saved['draft'];
  if (saved['storageVersion'] != 1 ||
      payload is! Map ||
      saved['sha256'] is! String ||
      sha256.convert(utf8.encode(jsonEncode(payload))).toString() !=
          saved['sha256']) {
    throw const FormatException('Designer draft integrity check failed');
  }
  final draft = Map<String, dynamic>.from(payload);
  _validateDraft(draft, schoolId);
  return draft;
}

T _withSchoolLock<T>(
  String rootPath,
  String schoolId,
  T Function(Directory root, String stem) task,
) {
  final root = Directory(rootPath);
  root.createSync(recursive: true);
  final stem = _draftStem(schoolId);
  final lockFile = File(root.path + Platform.pathSeparator + stem + '.lock');
  if (FileSystemEntity.isLinkSync(lockFile.path)) {
    throw StateError('Refusing linked draft lock path');
  }
  final lock = lockFile.openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.exclusive);
    try {
      return task(root, stem);
    } finally {
      lock.unlockSync();
    }
  } finally {
    lock.closeSync();
  }
}

File _currentFile(Directory root, String stem) =>
    File(root.path + Platform.pathSeparator + stem + '.draft.json');

void _writeDraft(String rootPath, String schoolId, String encoded) {
  final source = jsonDecode(encoded);
  if (source is! Map) {
    throw const FormatException('Invalid designer draft');
  }
  final draft = Map<String, dynamic>.from(source);
  _validateDraft(draft, schoolId);
  final wrapped = jsonEncode({
    'storageVersion': 1,
    'sha256': sha256.convert(utf8.encode(jsonEncode(draft))).toString(),
    'draft': draft,
  });
  if (utf8.encode(wrapped).length > IdCardDraftStorageIo.maxBytes + 256) {
    throw const FormatException('Stored designer draft exceeds size budget');
  }
  _withSchoolLock(rootPath, schoolId, (root, stem) {
    final target = _currentFile(root, stem);
    if (FileSystemEntity.isLinkSync(target.path)) {
      throw StateError('Refusing linked designer draft');
    }
    // Unique transient file, never considered committed until rename.
    final temp = File(target.path + '.tmp.' +
        DateTime.now().microsecondsSinceEpoch.toString() + '.' +
        pid.toString());
    var movedOld = false;
    File? previous;
    try {
      temp.writeAsStringSync(wrapped, flush: true);
      if (target.existsSync()) {
        // Validate the old revision before replacing it. Do not hide
        // corruption by overwriting the only evidence.
        _decodeAndCheck(target.readAsStringSync(), schoolId);
        var sequence = 0;
        while (true) {
          final suffix = DateTime.now().microsecondsSinceEpoch.toString() +
              '.' + sequence.toString();
          final candidate = File(target.path + '.bak.' + suffix);
          if (!candidate.existsSync()) {
            previous = candidate;
            break;
          }
          sequence++;
        }
        target.renameSync(previous.path);
        movedOld = true;
      }
      try {
        temp.renameSync(target.path);
      } catch (_) {
        if (movedOld && !target.existsSync()) {
          previous!.renameSync(target.path);
        }
        rethrow;
      }
    } finally {
      if (temp.existsSync()) temp.deleteSync();
    }
  });
}

Map<String, dynamic>? _readDraft(
  String rootPath,
  String schoolId, {
  required bool previous,
}) => _withSchoolLock(rootPath, schoolId, (root, stem) {
  final target = _currentFile(root, stem);
  if (FileSystemEntity.isLinkSync(target.path)) {
    throw StateError('Refusing linked designer draft');
  }
  File? selected;
  if (previous) {
    final candidates = root.listSync(followLinks: false)
        .whereType<File>()
        .where((file) => file.path.startsWith(target.path + '.bak.'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    if (candidates.isNotEmpty) selected = candidates.first;
  } else if (target.existsSync()) {
    selected = target;
  }
  if (selected == null) return null;
  if (FileSystemEntity.isLinkSync(selected.path)) {
    throw StateError('Refusing linked designer backup');
  }
  return _decodeAndCheck(selected.readAsStringSync(), schoolId);
});
