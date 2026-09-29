import 'dart:convert';
import 'dart:io';

import 'windows_service_status.dart';

class WindowsLocalStorage {
  WindowsLocalStorage._();

  static const String databaseName = 'local_database_v1.json';
  static String? _customDataPath;

  static Directory get _controlDirectory {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'];
    if (base == null || base.trim().isEmpty) {
      throw StateError('Windows application data folder unavailable.');
    }
    return Directory(
      '$base${Platform.pathSeparator}VidyaSaarthi',
    );
  }

  static File get _configFile => File(
        '${_controlDirectory.path}${Platform.pathSeparator}storage_config_v1.json',
      );

  static Directory get _defaultDataDirectory => _controlDirectory;

  static Future<void> initialize() async {
    await _controlDirectory.create(recursive: true);
    try {
      if (await _configFile.exists()) {
        final decoded = jsonDecode(await _configFile.readAsString());
        if (decoded is Map) {
          final raw = decoded['dataPath']?.toString().trim() ?? '';
          _customDataPath = raw.isEmpty ? null : raw;
        }
      }
    } catch (_) {
      _customDataPath = null;
    }

    await healthCheck();
  }

  static Future<Directory> dataDirectory() async {
    final custom = _customDataPath?.trim() ?? '';
    return custom.isEmpty ? _defaultDataDirectory : Directory(custom);
  }

  static Future<File> databaseFile() async {
    final directory = await dataDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}$databaseName',
    );
  }

  static Future<Directory> localFilesDirectory() async {
    final directory = await dataDirectory();
    return Directory(
      '${directory.path}${Platform.pathSeparator}LocalFiles',
    );
  }

  static Future<String> currentPath() async => (await dataDirectory()).path;

  static Future<bool> healthCheck() async {
    final status = WindowsServiceStatus.instance;
    status.checking(
      WindowsServiceType.localStorage,
      'Local storage read/write test chal raha hai...',
    );

    try {
      final directory = await dataDirectory();
      await directory.create(recursive: true);

      final probe = File(
        '${directory.path}${Platform.pathSeparator}.vidya_storage_probe',
      );
      final token = DateTime.now().microsecondsSinceEpoch.toString();
      await probe.writeAsString(token, flush: true);
      final readBack = await probe.readAsString();
      if (readBack != token) {
        throw StateError('Storage write/read verify fail hua.');
      }
      await probe.delete();

      final db = await databaseFile();
      if (await db.exists()) {
        final raw = await db.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) {
            throw const FormatException('Local database JSON invalid hai.');
          }
        }
      }

      status.healthy(
        WindowsServiceType.localStorage,
        'Local database read/write OK: ${directory.path}',
      );
      return true;
    } catch (e) {
      status.unhealthy(
        WindowsServiceType.localStorage,
        'Local storage problem: $e',
      );
      return false;
    }
  }

  static Future<void> openFolder() async {
    final directory = await dataDirectory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    await Process.start(
      'explorer.exe',
      [directory.path],
      mode: ProcessStartMode.detached,
    );
  }

  static Future<String> createBackup() async {
    final source = await dataDirectory();
    if (!await source.exists()) {
      throw StateError('Current local storage folder nahi mila.');
    }

    final backupRoot = Directory(
      '${_controlDirectory.path}${Platform.pathSeparator}Backups',
    );
    await backupRoot.create(recursive: true);

    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final destination = Directory(
      '${backupRoot.path}${Platform.pathSeparator}backup_$stamp',
    );
    await destination.create(recursive: true);

    final db = await databaseFile();
    if (await db.exists()) {
      await db.copy(
        '${destination.path}${Platform.pathSeparator}$databaseName',
      );
    }

    final dbBackup = File('${db.path}.bak');
    if (await dbBackup.exists()) {
      await dbBackup.copy(
        '${destination.path}${Platform.pathSeparator}$databaseName.bak',
      );
    }

    final localFiles = await localFilesDirectory();
    if (await localFiles.exists()) {
      await _copyDirectory(
        localFiles,
        Directory(
          '${destination.path}${Platform.pathSeparator}LocalFiles',
        ),
      );
    }

    return destination.path;
  }

  static Future<void> changeLocation(String newPath) async {
    final clean = newPath.trim().replaceAll(RegExp(r'[\\/]+$'), '');
    if (clean.isEmpty) {
      throw const FormatException('New storage folder path daalein.');
    }

    final current = await dataDirectory();
    final target = Directory(clean);

    if (_normalize(current.path) == _normalize(target.path)) {
      await healthCheck();
      return;
    }

    await target.create(recursive: true);

    final probe = File(
      '${target.path}${Platform.pathSeparator}.vidya_migration_probe',
    );
    await probe.writeAsString('ok', flush: true);
    if (await probe.readAsString() != 'ok') {
      throw StateError('New folder writable nahi hai.');
    }
    await probe.delete();

    if (await current.exists()) {
      final oldDb = File(
        '${current.path}${Platform.pathSeparator}$databaseName',
      );
      if (await oldDb.exists()) {
        await oldDb.copy(
          '${target.path}${Platform.pathSeparator}$databaseName',
        );
      }

      final oldDbBackup = File('${oldDb.path}.bak');
      if (await oldDbBackup.exists()) {
        await oldDbBackup.copy(
          '${target.path}${Platform.pathSeparator}$databaseName.bak',
        );
      }

      final oldFiles = Directory(
        '${current.path}${Platform.pathSeparator}LocalFiles',
      );
      if (await oldFiles.exists()) {
        await _copyDirectory(
          oldFiles,
          Directory(
            '${target.path}${Platform.pathSeparator}LocalFiles',
          ),
        );
      }
    }

    await _controlDirectory.create(recursive: true);
    final pending = File('${_configFile.path}.pending');
    await pending.writeAsString(
      jsonEncode({
        'dataPath': target.path,
        'updatedAt': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
    if (await _configFile.exists()) {
      await _configFile.delete();
    }
    await pending.rename(_configFile.path);
    _customDataPath = target.path;

    final ok = await healthCheck();
    if (!ok) {
      throw StateError('New local storage health check fail hua.');
    }
  }

  static Future<void> resetToDefaultLocation() async {
    final defaultPath = _defaultDataDirectory.path;
    await changeLocation(defaultPath);
    _customDataPath = null;
    if (await _configFile.exists()) {
      await _configFile.delete();
    }
    await healthCheck();
  }

  static Future<void> _copyDirectory(
    Directory source,
    Directory target,
  ) async {
    await target.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final name = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      final destination =
          '${target.path}${Platform.pathSeparator}$name';

      if (entity is File) {
        await entity.copy(destination);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(destination));
      }
    }
  }

  static String _normalize(String path) =>
      path.replaceAll('/', '\\').toLowerCase().replaceAll(RegExp(r'\\+$'), '');
}
