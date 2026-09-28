import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class WindowsFirebaseConnection {
  static Map<String, dynamic>? current;
  static String? startupError;
  static String get projectId => current?['projectId'] as String? ?? '';
  static File get file {
    final base = Platform.environment['APPDATA'] ?? Platform.environment['LOCALAPPDATA'];
    if (base == null) throw StateError('Windows application data folder unavailable.');
    return File('$base${Platform.pathSeparator}VidyaSaarthi${Platform.pathSeparator}firebase_connection_v1.json');
  }

  static Map<String, dynamic> parse(String input) {
    if (input.length > 20000) throw const FormatException('Connection link too long.');
    final uri = Uri.tryParse(input.trim());
    if (uri == null || uri.scheme != 'vidyasaarthi' || uri.host != 'firebase') {
      throw const FormatException('Use a vidyasaarthi://firebase?config= link, not a Console URL.');
    }
    final encoded = uri.queryParameters['config'];
    if (encoded == null) throw const FormatException('Missing Firebase config.');
    final decoded = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))));
    if (decoded is! Map<String, dynamic>) throw const FormatException('Invalid Firebase config.');
    return validate(decoded);
  }

  static Map<String, dynamic> validate(Map<String, dynamic> data) {
    const fields = ['apiKey', 'appId', 'messagingSenderId', 'projectId', 'authDomain', 'storageBucket'];
    final clean = <String, dynamic>{};
    for (final key in fields) {
      final value = data[key];
      if (value != null && value is! String) throw FormatException('Invalid $key.');
      if (value is String && value.trim().isNotEmpty) clean[key] = value.trim();
    }
    for (final key in fields.take(4)) {
      if (!clean.containsKey(key)) throw FormatException('Missing $key.');
    }
    if (!RegExp(r'^[a-z][a-z0-9-]{4,28}[a-z0-9]$').hasMatch(clean['projectId'] as String)) {
      throw const FormatException('Invalid project ID.');
    }
    if (data.containsKey('private_key') || data.containsKey('password')) {
      throw const FormatException('Never use passwords or service account keys in this link.');
    }
    return clean;
  }

  static FirebaseOptions options(Map<String, dynamic> c) => FirebaseOptions(
    apiKey: c['apiKey'] as String, appId: c['appId'] as String,
    messagingSenderId: c['messagingSenderId'] as String, projectId: c['projectId'] as String,
    authDomain: c['authDomain'] as String?, storageBucket: c['storageBucket'] as String?,
  );

  static Future<void> bootstrap() async {
    try {
      if (!await file.exists()) return;
      final config = validate(Map<String, dynamic>.from(jsonDecode(await file.readAsString())));
      await Firebase.initializeApp(options: options(config));
      // Force fresh server reads; do not show a previous session's Firestore disk cache.
      FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: false);
      await FirebaseAuth.instance.signOut();
      current = config;
    } catch (_) {
      startupError = 'Saved Firebase connection could not start. Enter the school connection again.';
    }
  }

  static Future<void> requireAdmin(User user) async {
    final token = await user.getIdTokenResult(true);
    if (token.claims?['admin'] != true) {
      throw StateError('This account needs the Firebase custom claim admin=true. Ask the school project owner.');
    }
  }

  static Future<UserCredential> signInAdmin({required String email, required String password}) async {
    final auth = FirebaseAuth.instance;
    final result = await auth.signInWithEmailAndPassword(email: email, password: password);
    try {
      await requireAdmin(result.user!);
      return result;
    } catch (_) {
      await auth.signOut();
      rethrow;
    }
  }

  static Future<void> verifyAndSave(String link, String email, String password) async {
    final config = parse(link);
    FirebaseApp? probe;
    FirebaseAuth? auth;
    var createdDefault = false;
    var saved = false;

    try {
      // main() sets current only after a saved default app has loaded.
      // On first run current is null, so setup creates the default app.
      final hasDefault = current != null;

      if (!hasDefault) {
        // First-run Windows setup: use the supplied school config as the
        // default app. This avoids a FlutterFire desktop [core/no-app]
        // failure that can occur when a named app is the first app created.
        await Firebase.initializeApp(options: options(config));
        createdDefault = true;
        auth = FirebaseAuth.instance;
        final db = FirebaseFirestore.instance;
        db.settings = const Settings(persistenceEnabled: false);

        final credential = await auth.signInWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
        await requireAdmin(credential.user!);
        await db
            .collection('school_config')
            .doc('windows_connection_check')
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 20));
      } else {
        // A signed-in school is already running. Probe another project in a
        // named app so the current saved project is left untouched on error.
        probe = await Firebase.initializeApp(
          name: 'school-check-${DateTime.now().microsecondsSinceEpoch}',
          options: options(config),
        );
        auth = FirebaseAuth.instanceFor(app: probe);
        final db = FirebaseFirestore.instanceFor(app: probe);
        db.settings = const Settings(persistenceEnabled: false);

        final credential = await auth.signInWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
        await requireAdmin(credential.user!);
        await db
            .collection('school_config')
            .doc('windows_connection_check')
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 20));
      }

      final target = file;
      await target.parent.create(recursive: true);
      final temporary = File('${target.path}.pending');
      await temporary.writeAsString(jsonEncode(config), flush: true);
      await temporary.rename(target.path);
      saved = true;
    } finally {
      try {
        await auth?.signOut();
      } catch (_) {}
      try {
        await probe?.delete();
      } catch (_) {}
      if (createdDefault && !saved) {
        try {
          await Firebase.app().delete();
        } catch (_) {}
      }
    }
  }
}

class WindowsFirebaseSetupScreen extends StatefulWidget {
  const WindowsFirebaseSetupScreen({super.key, this.protectCurrent = false});
  final bool protectCurrent;
  @override
  State<WindowsFirebaseSetupScreen> createState() => _WindowsFirebaseSetupScreenState();
}

class _WindowsFirebaseSetupScreenState extends State<WindowsFirebaseSetupScreen> {
  final _link = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _oldPassword = TextEditingController();
  bool _busy = false;
  bool _saved = false;
  String? _error;
  late final DateTime _opened = DateTime.now();

  Future<void> _save() async {
    if (_busy || _saved) return;
    setState(() { _busy = true; _error = null; });
    try {
      if (widget.protectCurrent) {
        final remaining = 30 - DateTime.now().difference(_opened).inSeconds;
        if (remaining > 0) throw StateError('Please wait $remaining seconds before changing the connection.');
        final user = FirebaseAuth.instance.currentUser;
        if (user == null || user.email == null) throw StateError('Sign in again before switching.');
        await user.reauthenticateWithCredential(EmailAuthProvider.credential(email: user.email!, password: _oldPassword.text));
        await WindowsFirebaseConnection.requireAdmin(user);
      }
      if (_email.text.trim().isEmpty || _password.text.isEmpty) throw StateError('Enter the new school Admin email and password.');
      await WindowsFirebaseConnection.verifyAndSave(_link.text, _email.text, _password.text);
      _password.clear();
      _oldPassword.clear();
      if (mounted) setState(() => _saved = true);
    } catch (e) {
      if (mounted) setState(() => _error = e is FirebaseAuthException ? 'Login failed: ${e.code}' : e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _link.dispose(); _email.dispose(); _password.dispose(); _oldPassword.dispose(); super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && !_saved,
    child: Scaffold(
      appBar: AppBar(title: const Text('School / Firebase Connection'), automaticallyImplyLeading: !_busy && !_saved),
      body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: SizedBox(width: 560,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Current school project: ${WindowsFirebaseConnection.projectId.isEmpty ? "Not connected" : WindowsFirebaseConnection.projectId}'),
          const SizedBox(height: 16),
          if (_saved) ...[
            const Text('Connection verified and saved. Close this app, then open it again and log in with the school Admin account.'),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => exit(0), child: const Text('Close app — reopen to apply')),
          ] else ...[
            const Text('Paste the school Firebase configuration link. Passwords are used for verification only and are not saved in the connection file.'),
            const SizedBox(height: 16),
            if (widget.protectCurrent) ...[
              const Text('Changing a signed-in school requires a 30-second wait and its current Admin password.'),
              TextField(controller: _oldPassword, obscureText: true, enabled: !_busy, decoration: const InputDecoration(labelText: 'Current Admin password')),
            ],
            TextField(controller: _link, enabled: !_busy, maxLines: 3, decoration: const InputDecoration(labelText: 'vidyasaarthi://firebase?config=...')),
            TextField(controller: _email, enabled: !_busy, decoration: const InputDecoration(labelText: 'New school Admin email')),
            TextField(controller: _password, enabled: !_busy, obscureText: true, decoration: const InputDecoration(labelText: 'New school Admin password')),
            const SizedBox(height: 16),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            if (WindowsFirebaseConnection.startupError != null) Text(WindowsFirebaseConnection.startupError!),
            FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Verifying connection...' : 'Verify and save school connection')),
          ],
        ]),
      ))),
    ),
  );
}
