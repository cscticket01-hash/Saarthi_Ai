import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

const String windowsAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.0',
);

class WindowsUpdateInfo {
  const WindowsUpdateInfo({
    required this.latestVersion,
    required this.minimumVersion,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.forceUpdate,
  });

  final String latestVersion;
  final String minimumVersion;
  final String downloadUrl;
  final String releaseNotes;
  final bool forceUpdate;
}

class WindowsUpdateCheckResult {
  const WindowsUpdateCheckResult({
    required this.message,
    this.info,
    this.configFound = true,
  });

  final String message;
  final WindowsUpdateInfo? info;
  final bool configFound;

  bool get updateAvailable => info != null;
}

class WindowsUpdateManager {
  WindowsUpdateManager._();

  static const String _tempInstallerPrefix = 'Vidya_Saarthi_Update_';
  static const String _tempInstallerSuffix = '.exe';

  static Future<void> cleanupOldInstallers() async {
    try {
      final temp = Directory.systemTemp;
      if (!await temp.exists()) return;

      await for (final entity in temp.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;

        if (!name.startsWith(_tempInstallerPrefix) ||
            !name.toLowerCase().endsWith(_tempInstallerSuffix)) {
          continue;
        }

        try {
          await entity.delete();
        } catch (_) {
          // A still-running installer can be locked. Next app start retries.
        }
      }
    } catch (_) {
      // Cleanup must never block Vidya Saarthi from opening.
    }
  }

  static Future<void> _scheduleInstallerCleanup({
    required int installerPid,
    required String installerPath,
  }) async {
    try {
      final escapedPath = installerPath.replaceAll("'", "''");
      final script = '''
\$ErrorActionPreference = 'SilentlyContinue'
try { Wait-Process -Id $installerPid -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Milliseconds 900
for (\$i = 0; \$i -lt 30; \$i++) {
  try {
    if (Test-Path -LiteralPath '$escapedPath') {
      Remove-Item -LiteralPath '$escapedPath' -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath '$escapedPath')) { break }
  } catch {}
  Start-Sleep -Seconds 1
}
''';

      await Process.start(
        'powershell.exe',
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      // Startup cleanup is the fallback if helper launch fails.
    }
  }

  static List<int> _versionParts(String value) {
    return value
        .trim()
        .split('.')
        .map(
          (part) =>
              int.tryParse(RegExp(r'\d+').stringMatch(part) ?? '') ?? 0,
        )
        .toList();
  }

  static int compareVersions(String a, String b) {
    final av = _versionParts(a);
    final bv = _versionParts(b);
    final length = av.length > bv.length ? av.length : bv.length;

    for (var i = 0; i < length; i++) {
      final ai = i < av.length ? av[i] : 0;
      final bi = i < bv.length ? bv[i] : 0;
      if (ai != bi) return ai.compareTo(bi);
    }

    return 0;
  }

  static Future<WindowsUpdateCheckResult> checkForUpdate() async {
    if (FirebaseAuth.instance.currentUser == null) {
      return const WindowsUpdateCheckResult(
        message: 'Update check ke liye Admin login required hai.',
      );
    }

    final doc = await FirebaseFirestore.instance
        .collection('app_config')
        .doc('windows_update')
        .get()
        .timeout(const Duration(seconds: 10));

    if (!doc.exists) {
      return const WindowsUpdateCheckResult(
        configFound: false,
        message:
            'Windows update configuration abhi set nahi hai. '
            'Firestore: app_config/windows_update',
      );
    }

    final data = doc.data() ?? <String, dynamic>{};

    if (data['enabled'] == false) {
      return const WindowsUpdateCheckResult(
        message: 'Windows auto update abhi disabled hai.',
      );
    }

    final latest = data['latestVersion']?.toString().trim() ?? '';
    final minimum = data['minimumVersion']?.toString().trim() ?? '';
    final downloadUrl = data['downloadUrl']?.toString().trim() ?? '';
    final releaseNotes = data['releaseNotes']?.toString().trim() ?? '';
    final configuredForce = data['forceUpdate'] == true;

    if (latest.isEmpty) {
      return const WindowsUpdateCheckResult(
        message: 'Update config me latestVersion missing hai.',
      );
    }

    if (compareVersions(latest, windowsAppVersion) <= 0) {
      return WindowsUpdateCheckResult(
        message: 'App up to date hai. Installed version $windowsAppVersion.',
      );
    }

    if (downloadUrl.isEmpty) {
      return WindowsUpdateCheckResult(
        message:
            'Version $latest available hai, lekin downloadUrl configure nahi hai.',
      );
    }

    final belowMinimum = minimum.isNotEmpty &&
        compareVersions(windowsAppVersion, minimum) < 0;

    return WindowsUpdateCheckResult(
      message: 'New Windows update available: $latest',
      info: WindowsUpdateInfo(
        latestVersion: latest,
        minimumVersion: minimum,
        downloadUrl: downloadUrl,
        releaseNotes: releaseNotes,
        forceUpdate: configuredForce || belowMinimum,
      ),
    );
  }

  static Future<void> downloadAndInstall(
    WindowsUpdateInfo update, {
    void Function(double? value)? onProgress,
  }) async {
    HttpClient? client;
    IOSink? sink;

    try {
      final uri = Uri.parse(update.downloadUrl);

      if (uri.scheme != 'https' && uri.scheme != 'http') {
        throw const FormatException('Update download URL invalid hai.');
      }

      client = HttpClient();
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 8;

      final response = await request.close();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Download failed: HTTP ${response.statusCode}',
        );
      }

      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'Vidya_Saarthi_Update_${update.latestVersion}.exe',
      );

      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }

      sink = file.openWrite();
      final total = response.contentLength;
      var received = 0;

      onProgress?.call(null);

      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;

        if (total > 0) {
          onProgress?.call(received / total);
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (!await file.exists() || await file.length() <= 0) {
        throw const FileSystemException(
          'Downloaded Windows installer empty hai.',
        );
      }

      final installerProcess = await Process.start(
        file.path,
        const <String>[
          '/SILENT',
          '/CLOSEAPPLICATIONS',
          '/RESTARTAPPLICATIONS',
        ],
        mode: ProcessStartMode.detached,
      );

      // Delete the downloaded update EXE after the installer exits.
      await _scheduleInstallerCleanup(
        installerPid: installerProcess.pid,
        installerPath: file.path,
      );

      await Future<void>.delayed(
        const Duration(milliseconds: 800),
      );

      exit(0);
    } finally {
      try {
        await sink?.close();
      } catch (_) {}

      client?.close(force: true);
    }
  }

  static Future<void> promptIfAvailable(
    BuildContext context,
  ) async {
    try {
      final result = await checkForUpdate();

      if (!context.mounted || result.info == null) {
        return;
      }

      await showUpdateDialog(
        context,
        result.info!,
      );
    } catch (e) {
      debugPrint('Windows update startup check skipped: $e');
    }
  }

  static Future<void> showUpdateDialog(
    BuildContext context,
    WindowsUpdateInfo update,
  ) async {
    bool downloading = false;
    double? progress;
    String? error;

    await showDialog<void>(
      context: context,
      barrierDismissible: !update.forceUpdate,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> startInstall() async {
              if (downloading) return;

              setDialogState(() {
                downloading = true;
                progress = null;
                error = null;
              });

              try {
                await downloadAndInstall(
                  update,
                  onProgress: (value) {
                    if (!dialogContext.mounted) return;
                    setDialogState(() {
                      progress = value;
                    });
                  },
                );
              } catch (e) {
                if (!dialogContext.mounted) return;

                setDialogState(() {
                  downloading = false;
                  progress = null;
                  error = 'Update install error: $e';
                });
              }
            }

            return PopScope(
              canPop: !update.forceUpdate && !downloading,
              child: AlertDialog(
                backgroundColor: const Color(0xFF172229),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                title: const Row(
                  children: [
                    Icon(
                      Icons.system_update_alt_rounded,
                      color: Color(0xFF00D9A5),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Windows Update Available',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: 500,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Installed: $windowsAppVersion   •   '
                        'New: ${update.latestVersion}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (update.releaseNotes.isNotEmpty) ...[
                        const SizedBox(height: 13),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(13),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D171D),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.06),
                            ),
                          ),
                          child: Text(
                            update.releaseNotes,
                            style: const TextStyle(
                              color: Colors.white60,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                      if (downloading) ...[
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          value: progress,
                          minHeight: 8,
                          color: const Color(0xFF00D9A5),
                          backgroundColor: Colors.white10,
                        ),
                        const SizedBox(height: 7),
                        Text(
                          progress == null
                              ? 'Downloading update...'
                              : 'Downloading '
                                  '${(progress! * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          error!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  if (!update.forceUpdate)
                    TextButton(
                      onPressed: downloading
                          ? null
                          : () => Navigator.pop(dialogContext),
                      child: const Text('Later'),
                    ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00A884),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: downloading ? null : startInstall,
                    icon: const Icon(
                      Icons.download_rounded,
                      size: 18,
                    ),
                    label: Text(
                      downloading ? 'Downloading...' : 'Update Now',
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class WindowsUpdateSettingsCard extends StatefulWidget {
  const WindowsUpdateSettingsCard({super.key});

  @override
  State<WindowsUpdateSettingsCard> createState() =>
      _WindowsUpdateSettingsCardState();
}

class _WindowsUpdateSettingsCardState
    extends State<WindowsUpdateSettingsCard> {
  bool _checking = false;
  WindowsUpdateCheckResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _check(showSnackBar: false);
    });
  }

  Future<void> _check({
    required bool showSnackBar,
  }) async {
    if (_checking) return;

    setState(() {
      _checking = true;
      _error = null;
    });

    try {
      final result =
          await WindowsUpdateManager.checkForUpdate();

      if (!mounted) return;

      setState(() {
        _checking = false;
        _result = result;
      });

      if (showSnackBar && result.info == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1F2C34),
            content: Text(result.message),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _checking = false;
        _error = e.toString();
      });

      if (showSnackBar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(
              'Windows update check error: $e',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _result?.info;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF38A8FF).withOpacity(0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF38A8FF).withOpacity(0.11),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.system_update_alt_rounded,
                  color: Color(0xFF69C2FF),
                  size: 22,
                ),
              ),
              const SizedBox(width: 11),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Windows App Update',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Check, download aur install new Admin software version.',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF38A8FF).withOpacity(0.09),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'v$windowsAppVersion',
                  style: const TextStyle(
                    color: Color(0xFF69C2FF),
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: const Color(0xFF0F191F),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: Colors.white.withOpacity(0.05),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  info != null
                      ? Icons.new_releases_rounded
                      : _error != null
                          ? Icons.error_outline_rounded
                          : Icons.verified_rounded,
                  color: info != null
                      ? Colors.orangeAccent
                      : _error != null
                          ? Colors.redAccent
                          : const Color(0xFF00D9A5),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _checking
                        ? 'Checking Windows update...'
                        : _error != null
                            ? 'Update check failed: $_error'
                            : _result?.message ??
                                'Update status check karein.',
                    style: TextStyle(
                      color: _error != null
                          ? Colors.redAccent
                          : Colors.white60,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (info != null) ...[
            const SizedBox(height: 11),
            Text(
              'Latest version: ${info.latestVersion}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (info.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                info.releaseNotes,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10.5,
                  height: 1.35,
                ),
              ),
            ],
          ],
          const SizedBox(height: 13),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              OutlinedButton.icon(
                onPressed: _checking
                    ? null
                    : () => _check(
                          showSnackBar: true,
                        ),
                icon: _checking
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(
                        Icons.refresh_rounded,
                        size: 18,
                      ),
                label: Text(
                  _checking
                      ? 'Checking...'
                      : 'Check for Update',
                ),
              ),
              if (info != null)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        const Color(0xFF00A884),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    await WindowsUpdateManager
                        .showUpdateDialog(
                      context,
                      info,
                    );

                    if (mounted) {
                      await _check(
                        showSnackBar: false,
                      );
                    }
                  },
                  icon: const Icon(
                    Icons.download_rounded,
                    size: 18,
                  ),
                  label: const Text(
                    'Download & Install',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
