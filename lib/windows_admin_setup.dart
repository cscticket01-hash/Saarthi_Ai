import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Text, InputDecoration;

import 'windows_local_auth.dart';
import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';
import 'windows_local_session.dart';

/// Local-first initial school/admin setup shown after the licence screen is
/// skipped on a fresh install. It never touches Firebase, Google Drive or any
/// network service: everything is written to this PC only.
class WindowsAdminSetup {
  WindowsAdminSetup._();

  static const fileVersion = 'admin_setup_v1';

  static File get _file {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'];
    if (base == null) {
      throw StateError('Windows application data directory unavailable.');
    }
    return File(
      '$base${Platform.pathSeparator}VidyaSaarthi${Platform.pathSeparator}'
      '$fileVersion.json',
    );
  }

  static Map<String, dynamic> _data = const {};
  static bool? _cachedCompleted;

  /// Test-only override so widget tests can pin the setup state without a
  /// real %APPDATA% round trip. Null means "check local storage".
  static bool? completedOverride;

  static Future<Map<String, dynamic>> read() async {
    try {
      final text = await _file.readAsString();
      _data = Map<String, dynamic>.from(jsonDecode(text));
    } catch (_) {
      _data = const {};
    }
    return _data;
  }

  /// True when an admin/school setup already exists — either saved by this
  /// screen, configured through the legacy Settings Lock, or present in the
  /// locally cached school profile of an existing installation. Existing
  /// users are therefore never forced through this page again.
  static Future<bool> completed() async {
    if (completedOverride != null) return completedOverride!;
    if (_cachedCompleted == true) return true;
    final data = await read();
    final basic = (data['schoolName']?.toString().isNotEmpty ?? false) &&
        (data['principalName']?.toString().isNotEmpty ?? false);
    if (basic) {
      _cachedCompleted = true;
      return true;
    }
    if (WindowsLocalSecurity.configured) {
      _cachedCompleted = true;
      return true;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('school_config')
          .doc('school_profile_cache')
          .get();
      final values = snap.data() ?? const {};
      final legacy = (values['schoolName']?.toString().isNotEmpty ?? false) &&
          (values['principalName']?.toString().isNotEmpty ?? false);
      if (legacy) {
        _cachedCompleted = true;
        return true;
      }
    } catch (_) {}
    return false;
  }

  static String get schoolName => _data['schoolName']?.toString() ?? '';
  static String get principalName => _data['principalName']?.toString() ?? '';

  static Future<void> save({
    required String schoolName,
    required String principalName,
    required String adminPassword,
    String? logoPath,
    String? sealPath,
    String? signaturePath,
  }) async {
    final name = schoolName.trim();
    final principal = principalName.trim();
    if (name.length < 2) {
      throw const FormatException('School Name is required.');
    }
    if (principal.length < 2) {
      throw const FormatException('Principal Name is required.');
    }
    if (adminPassword.length < 4) {
      throw const FormatException(
          'Admin Password must be at least 4 characters.');
    }
    final map = <String, dynamic>{
      'version': 1,
      'schoolName': name,
      'principalName': principal,
      'logoFileId': await _encodeImage(logoPath),
      'sealFileId': await _encodeImage(sealPath),
      'principalSignatureFileId': await _encodeImage(signaturePath),
      'savedAt': DateTime.now().toIso8601String(),
    };
    // Persist locally first so the app works fully offline.
    try {
      await _file.parent.create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(map), flush: true);
      await tmp.rename(_file.path);
      _data = map;
      _cachedCompleted = true;
    } catch (e) {
      throw StateError('Could not save the setup on this PC: $e');
    }
    // Mirror into the same local cache document the dashboard branding uses,
    // best-effort and strictly offline (local Firestore store).
    try {
      await FirebaseFirestore.instance
          .collection('school_config')
          .doc('school_profile_cache')
          .set({
        'schoolName': name,
        'principalName': principal,
        'logoFileId': map['logoFileId'],
        'sealFileId': map['sealFileId'],
        'principalSignatureFileId': map['principalSignatureFileId'],
      }, SetOptions(merge: true));
    } catch (_) {}
    // Reuse the existing local security lock with the entered password.
    if (!WindowsLocalSecurity.configured) {
      await WindowsLocalSecurity.create(
        adminId: 'Local Administrator',
        password: adminPassword,
      );
    } else {
      await WindowsLocalSecurity.change(
        currentPassword: adminPassword,
        newAdminId: WindowsLocalSecurity.adminId,
        newPassword: adminPassword,
      );
    }
    await FirebaseAuth.instance.refreshLocalUser();
    await WindowsLocalSession.markLoggedIn();
  }

  static Future<String> _encodeImage(String? path) async {
    if (path == null || path.isEmpty) return '';
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) return '';
      final ext = path.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
      return 'data:image/$ext;base64,${base64Encode(bytes)}';
    } catch (_) {
      return '';
    }
  }
}

class WindowsAdminSetupScreen extends StatefulWidget {
  const WindowsAdminSetupScreen({super.key, this.onFinished});
  final VoidCallback? onFinished;

  @override
  State<WindowsAdminSetupScreen> createState() =>
      _WindowsAdminSetupScreenState();
}

class _WindowsAdminSetupScreenState extends State<WindowsAdminSetupScreen> {
  final _school = TextEditingController();
  final _principal = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _logoPath, _sealPath, _signaturePath;
  bool _busy = false, _obscure = true;
  String? _error;

  @override
  void dispose() {
    _school.dispose();
    _principal.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _pick(int slot) async {
    // The Windows runner has no image_picker platform implementation, so the
    // gallery API always throws here. Use the native Windows file-open dialog
    // instead (PowerShell works on every supported Windows version). This is
    // local-only: no Firebase/network involvement.
    try {
      final path = await _pickImageViaWindowsDialog();
      if (path == null || path.isEmpty) return;
      if (!mounted) return;
      setState(() {
        if (slot == 0) {
          _logoPath = path;
        } else if (slot == 1) {
          _sealPath = path;
        } else {
          _signaturePath = path;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open file picker: $e');
    }
  }

  static Future<String?> _pickImageViaWindowsDialog() async {
    if (!Platform.isWindows) return null;
    const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = 'Select school image'
$dialog.Filter = 'Images (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg|All files (*.*)|*.*'
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.Write($dialog.FileName)
}
''';
    try {
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-Command', script],
      );
      final path = (result.stdout ?? '').toString().trim();
      if (result.exitCode != 0 || path.isEmpty || !File(path).existsSync()) {
        return null;
      }
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await WindowsAdminSetup.save(
        schoolName: _school.text,
        principalName: _principal.text,
        adminPassword: _password.text,
        logoPath: _logoPath,
        sealPath: _sealPath,
        signaturePath: _signaturePath,
      );
      if (!mounted) return;
      if (widget.onFinished != null) {
        widget.onFinished!();
      } else {
        Navigator.of(context).pushNamedAndRemoveUntil(
            '/dashboard', (route) => false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e
          .toString()
          .replaceFirst('FormatException: ', '')
          .replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _imageTile(String label, String? path, int slot) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(path == null
            ? Icons.add_photo_alternate_outlined
            : Icons.check_circle_outline,
            color: Colors.orangeAccent),
        title: Text(label),
        subtitle: Text(path == null ? 'Optional — choose an image file'
            : 'Selected: ${path.split(Platform.pathSeparator).last}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: OutlinedButton(
            onPressed: _busy ? null : () => _pick(slot),
            child: const Text('Choose')),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.account_balance_rounded,
                      size: 52, color: Colors.orangeAccent),
                  const SizedBox(height: 14),
                  const Text('Admin Setup',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                      'Saved on this PC only. No Firebase, cloud or school connection is needed.',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _school,
                    decoration: const InputDecoration(
                        labelText: 'School Name *',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _principal,
                    decoration: const InputDecoration(
                        labelText: 'Principal Name *',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Admin Password *',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                          icon: Icon(_obscure
                              ? Icons.visibility_off
                              : Icons.visibility)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirm,
                    obscureText: _obscure,
                    decoration: const InputDecoration(
                        labelText: 'Confirm Admin Password *',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  _imageTile('School Logo', _logoPath, 0),
                  _imageTile('School Seal', _sealPath, 1),
                  _imageTile('Principal / Authorized Signature',
                      _signaturePath, 2),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!,
                        key: const ValueKey('admin-setup-error'),
                        style: const TextStyle(color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 18),
                  FilledButton(
                      onPressed: _busy ? null : _save,
                      child: Text(_busy
                          ? 'Saving…'
                          : 'Save & Open App')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
