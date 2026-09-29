import 'package:flutter/material.dart';

import 'main_dashboard_screen_windows.dart';
import 'windows_html_shim.dart' as windows_html;
import 'windows_local_auth.dart';
import 'windows_local_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FirebaseAuth.instance.bootstrapLocalUser();

  windows_html.setSchoolStorageNamespace('local');

  runApp(
    const VidyaSaarthiWindowsApp(),
  );
}

class VidyaSaarthiWindowsApp
    extends StatelessWidget {
  const VidyaSaarthiWindowsApp({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vidya Saarthi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor:
            const Color(0xFF0B141A),
        appBarTheme: const AppBarTheme(
          backgroundColor:
              Color(0xFF1F2C34),
          elevation: 1,
        ),
        colorScheme:
            const ColorScheme.dark(
          primary: Color(0xFF00A884),
          secondary: Color(0xFF00D9A5),
        ),
      ),
      builder: (context, child) {
        return Listener(
          behavior:
              HitTestBehavior.translucent,
          onPointerDown: (_) =>
              windows_html.document
                  .dispatchClick(),
          child:
              child ??
              const SizedBox.shrink(),
        );
      },
      home: WindowsLocalSecurity.configured
          ? const WindowsLocalDashboardGate()
          : const WindowsFirstRunSecuritySetup(),
    );
  }
}

class WindowsLocalDashboardGate
    extends StatelessWidget {
  const WindowsLocalDashboardGate({
    super.key,
  });

  void _primeLocalAdminSession() {
    final storage =
        windows_html.window.localStorage;

    storage['saarthi_portal_role_v1'] =
        'admin';

    storage.remove(
      'saarthi_portal_student_id_v1',
    );

    storage.remove(
      'saarthi_portal_student_class_v1',
    );

    storage['saarthi_portal_expiry_v1'] =
        DateTime.now()
            .add(
              const Duration(days: 3650),
            )
            .millisecondsSinceEpoch
            .toString();
  }

  @override
  Widget build(BuildContext context) {
    _primeLocalAdminSession();

    return const AdminDashboardScreen();
  }
}

class WindowsFirstRunSecuritySetup
    extends StatefulWidget {
  const WindowsFirstRunSecuritySetup({
    super.key,
  });

  @override
  State<WindowsFirstRunSecuritySetup>
      createState() =>
          _WindowsFirstRunSecuritySetupState();
}

class _WindowsFirstRunSecuritySetupState
    extends State<
        WindowsFirstRunSecuritySetup> {
  final _adminId =
      TextEditingController();

  final _password =
      TextEditingController();

  final _confirm =
      TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  Future<void> _save() async {
    if (_busy) return;

    if (_password.text !=
        _confirm.text) {
      setState(() {
        _error =
            'Password match nahi kar raha.';
      });
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

      await FirebaseAuth.instance
          .refreshLocalUser();

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) =>
              const WindowsLocalDashboardGate(),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e
            .toString()
            .replaceFirst(
              'FormatException: ',
              '',
            )
            .replaceFirst(
              'Bad state: ',
              '',
            );
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
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
    return Scaffold(
      backgroundColor:
          const Color(0xFF06171D),
      body: Center(
        child: SingleChildScrollView(
          padding:
              const EdgeInsets.all(24),
          child: Container(
            width: 500,
            padding:
                const EdgeInsets.all(30),
            decoration: BoxDecoration(
              color:
                  const Color(0xFF0A1E26),
              borderRadius:
                  BorderRadius.circular(26),
              border: Border.all(
                color:
                    const Color(0xFF00E8D0)
                        .withOpacity(0.35),
              ),
            ),
            child: Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    gradient:
                        const LinearGradient(
                      colors: [
                        Color(0xFF33E9D0),
                        Color(0xFF00A8FF),
                      ],
                    ),
                    borderRadius:
                        BorderRadius.circular(
                      22,
                    ),
                  ),
                  child: const Icon(
                    Icons
                        .admin_panel_settings_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Vidya Saarthi',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight:
                        FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'CREATE LOCAL SETTINGS LOCK',
                  style: TextStyle(
                    color:
                        Color(0xFF00D9A5),
                    fontSize: 10,
                    fontWeight:
                        FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Ye ID/Password sirf is PC ke protected Settings ke liye hoga. Firebase login nahi hai.',
                  textAlign:
                      TextAlign.center,
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 22),
                TextField(
                  controller: _adminId,
                  decoration:
                      const InputDecoration(
                    labelText:
                        'Local Admin ID',
                    prefixIcon: Icon(
                      Icons.person_outline,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  decoration:
                      InputDecoration(
                    labelText:
                        'Settings Password',
                    prefixIcon: const Icon(
                      Icons.lock_outline,
                    ),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() {
                          _obscure =
                              !_obscure;
                        });
                      },
                      icon: Icon(
                        _obscure
                            ? Icons
                                .visibility_off
                            : Icons
                                .visibility,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirm,
                  obscureText: _obscure,
                  onSubmitted: (_) =>
                      _save(),
                  decoration:
                      const InputDecoration(
                    labelText:
                        'Confirm Password',
                    prefixIcon: Icon(
                      Icons
                          .verified_user_outlined,
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color:
                          Colors.redAccent,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed:
                        _busy ? null : _save,
                    icon: _busy
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child:
                                CircularProgressIndicator(
                              strokeWidth: 2,
                              color:
                                  Colors.white,
                            ),
                          )
                        : const Icon(
                            Icons
                                .arrow_forward_rounded,
                          ),
                    label: Text(
                      _busy
                          ? 'Saving...'
                          : 'Create Lock & Open App',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
