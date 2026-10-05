import 'windows_school_profile_restore.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Text, InputDecoration;

import 'windows_ui_localization.dart';
import 'windows_local_auth.dart';
import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';
import 'windows_local_session.dart';

/// School-scoped registration cache. Managed enrollment is verified centrally;
/// branding and operational data remain local or in the school's own Drive.
class WindowsAdminSetup {
  WindowsAdminSetup._();

  static const fileVersion = 'admin_setup_v1';

  static File _fileForSchool(String schoolId) {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'];
    if (base == null) {
      throw StateError('Windows application data directory unavailable.');
    }
    return File(
      '$base${Platform.pathSeparator}VidyaSaarthi${Platform.pathSeparator}'
      '$fileVersion${schoolId.isEmpty?'':'_$schoolId'}.json',
    );
  }

  static Map<String, dynamic> _data = const {};
  static bool? _cachedCompleted;

  /// Test-only override so widget tests can pin the setup state without a
  /// real %APPDATA% round trip. Null means "check local storage".
  static bool? completedOverride;

  static Future<Map<String, dynamic>> read() async {
    final saved = await CentralSchoolCloud.saved();
    final managed = saved['managed'] == true;
    final school = managed ? saved['schoolId'].toString() : '';
    final target = _fileForSchool(school);
    Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(jsonDecode(await target.readAsString()));
    } catch (_) {
      data = {};
    }
    if (managed) {
      final current = await CentralSchoolCloud.saved();
      if (current['schoolId'] != school || current['uid'] != saved['uid']) {
        throw StateError('School changed while reading registration. Retry login.');
      }
      // Older local files omitted schoolId. Bind their provenance to the exact
      // tenant filename, without relabelling a foreign declared identity.
      if (data.isNotEmpty) data.putIfAbsent('schoolId', () => school);
    }
    _data = data;
    return data;
  }

  /// True when an admin/school setup already exists — either saved by this
  /// screen, configured through the legacy Settings Lock, or present in the
  /// locally cached school profile of an existing installation. Existing
  /// users are therefore never forced through this page again.
  static Future<bool> completed() async {
    if (completedOverride != null) return completedOverride!;
    if (_cachedCompleted == true && WindowsLocalSecurity.configured && (await CentralSchoolCloud.saved())['managed']!=true) return true;
    var data = await read();
    final identity = await CentralSchoolCloud.saved();
    if (identity['managed'] == true) {
      final school = identity['schoolId'].toString();
      final uid = identity['uid'];
      final profileId = FirebaseFirestore.instance.activeProfileId;
      final target = _fileForSchool(school);
      Future<void> verifyIdentity() async {
        final current = await CentralSchoolCloud.saved();
        if (current['schoolId'] != school || current['uid'] != uid ||
            FirebaseFirestore.instance.activeProfileId != profileId ||
            FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] != school) {
          throw StateError('School changed during profile restore. Retry login.');
        }
      }
      try {
        await verifyIdentity();
        // The tenant database can survive an app upgrade even when its separate
        // registration JSON is missing. Never inspect another/unscoped profile.
        if (!WindowsSchoolProfileRestore.complete(data)) {
          final cached = (await FirebaseFirestore.instance.collection('school_config')
              .doc('school_profile_cache').get()).data();
          await verifyIdentity();
          if (cached != null && cached['schoolId'] == school &&
              WindowsSchoolProfileRestore.complete(cached)) data = Map<String, dynamic>.from(cached);
        }
        final restored = await WindowsSchoolProfileRestore.resolveEnrollment(
          schoolId: school, localProfile: data,
          call: (action, body) async {
            await verifyIdentity();
            final result = await ManagedSchoolSession.call(action, body);
            await verifyIdentity();
            return result;
          });
        await verifyIdentity();
        if (WindowsSchoolProfileRestore.ready(restored)) {
          await target.parent.create(recursive:true);
          final tmp = File('${target.path}.tmp');
          await tmp.writeAsString(jsonEncode(restored),flush:true);
          await tmp.rename(target.path);
          await verifyIdentity();
          await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() =>
            FirebaseFirestore.instance.collection('school_config').doc('school_profile_cache')
              .set(restored, SetOptions(merge:true)));
          await verifyIdentity();
          data = restored;
          _data = restored;
        }
      } catch (_) {
        // Verification/restore failures must not become a registration screen,
        // including on a PC with a previously completed local registration.
        await verifyIdentity();
        rethrow;
      }
    }
    final basic = (identity['managed'] == true && WindowsSchoolProfileRestore.ready(data)) ||
        (data['schoolName']?.toString().isNotEmpty ?? false) &&
        (data['principalName']?.toString().isNotEmpty ?? false);
    if (basic && (WindowsLocalSecurity.configured || (await CentralSchoolCloud.saved())['managed']==true)) {
      _cachedCompleted = true;
      return true;
    }
    if (WindowsLocalSecurity.configured && (await CentralSchoolCloud.saved())['managed']!=true) {
      _cachedCompleted = true;
      return true;
    }
    return false;
  }

  static String get restoreNotice => _data['restoreNotice']?.toString() ?? '';

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
    final saved=await CentralSchoolCloud.saved();final managed=saved['managed']==true;
    final targetFile=_fileForSchool(managed?saved['schoolId'].toString():'');
    final brandingRef=FirebaseFirestore.instance.collection('school_config').doc('school_profile_cache');
    if(managed){await ManagedSchoolSession.reauthenticate(saved['email'],adminPassword);if((await CentralSchoolCloud.saved())['schoolId']!=saved['schoolId'])throw StateError('School changed. Sign in and retry.');}
    if (adminPassword.length < 6) {
      throw const FormatException(
          'Admin Password must be at least 6 characters.');
    }
    final map = <String, dynamic>{
      'version': 1,
      if (managed) 'schoolId': saved['schoolId'],
      'schoolName': name,
      'principalName': principal,
      'logoUrl': await _encodeImage(logoPath),
      'sealUrl': await _encodeImage(sealPath),
      'principalSignatureUrl': await _encodeImage(signaturePath),
      'savedAt': DateTime.now().toIso8601String(),
    };
    if (managed) {
      final result = await ManagedSchoolSession.call('managed/profile', {
        'operation': 'initialize', 'schoolName': name, 'principalName': principal});
      if (result['success'] != true || result['schoolId'] != saved['schoolId'] ||
          result['registrationState'] != 'complete') {
        throw StateError('School registration could not be saved. Retry.');
      }
      final profile = result['profile'];
      if (profile is! Map || profile['schoolId'] != saved['schoolId'] ||
          profile['schoolName'] != name || profile['principalName'] != principal) {
        throw StateError('This school is already registered. Retry login to restore its saved profile.');
      }
    }
    // Keep private images on this PC until the school Drive is connected.
    // Persist locally first so the app works fully offline.
    try {
      await targetFile.parent.create(recursive: true);
      final tmp = File('${targetFile.path}.tmp');
      await tmp.writeAsString(jsonEncode(map), flush: true);
      await tmp.rename(targetFile.path);
      if(managed&&(await CentralSchoolCloud.saved())['schoolId']!=saved['schoolId'])throw StateError('School changed. Registration remains scoped to its original school.');
      _data = map;
    } catch (e) {
      throw StateError('Could not save the setup on this PC: $e');
    }
    // Mirror into the same local cache document the dashboard branding uses,
    // best-effort and strictly offline (local Firestore store).
    try {
      await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() => brandingRef.set({
        'schoolName': name,
        'principalName': principal,
        'logoUrl': map['logoUrl'],
        'sealUrl': map['sealUrl'],
        'principalSignatureUrl': map['principalSignatureUrl'],
      }, SetOptions(merge: true)));
    } catch (_) {}
    // Reuse the existing local security lock with the entered password.
    if(managed){await FirebaseAuth.instance.refreshLocalUser();await WindowsLocalSession.markLoggedIn();_cachedCompleted=true;await completed();return;}
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
    _cachedCompleted = true;
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
  final _licence = TextEditingController();
  String? _logoPath, _sealPath, _signaturePath;
  bool _busy = false, _obscure = true;
  String? _error;

  @override
  void dispose() {
    _school.dispose();
    _principal.dispose();
    _password.dispose();
    _confirm.dispose();
    _licence.dispose();
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
      if(_licence.text.trim().isNotEmpty)await ManagedSchoolSession.call('managed/licence/activate',{'key':_licence.text.trim()});
      await WindowsAdminSetup.save(
        schoolName: _school.text,
        principalName: _principal.text,
        adminPassword: _password.text,
        logoPath: _logoPath,
        sealPath: _sealPath,
        signaturePath: _signaturePath,
      );
      if (!mounted) return;
      if((await CentralSchoolCloud.saved())['managed']==true)ManagedSchoolSession.changed.value++;
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
                      labelText: 'Current School Password *',
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
                        labelText: 'Confirm Password *',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(controller:_licence,decoration:const InputDecoration(labelText:'Licence Key (optional during five-day trial)',border:OutlineInputBorder())),
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
