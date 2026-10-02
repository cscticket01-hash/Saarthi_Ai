import 'dart:convert';
import 'package:flutter/material.dart';
import 'school_backend_probe.dart';
import '../windows_connection_center.dart';
import '../windows_firebase_sync.dart';
import '../windows_local_settings.dart';
import '../windows_sync_engine.dart';
import 'google_authorization.dart';
import 'school_provisioner.dart';

class EasySchoolConnectScreen extends StatefulWidget {
  const EasySchoolConnectScreen({super.key, this.googleDrive = false});
  final bool googleDrive;
  @override
  State<EasySchoolConnectScreen> createState() => _EasySchoolConnectScreenState();
}
class _EasySchoolConnectScreenState extends State<EasySchoolConnectScreen> {
  final _name = TextEditingController();
  final _checkpoint = SecureSetupCheckpoint();
  final _auth = GoogleAuthorization();
  GoogleSetupApi? _api;
  SchoolProvisioner? _setup;
  bool _busy = false, _newSchool = false, _done = false, _scriptApproval = false;
  String _location = 'asia-south1', _message = '', _email = '';
  SetupActionRequired? _action;

  @override
  void dispose() {
    _api?.close(); _auth.close(); _name.dispose(); super.dispose();
  }
  void _progress(String message) {
    if (mounted) setState(() => _message = message);
  }
  Future<void> _start() async {
    if (_busy) return;
    setState(() { _busy = true; _action = null; _done = false; _scriptApproval = false; });
    try {
      final saved = await _checkpoint.read();
      final links = await WindowsExternalConnections.load();
      if (saved.isEmpty) {
        if (!_newSchool || _name.text.trim().length < 2) {
          throw StateError('Enter the school name and confirm that this is a new school cloud setup.');
        }
        if ((links['firebaseLink']?.toString() ?? '').isNotEmpty ||
            (links['googleScriptUrl']?.toString() ?? '').isNotEmpty) {
          throw StateError('This app already has school connections. Use the existing settings to manage them. Automatic setup will not replace existing school data or links.');
        }
      } else {
        final savedLink = links['firebaseLink']?.toString() ?? '';
        if (savedLink.isNotEmpty && WindowsExternalConnections.decodeFirebaseLink(savedLink)['projectId'] != saved['projectId']) {
          throw StateError('A different school is connected. This setup cannot replace it.');
        }
        final savedScript = links['googleScriptUrl']?.toString() ?? '';
        if (savedScript.isNotEmpty && savedScript != saved['scriptUrl']) {
          throw StateError('A different school Google backend is connected. Automatic replacement is blocked.');
        }
      }
      _progress('Sign in to the school’s Google account in your browser');
      final account = await _auth.authorize(script: widget.googleDrive);
      if (!mounted) return;
      if (!account.email.toLowerCase().endsWith('@gmail.com')) {
        throw StateError('This preview supports school Gmail accounts. Workspace/domain accounts still require the existing connection setup.');
      }
      setState(() => _email = account.email);
      _api?.close();
      final api = GoogleSetupApi(account.accessToken); _api = api;
      final setup = SchoolProvisioner(api: api, account: account, checkpoint: _checkpoint,
        progress: _progress, bundle: await loadSetupBundle());
      _setup = setup;
      await setup.begin(schoolName: _name.text, location: _location);
      await _connect(setup);
    } catch (e) { _handle(e); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _connect(SchoolProvisioner setup) async {
    final config = await setup.firebase();
    final status = await WindowsFirebaseRemote.status();
    if (!status.authenticated || status.projectId != setup.project) {
      _progress('Verifying your school administrator and database access');
      final password = await setup.adminPassword();
      final link = Uri(scheme: 'vidyasaarthi', host: 'firebase', queryParameters: {
        'config': base64Url.encode(utf8.encode(jsonEncode(config))).replaceAll('=', ''),
      }).toString();
      await WindowsFirebaseRemote.connectAndVerify(firebaseLink: link,
        email: setup.account.email, password: password);
    } else {
      await WindowsFirebaseRemote.testSavedConnection();
    }
    await setup.firebaseConnected();
    await WindowsConnectionCenter.reload();
    if (!widget.googleDrive) {
      if (mounted) setState(() { _done = true; _message = 'Firebase connected and verified. Next, connect Google Drive using this same school account.'; });
      return;
    }
    final editor = await setup.prepareScript();
    if (setup.data['scriptAuthorized'] != true) {
      _scriptApproval = true;
      throw SetupActionRequired('Your school script is ready. Open Google, select VS_easyConnectSetup and click Run, then allow the requested permissions. Return here and press Continue. You do not need to copy any code or link.', editor);
    }
    await _finishScript(setup);
  }

  Future<void> _finishScript(SchoolProvisioner setup) async {
    final url = await setup.deployScript();
    _progress('Verifying that Google Drive and Firebase belong to the same school');
    // No OAuth token or local fallback is used to inspect this unsaved backend.
    try {
      await verifySchoolBackend(Uri.parse(url), setup.project);
    } catch (_) {
      throw SetupActionRequired('Google authorization/storage is incomplete or the backend belongs to another school. Run VS_easyConnectSetup successfully before continuing.',
        Uri.parse('https://script.google.com/home/projects/${setup.data['scriptId']}/edit'));
    }
    await WindowsSyncEngine.instance.changeGoogleConnection(email: setup.account.email, scriptUrl: url);
    setup.data['scriptAuthorized'] = true;
    setup.data['complete'] = true;
    await setup.save();
    await WindowsConnectionCenter.reload();
    if (mounted) setState(() { _done = true; _message = 'Google Drive and Firebase are connected to this school. Existing school isolation checks remain active.'; });
  }

  Future<void> _continue() async {
    final setup = _setup;
    if (setup == null) { await _start(); return; }
    if (_busy) return;
    setState(() { _busy = true; _action = null; });
    try {
      if (_scriptApproval) {
        await _finishScript(setup);
      } else {
        await _connect(setup);
      }
    } catch (e) { _handle(e); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  void _handle(Object error) {
    if (!mounted) return;
    setState(() {
      _action = error is SetupActionRequired ? error : null;
      _message = error.toString().replaceFirst('Bad state: ', '');
    });
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.googleDrive ? 'Connect Google Drive' : 'Connect Firebase')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640),
      child: ListView(padding: const EdgeInsets.all(24), shrinkWrap: true, children: [
        Icon(_done ? Icons.verified_user : Icons.cloud_outlined, size: 52,
          color: _done ? Colors.greenAccent : Colors.tealAccent),
        const SizedBox(height: 18),
        const Text('Your school. Your Google account.', style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        const Text('Sign in and allow access in Google’s browser window. Vidya Saarthi creates a separate school project and fills connection links automatically. No Google password is entered in this app.'),
        const SizedBox(height: 16),
        if (!GoogleAuthorization.configured) const Card(child: Padding(padding: EdgeInsets.all(16),
          child: Text('Developer setup is pending for Google Connect in this build. Existing connections remain available.'))),
        TextField(controller: _name, enabled: !_busy, decoration: const InputDecoration(labelText: 'School name')),
        DropdownButtonFormField<String>(value: _location, isExpanded: true,
          decoration: const InputDecoration(labelText: 'School database location'),
          items: const [DropdownMenuItem(value: 'asia-south1', child: Text('India — Mumbai')),
            DropdownMenuItem(value: 'asia-south2', child: Text('India — Delhi'))],
          onChanged: _busy ? null : (v) => setState(() => _location = v!)),
        CheckboxListTile(contentPadding: EdgeInsets.zero, value: _newSchool,
          title: const Text('Create new, empty school cloud storage'),
          subtitle: const Text('Existing school cloud data must be connected through the existing settings. No billing account or paid plan will be enabled.'),
          onChanged: _busy ? null : (v) => setState(() => _newSchool = v ?? false)),
        if (_email.isNotEmpty) Text('School account: $_email'),
        if (_busy) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: LinearProgressIndicator()),
        if (_message.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text(_message)),
        if (_action != null) ...[
          OutlinedButton.icon(onPressed: _busy ? null : () async {
            try { await openGooglePage(_action!.url); } catch (e) { _handle(e); }
          }, icon: const Icon(Icons.open_in_browser), label: const Text('Open Google approval')),
          FilledButton(onPressed: _busy ? null : _continue, child: const Text('Continue after approval')),
        ] else if (!_done) FilledButton.icon(
          onPressed: _busy || !GoogleAuthorization.configured ? null : _start,
          icon: const Icon(Icons.login), label: const Text('Sign in with Google / Resume setup')),
        if (_busy) TextButton(onPressed: () { _auth.cancel(); _api?.close(); }, child: const Text('Cancel')),
        if (_done) FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Done')),
      ]))),
  );
}
