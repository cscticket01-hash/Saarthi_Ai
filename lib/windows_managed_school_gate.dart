import 'dart:async';

import 'school_cloud_engine.dart';
import 'windows_service_status.dart';

import 'package:flutter/material.dart';

import 'windows_connect/managed_school_session.dart';
import 'main_dashboard_screen_windows.dart' show WindowsLicenseSettingsPanel;
import 'windows_sync_engine.dart';

class WindowsManagedSchoolGate extends StatefulWidget {
  const WindowsManagedSchoolGate({
    super.key,
    required this.child,
    required this.legacy,
    this.onAuthenticated,
    this.engine,
  });
  final SchoolCloudEngine? engine;
  final Widget child, legacy;
  final VoidCallback? onAuthenticated;
  @override
  State<WindowsManagedSchoolGate> createState() =>
      _WindowsManagedSchoolGateState();
}

class _WindowsManagedSchoolGateState extends State<WindowsManagedSchoolGate> {
  late final SchoolCloudEngine engine;
  bool routed = false;
  String? error;
  final licence = TextEditingController();
  Timer? expiryTimer;
  @override
  void initState() {
    super.initState();
    engine = widget.engine ?? SchoolCloudEngine();
    engine.addListener(updated);
    WindowsSyncEngine.instance.state.addListener(updated);
    WindowsServiceStatus.instance.addListener(updated);
    ManagedSchoolSession.changed.addListener(sessionChanged);
    unawaited(engine.restore());
    expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (engine.access != null && !engine.canOpen && mounted) setState(() {});
    });
  }

  void updated() {
    if (mounted) setState(() {});
  }

  void sessionChanged() {
    routed = false;
    unawaited(
      engine.restore().then((_) {
        if (mounted && engine.canOpen && !routed) {
          routed = true;
          widget.onAuthenticated?.call();
        }
      }),
    );
  }

  @override
  void dispose() {
    expiryTimer?.cancel();
    engine.removeListener(updated);
    engine.dispose();
    WindowsSyncEngine.instance.state.removeListener(updated);
    WindowsServiceStatus.instance.removeListener(updated);
    ManagedSchoolSession.changed.removeListener(sessionChanged);
    licence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (engine.restoring)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!engine.hasIdentity) {
      if (engine.error != null)
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(engine.error!),
                FilledButton(
                  onPressed: engine.restore,
                  child: const Text('Retry saved school access'),
                ),
              ],
            ),
          ),
        );
      return const WindowsManagedSchoolLogin();
    }
    if (!engine.localReady)
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'School local data could not be opened. Existing data is retained.',
              ),
              FilledButton(
                onPressed: engine.restore,
                child: const Text('Retry saved school access'),
              ),
            ],
          ),
        ),
      );
    if (!engine.canOpen) {
      final s = engine.access;
      if (s == null)
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Verify this saved school once to enable local access. Existing data is retained.',
                ),
                FilledButton(
                  onPressed: engine.verify,
                  child: const Text('Retry school verification'),
                ),
                TextButton(
                  onPressed: ManagedSchoolSession.logout,
                  child: const Text('Sign in again'),
                ),
              ],
            ),
          ),
        );
      return Scaffold(
        body: Center(
          child: SizedBox(
            width: 430,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('School ${s['schoolId']} • ${s['status']}'),
                const Text(
                  'School access needs verification or a valid licence.',
                ),
                if (s['status'] != 'blocked' &&
                    s['status'] != 'auth_required') ...[
                  TextField(
                    controller: licence,
                    decoration: const InputDecoration(
                      labelText: 'School licence key',
                    ),
                  ),
                  FilledButton(
                    onPressed: () async {
                      try {
                        await ManagedSchoolSession.call(
                          'managed/licence/activate',
                          {'key': licence.text},
                        );
                        await engine.verify();
                      } catch (e) {
                        if (mounted) setState(() => error = '$e');
                      }
                    },
                    child: const Text('Verify licence'),
                  ),
                ],
                FilledButton(
                  onPressed: engine.verify,
                  child: const Text('Retry school verification'),
                ),
                if (error != null) Text(error!),
                TextButton(
                  onPressed: ManagedSchoolSession.logout,
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final s = engine.access!, status = engine.displayState;
    final pending =
        status == SchoolCloudState.offline ||
        status == SchoolCloudState.syncError ||
        status == SchoolCloudState.driveDisconnected;
    return Column(
      children: [
        if (pending)
          Material(
            color: Colors.orange.shade900,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off, size: 16),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Offline / Sync pending • Local data remains available',
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        unawaited(engine.verify());
                        WindowsSyncEngine.instance.scheduleSoon();
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (s['status'] == 'trial')
          Material(
            color: Colors.red.shade900,
            child: ListTile(
              title: Text(
                'Five-day trial • Ends ${DateTime.fromMillisecondsSinceEpoch((s['expiresAt'] as num).toInt()).toLocal()}',
              ),
              onTap: () => showDialog<void>(
                context: context,
                builder: (ctx) => Dialog(
                  child: SizedBox(
                    width: 650,
                    child: SingleChildScrollView(
                      child: WindowsLicenseSettingsPanel(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey(s['schoolId']),
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class WindowsManagedSchoolLogin extends StatefulWidget {
  const WindowsManagedSchoolLogin({super.key, this.error});
  final String? error;
  @override
  State<WindowsManagedSchoolLogin> createState() =>
      _WindowsManagedSchoolLoginState();
}

class _WindowsManagedSchoolLoginState extends State<WindowsManagedSchoolLogin> {
  final email = TextEditingController(), password = TextEditingController();
  bool busy = false, showPassword = false;
  String? error;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Vidya Saarthi • School Login')),
    body: Center(
      child: SingleChildScrollView(
        child: SizedBox(
          width: 430,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Use the school account created by your developer.'),
                TextField(
                  controller: email,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'School login email',
                  ),
                ),
                TextField(
                  controller: password,
                  obscureText: !showPassword,
                  enableSuggestions: false,
                  autocorrect: false,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: TextInputType.visiblePassword,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    suffixIcon: Semantics(
                      label: showPassword ? 'Hide password' : 'Show password',
                      button: true,
                      child: IconButton(
                        key: ValueKey(
                          showPassword ? 'hide-password' : 'show-password',
                        ),
                        onPressed: () =>
                            setState(() => showPassword = !showPassword),
                        icon: Icon(
                          showPassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),
                  ),
                ),
                if ((error ?? widget.error) != null)
                  Text(error ?? widget.error ?? ''),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          try {
                            await ManagedSchoolSession.login(
                              email.text,
                              password.text,
                            );
                            password.clear();
                            await WindowsSyncEngine.instance
                                .activateCurrentConnections(
                                  allowPairing: false,
                                );
                          } catch (e) {
                            if (mounted) setState(() => error = '$e');
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                  child: Text(busy ? 'Signing in…' : 'School Login'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
