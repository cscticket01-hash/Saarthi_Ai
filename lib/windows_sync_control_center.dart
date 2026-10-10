import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart' as files;

import 'windows_sync_engine.dart';
import 'windows_sync_recovery.dart';
import 'windows_recycle_bin.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_sync_conflict_review.dart';
import 'windows_local_firestore.dart' show FirebaseFirestore;
import 'windows_local_storage.dart';
import 'windows_backup_integrity.dart';
import 'windows_disaster_rehearsal.dart';

/// Evidence-driven own-school controls. No guessed health, ACKs or conflict repair.
class WindowsSyncControlCenter extends StatefulWidget {
  const WindowsSyncControlCenter({
    super.key,
    this.refreshOnOpen,
    this.healthProbe,
    this.storageProbe,
  });
  final Future<void> Function()? refreshOnOpen;
  final Future<Map<String, dynamic>> Function(String school)? healthProbe;
  final Future<Map<String, dynamic>> Function(String school)? storageProbe;
  static const categories = [
    'students_directory',
    'teachers_directory',
    'school_notices',
    'school_calendar',
    'attendance_records',
    'exam_results',
    'fee_payments',
    'fee_ledger',
    'teacher_salary',
    'school_expenses',
    'documents',
  ];
  @override
  State<WindowsSyncControlCenter> createState() =>
      _WindowsSyncControlCenterState();
}

class _WindowsSyncControlCenterState extends State<WindowsSyncControlCenter> {
  final engine = WindowsSyncEngine.instance;
  final db = FirebaseFirestore.instance;
  late final origin = db.activeProfileId;
  bool busy = false;
  String notice = '';
  String localHealth = 'Not checked in this session';
  Map<String, dynamic>? diagnostics;
  String cloudHealth = 'Not checked in this session';
  Map<String, dynamic>? cloudEvidence;
  Map<String, int>? categoryCounts;
  Map<String, dynamic>? storageEvidence;
  int? localBytes;
  bool localBytesPartial = false;
  int? lastBackupAt;

  Future<void> _storageDetails() async {
    final counts = <String, int>{};
    for (final category in WindowsSyncControlCenter.categories) {
      final rows = await db.collection(category).get();
      if (db.activeProfileId != origin) throw StateError('School changed');
      counts[category] = rows.docs
          .where((row) => row.data()['_syncDeleted'] != true)
          .length;
    }
    final root = await WindowsLocalStorage.dataDirectory();
    var bytes = 0, entries = 0, partial = false;
    final budget = Stopwatch()..start();
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      if (++entries > 10000 || budget.elapsed > const Duration(seconds: 5)) {
        partial = true;
        break;
      }
      if (entry is File) bytes += await entry.length();
    }
    final backup = await db
        .collection('_windows_sync_status')
        .doc('backup')
        .get();
    if (db.activeProfileId != origin) throw StateError('School changed');
    if (mounted)
      setState(() {
        categoryCounts = counts;
        localBytes = bytes;
        localBytesPartial = partial;
        lastBackupAt = backup.data()?['createdAt'] as int?;
      });
  }

  Future<void> _cloudStorageDetails() async {
    final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    if (school.isEmpty) throw StateError('School identity required');
    if (mounted) setState(() => storageEvidence = null);
    final result =
        await (widget.storageProbe != null
                ? widget.storageProbe!(school)
                : ManagedSchoolSession.callForSchool(
                    school,
                    'managed/summary',
                    {},
                  ))
            .timeout(const Duration(seconds: 95));
    if (db.activeProfileId != origin ||
        result['success'] != true ||
        result['schoolId'] != school ||
        result['driveBytes'] is! int ||
        (result['driveBytes'] as int) < 0 ||
        result['partial'] is! bool ||
        result['measuredAt'] is! int ||
        (result['measuredAt'] as int) <= 0)
      throw StateError('Storage usage unverified');
    if (mounted) setState(() => storageEvidence = result);
  }

  Future<void> _exportDiagnostics() async {
    final report = await engine.safeQueueDiagnostics();
    if (db.activeProfileId != origin) throw StateError('School changed');
    final destination = await files.getSaveLocation(
      suggestedName: 'vidya-sync-diagnostics.json',
      acceptedTypeGroups: const [
        files.XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (destination == null || db.activeProfileId != origin) return;
    await File(destination.path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    if (mounted)
      setState(() {
        diagnostics = report;
        notice = 'Sanitized diagnostic report exported.';
      });
  }

  String bytesLabel(int bytes) => bytes >= 1048576
      ? '${(bytes / 1048576).toStringAsFixed(2)} MB'
      : '${(bytes / 1024).toStringAsFixed(2)} KB';

  @override
  void initState() {
    super.initState();
    _run(
      () => (widget.refreshOnOpen ?? engine.refreshDetails)().timeout(
        const Duration(seconds: 30),
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      notice = '';
    });
    try {
      if (db.activeProfileId != origin)
        throw StateError('School changed. Reopen this page.');
      await action();
      if (db.activeProfileId != origin)
        throw StateError('School changed. Reopen this page.');
    } catch (error) {
      final decision = windowsSyncRecovery(error);
      if (mounted)
        setState(
          () => notice = error is TimeoutException
              ? 'Action timed out. Completion is unverified; local data is retained.'
              : decision.message,
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _checkCloudHealth() async {
    if (mounted)
      setState(() {
        cloudEvidence = null;
        cloudHealth = 'Checking authenticated school storage';
      });
    try {
      final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
      if (school.isEmpty || db.activeProfileId != origin)
        throw StateError('School identity required');
      final result =
          await (widget.healthProbe != null
                  ? widget.healthProbe!(school)
                  : ManagedSchoolSession.callForSchool(
                      school,
                      'managed/storage/check',
                      {},
                    ))
              .timeout(const Duration(seconds: 95));
      if (db.activeProfileId != origin)
        throw StateError('School changed during health check');
      ManagedSchoolSession.verifyStorageResponse(result, school);
      if (mounted)
        setState(() {
          cloudEvidence = result;
          cloudHealth =
              'Authenticated school storage handshake verified at ${DateTime.now().toLocal()}';
        });
    } catch (error) {
      if (mounted)
        setState(
          () => cloudHealth = error is TimeoutException
              ? 'Health check timed out — cloud readiness unverified'
              : 'Check failed — local data retained; cloud readiness unverified',
        );
      rethrow;
    }
  }

  Future<void> _backup() async {
    final path = await WindowsLocalStorage.createBackup();
    if (db.activeProfileId != origin) return;
    await db.collection('_windows_sync_status').doc('backup').set({
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'cloudVerified': false,
    });
    if (mounted)
      setState(() {
        lastBackupAt = DateTime.now().millisecondsSinceEpoch;
        notice =
            'Local backup created and file hashes verified: $path. Cloud backup and restore have not been verified.';
      });
  }

  Future<void> _cloudRecordBackup() async {
    const testSchool = 'vs-db8afb01a3be46a983c8284714d06e5d';
    final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    if (school != testSchool)
      throw StateError('This backup verification is isolated TEST only');
    final result = await ManagedSchoolSession.callForSchool(
      school,
      'managed/backup',
      {},
    ).timeout(const Duration(seconds: 95));
    if (db.activeProfileId != origin ||
        result['success'] != true ||
        result['schoolId'] != school ||
        result['recordBackupVersion'] != 4 ||
        result['verified'] != true ||
        result['fileId'] is! String)
      throw StateError('Cloud backup remains unverified');
    await db.collection('_windows_sync_status').doc('cloudRecordBackup').set({
      'verifiedAt': DateTime.now().millisecondsSinceEpoch,
      'recordBackupVersion': 4,
      'documentBinariesIncluded': false,
    });
    if (mounted)
      setState(
        () => notice = 'TEST cloud record backup and tombstones verified by Drive readback. Document binaries and full disaster restore are not included.',
      );
  }

  Future<void> _restoreRehearsal() async {
    final backup = await files.getDirectoryPath(
      confirmButtonText: 'Select Backup',
    );
    if (backup == null || !mounted) return;
    final parent = await files.getDirectoryPath(
      confirmButtonText: 'Select Rehearsal Folder',
    );
    if (parent == null || !mounted || db.activeProfileId != origin) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify backup restore?'),
        content: const Text(
          'Copy the backup into a new rehearsal folder and verify every file hash. Pending operations and original files remain unchanged. This does not activate restored data, send cloud records, or replace the current school database.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Verify restore copy'),
          ),
        ],
      ),
    );
    if (approved != true || db.activeProfileId != origin) return;
    final target = Directory(
      '$parent${Platform.pathSeparator}restore_rehearsal_${DateTime.now().microsecondsSinceEpoch}',
    );
    final count = await WindowsBackupIntegrity.stageRestore(
      Directory(backup),
      target,
    );
    if (mounted && db.activeProfileId == origin)
      setState(
        () => notice =
            'Restore rehearsal verified: $count files at ${target.path}. Current school storage remains active. Cloud disaster restore has not been verified.',
      );
  }

  String stamp(dynamic value) => value is num && value > 0
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt()).toLocal().toString()
      : 'Not yet verified';

  Widget metric(String name, String value) => SizedBox(
    width: 270,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: const TextStyle(color: Colors.white60)),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontSize: 18)),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sync & Backup Control Center')),
    body: AnimatedBuilder(
      animation: Listenable.merge([engine.state, engine.details]),
      builder: (context, _) {
        final details = engine.details.value;
        final ownSchool = db.activeProfileId == origin;
        final items = ownSchool
            ? (details['items'] as List? ?? [])
            : <dynamic>[];
        final active = busy || engine.isSyncing;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Smart Sync 3.0 — development preview',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Safe repair retries recoverable requests with the same operation identities. Conflicts require administrator review.',
            ),
            if (!ownSchool)
              const Text(
                'School changed. Close and reopen this page.',
                style: TextStyle(color: Colors.orange),
              ),
            if (ownSchool) ...[
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  metric(
                    'Pending uploads',
                    '${details['pending'] ?? 'Not measured'}',
                  ),
                  metric(
                    'Needs administrator attention',
                    '${details['needsAttention'] ?? 'Not measured'}',
                  ),
                  metric(
                    'Retained verified cloud receipts',
                    '${details['verifiedReceiptCount'] ?? 'Not measured'}',
                  ),
                  metric(
                    'Last verified cloud ACK',
                    stamp(details['lastCloudAckMillis']),
                  ),
                  metric(
                    'Last complete reconciliation',
                    engine.lastVerifiedCheckpoint?.toLocal().toString() ??
                        'Not yet verified',
                  ),
                  metric(
                    'Internet connectivity',
                    cloudEvidence == null ? 'Not independently verified' : 'Authenticated school API network path verified in this session',
                  ),
                  metric('Local database health', localHealth),
                  metric('School cloud health', cloudHealth),
                  metric(
                    'Current sync activity',
                    engine.isSyncing
                        ? 'Syncing'
                        : busy
                        ? 'Checking'
                        : 'Idle',
                  ),
                  metric(
                    'Pending downloads',
                    'Requires a verified reconciliation',
                  ),
                  metric(
                    'Conflict count',
                    details['items'] is! List
                        ? 'Not measured'
                        : '${items.where((item) => item['syncState'] == 'conflict').length}',
                  ),
                  metric(
                    'Failed / needs review',
                    details['items'] is! List
                        ? 'Not measured'
                        : '${items.where((item) => {'failed', 'needsAttention'}.contains(item['syncState'])).length}',
                  ),
                  metric(
                    'Documents pending',
                    details['items'] is! List
                        ? 'Not measured'
                        : '${items.where((item) => item['_queueCollection'] == '_windows_document_outbox' || item['collection'] == 'documents').length}',
                  ),
                  metric(
                    'Local application storage',
                    localBytes == null
                        ? 'Not measured'
                        : '${localBytesPartial ? 'At least ' : ''}${bytesLabel(localBytes!)} — all local profiles and backups',
                  ),
                  metric(
                    'School Drive storage',
                    storageEvidence == null
                        ? 'Not measured'
                        : '${storageEvidence!['partial'] == true ? 'At least ' : ''}${bytesLabel(storageEvidence!['driveBytes'] as int)} — measured ${stamp(storageEvidence!['measuredAt'])}',
                  ),
                  metric('Last local backup', stamp(lastBackupAt)),
                  metric(
                    'Next hourly reconciliation',
                    !engine.automaticSyncEnabled
                        ? 'Automatic sync paused'
                        : engine.lastVerifiedCheckpoint == null
                        ? 'Due at next permitted sync'
                        : engine.lastVerifiedCheckpoint!
                              .add(const Duration(hours: 1))
                              .toLocal()
                              .toString(),
                  ),
                  if (cloudEvidence != null) ...[
                    metric(
                      'Firebase school authorization',
                      'Authenticated school request accepted',
                    ),
                    metric(
                      'Render API availability',
                      'Authenticated response verified in this session',
                    ),
                    metric(
                      'School Apps Script',
                      'Signed storage response verified in this session',
                    ),
                    metric(
                      'Drive school root',
                      cloudEvidence!['driveRootVerified'] == true
                          ? 'Verified by current owner response'
                          : 'Not independently verified',
                    ),
                    metric(
                      'Google Sheets access',
                      cloudEvidence!['sheetsAccessVerified'] == true
                          ? 'Existing tab read verified'
                          : 'Not independently verified',
                    ),
                    metric(
                      'Cloud record backup',
                      cloudEvidence!['recordBackupVersion'] == 4 &&
                              cloudEvidence!['lastVerifiedRecordBackupAt']
                                  is num &&
                              (cloudEvidence!['lastVerifiedRecordBackupAt']
                                      as num) >
                                  0
                          ? 'Verified at ${DateTime.fromMillisecondsSinceEpoch((cloudEvidence!['lastVerifiedRecordBackupAt'] as num).toInt()).toLocal()} — records and tombstones only'
                          : 'No verified current-generation record backup',
                    ),
                  ],
                  metric(
                    'Next recovery retry',
                    engine.nextRetryAt?.toLocal().toString() ??
                        'No retry scheduled',
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (engine.recoveryDecision != null)
                Text(
                  engine.recoveryDecision!.message,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              if (notice.isNotEmpty) SelectableText(notice),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: active ? null : () => _run(engine.requestSync),
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync Now'),
                  ),
                  OutlinedButton.icon(
                    onPressed: active ? null : () => _run(engine.requestSync),
                    icon: const Icon(Icons.build_outlined),
                    label: const Text('Smart Repair — safe retry'),
                  ),
                  OutlinedButton(
                    onPressed: active ? null : () => _run(_checkCloudHealth),
                    child: const Text('Check Cloud Health'),
                  ),
                  OutlinedButton(
                    onPressed: active ? null : () => _run(_storageDetails),
                    child: const Text('Local Storage Details'),
                  ),
                  OutlinedButton(
                    onPressed: active ? null : () => _run(_cloudStorageDetails),
                    child: const Text('School Drive Usage'),
                  ),
                  OutlinedButton(
                    onPressed: active ? null : () => _run(_exportDiagnostics),
                    child: const Text('Export Sanitized Report'),
                  ),
                  OutlinedButton(
                    onPressed: active ? null : () => _run(_backup),
                    child: const Text('Backup Now'),
                  ),
                  OutlinedButton(
                    onPressed: active ? null : () => _run(_restoreRehearsal),
                    child: const Text('Verify Backup Restore'),
                  ),
                  if (db.activeProfileIdentity['schoolSyncId'] ==
                      'vs-db8afb01a3be46a983c8284714d06e5d')
                    OutlinedButton(
                      onPressed: active ? null : () => _run(_cloudRecordBackup),
                      child: const Text('TEST Cloud Record Backup'),
                    ),
                  if (db.activeProfileIdentity['schoolSyncId'] ==
                      'vs-db8afb01a3be46a983c8284714d06e5d')
                    OutlinedButton(
                      onPressed: active
                          ? null
                          : () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    const WindowsDisasterRehearsal(),
                              ),
                            ),
                      child: const Text('TEST Disaster Recovery'),
                    ),
                  OutlinedButton(
                    onPressed: active
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const WindowsRecycleBin(),
                            ),
                          ),
                    child: const Text('Recycle Bin'),
                  ),
                  OutlinedButton(
                    onPressed: active
                        ? null
                        : () => _run(() async {
                            final ok = await WindowsLocalStorage.healthCheck();
                            if (mounted)
                              setState(
                                () => localHealth = ok
                                    ? 'Integrity/read-write check passed'
                                    : 'Check failed — retained for diagnosis',
                              );
                          }),
                    child: const Text('Local Data Health'),
                  ),
                  OutlinedButton(
                    onPressed: active
                        ? null
                        : () => _run(() async {
                            final report = await engine.safeQueueDiagnostics();
                            if (mounted && db.activeProfileId == origin)
                              setState(() => diagnostics = report);
                          }),
                    child: const Text('Diagnostic Report'),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Automatic sync'),
                subtitle: const Text(
                  'Local edits remain durable when automatic sync is paused.',
                ),
                value: engine.automaticSyncEnabled,
                onChanged: active
                    ? null
                    : (enabled) => _run(() => engine.setAutomaticSync(enabled)),
              ),
              if (active)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Operation in progress. Cloud requests have bounded timeouts; local records stay accessible.',
                  ),
                ),
              const Divider(height: 32),
              if (categoryCounts != null) ...[
                const Text(
                  'Local records by category — current school',
                  style: TextStyle(fontSize: 20),
                ),
                for (final entry in categoryCounts!.entries)
                  ListTile(
                    title: Text(entry.key.replaceAll('_', ' ')),
                    trailing: Text('${entry.value}'),
                  ),
                const Text(
                  'These counts describe local active records. Cloud completeness requires verified reconciliation.',
                ),
                const Divider(height: 32),
              ],
              const Text(
                'Pending Queue & Conflict Review',
                style: TextStyle(fontSize: 20),
              ),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'No pending entries in this local profile. This alone does not prove cloud completeness.',
                  ),
                ),
              for (final raw in items)
                Builder(
                  builder: (context) {
                    final item = Map<String, dynamic>.from(raw as Map);
                    return Card(
                      child: ListTile(
                        title: Text(
                          '${item['collection'] ?? 'documents'} • ${item['documentId'] ?? item['id']}',
                        ),
                        subtitle: Text(
                          'Status: ${item['syncState'] ?? 'pending'} • Attempts: ${item['retryCount'] ?? 0} • ${item['failureCategory'] ?? 'No classified failure'}',
                        ),
                        trailing: item['syncState'] == 'conflict'
                            ? TextButton(
                                onPressed: active
                                    ? null
                                    : () => _run(() async {
                                        await showWindowsConflictReview(
                                          context,
                                          item,
                                        );
                                        await engine.refreshDetails();
                                      }),
                                child: const Text('Review'),
                              )
                            : null,
                      ),
                    );
                  },
                ),
              const Divider(height: 32),
              const Text(
                'Recovery History — this school',
                style: TextStyle(fontSize: 20),
              ),
              if (engine.recoveryHistory.isEmpty)
                const Text('No recovery events recorded for this school.'),
              for (final event in engine.recoveryHistory.reversed)
                ListTile(
                  title: Text('${event['category']} • ${event['outcome']}'),
                  subtitle: Text(
                    '${event['atUtc']} • attempt ${event['attempt']}',
                  ),
                ),
              if (diagnostics != null) ...[
                const Divider(height: 32),
                const Text('Sanitized diagnostic evidence'),
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(diagnostics),
                ),
              ],
            ],
          ],
        );
      },
    ),
  );
}
