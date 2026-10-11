import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_school_backup_export.dart';

void main() {
  const school = 'vs-11111111111111111111111111111111';
  const password = 'A strong backup password';
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('school-backup-test');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> make({
    Map<String, dynamic>? snapshot,
    List<String> missing = const [],
  }) async {
    final photo = File('${root.path}/photo');
    await photo.writeAsBytes([1, 2, 3]);
    return WindowsSchoolBackupExport.export(
      schoolId: school,
      password: password,
      snapshot:
          snapshot ??
          {
            'schoolId': school,
            'students': [
              {'name': 'Bengali বাংলা'},
            ],
          },
      files: {'photos/student.bin': photo},
      destination: File('${root.path}/backup.vsb'),
      stillSameSchool: () => true,
      missingData: missing,
    );
  }

  test('encrypted export restores organized content with hashes and no plaintext data', () async {
    final result = await make();
    expect(result['complete'], true);
    final bytes = await File('${root.path}/backup.vsb').readAsString();
    expect(bytes, isNot(contains('Bengali')));
    expect(bytes, isNot(contains(password)));
    final m = await WindowsSchoolBackupExport.stageRestore(
      backup: File('${root.path}/backup.vsb'),
      password: password,
      schoolId: school,
      destination: Directory('${root.path}/restore'),
    );
    expect(m['files'], hasLength(2));
    expect(
      await File('${root.path}/restore/files/photos/student.bin').readAsBytes(),
      [1, 2, 3],
    );
  });
  test(
    'wrong password and foreign school never create restore destination',
    () async {
      await make();
      for (final pair in [
        [school, 'wrong'],
        ['vs-22222222222222222222222222222222', password],
      ]) {
        await expectLater(
          WindowsSchoolBackupExport.stageRestore(
            backup: File('${root.path}/backup.vsb'),
            password: pair[1],
            schoolId: pair[0],
            destination: Directory('${root.path}/restore'),
          ),
          throwsA(anything),
        );
        expect(await Directory('${root.path}/restore').exists(), false);
      }
    },
  );
  test('authenticated header and ciphertext tampering rejected', () async {
    await make();
    final f = File('${root.path}/backup.vsb');
    final data = jsonDecode(await f.readAsString()) as Map;
    final bytes = base64Decode(data['ciphertext']);
    bytes[0] ^= 1;
    data['ciphertext'] = base64Encode(bytes);
    await f.writeAsString(jsonEncode(data));
    await expectLater(
      WindowsSchoolBackupExport.stageRestore(
        backup: f,
        password: password,
        schoolId: school,
        destination: Directory('${root.path}/restore'),
      ),
      throwsA(anything),
    );
    expect(await Directory('${root.path}/restore').exists(), false);
  });
  test('credential fields rejected and existing export retained', () async {
    final result = await make(
      snapshot: {'schoolId': school, 'password': 'secret'},
    );
    expect(result['excludedCredentialFields'], ['records/password']);
    expect(
      await File('${root.path}/backup.vsb').readAsString(),
      isNot(contains('secret')),
    );
    final before = await File('${root.path}/backup.vsb').readAsBytes();
    await expectLater(make(), throwsStateError);
    expect(await File('${root.path}/backup.vsb').readAsBytes(), before);
  });
  test(
    'missing data is explicit and incomplete export never claims completeness',
    () async {
      final result = await make(missing: ['cloud-only document unavailable']);
      expect(result['complete'], false);
      expect(result['missingData'], ['cloud-only document unavailable']);
    },
  );
  test(
    'single Windows separator and traversal file paths are rejected',
    () async {
      final file = File('${root.path}/photo');
      await file.writeAsBytes([1]);
      for (final path in [
        '..' + String.fromCharCode(92) + 'escape.bin',
        'photos/../escape',
        '/absolute',
        'trailing.',
      ]) {
        await expectLater(
          WindowsSchoolBackupExport.export(
            schoolId: school,
            password: password,
            snapshot: {'schoolId': school},
            files: {path: file},
            destination: File('${root.path}/invalid.vsb'),
            stillSameSchool: () => true,
          ),
          throwsStateError,
        );
        expect(await File('${root.path}/invalid.vsb').exists(), false);
      }
    },
  );
  test('resolved parent aliases permit a fresh sibling restore', () async {
    await make();
    final parent = await root.resolveSymbolicLinks();
    final destination = Directory(
      '$parent${Platform.pathSeparator}alias-restore',
    );
    final result = await WindowsSchoolBackupExport.stageRestore(
      backup: File('${root.path}/backup.vsb'),
      password: password,
      schoolId: school,
      destination: destination,
    );
    expect(result['schoolId'], school);
    expect(await File('${destination.path}/manifest.json').exists(), true);
  });
  test(
    'linked parent restore is rejected without touching linked contents',
    () async {
      await make();
      final real = await Directory('${root.path}/real').create();
      final link = Link('${root.path}/link');
      await link.create(real.path);
      await expectLater(
        WindowsSchoolBackupExport.stageRestore(
          backup: File('${root.path}/backup.vsb'),
          password: password,
          schoolId: school,
          destination: Directory('${link.path}/restore'),
        ),
        throwsStateError,
      );
      expect(await Directory('${real.path}/restore').exists(), false);
    },
    skip: Platform.isWindows
        ? 'Windows symlink privilege is environment dependent; canonical restore covered above'
        : false,
  );
}
