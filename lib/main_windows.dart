import 'dart:async';

import 'package:flutter/material.dart';

import 'main_dashboard_screen_windows.dart';
import 'windows_html_shim.dart' as windows_html;
import 'windows_local_auth.dart';
import 'windows_local_session.dart';
import 'windows_local_settings.dart';
import 'windows_local_storage.dart';
import 'windows_sync_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await WindowsLocalStorage.initialize();
  await WindowsLocalSession.initialize();
  await FirebaseAuth.instance.bootstrapLocalUser();
  await WindowsSyncEngine.instance.initialize();

  if (WindowsLocalSession.loggedOut) {
    await FirebaseAuth.instance.signOut();
  }

  // WindowsSyncEngine has already selected the connection-scoped
  // storage namespace. Never force all schools back into one 'local' bucket.
  runApp(const VidyaSaarthiWindowsApp());
}

class VidyaSaarthiWindowsApp extends StatelessWidget {
  const VidyaSaarthiWindowsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vidya Saarthi',
      debugShowCheckedModeBanner: false,

      // Website main.dart ka theme intentionally same rakha gaya hai.
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B141A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F2C34),
          elevation: 1,
        ),
      ),
      builder: (context, child) {
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => windows_html.document.dispatchClick(),
          child: child ?? const SizedBox.shrink(),
        );
      },
      routes: {
        '/local-login': (_) => const WindowsLocalLoginScreen(),
        '/dashboard': (_) => const WindowsLocalDashboardGate(),
      },
      home: !WindowsLocalSecurity.configured
          ? const WindowsFirstRunSecuritySetup()
          : WindowsLocalSession.loggedOut
              ? const WindowsLocalLoginScreen()
              : const WindowsLocalDashboardGate(),
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
        .add(const Duration(days: 3650))
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
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/dashboard',
        (route) => false,
      );
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
