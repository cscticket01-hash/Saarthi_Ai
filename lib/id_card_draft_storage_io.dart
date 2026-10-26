import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'id_card_local_cipher.dart';

import 'package:crypto/crypto.dart';

import 'id_card_manifest.dart';

/// File-backed designer drafts for Windows and other dart:io platforms.
/// Callers supply an application-owned directory; this never connects to cloud
/// services or changes an existing school data store.
///
/// The latest committed draft is never silently replaced by an older backup.
/// Backups are retained (not purged) and may be recovered only explicitly.
/// On-disk JSON is integrity-checked, but is encrypted and authenticated with a school-scoped OS-protected key.
class IdCardDraftStorageIo {
  IdCardDraftStorageIo({required this.rootPath, required this.schoolId, this.keyProvider}) {
    if (rootPath.trim().isEmpty || schoolId.trim().isEmpty) {
      throw ArgumentError('School and app-owned storage path required');
    }
  }

  final IdCardKeyProvider? keyProvider;
  Future<Uint8List>? _key;
  Future<Uint8List> get key => _key ??= (keyProvider?.call() ?? IdCardLocalCipher.schoolKey(schoolId));
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
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    await _serial(() => Isolate.run(() => _writeDraft(storageRoot, boundSchool, encoded, secret)));
  }

  /// A corrupt latest file fails visibly; never silently fall back to stale
  /// design content. Null means no draft was saved for this school.
  Future<Map<String, dynamic>?> loadDraft() async {
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    return _serial(() => Isolate.run(() => _readDraft(storageRoot, boundSchool, secret, previous: false)));
  }

  /// Opt-in recovery of the most recent retained previous revision. This
  /// operation does NOT mutate or replace the current draft.
  Future<Map<String, dynamic>?> readPreviousRevision() async {
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    return _serial(() => Isolate.run(() => _readDraft(storageRoot, boundSchool, secret, previous: true)));
  }
  Future<Map<String, dynamic>?> loadAppliedTemplate() async {
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    return _serial(() => Isolate.run(() => _readDraft(storageRoot, boundSchool, secret, previous: false, applied: true)));
  }

  /// Saving a draft never invokes this method. The caller must review the exact
  /// PDF and explicitly confirm applying this saved manifest revision.
  Future<void> applyReviewedDraft(Map<String, dynamic> draft, {
    required String reviewedManifestHash, required bool confirmed,
  }) async {
    if (!confirmed) throw StateError('Confirm applying the reviewed template');
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    await _serial(() => Isolate.run(() => _writeDraft(storageRoot, boundSchool, jsonEncode(draft), secret,
      applied: true, reviewedManifestHash: reviewedManifestHash)));
  }

  static String manifestHash(Map<String, dynamic> draft) =>
      sha256.convert(utf8.encode(jsonEncode(draft['manifest']))).toString();

  /// Explicit, bounded migration preserves every revision payload while
  /// replacing only validated plaintext files with authenticated envelopes.
  Future<int> migrateLegacy({required bool confirmed}) async {
    if (!confirmed) throw StateError('Confirm protected draft migration');
    final secret = await key;
    final storageRoot = rootPath, boundSchool = schoolId;
    return _serial(() => Isolate.run(() => _withSchoolLock(storageRoot, boundSchool, (root, stem) async {
      final prefix = _currentFile(root, stem).path;
      final inventory=root.listSync(followLinks:false);
      if(inventory.any((f)=>f is Link && (f.path==prefix||f.path.startsWith('$prefix.bak.'))))throw StateError('Linked draft revision requires review');
      final files = inventory.whereType<File>()
          .where((f) => f.path == prefix || f.path.startsWith('$prefix.bak.')).toList();
      if (files.length > 500) throw StateError('Draft revision inventory requires review');
      final cipher = IdCardLocalCipher(boundSchool, secret);
      var changed = 0;
      for (final file in files) {
        if(FileSystemEntity.isLinkSync(file.path)||file.lengthSync()>((IdCardDraftStorageIo.maxBytes + 256)*4~/3)+4096)throw StateError('Unsafe ID revision');
        final raw = file.readAsBytesSync();
        try { await cipher.open(raw, 'designer-draft', maxBytes: maxBytes + 256); continue; }
        on IdCardLegacyPlaintextException { /* Explicit legacy validation below. */ }
        _checkPlain(utf8.decode(raw), boundSchool);
        final sealed = await cipher.seal(raw, 'designer-draft');
        final temp = File('${file.path}.migration.$pid.${DateTime.now().microsecondsSinceEpoch}');
        temp.writeAsBytesSync(sealed, flush: true);
        // Rename replacement retains the old file on failure; encrypted temp
        // remains available for operator recovery if the filesystem fails.
        temp.renameSync(file.path);
        changed++;
      }
      return changed;
    })));
  }
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

Future<Map<String, dynamic>> _decodeAndCheck(String source, String schoolId, Uint8List secret, {String purpose = 'designer-draft'}) async {
  final plain = await IdCardLocalCipher(schoolId, secret).open(Uint8List.fromList(utf8.encode(source)), purpose, maxBytes: IdCardDraftStorageIo.maxBytes + 256);
  return _checkPlain(utf8.decode(plain), schoolId);
}

Map<String, dynamic> _checkPlain(String json, String schoolId) {
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

Future<T> _withSchoolLock<T>(
  String rootPath,
  String schoolId,
  Future<T> Function(Directory root, String stem) task,
) async {
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
      return await task(root, stem);
    } finally {
      lock.unlockSync();
    }
  } finally {
    lock.closeSync();
  }
}

File _currentFile(Directory root, String stem) =>
    File(root.path + Platform.pathSeparator + stem + '.draft.json');

Future<void> _writeDraft(String rootPath, String schoolId, String encoded, Uint8List secret, {bool applied = false, String? reviewedManifestHash}) async {
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
  final purpose = applied ? 'reviewed-template' : 'designer-draft';
  final encrypted = await IdCardLocalCipher(schoolId, secret).seal(Uint8List.fromList(utf8.encode(wrapped)), purpose);
  await _withSchoolLock(rootPath, schoolId, (root, stem) async {
    if (applied) {
      final saved = await _decodeAndCheck(_boundedText(_currentFile(root, stem)), schoolId, secret);
      if (reviewedManifestHash != IdCardDraftStorageIo.manifestHash(saved) ||
          reviewedManifestHash != IdCardDraftStorageIo.manifestHash(draft)) {
        throw StateError('Saved draft changed since review; reopen the PDF preview');
      }
    }
    final target = applied ? File('${root.path}${Platform.pathSeparator}$stem.applied.json') : _currentFile(root, stem);
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
      temp.writeAsBytesSync(encrypted, flush: true);
      if (target.existsSync()) {
        // Validate the old revision before replacing it. Do not hide
        // corruption by overwriting the only evidence.
        await _decodeAndCheck(_boundedText(target), schoolId, secret, purpose: purpose);
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

Future<Map<String, dynamic>?> _readDraft(
  String rootPath,
  String schoolId, Uint8List secret, {
  required bool previous, bool applied = false,
}) => _withSchoolLock(rootPath, schoolId, (root, stem) async {
  final target = applied ? File('${root.path}${Platform.pathSeparator}$stem.applied.json') : _currentFile(root, stem);
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
  return _decodeAndCheck(_boundedText(selected), schoolId, secret, purpose: applied ? 'reviewed-template' : 'designer-draft');
});

String _boundedText(File file) {
  if(FileSystemEntity.isLinkSync(file.path))throw StateError('Linked ID storage is unsafe');
  final budget=((IdCardDraftStorageIo.maxBytes + 256)*4~/3)+4096;
  if(file.lengthSync()>budget)throw const FormatException('Protected ID file exceeds size budget');
  return file.readAsStringSync();
}
