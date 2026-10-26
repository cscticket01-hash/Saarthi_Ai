import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'sync_recovery_policy.dart';
import 'windows_sync_recovery.dart';
import 'windows_connect/central_school_cloud.dart';

/// School-bound, content-addressed copies. Never modifies original files,
/// record references, queues or receipts. Metadata alone is never available.
class WindowsBinaryDownloads {
  WindowsBinaryDownloads({
    required this.schoolId,
    required this.storageDirectory,
    required this.currentSchool,
    required this.request,
    DateTime Function()? now,
    double Function()? jitter,
  }) : now = now ?? DateTime.now,
       jitter = jitter ?? Random.secure().nextDouble {
    if (!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(schoolId)) {
      throw ArgumentError('Invalid school identity');
    }
  }

  final String schoolId;
  final Directory storageDirectory;
  final String Function() currentSchool;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) request;
  final DateTime Function() now;
  final double Function() jitter;
  static const retryLimit = 3;
  static const maxBytes = 20 * 1024 * 1024;
  static const maxItems = 1000;
  final Map<String, Map<String, dynamic>> _items = {};
  final Set<String> _seenInventory = {};
  bool _loaded = false;
  bool _inventoryInspected = false;
  bool _busy = false;
  bool _available = false;
  bool _partial = true;
  bool _cycleUnverified = false;
  String? _cursor;
  String? _fingerprint;
  String? _failure;
  int _observedAt = 0;
  int _lastDownload = 0;
  int _generation = 0;
  int _quotaRetryAt = 0;
  bool _rangeSupported = false;
  static final Set<String> _activeRanges = {};
  String? _repairBlockedCategory;

  Directory get schoolDirectory => Directory(
    '${storageDirectory.path}${Platform.pathSeparator}$schoolId',
  );

  void _guard() {
    if (currentSchool() != schoolId) {
      throw StateError('School changed; download operation stopped.');
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action, {bool inspectOnLoad = true}) async {
    if (_busy) throw StateError('A binary verification is already running.');
    _guard();
    _busy = true;
    try {
      await _load(verifyFiles: inspectOnLoad);
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<void> _safeDirectory() async {
    // Reject links in every existing ancestor, not just the cache leaf.
    Directory cursor = schoolDirectory.absolute;
    while (true) {
      final type = await FileSystemEntity.type(cursor.path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.directory)) {
        throw StateError('Unsafe binary cache location');
      }
      final parent = cursor.parent;
      if (parent.path == cursor.path) break;
      cursor = parent;
    }
    _guard();
    await schoolDirectory.create(recursive: true);
  }

  File _binary(String digest) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw StateError('Invalid binary cache identity');
    }
    return File('${schoolDirectory.path}${Platform.pathSeparator}$digest.bin');
  }

  Future<bool> _verified(String digest, int size) async {
    final file = _binary(digest);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) return false;
    if (await file.length() != size) return false;
    final modified = await file.lastModified();
    final actual = await sha256.bind(file.openRead()).first;
    _guard();
    return actual.toString() == digest && await file.length() == size &&
        await file.lastModified() == modified;
  }

  Future<void> _load({bool verifyFiles = true}) async {
    if (_loaded) {
      if (verifyFiles && !_inventoryInspected) { await _inspect(); _inventoryInspected = true; }
      return;
    }
    await _safeDirectory();
    final allEntities = await schoolDirectory.list().toList();
    for (final entity in allEntities) {
      final match = RegExp(r'[/\\]inventory-(\d{20})\.json(?:\.part)?$').firstMatch(entity.path);
      if (match != null) {
        final value = int.parse(match.group(1)!);
        if (value > _generation) _generation = value;
      }
    }
    final journals = allEntities.where((entity) =>
      entity is File && RegExp(r'[/\\]inventory-\d{20}\.json$').hasMatch(entity.path),
    ).cast<File>().toList();
    journals.sort((a, b) => b.path.compareTo(a.path));
    if (journals.isNotEmpty) {
      // A corrupt newest journal is not silently replaced with stale success.
      final file = journals.first;
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file || await file.length() > 2 * 1024 * 1024) {
        throw StateError('Invalid binary download journal');
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['schoolId'] != schoolId ||
          decoded['schemaVersion'] != 1 || decoded['items'] is! Map ||
          (decoded['items'] as Map).length > maxItems) {
        throw StateError('Foreign or unsupported binary download journal');
      }
      final entries = Map<String, dynamic>.from(decoded['items'] as Map);
      for (final entry in entries.entries) {
        if (!_validId(entry.key) || entry.value is! Map) {
          throw StateError('Invalid binary download journal entry');
        }
        final item = Map<String, dynamic>.from(entry.value as Map);
        _validateItem(item);
        if (item['state'] == 'downloading') item['state'] = 'interrupted';
        if (item['state'] == 'verified') item['state'] = 'unverified';
        _items[entry.key] = item;
      }
      final recordedGeneration = decoded['generation'] as int;
      if (recordedGeneration > _generation) _generation = recordedGeneration;
      final seen = decoded['seenInventory'];
      if (seen is List && seen.length <= maxItems && seen.every(_validId)) {
        _seenInventory.addAll(seen.cast<String>());
      }
      _lastDownload = decoded['lastVerifiedDownloadAt'] as int;
      _observedAt = decoded['observedAt'] as int;
      _cursor = decoded['cursor'] as String?;
      _fingerprint = decoded['inventoryFingerprint'] as String?;
      _cycleUnverified = decoded['cycleUnverified'] == true;
      _quotaRetryAt = decoded['quotaRetryAt'] as int? ?? 0;
      _rangeSupported = decoded['binaryRangeVersion'] == 1;
      _repairBlockedCategory = decoded['repairBlockedCategory'] as String?;
      // Previous inventory is historical until an authenticated refresh succeeds.
      _available = false;
      _partial = true;
    }
    _loaded = true;
    if (verifyFiles) { await _inspect(); _inventoryInspected = true; }
  }

  bool _validId(dynamic id) => id is String &&
    RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(id);

  void _validateItem(Map<String, dynamic> item) {
    if (!_validId(item['fileId']) || item['name'] is! String ||
        (item['name'] as String).length > 1000 || item['mime'] is! String ||
        (item['mime'] as String).length > 200 ||
        item['sizeBytes'] is! int || (item['sizeBytes'] as int) < 0) {
      throw StateError('Invalid binary inventory item');
    }
    if (item['verification'] == 'bytes_hashed') {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(item['sha256']?.toString() ?? '') ||
          item['version'] is! String || (item['version'] as String).isEmpty ||
          (item['version'] as String).length > 150 ||
          (item['sizeBytes'] as int) < 1 || (item['sizeBytes'] as int) > maxBytes) {
        throw StateError('Invalid cloud binary hash or version');
      }
    } else if (item['verification'] != 'unavailable') {
      throw StateError('Unverified binary inventory item');
    }
    if (item.containsKey('previousSha256') &&
        (!RegExp(r'^[a-f0-9]{64}$').hasMatch(item['previousSha256'].toString()) ||
         item['previousSizeBytes'] is! int ||
         (item['previousSizeBytes'] as int) < 1 ||
         (item['previousSizeBytes'] as int) > maxBytes)) {
      throw StateError('Invalid preserved binary version');
    }
  }

  Future<void> _save() async {
    _guard();
    await _safeDirectory();
    _generation++;
    final target = File('${schoolDirectory.path}${Platform.pathSeparator}'
        'inventory-${_generation.toString().padLeft(20, '0')}.json');
    if (await target.exists()) throw StateError('Binary journal collision');
    final temporary = File('${target.path}.part');
    if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('Interrupted binary journal requires review');
    }
    await temporary.writeAsString(jsonEncode({
      'schemaVersion': 1, 'schoolId': schoolId, 'generation': _generation,
      'lastVerifiedDownloadAt': _lastDownload, 'observedAt': _observedAt,
      'cursor': _cursor, 'cycleUnverified': _cycleUnverified,
      'seenInventory': _seenInventory.toList(), 'items': _items,
      'inventoryFingerprint': _fingerprint,
      'quotaRetryAt': _quotaRetryAt,
      'binaryRangeVersion': _rangeSupported ? 1 : 0,
      'repairBlockedCategory': _repairBlockedCategory,
    }), flush: true);
    _guard();
    await temporary.rename(target.path); // Unique target: atomic on Windows too.
  }

  Future<void> load() => _exclusive(() async {});

  /// One bounded authenticated page; no automatic unbounded inventory loop.
  Future<void> refreshInventory({bool restart = false}) => _exclusive(() async {
    if (restart) _cursor = null;
    if (_cursor == null) { _cycleUnverified = false; _seenInventory.clear(); _fingerprint = null; }
    try {
      final response = await request({
        'action': 'managed/file/inventory', 'schoolId': schoolId,
        if (_cursor != null) 'cursor': _cursor,
      }).timeout(const Duration(seconds: 40));
      _guard();
      if (response['success'] != true || response['schoolId'] != schoolId ||
          response['binaryInventoryVersion'] != 1 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(response['inventoryFingerprint']?.toString() ?? '') ||
          response['inventoryScope'] != 'application_media_folders' ||
          response['items'] is! List || (response['items'] as List).length > 5 ||
          response['partial'] is! bool || response['scanLimited'] is! bool ||
          response['coverageComplete'] is! bool || response['observedAt'] is! int ||
          (response['nextCursor'] != null && !_validId(response['nextCursor']))) {
        throw StateError('Authoritative binary inventory unavailable');
      }
      if (_cursor != null && _fingerprint != response['inventoryFingerprint']) {
        throw StateError('Cloud file inventory changed; restart verification.');
      }
      _rangeSupported = response['binaryRangeVersion'] == 1;
      _fingerprint = response['inventoryFingerprint'] as String;
      final page = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final raw in response['items'] as List) {
        if (raw is! Map) throw StateError('Invalid binary inventory');
        final received = Map<String, dynamic>.from(raw);
        final item = <String, dynamic>{for (final key in ['fileId','name','mime','sizeBytes','sha256','version','verification','reason'])
          if (received.containsKey(key)) key: received[key]};
        _validateItem(item);
        if (!seen.add(item['fileId'] as String)) {
          throw StateError('Duplicate cloud binary inventory');
        }
        page.add(item);
      }
      if ({..._items.keys, ...seen}.length > maxItems) {
        throw StateError('Binary inventory exceeds safe local limit');
      }
      for (final item in page) {
        final id = item['fileId'] as String;
        final old = _items[id];
        final same = (old == null ? null : old['sha256']) == item['sha256'] &&
                     (old == null ? null : old['version']) == item['version'];
        final previous = (old == null ? null : old['state']) == 'verified' ? (old == null ? null : old['sha256']) :
                         (old == null ? null : old['previousSha256']);
        final previousSize = (old == null ? null : old['state']) == 'verified' ? (old == null ? null : old['sizeBytes']) :
                             (old == null ? null : old['previousSizeBytes']);
        _items[id] = {
          ...item, 'expected': true,
          'state': same ? (old == null ? null : old['state']) ?? 'pending' : 'pending',
          if (same && old != null) 'retryAttempts': old['retryAttempts'] ?? 0,
          if (same && old != null) 'retryAt': old['retryAt'] ?? 0,
          if (same && old != null && old['transferOffset'] != null)
            'transferOffset': old['transferOffset'],
          if (same && old != null && old['transferHash'] != null)
            'transferHash': old['transferHash'],
          // Inventory metadata cannot grant download authorization.
          if (old?['automaticRetryBlocked'] == true) ...{
            'automaticRetryBlocked': true,
            'failureCategory': old!['failureCategory'],
          },
          if (previous != null) 'previousSha256': previous,
          if (previousSize != null) 'previousSizeBytes': previousSize,
        };
        if (item['verification'] != 'bytes_hashed') {
          _items[id]!['state'] = 'unavailable';
          _cycleUnverified = true;
        }
      }
      _seenInventory.addAll(seen);
      _cursor = response['nextCursor'] as String?;
      if (_cursor == null && response['scanLimited'] == false) {
        for (final entry in _items.entries) {
          entry.value['expected'] = _seenInventory.contains(entry.key);
        }
      }
      _cycleUnverified = _cycleUnverified || response['scanLimited'] == true;
      _available = true;
      _partial = response['coverageComplete'] != true || _cycleUnverified;
      _observedAt = response['observedAt'] as int;
      _failure = null;
      await _inspect();
      await _save();
    } catch (error) {
      _available = false;
      _partial = true;
      _failure = error is TimeoutException ? 'timeout' : 'inventory_unavailable';
      rethrow;
    }
  });

  Future<void> _inspect() async {
    for (final item in _items.values) {
      if (item['verification'] != 'bytes_hashed') continue;
      if (await _verified(item['sha256'] as String, item['sizeBytes'] as int)) {
        item['state'] = 'verified';
      } else if (item['state'] == 'verified' || item['state'] == 'unverified') {
        final file = _binary(item['sha256'] as String);
        item['state'] = await file.exists() ? 'damaged' : 'missing';
      }
    }
  }

  Future<void> inspectLocal() => _exclusive(() async {
    await _inspect();
    await _save();
  });

  File _rangeFile(Map<String, dynamic> item) {
    final key = sha256.convert(utf8.encode('${item['fileId']}/${item['version']}/${item['sha256']}'));
    return File('${schoolDirectory.path}${Platform.pathSeparator}$key.transfer.part');
  }

  Future<List<int>> _downloadBytes(Map<String, dynamic> item) async {
    if (_rangeSupported) {
      try { return await _downloadRange(item); }
      on CentralCloudException catch (error) {
        if (error.status != 400 && error.status != 404) rethrow;
        // A broker rollback must prove that the negotiated capability is gone.
        // Access/quota failures never enter this backward-compatible fallback.
        final capability = await request({'action': 'managed/file/inventory', 'schoolId': schoolId})
            .timeout(const Duration(seconds: 40));
        _guard();
        if (capability['success'] != true || capability['schoolId'] != schoolId ||
            capability['binaryInventoryVersion'] != 1 || capability['binaryRangeVersion'] == 1) rethrow;
        _rangeSupported = false;
      }
    }
    final response = await request({
        'action': 'managed/file/download', 'schoolId': schoolId,
        'fileId': item['fileId'], 'expectedSha256': item['sha256'],
        'expectedVersion': item['version'],
      }).timeout(const Duration(seconds: 40));
      _guard();
      if (response['success'] != true || response['schoolId'] != schoolId ||
          response['binaryDownloadVersion'] != 1 ||
          response['fileId'] != item['fileId'] ||
          response['sha256'] != item['sha256'] || response['version'] != item['version'] ||
          response['sizeBytes'] != item['sizeBytes'] || response['base64'] is! String ||
          (response['base64'] as String).length > 28 * 1024 * 1024) {
        throw StateError('Unverified binary download');
      }
      return base64Decode(response['base64'] as String);
  }

  Future<List<int>> _downloadRange(Map<String, dynamic> item) async {
    final file = _rangeFile(item);
    if (!_activeRanges.add(file.path)) throw StateError('Binary transfer already active.');
    try {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.file && type != FileSystemEntityType.notFound) {
        throw StateError('Unsafe partial binary transfer.');
      }
      var offset = item['transferOffset'] as int? ?? 0;
      final size = item['sizeBytes'] as int;
      var reusable = type == FileSystemEntityType.file && offset > 0 && offset <= size;
      if (reusable) {
        reusable = await file.length() == offset &&
            (await sha256.bind(file.openRead()).first).toString() == item['transferHash'];
      }
      if (!reusable) {
        if (type == FileSystemEntityType.file) {
          final quarantine = '${file.path}.unverified-$_generation';
          if (await FileSystemEntity.type(quarantine, followLinks: false) != FileSystemEntityType.notFound) {
            throw StateError('Partial binary evidence collision.');
          }
          await file.rename(quarantine);
        }
        offset = 0;
        await file.writeAsBytes(const [], flush: true);
      }
      for (var chunks = 0; offset < size && chunks < 80; chunks++) {
        _guard();
        final response = await request({
          'action': 'managed/file/download/part', 'schoolId': schoolId,
          'fileId': item['fileId'], 'expectedSha256': item['sha256'],
          'expectedVersion': item['version'], 'offset': offset, 'length': 256 * 1024,
        }).timeout(const Duration(seconds: 40));
        _guard();
        if (response['success'] != true || response['schoolId'] != schoolId ||
            response['binaryRangeVersion'] != 1 || response['fileId'] != item['fileId'] ||
            response['version'] != item['version'] || response['sha256'] != item['sha256'] ||
            response['sizeBytes'] != size || response['offset'] != offset ||
            response['base64'] is! String || (response['base64'] as String).length > 350000) {
          throw StateError('Unverified binary transfer range.');
        }
        final chunk = base64Decode(response['base64'] as String);
        if (chunk.isEmpty || chunk.length > 256 * 1024 || offset + chunk.length > size ||
            response['nextOffset'] != offset + chunk.length ||
            sha256.convert(chunk).toString() != response['chunkSha256']) {
          throw StateError('Partial binary integrity check failed.');
        }
        await file.writeAsBytes(chunk, mode: FileMode.append, flush: true);
        _guard();
        offset += chunk.length;
        item['transferOffset'] = offset;
        item['transferHash'] = (await sha256.bind(file.openRead()).first).toString();
        await _save(); // Verified prefix is durable before requesting more bytes.
      }
      if (offset != size) throw StateError('Binary range budget exceeded.');
      return await file.readAsBytes(); // Final whole-file hash is checked by owner.
    } finally { _activeRanges.remove(file.path); }
  }

  /// Complete restart-safe retry of one item. Partial files never count as ACKs.
  /// Original usable version is retained until the new hash has been verified.
  Future<bool> repairNext({bool administratorRetry = false}) => _exclusive(() async {
    // A local retry button cannot override a provider quota cooldown. Shared
    // access/configuration denial blocks the entire lane, including new files.
    if (_quotaRetryAt > now().millisecondsSinceEpoch ||
        (_repairBlockedCategory != null && !administratorRetry)) return false;
    await _inspect();
    final candidates = _items.values.where((item) =>
      item['expected'] != false && item['verification'] == 'bytes_hashed' && item['state'] != 'verified').toList();
    if (candidates.isEmpty) return false;
    final eligible = candidates.where((item) =>
      item['automaticRetryBlocked'] != true &&
      (item['retryAttempts'] as int? ?? 0) < retryLimit &&
      (item['retryAt'] as int? ?? 0) <= now().millisecondsSinceEpoch);
    if (eligible.isEmpty && !administratorRetry) return false;
    final item = eligible.isNotEmpty ? eligible.first : candidates.first;
    if (eligible.isEmpty) {
      item['retryAttempts'] = 0;
      item.remove('automaticRetryBlocked');
    }
    final attempt = (item['retryAttempts'] as int? ?? 0) + 1;
    final delaySeconds = min(300, 5 * pow(2, attempt - 1)).toDouble();
    final random = jitter().clamp(0.0, 1.0);
    item['retryAttempts'] = attempt;
    item['retryAt'] = now().millisecondsSinceEpoch +
        (delaySeconds * (0.75 + random * 0.5) * 1000).round();
    item['state'] = 'downloading';
    await _save(); // Persist intent before any network operation.
    File? part;
    try {
      final bytes = await _downloadBytes(item);
      if (bytes.length != item['sizeBytes'] || bytes.length > maxBytes ||
          sha256.convert(bytes).toString() != item['sha256']) {
        throw StateError('Downloaded bytes failed integrity verification');
      }
      final target = _binary(item['sha256'] as String);
      part = File('${target.path}.${_generation.toString()}.part');
      if (await FileSystemEntity.type(part.path, followLinks: false) !=
          FileSystemEntityType.notFound) throw StateError('Unsafe download staging');
      await part.writeAsBytes(bytes, flush: true);
      if (await part.length() != bytes.length ||
          (await sha256.bind(part.openRead()).first).toString() != item['sha256']) {
        throw StateError('Staged bytes failed integrity verification');
      }
      _guard();
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        if (!await _verified(item['sha256'] as String, item['sizeBytes'] as int)) {
          // Preserve damaged evidence and use a fresh unique verified cache path.
          final quarantine = '${target.path}.damaged-${_generation.toString()}';
          if (await FileSystemEntity.type(quarantine, followLinks: false) !=
              FileSystemEntityType.notFound) throw StateError('Damaged cache collision');
          await target.rename(quarantine);
          _guard();
          await part.rename(target.path);
        } else {
          await part.delete();
        }
      } else {
        await part.rename(target.path);
      }
      if (!await _verified(item['sha256'] as String, item['sizeBytes'] as int)) {
        throw StateError('Final binary readback failed');
      }
      item['state'] = 'verified';
      item.remove('failure');
      item.remove('failureCategory');
      item.remove('automaticRetryBlocked');
      item['retryAttempts'] = 0;
      item['retryAt'] = 0;
      _lastDownload = now().millisecondsSinceEpoch;
      _repairBlockedCategory = null;
      _failure = null;
      item.remove('transferOffset');item.remove('transferHash');
      await _save();
      final transfer = _rangeFile(item);
      if (await FileSystemEntity.type(transfer.path, followLinks: false) == FileSystemEntityType.file) {
        try { await transfer.delete(); } catch (_) { /* verified bytes remain usable */ }
      }
      return true;
    } catch (error) {
      item['state'] = error is TimeoutException ? 'interrupted' : 'failed';
      item['failure'] = error is TimeoutException ? 'timeout' : 'download_unverified';
      final decision = windowsSyncRecovery(error);
      item['failureCategory'] = decision.kind.name;
      if ({
        SyncFailureKind.authorization,
        SyncFailureKind.configuration,
        SyncFailureKind.conflict,
        SyncFailureKind.validation,
      }.contains(decision.kind)) {
        item['automaticRetryBlocked'] = true;
        if ({SyncFailureKind.authorization, SyncFailureKind.configuration}
            .contains(decision.kind)) {
          _repairBlockedCategory = decision.kind.name;
        }
      } else if (decision.kind == SyncFailureKind.quota) {
        // Stop the shared media lane for the existing quota-policy cooldown.
        final deadline = now().add(decision.delay(attempt, jitter: random))
            .millisecondsSinceEpoch;
        _quotaRetryAt = max(_quotaRetryAt, deadline);
        for (final pending in _items.values) {
          if (pending['state'] != 'verified' &&
              (pending['retryAt'] as int? ?? 0) < deadline) {
            pending['retryAt'] = deadline;
          }
        }
      }
      _failure = item['failure'] as String;
      if (currentSchool() == schoolId) await _save();
      rethrow;
    }
  });

  /// Returned only after checking actual bytes; falls back to the prior usable
  /// version when a newer cloud download is pending, interrupted or invalid.
  Future<String?> verifiedPath(String fileId) => _exclusive(() async {
    final item = _items[fileId];
    if (item == null) return null;
    if (item['verification'] == 'bytes_hashed' &&
        await _verified(item['sha256'] as String, item['sizeBytes'] as int)) {
      item['state'] = 'verified';
      return _binary(item['sha256'] as String).path;
    }
    if (item['previousSha256'] != null &&
        await _verified(item['previousSha256'] as String, item['previousSizeBytes'] as int)) {
      return _binary(item['previousSha256'] as String).path;
    }
    return null;
  }, inspectOnLoad: false);

  List<Map<String,dynamic>> get entries {
    _guard();
    return _items.values.where((item)=>item['expected']!=false).map((item)=>Map<String,dynamic>.unmodifiable(item)).toList(growable:false);
  }

  Map<String, dynamic> get summary {
    _guard();
    final expected = _items.values.where((item) => item['expected'] != false);
    int count(String state) => expected.where((item) => item['state'] == state).length;
    final verified = expected.where((item) => item['state'] == 'verified');
    final awaiting = expected.where((item) => item['verification'] == 'bytes_hashed' && item['state'] != 'verified');
    final deadlines = awaiting.where((item) => item['automaticRetryBlocked'] != true && (item['retryAttempts'] as int? ?? 0) < retryLimit)
      .map((item) => item['retryAt'] as int? ?? 0).where((value) => value > now().millisecondsSinceEpoch).toList();
    deadlines.sort();
    return {
      'schoolId': schoolId, 'scope': 'application_media_folders',
      'inventory': !_available ? 'UNKNOWN' : _partial ? 'PARTIAL' : 'VERIFIED',
      'knownFiles': expected.length, 'retainedHistoricalFiles': _items.length - expected.length, 'verifiedFiles': count('verified'),
      'pending': count('pending') + count('downloading') + count('unverified'),
      'unverifiedLocal': count('unverified'),
      'failed': count('failed'), 'interrupted': count('interrupted'),
      'missing': count('missing'), 'damaged': count('damaged'),
      'unavailable': count('unavailable'),
      'verifiedBytes': verified.fold<int>(0, (sum, item) => sum + (item['sizeBytes'] as int)),
      'knownBytes': expected.fold<int>(0, (sum, item) => sum + (item['sizeBytes'] as int)),
      'lastVerifiedDownloadAt': _lastDownload, 'observedAt': _observedAt,
      'retryAt': deadlines.isEmpty ? 0 : deadlines.first,
      'retryBlocked': awaiting.where((item) =>
        item['automaticRetryBlocked'] == true ||
        (item['retryAttempts'] as int? ?? 0) >= retryLimit).length,
      'reviewRequired': awaiting.where((item) => item['automaticRetryBlocked'] == true).length,
      'repairBlockedCategory': _repairBlockedCategory,
      'quotaRetryAt': _quotaRetryAt,
      'hasMore': _cursor != null, 'busy': _busy, 'failure': _failure,
    };
  }
}
