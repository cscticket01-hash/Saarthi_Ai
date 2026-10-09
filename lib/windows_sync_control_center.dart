import 'dart:convert';
import 'package:flutter/material.dart';
import 'windows_sync_engine.dart';
import 'windows_sync_conflict_review.dart';
import 'windows_local_firestore.dart' show FirebaseFirestore;
import 'windows_local_storage.dart';

/// Evidence-driven own-school controls. No guessed health, ACKs or conflict repair.
class WindowsSyncControlCenter extends StatefulWidget {
  const WindowsSyncControlCenter({super.key, this.refreshOnOpen});
  final Future<void> Function()? refreshOnOpen;
  @override
  State<WindowsSyncControlCenter> createState() => _WindowsSyncControlCenterState();
}

class _WindowsSyncControlCenterState extends State<WindowsSyncControlCenter> {
  final engine = WindowsSyncEngine.instance;
  final db = FirebaseFirestore.instance;
  late final origin = db.activeProfileId;
  bool busy = false;
  String notice = '';
  String localHealth = 'Not checked in this session';
  Map<String, dynamic>? diagnostics;

  @override
  void initState() {
    super.initState();
    _run(() => (widget.refreshOnOpen ?? engine.refreshDetails)().timeout(const Duration(seconds: 30)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() { busy = true; notice = ''; });
    try {
      if (db.activeProfileId != origin) throw StateError('School changed. Reopen this page.');
      await action();
      if (db.activeProfileId != origin) throw StateError('School changed. Reopen this page.');
    } catch (_) {
      if (mounted) setState(() => notice = 'Action could not complete. Data is retained; check the current school and diagnostics.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _backup() async {
    final path = await WindowsLocalStorage.createBackup();
    if (db.activeProfileId != origin) return;
    await db.collection('_windows_sync_status').doc('backup').set({
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'cloudVerified': false,
    });
    if (mounted) setState(() => notice = 'Local backup created: $path. Cloud backup and restore have not been verified.');
  }

  String stamp(dynamic value) => value is num && value > 0
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt()).toLocal().toString()
      : 'Not yet verified';

  Widget metric(String name, String value) => SizedBox(width: 270,
    child: Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(color: Colors.white60)),
        const SizedBox(height: 8), Text(value, style: const TextStyle(fontSize: 18)),
      ]))));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sync & Backup Control Center')),
    body: AnimatedBuilder(animation: Listenable.merge([engine.state, engine.details]), builder: (context, _) {
      final details = engine.details.value;
      final ownSchool = db.activeProfileId == origin;
      final items = ownSchool ? (details['items'] as List? ?? []) : <dynamic>[];
      final active = busy || engine.isSyncing;
      return ListView(padding: const EdgeInsets.all(24), children: [
        const Text('Smart Sync 3.0 — development preview', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Safe repair retries recoverable requests with the same operation identities. Conflicts require administrator review.'),
        if (!ownSchool) const Text('School changed. Close and reopen this page.', style: TextStyle(color: Colors.orange)),
        if (ownSchool) ...[
          const SizedBox(height: 20),
          Wrap(spacing: 12, runSpacing: 12, children: [
            metric('Pending uploads', '${details['pending'] ?? 'Not measured'}'),
            metric('Needs administrator attention', '${details['needsAttention'] ?? 'Not measured'}'),
            metric('Retained verified cloud receipts', '${details['verifiedReceiptCount'] ?? 'Not measured'}'),
            metric('Last verified cloud ACK', stamp(details['lastCloudAckMillis'])),
            metric('Last complete reconciliation', engine.lastVerifiedCheckpoint?.toLocal().toString() ?? 'Not yet verified'),
            metric('Internet connectivity', 'Not independently verified'),
            metric('Local database health', localHealth),
            metric('Next recovery retry', engine.nextRetryAt?.toLocal().toString() ?? 'No retry scheduled'),
          ]),
          const SizedBox(height: 20),
          if (engine.recoveryDecision != null) Text(engine.recoveryDecision!.message, style: const TextStyle(color: Colors.orangeAccent)),
          if (notice.isNotEmpty) SelectableText(notice),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            FilledButton.icon(onPressed: active ? null : () => _run(engine.requestSync), icon: const Icon(Icons.sync), label: const Text('Sync Now')),
            OutlinedButton.icon(onPressed: active ? null : () => _run(engine.requestSync), icon: const Icon(Icons.build_outlined), label: const Text('Smart Repair — safe retry')),
            OutlinedButton(onPressed: active ? null : () => _run(_backup), child: const Text('Backup Now')),
            OutlinedButton(onPressed: active ? null : () => _run(() async {
              final ok = await WindowsLocalStorage.healthCheck();
              if (mounted) setState(() => localHealth = ok ? 'Integrity/read-write check passed' : 'Check failed — retained for diagnosis');
            }), child: const Text('Local Data Health')),
            OutlinedButton(onPressed: active ? null : () => _run(() async {
              final report = await engine.safeQueueDiagnostics();
              if (mounted && db.activeProfileId == origin) setState(() => diagnostics = report);
            }), child: const Text('Diagnostic Report')),
          ]),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Automatic sync'),
            subtitle: const Text('Local edits remain durable when automatic sync is paused.'),
            value: engine.automaticSyncEnabled, onChanged: active ? null : (enabled) => _run(() => engine.setAutomaticSync(enabled))),
          if (active) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Operation in progress. Cloud requests have bounded timeouts; local records stay accessible.')),
          const Divider(height: 32),
          const Text('Pending Queue & Conflict Review', style: TextStyle(fontSize: 20)),
          if (items.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No pending entries in this local profile. This alone does not prove cloud completeness.')),
          for (final raw in items) Builder(builder: (context) {
            final item = Map<String, dynamic>.from(raw as Map);
            return Card(child: ListTile(
              title: Text('${item['collection'] ?? 'documents'} • ${item['documentId'] ?? item['id']}'),
              subtitle: Text('Status: ${item['syncState'] ?? 'pending'} • Attempts: ${item['retryCount'] ?? 0} • ${item['failureCategory'] ?? 'No classified failure'}'),
              trailing: item['syncState'] == 'conflict' ? TextButton(onPressed: active ? null : () => _run(() async {
                await showWindowsConflictReview(context, item);
                await engine.refreshDetails();
              }), child: const Text('Review')) : null,
            ));
          }),
          const Divider(height: 32),
          const Text('Recovery History — this school', style: TextStyle(fontSize: 20)),
          if (engine.recoveryHistory.isEmpty) const Text('No recovery events recorded for this school.'),
          for (final event in engine.recoveryHistory.reversed) ListTile(
            title: Text('${event['category']} • ${event['outcome']}'),
            subtitle: Text('${event['atUtc']} • attempt ${event['attempt']}')),
          if (diagnostics != null) ...[
            const Divider(height: 32), const Text('Sanitized diagnostic evidence'),
            SelectableText(const JsonEncoder.withIndent('  ').convert(diagnostics)),
          ],
        ],
      ]);
    }),
  );
}
