import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_binary_downloads.dart';
import '../lib/windows_connect/central_school_cloud.dart';

void main() {
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const other = 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  late Directory temporary;
  late String activeSchool;
  late int clock;
  late List<int> original;
  late Map<String, dynamic> expected;
  late Future<Map<String, dynamic>> Function(Map<String, dynamic>) remote;
  WindowsBinaryDownloads manager() => WindowsBinaryDownloads(
    schoolId: school, storageDirectory: temporary,
    currentSchool: () => activeSchool, request: (body) => remote(body),
    now: () => DateTime.fromMillisecondsSinceEpoch(clock), jitter: () => 0.5,
  );
  Map<String, dynamic> inventory(List<Map<String, dynamic>> items, {
    bool partial = false, String? cursor,
  }) => {
    'success': true, 'schoolId': school, 'binaryInventoryVersion': 1,
    'inventoryFingerprint': sha256.convert(utf8.encode('stable test inventory')).toString(),
    'inventoryScope': 'application_media_folders', 'items': items,
    'observedAt': 1799999999000, 'partial': partial,
    'scanLimited': false, 'coverageComplete': !partial, 'nextCursor': cursor,
  };
  Map<String, dynamic> download(Map<String, dynamic> item, List<int> bytes) => {
    ...item, 'success': true, 'schoolId': school, 'binaryDownloadVersion': 1,
    'base64': base64Encode(bytes),
  };
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('isolated-binary-');
    activeSchool = school;
    clock = 1800000000000;
    original = utf8.encode('original synthetic PDF bytes');
    expected = {
      'fileId': 'school_file_1', 'name': 'synthetic.pdf',
      'mime': 'application/pdf', 'sizeBytes': original.length,
      'sha256': sha256.convert(original).toString(), 'version': 'original-1',
      'verification': 'bytes_hashed',
    };
    remote = (body) async => body['action'] == 'managed/file/inventory'
        ? inventory([expected]) : download(expected, original);
  });
  tearDown(() async { await temporary.delete(recursive: true); });

  test('metadata stays pending until actual hash-verified byte download', () async {
    final cache = manager();
    await cache.refreshInventory();
    expect(cache.summary['knownFiles'], 1);
    expect(cache.summary['verifiedFiles'], 0);
    expect(cache.summary['pending'], 1);
    expect(await cache.verifiedPath('school_file_1'), isNull);
    expect(await cache.repairNext(), isTrue);
    expect(cache.summary['verifiedFiles'], 1);
    expect(cache.summary['verifiedBytes'], original.length);
    expect(cache.summary['lastVerifiedDownloadAt'], 1800000000000);
    final path = await cache.verifiedPath('school_file_1');
    expect(await File(path!).readAsBytes(), original);
    expect(await cache.repairNext(), isFalse);
  });

  test('restart verifies durable bytes and marks inventory freshness unknown', () async {
    final first = manager();
    await first.refreshInventory();await first.repairNext();
    final second = manager();await second.load();
    expect(second.summary['verifiedFiles'], 1);
    expect(second.summary['inventory'], 'UNKNOWN');
    expect(await File((await second.verifiedPath('school_file_1'))!).readAsBytes(), original);
  });

  test('broken newer replacement preserves previous usable offline original', () async {
    final cache = manager();await cache.refreshInventory();await cache.repairNext();
    final originalPath = await cache.verifiedPath('school_file_1');
    final replacement = utf8.encode('newer cloud PDF');
    expected = {...expected, 'sha256': sha256.convert(replacement).toString(),
      'version': 'newer-2', 'sizeBytes': replacement.length};
    remote = (body) async => body['action'] == 'managed/file/inventory'
      ? inventory([expected]) : download(expected, utf8.encode('corrupt'));
    await cache.refreshInventory(restart: true);
    await expectLater(cache.repairNext(), throwsStateError);
    expect(cache.summary['failed'], 1);
    expect(cache.summary['verifiedFiles'], 0);
    expect(await cache.verifiedPath('school_file_1'), originalPath);
    expect(await File(originalPath!).readAsBytes(), original);
    final restarted = manager();await restarted.load();
    expect(await restarted.verifiedPath('school_file_1'), originalPath);
  });

  test('missing and corrupt cache are detected and repaired from verified original', () async {
    final cache = manager();await cache.refreshInventory();await cache.repairNext();
    final path = (await cache.verifiedPath('school_file_1'))!;
    await File(path).delete();await cache.inspectLocal();
    expect(cache.summary['missing'], 1);
    await cache.repairNext();expect(await File(path).readAsBytes(), original);
    await File(path).writeAsString('damaged original cache');await cache.inspectLocal();
    expect(cache.summary['damaged'], 1);expect(cache.summary['verifiedFiles'], 0);
    await cache.repairNext();expect(await File(path).readAsBytes(), original);
    expect((await cache.schoolDirectory.list().toList()).any((e) => e.path.contains('.damaged-')), isTrue);
  });

  test('unavailable inventory and HTTP failures retain real cached files', () async {
    final cache = manager();await cache.refreshInventory();await cache.repairNext();
    remote = (_) async => throw StateError('HTTP 502');
    await expectLater(cache.refreshInventory(), throwsStateError);
    expect(cache.summary['inventory'], 'UNKNOWN');
    expect(cache.summary['verifiedFiles'], 1);
    expect(await cache.verifiedPath('school_file_1'), isNotNull);
  });

  test('timeout retains pending evidence and allows restart recovery', () async {
    final cache = manager();await cache.refreshInventory();
    remote = (_) async => throw TimeoutException('isolated timeout');
    await expectLater(cache.repairNext(), throwsA(isA<TimeoutException>()));
    expect(cache.summary['interrupted'], 1);expect(cache.summary['verifiedFiles'], 0);
    final restarted = manager();await restarted.load();
    expect(restarted.summary['interrupted'], 1);
    remote = (_) async => download(expected, original);
    expect(await restarted.repairNext(), isFalse);
    clock += 6000;
    await restarted.repairNext();expect(restarted.summary['verifiedFiles'], 1);
  });

  test('school switch and foreign API bytes cannot leak into active cache', () async {
    final cache = manager();await cache.refreshInventory();
    remote = (_) async => {...download(expected, original), 'schoolId': other};
    await expectLater(cache.repairNext(), throwsStateError);
    expect(cache.summary['verifiedFiles'], 0);
    clock += 6000;
    remote = (_) async { activeSchool = other;return download(expected, original); };
    await expectLater(cache.repairNext(), throwsStateError);
    expect(() => cache.summary, throwsStateError);
    activeSchool = school;
    final restarted = manager();await restarted.load();
    expect(restarted.summary['interrupted'], 1);
    expect(await restarted.verifiedPath('school_file_1'), isNull);
  });

  test('paginated scope stays partial until final authenticated page', () async {
    final cache = manager();
    final second = {...expected, 'fileId': 'school_file_2'};
    remote = (body) async => body['cursor'] == null
      ? inventory([expected], partial: true, cursor: 'school_file_1')
      : inventory([second]);
    await cache.refreshInventory();expect(cache.summary['inventory'], 'PARTIAL');
    expect(cache.summary['hasMore'], isTrue);
    await cache.refreshInventory();expect(cache.summary['inventory'], 'VERIFIED');
    expect(cache.summary['knownFiles'], 2);expect(cache.summary['verifiedFiles'], 0);
  });

  test('whole page rejects duplicate and foreign metadata without fabricated counts', () async {
    final cache = manager();
    remote = (_) async => inventory([expected, expected]);
    await expectLater(cache.refreshInventory(), throwsStateError);
    expect(cache.summary['knownFiles'], 0);expect(cache.summary['inventory'], 'UNKNOWN');
    remote = (_) async => {...inventory([expected]), 'schoolId': other};
    await expectLater(cache.refreshInventory(), throwsStateError);
    expect(cache.summary['knownFiles'], 0);
  });

  test('completed empty inventory keeps historical originals accessible', () async {
    final cache = manager();await cache.refreshInventory();await cache.repairNext();
    remote = (_) async => inventory([]);
    await cache.refreshInventory(restart: true);
    expect(cache.summary['knownFiles'], 0);
    expect(cache.summary['retainedHistoricalFiles'], 1);
    expect(await cache.verifiedPath('school_file_1'), isNotNull);
  });

  test('orphan journal temp does not prevent interrupted download retry', () async {
    final cache = manager();await cache.refreshInventory();
    final orphan = File('${cache.schoolDirectory.path}${Platform.pathSeparator}'
      'inventory-00000000000000000002.json.part');
    await orphan.writeAsString('interrupted journal');
    final restarted = manager();await restarted.load();await restarted.repairNext();
    expect(restarted.summary['verifiedFiles'], 1);
    expect(await orphan.readAsString(), 'interrupted journal');
  });

  test('normal image lookup verifies only its file, leaving other bytes unverified until inventory inspection', () async {
    final first = manager();
    final second = {...expected, 'fileId':'school_file_2', 'sha256':sha256.convert(utf8.encode('second original')).toString(),
      'sizeBytes':utf8.encode('second original').length, 'version':'second-1'};
    remote = (body) async {
      if(body['action']=='managed/file/inventory')return inventory([expected,second]);
      return body['fileId']=='school_file_1'?download(expected,original):download(second,utf8.encode('second original'));
    };
    await first.refreshInventory();await first.repairNext();await first.repairNext();
    final otherPath=(await first.verifiedPath('school_file_2'))!;
    await File(otherPath).writeAsString('damaged unrelated image');
    final restarted=manager();
    expect(await restarted.verifiedPath('school_file_1'),isNotNull);
    expect(restarted.summary['verifiedFiles'],1);
    expect(restarted.summary['unverifiedLocal'],1);
    expect(restarted.summary['damaged'],0);
    await restarted.load();
    expect(restarted.summary['unverifiedLocal'],0);
    expect(restarted.summary['damaged'],1);
  });

  test('bounded persisted retry budget stops repeated outages and needs admin restart', () async {
    final cache = manager();await cache.refreshInventory();
    remote = (_) async => throw StateError('HTTP 503');
    for (var attempt = 0; attempt < 3; attempt++) {
      await expectLater(cache.repairNext(), throwsStateError);
      expect(await cache.repairNext(), isFalse);
      clock += 400000;
    }
    expect(cache.summary['retryBlocked'], 1);
    final restarted = manager();await restarted.load();
    expect(await restarted.repairNext(), isFalse);
    remote = (_) async => download(expected, original);
    expect(await restarted.repairNext(administratorRetry: true), isTrue);
    expect(restarted.summary['verifiedFiles'], 1);
    expect(restarted.summary['retryBlocked'], 0);
  });

  test('cache directory links and foreign sealed journal are rejected', () async {
    final foreign = Directory('${temporary.path}${Platform.pathSeparator}$school');
    await foreign.create();
    await File('${foreign.path}${Platform.pathSeparator}inventory-00000000000000000001.json')
      .writeAsString(jsonEncode({'schemaVersion':1, 'schoolId':other, 'items':{}}));
    await expectLater(manager().load(), throwsStateError);
  });
  for (final status in [401, 403, 409, 422]) {
    test('HTTP $status media failure requires review across restart and refresh', () async {
      final cache = manager();await cache.refreshInventory();
      var reads = 0;
      remote = (_) async {
        reads++;
        throw CentralCloudException(status, 'school_cloud', 'synthetic protected failure');
      };
      await expectLater(cache.repairNext(), throwsA(isA<CentralCloudException>()));
      expect(cache.summary['reviewRequired'], 1);
      clock += 400000;
      final restarted = manager();await restarted.load();
      expect(await restarted.repairNext(), false);
      expect(reads, 1);
      remote = (_) async => inventory([{...expected, 'version': 'newer-version'}]);
      await restarted.refreshInventory(restart: true);
      expect(await restarted.repairNext(), false);
      expect(restarted.summary['reviewRequired'], 1);
      expect(await restarted.verifiedPath('school_file_1'), isNull);
    });
  }

  test('quota cooldown covers other files and survives cache restart', () async {
    final cache = manager(), second = {...expected, 'fileId': 'school_file_2'};
    remote = (_) async => inventory([expected, second]);
    await cache.refreshInventory();
    var reads = 0;
    remote = (_) async {
      reads++;
      throw CentralCloudException(429, 'school_cloud', 'synthetic quota');
    };
    await expectLater(cache.repairNext(), throwsA(isA<CentralCloudException>()));
    final restarted = manager();await restarted.load();
    expect(await restarted.repairNext(), false);
    expect(await restarted.repairNext(administratorRetry: true), false);
    expect(reads, 1);
    expect(restarted.summary['retryAt'], greaterThan(clock + 59000));
    clock += 70000;
    remote = (body) async => download(body['fileId'] == 'school_file_1' ? expected : second, original);
    expect(await restarted.repairNext(), true);
  });

  for (final status in [502, 503]) {
    test('HTTP $status media recovery waits for durable cooldown then verifies exact bytes', () async {
      final cache = manager();await cache.refreshInventory();
      remote = (_) async => throw CentralCloudException(status, 'school_cloud', 'synthetic temporary failure');
      await expectLater(cache.repairNext(), throwsA(isA<CentralCloudException>()));
      final restarted = manager();await restarted.load();
      expect(await restarted.repairNext(), false);clock += 6000;
      remote = (_) async => download(expected, original);
      expect(await restarted.repairNext(), true);
      expect(restarted.summary['verifiedFiles'], 1);
      expect(await File((await restarted.verifiedPath('school_file_1'))!).readAsBytes(), original);
    });
  }

}
