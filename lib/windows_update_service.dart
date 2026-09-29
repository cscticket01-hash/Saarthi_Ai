import 'dart:convert';
import 'dart:io';

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

class WindowsUpdateService {
  WindowsUpdateService._();

  static const String _owner = 'cscticket01-hash';
  static const String _repo = 'Saarthi_Ai';

  static Future<WindowsUpdateInfo> check() async {
    final uri = Uri.parse(
      'https://api.github.com/repos/$_owner/$_repo/releases?per_page=20',
    );

    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      request.headers.set(HttpHeaders.userAgentHeader, 'Vidya-Saarthi-Windows/$windowsAppVersion');
      final response = await request.close().timeout(const Duration(seconds: 20));
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

  static Future<File> download(
    WindowsUpdateInfo update, {
    void Function(double progress)? onProgress,
  }) async {
    final uri = Uri.parse(update.downloadUrl);
    final client = HttpClient();

    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'Vidya-Saarthi-Windows/$windowsAppVersion');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Update download failed: ${response.statusCode}');
      }

      final temp = Directory.systemTemp;
      final target = File(
        '${temp.path}${Platform.pathSeparator}${update.fileName}',
      );
      final sink = target.openWrite();
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

      if (!await target.exists() || await target.length() == 0) {
        throw StateError('Downloaded installer empty hai.');
      }
      return target;
    } on SocketException {
      throw StateError('Update download ke waqt internet connection fail hua.');
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> launchInstaller(File installer) async {
    if (!await installer.exists()) {
      throw StateError('Downloaded installer nahi mila.');
    }
    await Process.start(
      installer.path,
      const <String>[],
      mode: ProcessStartMode.detached,
    );
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
