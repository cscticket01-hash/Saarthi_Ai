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
  static String? _justCompletedIdentity;
  static bool consumeCompletedSetup(String schoolId, String uid) {
    if (_justCompletedIdentity != '$schoolId:$uid') return false;
    _justCompletedIdentity = null;
    return true;
  }

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
        final pending = await FirebaseFirestore.instance.collection('_windows_firebase_outbox')
            .where('collection',isEqualTo:'school_config').where('documentId',isEqualTo:'school_profile_cache').get();
        await verifyIdentity();
        if (!WindowsSchoolProfileRestore.complete(data) || pending.docs.isNotEmpty) {
          final cached = await FirebaseFirestore.instance.readSchoolRegistrationCache(school);
          await verifyIdentity();
          if (cached != null && cached['schoolId'] == school &&
              WindowsSchoolProfileRestore.complete(cached)) data = Map<String, dynamic>.from(cached);
        }
        // Central auth/licence has already been checked by the startup gate.
        // A complete cache in this exact tenant needs no synchronous Drive pull.
        if (data['schoolId'] == school && WindowsSchoolProfileRestore.ready(data)) {
          await verifyIdentity();
          await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() =>
            FirebaseFirestore.instance.collection('school_config').doc('school_profile_cache')
              .set(data, SetOptions(merge:true)));
          await verifyIdentity();
          _data = data; _cachedCompleted = true;
          return true;
        }
        final restored = await WindowsSchoolProfileRestore.resolveEnrollment(
          schoolId: school, localProfile: data,
          preferLocalProfile: pending.docs.isNotEmpty,
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
    String schoolContactNo = '',
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

    await WindowsLocalSecurity.initialize();
    if (managed && WindowsLocalSecurity.configured && !WindowsLocalSecurity.verifyPassword(adminPassword)) throw StateError('Enter the existing App Lock password for this school.');
    if (managed && adminPassword.length < 6) throw const FormatException('App Lock password must be at least 6 characters.');
    if (schoolContactNo.isNotEmpty && !RegExp(r'^\+?[0-9][0-9 -]{5,18}[0-9]$').hasMatch(schoolContactNo.trim()))
      throw const FormatException('Enter a valid school contact number.');
    if (!managed && adminPassword.length < 6) {
      throw const FormatException(
          'Admin Password must be at least 6 characters.');
    }
    final map = <String, dynamic>{
      'version': 1,
      if (managed) 'schoolId': saved['schoolId'],
      'schoolName': name,
      'principalName': principal,
      'schoolContactNo': schoolContactNo.trim(),
      'logoUrl': await _encodeImage(logoPath),
      'sealUrl': await _encodeImage(sealPath),
      'principalSignatureUrl': await _encodeImage(signaturePath),
      'savedAt': DateTime.now().toIso8601String(),
    };
    if (managed) {
      final result = await ManagedSchoolSession.call('managed/profile', {
        'operation': 'initialize', 'schoolName': name, 'principalName': principal,
        'schoolContactNo': schoolContactNo.trim()});
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
    // Keep initial branding in the durable outbox until its own Drive is ready.
    final cache = <String,dynamic>{
      if(managed) 'schoolId':saved['schoolId'],
      'schoolName':name,'principalName':principal,'schoolContactNo':schoolContactNo.trim(),'logoUrl':map['logoUrl'],
      'sealUrl':map['sealUrl'],'principalSignatureUrl':map['principalSignatureUrl'],
      'updatedAt':DateTime.now().millisecondsSinceEpoch,
    };
    if(managed) {
      await brandingRef.set(cache,SetOptions(merge:true));
    } else {
      await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>brandingRef.set(cache,SetOptions(merge:true)));
    }
    // Reuse the existing local security lock with the entered password.
    if(managed){if(!WindowsLocalSecurity.configured){await WindowsLocalSecurity.create(adminId:'School app',password:adminPassword);}await FirebaseAuth.instance.refreshLocalUser();await WindowsLocalSession.markLoggedIn();_cachedCompleted=true;await completed();_justCompletedIdentity="${saved['schoolId']}:${saved['uid']}";return;}
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
  final _contact = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _licence = TextEditingController();
  String? _logoPath, _sealPath, _signaturePath;
  bool _busy = false, _obscure = true, _confirmObscure = true;
  bool _skipLicence = false;
  bool _trialEligible = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    CentralSchoolCloud.saved().then((saved) {
      final access = saved['verifiedAccess'];
      if (mounted) setState(() => _trialEligible = access is Map &&
        access['status'] == 'trial' && access['allowed'] == true &&
        access['expiresAt'] is num && access['serverTime'] is num &&
        (access['expiresAt'] as num) > (access['serverTime'] as num));
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _school.dispose();
    _principal.dispose();
    _contact.dispose();
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
    if (_school.text.trim().length < 2) {
      setState(() => _error = 'School Name is required.');
      return;
    }
    if (_principal.text.trim().length < 2) {
      setState(() => _error = 'Principal Name is required.');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    if (_password.text.length < 6) {
      setState(() => _error = 'App Lock password must be at least 6 characters.');
      return;
    }
    if (_contact.text.trim().isNotEmpty &&
        !RegExp(r'^\+?[0-9][0-9 -]{5,18}[0-9]$').hasMatch(_contact.text.trim())) {
      setState(() => _error = 'Enter a valid school contact number.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_skipLicence && _trialEligible) {
        final access = await ManagedSchoolSession.call('managed/session');
        if (access['allowed'] != true || access['status'] != 'trial' ||
            access['expiresAt'] is! num || access['serverTime'] is! num ||
            (access['expiresAt'] as num) <= (access['serverTime'] as num)) {
          if (mounted) setState(() { _skipLicence = false; _trialEligible = false; });
          throw StateError('The five-day trial has ended. Enter your school licence key.');
        }
      } else {
        if (_licence.text.trim().isEmpty) throw const FormatException('Enter your school licence key, or choose Skip for the valid five-day trial.');
        await ManagedSchoolSession.call('managed/licence/activate',{'key':_licence.text.trim()});
      }
      await WindowsAdminSetup.save(
        schoolName: _school.text,
        principalName: _principal.text,
        schoolContactNo: _contact.text.trim(),
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

  static const _background = Color(0xFF0B141C);
  static const _surface = Color(0xFF16212D);
  static const _accent = Color(0xFF00C8C8);
  static const _muted = Color(0xFF9AABBE);

  Widget _field({
    required String label,
    required String hint,
    required TextEditingController controller,
    required String fieldKey,
    TextInputType? keyboardType,
    bool obscureText = false,
    bool enabled = true,
    VoidCallback? toggleVisibility,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 15),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 7),
        TextField(
          key: ValueKey(fieldKey),
          controller: controller,
          keyboardType: keyboardType,
          enabled: enabled && !_busy,
          obscureText: obscureText,
          enableSuggestions: !obscureText && toggleVisibility == null,
          autocorrect: toggleVisibility == null,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: _muted, fontSize: 13),
            filled: true,
            fillColor: enabled ? _surface : const Color(0xFF101922),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: const BorderSide(color: Color(0xFF405264))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: const BorderSide(color: Color(0xFF405264))),
            disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: const BorderSide(color: Color(0xFF2B3947))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: const BorderSide(color: _accent, width: 1.5)),
            suffixIcon: toggleVisibility == null ? null : IconButton(
              onPressed: _busy ? null : toggleVisibility,
              tooltip: obscureText ? 'Show password' : 'Hide password',
              icon: Icon(obscureText ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: _muted, size: 20),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _imageTile(String label, String? path, int slot) => Padding(
    padding: const EdgeInsets.only(bottom: 15),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              width: 66, height: 60,
              decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(7), border: Border.all(color: const Color(0xFF405264))),
              clipBehavior: Clip.antiAlias,
              child: path == null
                ? const Icon(Icons.image_outlined, color: _muted, size: 27)
                : Image.file(File(path), fit: slot == 0 ? BoxFit.cover : BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(Icons.image_not_supported_outlined, color: _muted)),
            ),
            const SizedBox(width: 15),
            OutlinedButton(
              key: ValueKey('setup-upload-$slot'),
              onPressed: _busy ? null : () => _pick(slot),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: _surface,
                side: const BorderSide(color: Color(0xFF405264)),
                padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
              ),
              child: const Text('Choose file'),
            ),
            if (path != null) ...[
              const SizedBox(width: 12),
              Expanded(child: Text(path.split(Platform.pathSeparator).last,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _muted, fontSize: 11))),
            ],
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Theme(
    data: ThemeData.dark(useMaterial3: true).copyWith(
      textTheme: ThemeData.dark(useMaterial3: true).textTheme.apply(fontFamily: 'Segoe UI'),
      colorScheme: const ColorScheme.dark(primary: _accent, surface: _surface),
      scaffoldBackgroundColor: _background,
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? _accent : Colors.transparent),
        checkColor: const WidgetStatePropertyAll(_background),
        side: const BorderSide(color: _muted),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    ),
    child: Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 650),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.menu_book_rounded, color: _accent, size: 44),
                  const SizedBox(height: 8),
                  const Text('Vidya Saarthi', textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  Center(child: Container(width: 32, height: 3, decoration: BoxDecoration(color: _accent, borderRadius: BorderRadius.circular(2)))),
                  const SizedBox(height: 12),
                  const Text('School Setup', textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFFD7E0EA), fontSize: 19, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 24),
                  _field(label: 'School name *', hint: 'Enter school name', controller: _school, fieldKey: 'setup-school-name'),
                  _field(label: 'Principal name *', hint: 'Enter principal name', controller: _principal, fieldKey: 'setup-principal-name'),
                  _field(label: 'Contact no', hint: 'Enter contact number', controller: _contact, fieldKey: 'setup-contact', keyboardType: TextInputType.phone),
                  _field(label: 'New App lock *', hint: 'Create App Lock password', controller: _password, fieldKey: 'setup-app-lock',
                    obscureText: _obscure, toggleVisibility: () => setState(() => _obscure = !_obscure)),
                  _field(label: 'Confirm app lock *', hint: 'Confirm App Lock password', controller: _confirm, fieldKey: 'setup-confirm-lock',
                    obscureText: _confirmObscure, toggleVisibility: () => setState(() => _confirmObscure = !_confirmObscure)),
                  _field(label: 'Valid licence key', hint: 'Enter licence key', controller: _licence, fieldKey: 'setup-licence', enabled: !_skipLicence),
                  if (_trialEligible) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 26, height: 26, child: Checkbox(
                          key: const ValueKey('setup-skip-trial'),
                          value: _skipLicence,
                          onChanged: _busy ? null : (value) => setState(() { _skipLicence = value ?? false; _error = null; }),
                        )),
                        const SizedBox(width: 10),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Skip for now — use free trial', style: TextStyle(color: Colors.white, fontSize: 13)),
                            const SizedBox(height: 4),
                            const Text('Available during the 5-day trial. Add your licence later in Settings.',
                              style: TextStyle(color: _muted, fontSize: 11, height: 1.5)),
                          ],
                        )),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ] else const SizedBox(height: 8),
                  _imageTile('School logo', _logoPath, 0),
                  _imageTile('School signature', _signaturePath, 2),
                  _imageTile('School seal', _sealPath, 1),
                  if (_error != null) ...[
                    const SizedBox(height: 4),
                    Text(_error!, key: const ValueKey('admin-setup-error'),
                      style: const TextStyle(color: Color(0xFFFF8C8C), fontSize: 13)),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 4),
                  FilledButton(
                    key: const ValueKey('setup-submit'),
                    onPressed: _busy ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent, foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                    ),
                    child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: _background))
                      : const Text('Submit', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(height: 19),
                  const Text('After 1 hour without a mouse click in this app, App Lock will appear.', textAlign: TextAlign.center,
                    style: TextStyle(color: _muted, fontSize: 11)),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
