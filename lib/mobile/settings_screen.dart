import 'package:flutter/material.dart';
import '../platform/github_updates.dart';

class VidyaSaarthiBrand extends StatelessWidget {
  const VidyaSaarthiBrand({super.key});
  @override
  Widget build(BuildContext context) => const Row(children: [
    Icon(Icons.school_rounded, size: 26),
    SizedBox(width: 8),
    Flexible(child: Text('Vidya Saarthi', maxLines: 1, overflow: TextOverflow.ellipsis)),
  ]);
}

class MobileSettingsScreen extends StatelessWidget {
  const MobileSettingsScreen({super.key, required this.version, required this.buildNumber,
    required this.checkUpdate, required this.installUpdate});
  final String version;
  final int buildNumber;
  final Future<Map<String, dynamic>> Function() checkUpdate;
  final Future<void> Function(Map<String, dynamic>) installUpdate;
  static const whatsNew = [
    'School-published ID cards with verified local PDF caching.',
    'Changed-data notice synchronization and deletion handling.',
    'Settings with About and App Update.',
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(children: [
      ListTile(leading: const Icon(Icons.info_outline), title: const Text('About'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('About')),
          body: ListView(padding: const EdgeInsets.all(20), children: [
            const VidyaSaarthiBrand(), const SizedBox(height: 20),
            Text('Installed version: $version'), Text('Build: $buildNumber'),
            const SizedBox(height: 20), const Text("What's New"),
            ...whatsNew.map((line) => Padding(padding: const EdgeInsets.only(top: 12), child: Text(line))),
          ]),
        )))),
      ListTile(leading: const Icon(Icons.system_update), title: const Text('App Update'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MobileAppUpdateScreen(
          version: version, buildNumber: buildNumber, checkUpdate: checkUpdate, installUpdate: installUpdate)))),
    ]),
  );
}

class MobileAppUpdateScreen extends StatefulWidget {
  const MobileAppUpdateScreen({super.key, required this.version, required this.buildNumber,
    required this.checkUpdate, required this.installUpdate});
  final String version;
  final int buildNumber;
  final Future<Map<String, dynamic>> Function() checkUpdate;
  final Future<void> Function(Map<String, dynamic>) installUpdate;
  @override
  State<MobileAppUpdateScreen> createState() => _MobileAppUpdateScreenState();
}
class _MobileAppUpdateScreenState extends State<MobileAppUpdateScreen> {
  bool busy = false;
  String? error;
  Map<String, dynamic>? latest;
  Future<void> check() async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      final result = await widget.checkUpdate();
      if (result['update'] is! Map) throw StateError('No update is published yet.');
      final update = Map<String, dynamic>.from(result['update'] as Map);
      validateAndroidUpdate(update);
      if (mounted) setState(() => latest = update);
    } catch (_) {
      if (mounted) setState(() => error = 'Unable to check updates. Please try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('App Update')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      Text('Current version: ${widget.version} (build ${widget.buildNumber})'),
      Text('Latest version: ${latest?['versionName'] ?? 'Not checked'}'),
      if (latest != null) Text((latest!['versionCode'] as int) > widget.buildNumber
          ? 'Update available' : 'You’re up to date.'),
      if (error != null) Text(error!),
      if (busy) const LinearProgressIndicator(),
      FilledButton(onPressed: busy ? null : check, child: const Text('Check for Updates')),
      if (latest != null && (latest!['versionCode'] as int) > widget.buildNumber)
        FilledButton(onPressed: busy ? null : () async {
          setState(() => busy = true);
          try { await widget.installUpdate(latest!); }
          finally { if (mounted) setState(() => busy = false); }
        }, child: const Text('Download update')),
    ]),
  );
}
