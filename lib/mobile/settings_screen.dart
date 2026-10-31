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
  bool busy = false, installing = false;
  String? error;
  Map<String, dynamic>? latest;
  Future<void> check() async {
    if (busy) return;
    setState(() { busy = true; installing = false; error = null; });
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

  Future<void> install() async {
    if (busy || latest == null) return;
    androidUpdateTransfer.value = null;
    setState(() { busy = true; installing = true; error = null; });
    try {
      await widget.installUpdate(latest!);
    } catch (_) {
      if (mounted) setState(() => error = 'Update could not be installed. Try again.');
    } finally {
      if (mounted) setState(() { busy = false; installing = false; });
    }
  }

  Widget _panel(Widget child) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
  @override
  Widget build(BuildContext context) {
    final available = latest != null &&
      (latest!['versionCode'] as int) > widget.buildNumber;
    return Scaffold(
      appBar: AppBar(title: const Text('App Update')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(available ? Icons.system_update_alt : Icons.verified_outlined,
              size: 34, color: Colors.tealAccent),
            const SizedBox(width: 14),
            Expanded(child: Text(
              available ? 'New version available' :
              latest == null ? 'Check your app version' : 'You’re up to date.',
              style: const TextStyle(fontWeight: FontWeight.w700,fontSize: 19))),
          ]),
          const SizedBox(height: 16),
          Text('Current version: ${widget.version} (build ${widget.buildNumber})'),
          const SizedBox(height: 8),
          Text('Latest version: ${latest?['versionName'] ?? 'Not checked'}'),
          const SizedBox(height: 8),
          Text(latest == null ? 'No update check yet' :
            available ? 'A newer signed APK can be downloaded.' : 'You’re up to date.',
            style: const TextStyle(color: Colors.white70)),
        ])),
        if (busy && !installing) _panel(const Column(
          children: [LinearProgressIndicator(), SizedBox(height: 12),
            Text('Checking for updates…')],
        )),
        if (installing) _panel(ValueListenableBuilder<AndroidUpdateTransfer?>(
          valueListenable: androidUpdateTransfer,
          builder: (context, progress, _) {
            final fraction = progress?.fraction;
            final downloading = progress != null && !progress.verified;
            final label = progress == null ? 'Preparing secure download…' :
              progress.verified ? 'Download verified. Open installer to update.' :
              fraction == null ? 'Downloading APK…' :
              'Downloading ${(fraction * 100).floor()}%';
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: downloading ? fraction : (progress?.verified == true ? 1 : null)),
              const SizedBox(height: 8),
              if (progress != null) Text(
                fraction == null ?
                  '${(progress.received / 1048576).toStringAsFixed(1)} MB received' :
                  '${(progress.received / 1048576).toStringAsFixed(1)} / ${(progress.total! / 1048576).toStringAsFixed(1)} MB',
                style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
              const Text('Installation is completed by Android after file verification.',
                style: TextStyle(fontSize: 12, color: Colors.white60)),
            ]);
          },
        )),
        if (error != null) _panel(Text(error!,
          style: const TextStyle(color: Colors.orangeAccent))),
        FilledButton.icon(
          onPressed: busy ? null : check,
          icon: const Icon(Icons.refresh),
          label: const Text('Check for Updates'),
        ),
        if (available) Padding(
          padding: const EdgeInsets.only(top: 12),
          child: FilledButton.icon(
            onPressed: busy ? null : install,
            icon: const Icon(Icons.download_rounded),
            label: const Text('Download update'),
          ),
        ),
        const SizedBox(height: 18),
        const Text('How updating works',
          style: TextStyle(fontWeight: FontWeight.bold,fontSize: 17)),
        const SizedBox(height: 9),
        const Text('1. Check the latest signed release.\n'
          '2. Download and verify the APK.\n'
          '3. Android opens the installer. Confirm the update.\n'
          'Your saved school records and offline attendance are not erased.'),
      ]),
    );
  }
}
