import 'school_password_panel.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_ui_localization.dart';
import 'dart:io';

import 'package:flutter/material.dart' hide Text, InputDecoration;

import 'windows_firebase_sync.dart';
import 'windows_local_auth.dart';
import 'windows_local_settings.dart';
import 'windows_local_storage.dart';
import 'windows_service_status.dart';
import 'windows_update_service.dart';
import 'windows_app_restart.dart';
import 'windows_runtime_flags.dart';
import 'windows_connection_center.dart';

class WindowsSettingsPanel extends StatefulWidget {
  const WindowsSettingsPanel({
    super.key,
    this.showLocalLock = true,
    this.showFirebase = false,
    this.lockRowOnly = false,
  });

  /// Keeps the Local Settings Lock on Password Management.
  final bool showLocalLock;

  /// Shows the school Firebase connection only from Advanced Settings.
  final bool showFirebase;
  final bool lockRowOnly;

  @override
  State<WindowsSettingsPanel> createState() => _WindowsSettingsPanelState();
}

class _WindowsSettingsPanelState extends State<WindowsSettingsPanel> {
  final _firebase = TextEditingController();
  final _firebaseEmail = TextEditingController();
  final _firebasePassword = TextEditingController();

  bool _managed=false;
  bool _loading = true;
  bool _firebaseBusy = false;
  bool _disconnectBusy = false;
  bool _obscure = true;
  String _projectId = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _firebase.dispose();
    _firebaseEmail.dispose();
    _firebasePassword.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _managed=(await CentralSchoolCloud.saved())['managed']==true;
    if (!widget.showFirebase || _managed) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final local = await WindowsExternalConnections.load();
    final remote = await WindowsFirebaseRemote.status();
    _firebase.text = local['firebaseLink']?.toString() ?? '';
    _firebaseEmail.text = remote.email;
    _projectId = remote.projectId;

    if (remote.authenticated) {
      WindowsServiceStatus.instance.checking(
        WindowsServiceType.firebase,
        'Saved Firebase connection actual test chal raha hai...',
      );
      try {
        final result = await WindowsFirebaseRemote.testSavedConnection();
        _projectId = result.projectId;
        _firebaseEmail.text = result.email;
        WindowsServiceStatus.instance.healthy(
          WindowsServiceType.firebase,
          'Firebase Auth + Firestore actual request successful.',
        );
      } catch (e) {
        WindowsServiceStatus.instance.unhealthy(
          WindowsServiceType.firebase,
          'Firebase actual test fail: $e',
        );
      }
    } else {
      WindowsServiceStatus.instance.unhealthy(
        WindowsServiceType.firebase,
        'Firebase connected nahi hai.',
      );
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _unlock() async {
    final controller = TextEditingController();
    String? error;
    bool obscure = true;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF172229),
          title: const Text(
            'App Lock',
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: controller,
              obscureText: obscure,
              autofocus: true,
              onSubmitted: (_) {
                final ok = WindowsLocalSecurity.verifyPassword(controller.text);
                if (ok) {
                  Navigator.pop(dialogContext, true);
                } else {
                  setDialogState(() => error = 'Galat Local Password.');
                }
              },
              decoration: InputDecoration(
                labelText: 'Local Password',
                errorText: error,
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  onPressed: () => setDialogState(() => obscure = !obscure),
                  icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final ok = WindowsLocalSecurity.verifyPassword(controller.text);
                if (ok) {
                  Navigator.pop(dialogContext, true);
                } else {
                  setDialogState(() => error = 'Galat Local Password.');
                }
              },
              child: const Text('Unlock'),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    return result == true;
  }

  Future<void> _changeLock() async {
    final current = TextEditingController();
    final id = TextEditingController(text: WindowsLocalSecurity.adminId);
    final password = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    bool obscure = true;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF172229),
          title: const Text(
            'Set / Change App Lock',
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 470,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: current,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Current Local Password',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: id,
                  decoration: const InputDecoration(labelText: 'Local Admin ID'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: password,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: 'New Password',
                    suffixIcon: IconButton(
                      onPressed: () => setDialogState(() => obscure = !obscure),
                      icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirm,
                  obscureText: obscure,
                  decoration: const InputDecoration(labelText: 'Confirm Password'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (password.text != confirm.text) {
                  setDialogState(() => error = 'Password match nahi kar raha.');
                  return;
                }
                try {
                  await WindowsLocalSecurity.change(
                    currentPassword: current.text,
                    newAdminId: id.text,
                    newPassword: password.text,
                  );
                  await FirebaseAuth.instance.refreshLocalUser();
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                } catch (e) {
                  setDialogState(() {
                    error = e.toString().replaceFirst('Bad state: ', '');
                  });
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    current.dispose();
    id.dispose();
    password.dispose();
    confirm.dispose();

    if (saved == true && mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF00A884),
          content: Text('Local ID / Password update ho gaya.'),
        ),
      );
    }
  }

  Future<void> _connectFirebase() async {
    if (_firebaseBusy) return;
    if (!await _unlock()) return;

    final link = _firebase.text.trim();
    final email = _firebaseEmail.text.trim();
    final password = _firebasePassword.text;

    if (link.isEmpty || email.isEmpty || password.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text('Firebase URL, Admin Email aur Password tino bharein.'),
        ),
      );
      return;
    }

    setState(() => _firebaseBusy = true);
    WindowsServiceStatus.instance.checking(
      WindowsServiceType.firebase,
      'Firebase Auth + Firestore verify ho raha hai...',
    );

    try {
      final result = await WindowsFirebaseRemote.connectAndVerify(
        firebaseLink: link,
        email: email,
        password: password,
      );
      _firebasePassword.clear();
      _projectId = result.projectId;
      _firebaseEmail.text = result.email;
      WindowsServiceStatus.instance.healthy(
        WindowsServiceType.firebase,
        'Firebase Auth + Firestore actual request successful.',
      );
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text('Firebase connected: ${result.projectId}'),
        ),
      );
      await WindowsAppRestart.restart(reason: 'Firebase connection changed');
    } catch (e) {
      WindowsServiceStatus.instance.unhealthy(
        WindowsServiceType.firebase,
        'Firebase connection fail: $e',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            e.toString()
                .replaceFirst('Bad state: ', '')
                .replaceFirst('FormatException: ', ''),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _firebaseBusy = false);
    }
  }

  Future<void> _testFirebase() async {
    if (_firebaseBusy) return;
    setState(() => _firebaseBusy = true);
    WindowsServiceStatus.instance.checking(
      WindowsServiceType.firebase,
      'Firebase actual connection test chal raha hai...',
    );
    try {
      final result = await WindowsFirebaseRemote.testSavedConnection();
      _projectId = result.projectId;
      _firebaseEmail.text = result.email;
      WindowsServiceStatus.instance.healthy(
        WindowsServiceType.firebase,
        'Firebase Auth + Firestore actual request successful.',
      );
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF00A884),
            content: Text('Firebase actual connection OK.'),
          ),
        );
      }
    } catch (e) {
      WindowsServiceStatus.instance.unhealthy(
        WindowsServiceType.firebase,
        'Firebase actual test fail: $e',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(e.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _firebaseBusy = false);
    }
  }

  Future<void> _disconnectFirebase() async {
    if (_disconnectBusy) return;
    if (!await _unlock()) return;
    if (!mounted) return;

    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF172229),
        title: const Text('Disconnect Firebase?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Sirf Firebase connection remove hoga. Local school data delete nahi hoga.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (yes != true) return;

    setState(() => _disconnectBusy = true);
    try {
      await WindowsFirebaseRemote.disconnect();
      _firebase.clear();
      _firebaseEmail.clear();
      _firebasePassword.clear();
      _projectId = '';
      WindowsServiceStatus.instance.unhealthy(
        WindowsServiceType.firebase,
        'Firebase disconnected.',
      );
      if (mounted) setState(() {});
      await WindowsAppRestart.restart(reason: 'Firebase disconnected');
    } finally {
      if (mounted) setState(() => _disconnectBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Column(
      children: [
        if (widget.showLocalLock) ...[
          if(_managed && !widget.lockRowOnly)SchoolPasswordPanel(change:ManagedSchoolSession.changePassword),
          if(_managed && !widget.lockRowOnly)const SizedBox(height:14),
          _localLockCard(),
        ],
        if (widget.showLocalLock && widget.showFirebase)
          const SizedBox(height: 14),
        if (widget.showFirebase && !_managed) _firebaseCard(),
      ],
    );
  }

  Widget _localLockCard() {
    if(widget.lockRowOnly) return ListTile(leading:const Icon(Icons.lock),title:const Text('App Lock'),subtitle:Text(WindowsLocalSecurity.configured?'ON • local app-open password':'OFF • password not set'),trailing:Wrap(children:[TextButton(onPressed:_changeLock,child:const Text('Set / Change Password')),if(WindowsLocalSecurity.configured)TextButton(onPressed:()async{if(!await _unlock())return;await WindowsLocalSecurity.clearAppLock();if(mounted)setState((){});},child:const Text('Disable'))]));
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_rounded, color: Color(0xFF00D9A5)),
              SizedBox(width: 9),
              Text(
                'App Lock',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Admin ID: ${WindowsLocalSecurity.adminId}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 4),
          const Text(
            'App kholne ka local password. School Login se alag hai.',
            style: TextStyle(color: Colors.white38, fontSize: 10.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _changeLock,
            icon: const Icon(Icons.manage_accounts_rounded, size: 18),
            label: const Text('Set / Change App Lock'),
          ),
          if(WindowsLocalSecurity.configured)TextButton(
            onPressed:()async{if(!await _unlock())return;await WindowsLocalSecurity.clearAppLock();await FirebaseAuth.instance.refreshLocalUser();if(mounted)setState((){});},
            child:const Text('Disable App Lock'),
          ),
        ],
      ),
    );
  }

  Widget _firebaseCard() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.local_fire_department_rounded, color: Colors.orangeAccent),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Firebase Connection',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              WindowsStatusLed(service: WindowsServiceType.firebase),
            ],
          ),
          if (_projectId.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Project: $_projectId',
              style: const TextStyle(
                color: Color(0xFF00D9A5),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 13),
          TextField(
            controller: _firebase,
            maxLines: 2,
            enabled: !_firebaseBusy,
            decoration: const InputDecoration(
              labelText: 'Firebase URL',
              hintText: 'vidyasaarthi://firebase?config=...',
              prefixIcon: Icon(Icons.link_rounded),
            ),
          ),
          const SizedBox(height: 11),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 650;
              final email = TextField(
                controller: _firebaseEmail,
                enabled: !_firebaseBusy,
                decoration: const InputDecoration(
                  labelText: 'Admin Email',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              );
              final password = TextField(
                controller: _firebasePassword,
                obscureText: _obscure,
                enabled: !_firebaseBusy,
                onSubmitted: (_) => _connectFirebase(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                  ),
                ),
              );

              if (compact) {
                return Column(
                  children: [email, const SizedBox(height: 10), password],
                );
              }
              return Row(
                children: [
                  Expanded(child: email),
                  const SizedBox(width: 10),
                  Expanded(child: password),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _firebaseBusy ? null : _connectFirebase,
              icon: _firebaseBusy
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.link_rounded),
              label: Text(_firebaseBusy ? 'Verifying...' : 'Connect & Verify'),
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _firebaseBusy ? null : _testFirebase,
                  icon: const Icon(Icons.verified_rounded, size: 18),
                  label: const Text('Test Actual Connection'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _disconnectBusy ? null : _disconnectFirebase,
                  icon: const Icon(Icons.link_off_rounded, size: 18),
                  label: const Text('Disconnect'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'LED GREEN tabhi hoga jab Firebase Auth + Firestore actual request successful ho. Password save nahi hota.',
            style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _panel({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF111B21),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(.06)),
      ),
      child: child,
    );
  }
}

class WindowsLocalStorageCard extends StatefulWidget {
  const WindowsLocalStorageCard({super.key});

  @override
  State<WindowsLocalStorageCard> createState() => _WindowsLocalStorageCardState();
}

class _WindowsLocalStorageCardState extends State<WindowsLocalStorageCard> {
  String _path = '';
  bool _busy = true;
  bool _localStorageEnabled = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final path = await WindowsLocalStorage.currentPath();
    final localEnabled = await WindowsRuntimeFlags.localStorageEnabled();
    if (localEnabled) {
      await WindowsLocalStorage.healthCheck();
    }
    if (mounted) {
      setState(() {
        _path = path;
        _localStorageEnabled = localEnabled;
        _busy = false;
      });
    }
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      final path = await WindowsLocalStorage.createBackup();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text('Backup ready: $path'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.redAccent, content: Text('Backup error: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeLocation() async {
    final controller = TextEditingController(text: _path);
    String? error;
    final next = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF172229),
          title: const Text('Change Local Storage Location', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 570,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Example: D:\\VidyaSaarthiData\nCurrent database aur LocalFiles new HDD/folder me COPY honge. Old copy safety ke liye rahegi.',
                  style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.45),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'New Folder Path',
                    errorText: error,
                    prefixIcon: const Icon(Icons.folder_open_rounded),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setDialogState(() => error = 'Folder path daalein.');
                  return;
                }
                Navigator.pop(ctx, value);
              },
              child: const Text('Move / Use This Folder'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (next == null || next.trim().isEmpty) return;

    setState(() => _busy = true);
    try {
      await WindowsLocalStorage.changeLocation(next);
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF00A884),
          content: Text('Local storage location safely change ho gaya.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.redAccent, content: Text('Storage change error: $e')),
      );
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _settingsStyleCard(
      icon: Icons.storage_rounded,
      iconColor: const Color(0xFF00D9A5),
      title: 'Local Data',
      subtitle: 'Device data ON/OFF + optional HDD location',
      trailing: const WindowsStatusLed(service: WindowsServiceType.localStorage),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _localStorageEnabled,
            title: const Text('Local Data', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
            subtitle: Text(
              _localStorageEnabled
                  ? 'ON: device local data show/save hoga; active school profile se isolated rahega.'
                  : 'OFF: local school data disk par read/save nahi hoga; remote Firebase + Google mode chalega.',
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
            onChanged: _busy
                ? null
                : (value) async {
                    setState(() => _busy = true);
                    try {
                      await WindowsRuntimeFlags.setLocalStorageEnabled(value);
                      await WindowsConnectionCenter.localStorageModeChanged();
                      if (!mounted) return;
                      setState(() {
                        _localStorageEnabled = value;
                        _busy = false;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          backgroundColor: const Color(0xFF00A884),
                          content: Text(
                            value
                                ? 'Local Data ON: device local data enabled.'
                                : 'Local Data OFF: disk cache/save disabled. Remote data only.',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      setState(() => _busy = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          backgroundColor: Colors.redAccent,
                          content: Text('Local Data switch error: $e'),
                        ),
                      );
                    }
                  },
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F191F),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              _path.isEmpty ? 'Loading...' : _path,
              style: const TextStyle(color: Colors.white70, fontSize: 11.5),
            ),
          ),
          const SizedBox(height: 11),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : WindowsLocalStorage.openFolder,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('Open Folder'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _backup,
                icon: const Icon(Icons.backup_rounded, size: 18),
                label: const Text('Backup Data'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _changeLocation,
                icon: const Icon(Icons.drive_file_move_rounded, size: 18),
                label: const Text('Change HDD / Folder'),
              ),
              IconButton(
                tooltip: WindowsUiLanguage.translate('Re-test local storage'),
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'LED RED hua to folder/disk/permission/database me problem hai. HDD change karne par existing local data new location me copy karke hi switch hoga.',
            style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class WindowsAppUpdateCard extends StatelessWidget {
  const WindowsAppUpdateCard({super.key});

  Future<void> _check() async {
    try {
      await WindowsUpdateService.checkAndRemember();
    } catch (_) {
      // Global state already contains the user-visible error.
    }
  }

  Future<void> _install() async {
    try {
      await WindowsUpdateService.startDownloadAndInstall();
    } catch (_) {
      // Global state already contains the user-visible error.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WindowsUpdateRuntimeState>(
      valueListenable: WindowsUpdateService.state,
      builder: (context, state, _) {
        final update = state.update;
        final progressText = state.progress == null
            ? ''
            : ' ${(state.progress! * 100).clamp(0, 100).toStringAsFixed(0)}%';

        return _settingsStyleCard(
          icon: Icons.system_update_alt_rounded,
          iconColor: const Color(0xFF4DA3FF),
          title: 'App Update',
          subtitle: 'Windows master app update • Current v$windowsAppVersion',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (state.message.isNotEmpty) ...[
                Text(
                  state.message,
                  style: TextStyle(
                    color: state.phase == WindowsUpdatePhase.error
                        ? Colors.redAccent
                        : Colors.white70,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (state.downloading || state.launching) ...[
                LinearProgressIndicator(
                  value: state.launching ? 1 : state.progress,
                  minHeight: 7,
                ),
                const SizedBox(height: 7),
                Text(
                  state.launching
                      ? 'Download complete. Installer open ho raha hai...'
                      : 'Downloading$progressText • Page change karne par bhi download continue rahega.',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: state.busy ? null : _check,
                      icon: state.checking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(state.checking ? 'Checking...' : 'Check for Update'),
                    ),
                  ),
                  if (update?.updateAvailable == true) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: state.busy ? null : _install,
                        icon: const Icon(Icons.download_rounded, size: 18),
                        label: Text(
                          state.downloading
                              ? 'Downloading$progressText'
                              : state.launching
                                  ? 'Opening Installer...'
                                  : 'Download & Install',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

Widget _settingsStyleCard({
  required IconData icon,
  required Color iconColor,
  required String title,
  required String subtitle,
  required Widget child,
  Widget? trailing,
}) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xFF172229),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Colors.white.withOpacity(.06)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: iconColor, size: 25),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    ),
  );
}
