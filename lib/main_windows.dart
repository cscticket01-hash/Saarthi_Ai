import 'windows_managed_school_gate.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_ui_localization.dart';
import 'dart:async';
import 'windows_platform_client.dart';
import 'windows_license_gate.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart' hide Text, InputDecoration;

import 'main_dashboard_screen_windows.dart';
import 'windows_html_shim.dart' as windows_html;
import 'windows_local_auth.dart';
import 'windows_local_session.dart';
import 'windows_local_settings.dart';
import 'windows_local_storage.dart';
import 'windows_connection_center.dart';
import 'windows_admin_setup.dart';
import 'windows_update_service.dart' as update_service;
import 'windows_update_manager.dart';

final _schoolNavigatorKey=GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await WindowsLocalSecurity.initialize();
  await WindowsLocalStorage.initialize();
  try {
    await WindowsUpdateManager.cleanupOldInstallers();
  } catch (_) {}
  await WindowsLocalSession.initialize();
  await FirebaseAuth.instance.bootstrapLocalUser();

  if (WindowsLocalSession.loggedOut) {
    await FirebaseAuth.instance.signOut();
  }

  windows_html.setSchoolStorageNamespace('local');
  await WindowsPlatformClient.instance.initialize();
  runApp(const VidyaSaarthiWindowsApp());

}

class VidyaSaarthiWindowsApp extends StatelessWidget {
  const VidyaSaarthiWindowsApp({
    super.key,
    this.initializeConnections = WindowsConnectionCenter.initialize,
  });

  final Future<void> Function() initializeConnections;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(valueListenable: WindowsUiLanguage.changed,
      builder: (context, language, _) => MaterialApp(
      navigatorKey:_schoolNavigatorKey,
      locale: Locale(language),
      supportedLocales: const [Locale('en'), Locale('hi'), Locale('bn'), Locale('as')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      title: 'Vidya Saarthi',
      debugShowCheckedModeBanner: false,

      // Website main.dart ka theme intentionally same rakha gaya hai.
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'Segoe UI',
        fontFamilyFallback: const ['Nirmala UI', 'Arial'],
        scaffoldBackgroundColor: const Color(0xFF0B141A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F2C34),
          elevation: 1,
        ),
      ),
      builder: (context, child) {
        final content = Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => windows_html.document.dispatchClick(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: child ?? const SizedBox.shrink(),
                ),
                const _WindowsGlobalUpdateProgress(),
              ],
            ),
          );
        return WindowsManagedSchoolGate(child:content,legacy:WindowsLicenseGate(child:content),onAuthenticated:()=>_schoolNavigatorKey.currentState?.pushNamedAndRemoveUntil('/',(route)=>false));
      },
      routes: {
        '/first-run': (_) => const WindowsFirstRunSecuritySetup(),
        '/admin-setup': (_) => const WindowsAdminSetupScreen(),
        '/local-login': (_) => const WindowsLocalLoginScreen(),
        '/dashboard': (_) => const WindowsLocalDashboardGate(),
      },
      home: WindowsStartupFlow(
        initializeConnections: initializeConnections,
      ),
    ));
  }
}

/// Startup order after the licence gate:
///   License screen (handled by WindowsLicenseGate) -> Skip -> Admin Setup
///   (only when not already completed) -> Home.
/// The optional online connection check now runs in the background; it never
/// blocks opening the app and Firebase is not required to reach Home.
class WindowsStartupFlow extends StatefulWidget {
  const WindowsStartupFlow(
      {super.key,
      this.initializeConnections = WindowsConnectionCenter.initialize});

  final Future<void> Function() initializeConnections;

  @override
  State<WindowsStartupFlow> createState() => _WindowsStartupFlowState();
}

class _WindowsStartupFlowState extends State<WindowsStartupFlow> {
  bool _loading = true;
  bool _setupDone = false;
  bool _managed = false;

  @override
  void initState() {
    super.initState();
    // Optional school-connection init continues in the background only.
    unawaited(widget.initializeConnections().catchError((error) {
      debugPrint('Windows background connection init: $error');
    }));
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      await WindowsLocalSecurity.initialize();
      final done = await WindowsAdminSetup.completed();
      final managed=(await CentralSchoolCloud.saved())['managed']==true;
      if (!mounted) return;
      setState(() {
        _setupDone = done;
        _managed = managed;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _setupDone = WindowsLocalSecurity.configured;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B141A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF00A884)),
        ),
      );
    }
    if(_managed) return _setupDone ? const WindowsLocalDashboardGate() : const WindowsAdminSetupScreen();
    // Fresh install: local-first Admin Setup before the dashboard.
    if (!_setupDone && !WindowsLocalSecurity.configured) {
      return const WindowsAdminSetupScreen();
    }
    // School/cloud initialization is already running in the background.
    // Never add a second online-startup screen or a duplicate connection check.
    return WindowsLocalSession.loggedOut
        ? const WindowsLocalLoginScreen()
        : const WindowsStartupGate(child: WindowsLocalDashboardGate());
  }
}

/// Requires the existing local password before showing a saved dashboard.
/// School Firebase verification remains in Advanced Settings.
class WindowsStartupGate extends StatefulWidget {
  const WindowsStartupGate({super.key, required this.child});

  final Widget child;

  @override
  State<WindowsStartupGate> createState() => _WindowsStartupGateState();
}

class _WindowsStartupGateState extends State<WindowsStartupGate> {
  final _password = TextEditingController();
  bool _loading = true;
  bool _locked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      await WindowsLocalSecurity.initialize();
      final shouldLock = WindowsLocalSecurity.configured;
      if (!mounted) return;
      setState(() {
        _locked = shouldLock;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _locked = true;
        _error = 'App Password load nahi ho paya. App restart karein.';
      });
    }
  }

  void _unlock() {
    final password = _password.text;
    if (WindowsLocalSecurity.verifyPassword(password)) {
      setState(() {
        _locked = false;
        _error = null;
      });
      _password.clear();
      return;
    }
    setState(() => _error = 'Galat App Password.');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B141A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF00A884)),
        ),
      );
    }

    if (!_locked) return widget.child;

    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Card(
            color: const Color(0xFF172229),
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_rounded,
                      color: Color(0xFF00D9A5), size: 42),
                  const SizedBox(height: 12),
                  const Text(
                    'Vidya Saarthi Locked',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'App open karne ke liye password daalein.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _password,
                    autofocus: true,
                    obscureText: true,
                    onSubmitted: (_) => _unlock(),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'App Password',
                      errorText: _error,
                      prefixIcon: const Icon(Icons.password_rounded),
                      filled: true,
                      fillColor: const Color(0xFF0F191F),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _unlock,
                    icon: const Icon(Icons.login_rounded),
                    label: const Text('Unlock App'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00A884),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowsGlobalUpdateProgress extends StatelessWidget {
  const _WindowsGlobalUpdateProgress();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<update_service.WindowsUpdateRuntimeState>(
      valueListenable: update_service.WindowsUpdateService.state,
      builder: (context, state, _) {
        if (!state.downloading && !state.launching) {
          return const SizedBox.shrink();
        }

        final percent = state.progress == null
            ? null
            : (state.progress! * 100).clamp(0, 100).toStringAsFixed(0);

        return IgnorePointer(
          child: Align(
            alignment: Alignment.topRight,
            child: SafeArea(
              child: Container(
                width: 310,
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF172229),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white10),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black38,
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.system_update_alt_rounded,
                          color: Color(0xFF4DA3FF),
                          size: 19,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            state.launching
                                ? 'Update ready'
                                : 'App update downloading${percent == null ? '' : ' • $percent%'}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: state.launching ? 1 : state.progress,
                      minHeight: 5,
                      color: const Color(0xFF4DA3FF),
                      backgroundColor: Colors.white10,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      state.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 9.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class WindowsLocalDashboardGate extends StatelessWidget {
  const WindowsLocalDashboardGate({super.key});

  void _primeLocalAdminSession() {
    final storage = windows_html.window.localStorage;
    storage['saarthi_portal_role_v1'] = 'admin';
    storage.remove('saarthi_portal_student_id_v1');
    storage.remove('saarthi_portal_student_class_v1');
    storage['saarthi_portal_expiry_v1'] = DateTime.now()
        .add(const Duration(minutes: 30))
        .millisecondsSinceEpoch
        .toString();
  }

  @override
  Widget build(BuildContext context) {
    _primeLocalAdminSession();
    return const AdminDashboardScreen();
  }
}

class WindowsLocalLoginScreen extends StatefulWidget {
  const WindowsLocalLoginScreen({super.key});

  @override
  State<WindowsLocalLoginScreen> createState() =>
      _WindowsLocalLoginScreenState();
}

class _WindowsLocalLoginScreenState extends State<WindowsLocalLoginScreen> {
  final _adminId = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _adminId.text = WindowsLocalSecurity.adminId;
  }

  Future<void> _login() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _adminId.text,
        password: _password.text,
      );
      await WindowsLocalSession.markLoggedIn();
      if (!mounted) return;
      final navigator = Navigator.of(context);
      navigator.pushNamedAndRemoveUntil(
        '/dashboard',
        (route) => false,
      );
      // Open the dashboard first. An optional network/update check must not
      // leave a successfully authenticated user waiting on the login screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final overlayContext = navigator.overlay?.context;
        if (overlayContext != null && overlayContext.mounted) {
          unawaited(WindowsUpdateManager.promptIfAvailable(overlayContext));
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e
            .toString()
            .replaceFirst('FirebaseAuthException: ', '')
            .replaceFirst('Bad state: ', '');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _adminId.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _LocalAuthShell(
      title: 'Vidya Saarthi',
      subtitle: 'LOCAL ADMIN LOGIN',
      description:
          'Local ID/Password se Windows app unlock karein. Firebase connection alag rahega.',
      children: [
        TextField(
          controller: _adminId,
          decoration: const InputDecoration(
            labelText: 'Local Admin ID',
            prefixIcon: Icon(Icons.person_outline_rounded),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: _obscure,
          onSubmitted: (_) => _login(),
          decoration: InputDecoration(
            labelText: 'Local Password',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ],
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: _busy ? null : _login,
            icon: _busy
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.login_rounded),
            label: Text(_busy ? 'Opening...' : 'Open Vidya Saarthi'),
          ),
        ),
      ],
    );
  }
}

class WindowsFirstRunSecuritySetup extends StatefulWidget {
  const WindowsFirstRunSecuritySetup({super.key});

  @override
  State<WindowsFirstRunSecuritySetup> createState() =>
      _WindowsFirstRunSecuritySetupState();
}

class _WindowsFirstRunSecuritySetupState
    extends State<WindowsFirstRunSecuritySetup> {
  final _adminId = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  Future<void> _save() async {
    if (_busy) return;
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Password match nahi kar raha.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await WindowsLocalSecurity.create(
        adminId: _adminId.text,
        password: _password.text,
      );
      await FirebaseAuth.instance.refreshLocalUser();
      await WindowsLocalSession.markLoggedIn();
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/dashboard',
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e
            .toString()
            .replaceFirst('FormatException: ', '')
            .replaceFirst('Bad state: ', '');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _adminId.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _LocalAuthShell(
      title: 'Vidya Saarthi',
      subtitle: 'CREATE LOCAL SETTINGS LOCK',
      description:
          'Ye ID/Password sirf is PC ke protected Settings aur local login ke liye hoga. Firebase login nahi hai.',
      children: [
        TextField(
          controller: _adminId,
          decoration: const InputDecoration(
            labelText: 'Local Admin ID',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'Settings Password',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirm,
          obscureText: _obscure,
          onSubmitted: (_) => _save(),
          decoration: const InputDecoration(
            labelText: 'Confirm Password',
            prefixIcon: Icon(Icons.verified_user_outlined),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.arrow_forward_rounded),
            label: Text(_busy ? 'Saving...' : 'Create Lock & Open App'),
          ),
        ),
      ],
    );
  }
}

class _LocalAuthShell extends StatelessWidget {
  const _LocalAuthShell({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.children,
  });

  final String title;
  final String subtitle;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF06171D),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: 500,
            padding: const EdgeInsets.all(30),
            decoration: BoxDecoration(
              color: const Color(0xFF0A1E26),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: const Color(0xFF00E8D0).withOpacity(0.35),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF33E9D0), Color(0xFF00A8FF)],
                    ),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: const Icon(
                    Icons.admin_panel_settings_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF00D9A5),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 22),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
