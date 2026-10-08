import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

const String windowsAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '2.0.0',
);

class WindowsUpdateInfo {
  const WindowsUpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    required this.fileName,
    required this.releaseNotes,
  });

  final String latestVersion;
  final String downloadUrl;
  final String fileName;
  final String releaseNotes;

  bool get updateAvailable =>
      WindowsUpdateService.compareVersions(latestVersion, windowsAppVersion) > 0;
}

enum WindowsUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  launchingInstaller,
  error,
}

class WindowsUpdateRuntimeState {
  const WindowsUpdateRuntimeState({
    required this.phase,
    this.update,
    this.progress,
    this.message = '',
  });

  final WindowsUpdatePhase phase;
  final WindowsUpdateInfo? update;
  final double? progress;
  final String message;

  bool get checking => phase == WindowsUpdatePhase.checking;
  bool get downloading => phase == WindowsUpdatePhase.downloading;
  bool get launching => phase == WindowsUpdatePhase.launchingInstaller;
  bool get busy => checking || downloading || launching;
  bool get updateAvailable => update?.updateAvailable == true;

  WindowsUpdateRuntimeState copyWith({
    WindowsUpdatePhase? phase,
    WindowsUpdateInfo? update,
    bool clearUpdate = false,
    double? progress,
    bool clearProgress = false,
    String? message,
  }) {
    return WindowsUpdateRuntimeState(
      phase: phase ?? this.phase,
      update: clearUpdate ? null : (update ?? this.update),
      progress: clearProgress ? null : (progress ?? this.progress),
      message: message ?? this.message,
    );
  }
}

class WindowsUpdateService {
  WindowsUpdateService._();

  static const String _owner = 'cscticket01-hash';
  static const String _repo = 'Saarthi_Ai';

  /// Global update state. It belongs to the APP, not the Settings page.
  /// Therefore navigating away from Settings never cancels or resets a
  /// running download. Reopening Settings sees the same progress.
  static final ValueNotifier<WindowsUpdateRuntimeState> state =
      ValueNotifier<WindowsUpdateRuntimeState>(
    const WindowsUpdateRuntimeState(phase: WindowsUpdatePhase.idle),
  );

  static Future<void>? _activeInstallJob;

  static Future<WindowsUpdateInfo> check() async {
    final uri = Uri.parse(
      'https://api.github.com/repos/$_owner/$_repo/releases?per_page=30',
    );

    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Vidya-Saarthi-Windows/$windowsAppVersion',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await utf8.decoder.bind(response).join();

      if (response.statusCode != 200) {
        throw StateError(
          'Update server response ${response.statusCode}. GitHub release public/accessibile hona chahiye.',
        );
      }

      final decoded = jsonDecode(body);
      if (decoded is! List) {
        throw StateError('Update response invalid hai.');
      }

      for (final release in decoded) {
        if (release is! Map) continue;
        if (release['draft'] == true || release['prerelease'] == true) continue;

        final tag = release['tag_name']?.toString().trim() ?? '';
        if (!tag.toLowerCase().startsWith('windows-v')) continue;

        final latestVersion = tag.replaceFirst(
          RegExp(r'^windows-v', caseSensitive: false),
          '',
        );
        final notes = release['body']?.toString() ?? '';
        final assets = release['assets'];

        if (assets is! List) continue;
        for (final item in assets) {
          if (item is! Map) continue;
          final name = item['name']?.toString() ?? '';
          final candidate = item['browser_download_url']?.toString() ?? '';
          if (name.toLowerCase().endsWith('.exe') &&
              name.toLowerCase().contains('vidya_saarthi_setup') &&
              candidate.startsWith('https://')) {
            return WindowsUpdateInfo(
              latestVersion: latestVersion,
              downloadUrl: candidate,
              fileName: name,
              releaseNotes: notes,
            );
          }
        }
      }

      throw StateError('Windows installer release nahi mila.');
    } on SocketException {
      throw StateError('Internet connection nahi mil raha.');
    } finally {
      client.close(force: true);
    }
  }

  static Future<WindowsUpdateInfo?> checkAndRemember() async {
    if (state.value.downloading || state.value.launching) {
      return state.value.update;
    }

    state.value = state.value.copyWith(
      phase: WindowsUpdatePhase.checking,
      clearProgress: true,
      message: 'Checking GitHub update...',
    );

    try {
      final update = await check();
      if (update.updateAvailable) {
        state.value = WindowsUpdateRuntimeState(
          phase: WindowsUpdatePhase.available,
          update: update,
          message: 'New version ${update.latestVersion} available.',
        );
      } else {
        state.value = WindowsUpdateRuntimeState(
          phase: WindowsUpdatePhase.upToDate,
          update: update,
          message: 'App already latest version par hai.',
        );
      }
      return update;
    } catch (e) {
      state.value = WindowsUpdateRuntimeState(
        phase: WindowsUpdatePhase.error,
        update: state.value.update,
        message: e.toString().replaceFirst('Bad state: ', ''),
      );
      rethrow;
    }
  }

  static Future<File> download(
    WindowsUpdateInfo update, {
    void Function(double progress)? onProgress,
  }) async {
    final uri = Uri.parse(update.downloadUrl);
    if (uri.scheme != 'https') {
      throw StateError('Update URL secure HTTPS nahi hai.');
    }

    final client = HttpClient();
    IOSink? sink;

    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 8;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Vidya-Saarthi-Windows/$windowsAppVersion',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 45),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Update download failed: ${response.statusCode}');
      }

      final target = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'Vidya_Saarthi_Update_${update.latestVersion}.exe',
      );

      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }

      sink = target.openWrite();
      final total = response.contentLength;
      var received = 0;

      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (!await target.exists() || await target.length() == 0) {
        throw StateError('Downloaded installer empty hai.');
      }

      return target;
    } on SocketException {
      throw StateError('Update download ke waqt internet connection fail hua.');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  static Future<void> launchInstaller(File installer) async {
    if (!await installer.exists()) {
      throw StateError('Downloaded installer nahi mila.');
    }

    await Process.start(
      installer.path,
      const <String>[
        '/SILENT',
        '/CLOSEAPPLICATIONS',
        '/RESTARTAPPLICATIONS',
      ],
      mode: ProcessStartMode.detached,
    );
  }

  /// Starts one app-wide download/install job. Calling this again from a new
  /// Settings page returns the same Future instead of starting/cancelling a
  /// second download.
  static Future<void> startDownloadAndInstall([WindowsUpdateInfo? update]) {
    final running = _activeInstallJob;
    if (running != null) return running;

    final selected = update ?? state.value.update;
    if (selected == null || !selected.updateAvailable) {
      return Future<void>.error(
        StateError('Pehle Check for Update karein.'),
      );
    }

    final future = _runInstall(selected);
    _activeInstallJob = future;
    future.then<void>(
      (_) {
        if (identical(_activeInstallJob, future)) {
          _activeInstallJob = null;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_activeInstallJob, future)) {
          _activeInstallJob = null;
        }
      },
    );
    return future;
  }

  static Future<void> _runInstall(WindowsUpdateInfo update) async {
    state.value = WindowsUpdateRuntimeState(
      phase: WindowsUpdatePhase.downloading,
      update: update,
      progress: 0,
      message: 'Update download chal raha hai...',
    );

    try {
      final installer = await download(
        update,
        onProgress: (value) {
          state.value = WindowsUpdateRuntimeState(
            phase: WindowsUpdatePhase.downloading,
            update: update,
            progress: value.clamp(0.0, 1.0).toDouble(),
            message: 'Update download chal raha hai...',
          );
        },
      );

      state.value = WindowsUpdateRuntimeState(
        phase: WindowsUpdatePhase.launchingInstaller,
        update: update,
        progress: 1,
        message: 'Download complete. Installer open ho raha hai...',
      );

      await launchInstaller(installer);
    } catch (e) {
      state.value = WindowsUpdateRuntimeState(
        phase: WindowsUpdatePhase.error,
        update: update,
        message: 'Update error: $e',
      );
      rethrow;
    }
  }

  static int compareVersions(String a, String b) {
    List<int> parts(String value) => value
        .replaceAll(RegExp(r'[^0-9.]'), '')
        .split('.')
        .where((e) => e.isNotEmpty)
        .map((e) => int.tryParse(e) ?? 0)
        .toList();

    final av = parts(a);
    final bv = parts(b);
    final length = av.length > bv.length ? av.length : bv.length;
    for (var i = 0; i < length; i++) {
      final ai = i < av.length ? av[i] : 0;
      final bi = i < bv.length ? bv[i] : 0;
      if (ai != bi) return ai.compareTo(bi);
    }
    return 0;
  }
}
