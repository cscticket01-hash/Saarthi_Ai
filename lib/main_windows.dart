import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'main_dashboard_screen_windows.dart';
import 'windows_html_shim.dart' as windows_html;

const String _windowsAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.0',
);

void _saveWindowsAdminPortalSession() {
  final storage = windows_html.window.localStorage;
  storage['saarthi_portal_role_v1'] = 'admin';
  storage.remove('saarthi_portal_student_id_v1');
  storage.remove('saarthi_portal_student_class_v1');
  storage['saarthi_portal_expiry_v1'] = DateTime.now()
      .add(const Duration(minutes: 30))
      .millisecondsSinceEpoch
      .toString();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: 'AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A',
      appId: '1:751405981184:web:f1240e05c084bac7b242e5',
      messagingSenderId: '751405981184',
      projectId: 'saarthi-ai-df12b',
      authDomain: 'vidyasaarthi.web.app',
      storageBucket: 'saarthi-ai-df12b.firebasestorage.app',
    ),
  );

  runApp(const VidyaSaarthiWindowsApp());
}

class VidyaSaarthiWindowsApp extends StatelessWidget {
  const VidyaSaarthiWindowsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vidya Saarthi Admin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B141A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F2C34),
          elevation: 1,
        ),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00A884),
          secondary: Color(0xFF00D9A5),
        ),
      ),
      builder: (context, child) {
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => windows_html.document.dispatchClick(),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const WindowsUpdateGate(),
    );
  }
}

class _WindowsUpdateInfo {
  const _WindowsUpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.forceUpdate,
  });

  final String latestVersion;
  final String downloadUrl;
  final String releaseNotes;
  final bool forceUpdate;
}

class WindowsUpdateGate extends StatefulWidget {
  const WindowsUpdateGate({super.key});

  @override
  State<WindowsUpdateGate> createState() => _WindowsUpdateGateState();
}

class _WindowsUpdateGateState extends State<WindowsUpdateGate> {
  bool _checking = true;
  bool _downloading = false;
  double? _progress;
  String? _error;
  _WindowsUpdateInfo? _update;
  bool _continueWithoutUpdate = false;

  @override
  void initState() {
    super.initState();
    _checkForUpdate();
  }

  List<int> _versionParts(String value) {
    return value
        .trim()
        .split('.')
        .map((part) => int.tryParse(RegExp(r'\d+').stringMatch(part) ?? '') ?? 0)
        .toList();
  }

  int _compareVersions(String a, String b) {
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

  Future<void> _checkForUpdate() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('windows_update')
          .get()
          .timeout(const Duration(seconds: 8));

      final data = doc.data();
      if (data == null || data['enabled'] == false) {
        if (mounted) setState(() => _checking = false);
        return;
      }

      final latest = data['latestVersion']?.toString().trim() ?? '';
      final minimum = data['minimumVersion']?.toString().trim() ?? '';
      final downloadUrl = data['downloadUrl']?.toString().trim() ?? '';
      final releaseNotes = data['releaseNotes']?.toString().trim() ?? '';
      final configuredForce = data['forceUpdate'] == true;

      if (latest.isEmpty || downloadUrl.isEmpty) {
        if (mounted) setState(() => _checking = false);
        return;
      }

      if (_compareVersions(latest, _windowsAppVersion) <= 0) {
        if (mounted) setState(() => _checking = false);
        return;
      }

      final belowMinimum = minimum.isNotEmpty &&
          _compareVersions(_windowsAppVersion, minimum) < 0;

      if (!mounted) return;
      setState(() {
        _update = _WindowsUpdateInfo(
          latestVersion: latest,
          downloadUrl: downloadUrl,
          releaseNotes: releaseNotes,
          forceUpdate: configuredForce || belowMinimum,
        );
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Update server unavailable should never block normal admin work.
      setState(() {
        _checking = false;
        _error = 'Update check skipped: $e';
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    final update = _update;
    if (update == null || _downloading) return;

    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
    });

    HttpClient? client;
    IOSink? sink;

    try {
      final uri = Uri.parse(update.downloadUrl);
      client = HttpClient();
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      final response = await request.close();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Download failed: HTTP ${response.statusCode}');
      }

      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'Vidya_Saarthi_Update_${update.latestVersion}.exe',
      );

      sink = file.openWrite();
      final total = response.contentLength;
      var received = 0;

      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (mounted && total > 0) {
          setState(() => _progress = received / total);
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (!await file.exists() || await file.length() == 0) {
        throw const FileSystemException('Downloaded installer empty hai.');
      }

      await Process.start(
        file.path,
        const <String>[
          '/SILENT',
          '/CLOSEAPPLICATIONS',
          '/RESTARTAPPLICATIONS',
        ],
        mode: ProcessStartMode.detached,
      );

      await Future<void>.delayed(const Duration(milliseconds: 700));
      exit(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _progress = null;
        _error = 'Update install error: $e';
      });
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client?.close(force: true);
    }
  }

  Widget _brandLoading() {
    return const Scaffold(
      backgroundColor: Color(0xFF06171D),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories_rounded,
              color: Color(0xFF00E8D0),
              size: 54,
            ),
            SizedBox(height: 14),
            Text(
              'Vidya Saarthi',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 18),
            CircularProgressIndicator(color: Color(0xFF00D9A5)),
            SizedBox(height: 10),
            Text(
              'Checking Windows app...',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) return _brandLoading();

    final update = _update;
    if (update == null || _continueWithoutUpdate) {
      return WindowsAdminLoginScreen(updateWarning: _error);
    }

    return Scaffold(
      backgroundColor: const Color(0xFF07151B),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: 540,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF122129),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: const Color(0xFF00D9A5).withOpacity(0.24),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.system_update_alt_rounded,
                      color: Color(0xFF00D9A5),
                      size: 32,
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Vidya Saarthi Update Available',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Installed: $_windowsAppVersion   •   New: ${update.latestVersion}',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (update.releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0C171D),
                      borderRadius: BorderRadius.circular(12),
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
                if (_downloading) ...[
                  const SizedBox(height: 18),
                  LinearProgressIndicator(
                    value: _progress,
                    minHeight: 8,
                    color: const Color(0xFF00D9A5),
                    backgroundColor: Colors.white10,
                  ),
                  const SizedBox(height: 7),
                  Text(
                    _progress == null
                        ? 'Downloading update...'
                        : 'Downloading ${(100 * _progress!).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!update.forceUpdate)
                      TextButton(
                        onPressed: _downloading
                            ? null
                            : () => setState(() => _continueWithoutUpdate = true),
                        child: const Text('Later'),
                      ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00A884),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _downloading ? null : _downloadAndInstall,
                      icon: const Icon(Icons.download_rounded),
                      label: Text(
                        _downloading ? 'Downloading...' : 'Update Now',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WindowsAdminLoginScreen extends StatefulWidget {
  const WindowsAdminLoginScreen({
    super.key,
    this.updateWarning,
  });

  final String? updateWarning;

  @override
  State<WindowsAdminLoginScreen> createState() =>
      _WindowsAdminLoginScreenState();
}

class _WindowsAdminLoginScreenState extends State<WindowsAdminLoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscure = true;
  bool _loggingIn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAdmin());
  }

  Future<void> _restoreAdmin() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !mounted) return;

    _saveWindowsAdminPortalSession();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AdminDashboardScreen(),
      ),
    );

    if (mounted) setState(() {});
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Admin Email aur Password bharein.'),
        ),
      );
      return;
    }

    setState(() => _loggingIn = true);

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      _saveWindowsAdminPortalSession();

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const AdminDashboardScreen(),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            e.code == 'invalid-credential'
                ? 'Galat Admin Email ya Password.'
                : 'Admin login error: ${e.message ?? e.code}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Admin login error: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF06171D),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.25),
            radius: 1.2,
            colors: [
              Color(0xFF0B3B3A),
              Color(0xFF08262D),
              Color(0xFF06171D),
              Color(0xFF041116),
            ],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              width: 460,
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: const Color(0xFF0A1E26).withOpacity(0.96),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: const Color(0xFF00E8D0).withOpacity(0.45),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.35),
                    blurRadius: 35,
                    offset: const Offset(0, 18),
                  ),
                ],
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
                      size: 40,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Vidya Saarthi',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'WINDOWS ADMIN CONSOLE',
                    style: TextStyle(
                      color: Color(0xFF00D9A5),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.8,
                    ),
                  ),
                  if (widget.updateWarning != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      widget.updateWarning!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white30, fontSize: 9),
                    ),
                  ],
                  const SizedBox(height: 24),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Admin Email',
                      prefixIcon: Icon(Icons.email_outlined),
                      filled: true,
                      fillColor: Color(0xFF10242C),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscure,
                    onSubmitted: (_) => _login(),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      filled: true,
                      fillColor: const Color(0xFF10242C),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00A884),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _loggingIn ? null : _login,
                      icon: _loggingIn
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.login_rounded),
                      label: Text(
                        _loggingIn ? 'Signing in...' : 'Admin Login',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Version $_windowsAppVersion',
                    style: const TextStyle(color: Colors.white24, fontSize: 9),
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
