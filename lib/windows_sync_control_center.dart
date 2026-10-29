import 'windows_sync_flow.dart';
import 'windows_sync_evidence.dart';
import 'windows_ui_localization.dart';
import 'windows_repair_memory.dart';
import 'windows_sync_performance.dart';
import 'sync_pending_diagnostics.dart';
import 'cloud_transfer_status.dart';
import 'windows_appearance.dart';
import 'sync_recovery_policy.dart' as failure_policy;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'package:file_selector/file_selector.dart' as files;

import 'windows_sync_engine.dart';
import 'windows_student_sync_audit.dart';
import 'windows_sync_comparison.dart';
import 'windows_sync_recovery.dart';
import 'windows_sync_projection.dart';
import 'windows_recycle_bin.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_sync_conflict_review.dart';
import 'windows_local_firestore.dart' show FirebaseFirestore;
import 'windows_local_storage.dart';
import 'windows_disk_storage.dart';
import 'windows_drive_quota.dart';
import 'windows_backup_integrity.dart';
import 'windows_disaster_rehearsal.dart';
import 'windows_binary_downloads.dart';
import 'windows_clean_install_entry.dart';

/// Evidence-driven own-school controls. No guessed health, ACKs or conflict repair.
class WindowsSyncControlCenter extends StatefulWidget {
  const WindowsSyncControlCenter({
    super.key,
    this.refreshOnOpen,
    this.healthProbe,
    this.storageProbe,
    this.diskProbe,
    this.quotaProbe,
    this.syncRequest,
    this.pauseRequest,
    this.backupRequest,
  });
  final Future<void> Function()? refreshOnOpen;
  final Future<void> Function()? syncRequest;
  final Future<void> Function(Duration)? pauseRequest;
  final Future<void> Function()? backupRequest;
  final Future<Map<String, dynamic>> Function(String school)? healthProbe;
  final Future<Map<String, dynamic>> Function(String school)? storageProbe;
  final Future<Map<String, dynamic>> Function(String path)? diskProbe;
  final Future<Map<String, dynamic>> Function(String school)? quotaProbe;
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
  bool syncCommandRunning = false;
  Timer? pauseDisplayTimer;
  bool showDiagnostics = false;
  bool showQueue = false;
  bool showHistory = false;
  String notice = '';
  String localHealth = 'Not checked in this session';
  Map<String, dynamic>? diagnostics;
  String cloudHealth = 'Not checked in this session';
  Map<String, dynamic>? cloudEvidence;
  Map<String, int>? categoryCounts;
  Map<String, dynamic>? studentAudit;
  Map<String, dynamic>? storageEvidence;
  final diskStorage = WindowsDiskStorage();
  Map<String, dynamic>? diskEvidence;
  String? localDataPath;
  String? localFilesPath;
  Map<String, dynamic>? quotaEvidence;
  int? localBytes;
  bool localBytesPartial = false;
  int? lastBackupAt;
  WindowsBinaryDownloads? binaryDownloads;
  Map<String, dynamic>? binaryEvidence;

  Future<void> _binaryAction(String action) async {
    final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    if (db.activeProfileId != origin || school.isEmpty)
      throw StateError('Current school required');
    binaryDownloads ??= WindowsBinaryDownloads(
      schoolId: school,
      storageDirectory: Directory(
        '${(await WindowsLocalStorage.localFilesDirectory()).path}/Verified_Cloud_Cache',
      ),
      currentSchool: () => db.activeProfileId == origin
          ? db.activeProfileIdentity['schoolSyncId']?.toString() ?? ''
          : '',
      request: (body) => ManagedSchoolSession.callForSchool(
        school,
        body['action'] as String,
        {...body}..remove('action'),
      ),
    );
    final downloads = binaryDownloads!;
    try {
      if (action == 'inventory' || action == 'restart')
        await downloads.refreshInventory(restart: action == 'restart');
      else if (action == 'repair' || action == 'retry') {
        final repaired = await downloads.repairNext(
          administratorRetry: action == 'retry',
        );
        if (!repaired && mounted)
          setState(
            () => notice = 'No verified download completed. Check the retained item state and retry deadline.',
          );
      } else
        await downloads.inspectLocal();
    } finally {
      if (mounted &&
          db.activeProfileId == origin &&
          db.activeProfileIdentity['schoolSyncId'] == school) {
        final summary = downloads.summary;
        await db.collection('_windows_binary_status').doc('current').set({
          ...summary,
          'measuredAt': DateTime.now().millisecondsSinceEpoch,
        });
        if (mounted &&
            db.activeProfileId == origin &&
            db.activeProfileIdentity['schoolSyncId'] == school)
          setState(() => binaryEvidence = summary);
      }
    }
  }

  Future<void> _verifyStudentRecords() async {
    if (mounted) setState(() => studentAudit = null);
    final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    void guard() {
      if (db.activeProfileId != origin ||
          db.activeProfileIdentity['schoolSyncId'] != school)
        throw StateError('School changed. Reopen Sync details.');
    }

    guard();
    final local = {
      for (final row in (await db.collection('students_directory').get()).docs)
        row.id: row.data(),
    };
    final before = syncPayloadHash(local);
    final pending = {
      for (final row
          in (await db.collection('_windows_firebase_outbox').get()).docs)
        if (row.data()['collection'] == 'students_directory' &&
            row.data()['schoolId'] == school)
          row.data()['documentId'].toString(),
    };
    final reply = await ManagedSchoolSession.callForSchool(
      school,
      'managed/records',
      {
        'operation': 'read',
        'collection': 'students_directory',
        'syncProtocol': 2,
      },
    ).timeout(const Duration(seconds: 60));
    guard();
    if (reply['schoolId'] != school ||
        reply['syncProtocol'] != 2 ||
        reply['records'] is! Map ||
        reply['unchanged'] == true)
      throw StateError('Full authenticated student snapshot required.');
    final after = {
      for (final row in (await db.collection('students_directory').get()).docs)
        row.id: row.data(),
    };
    guard();
    if (syncPayloadHash(after) != before)
      throw StateError('Students changed during verification. Run again.');
    final result = compareStudentSyncSnapshot(
      school: school,
      local: local,
      cloud: Map<String, dynamic>.from(reply['records'] as Map),
      pendingIds: pending,
    );
    if (mounted)
      setState(
        () => studentAudit = {
          ...result,
          'measuredAt': DateTime.now().toIso8601String(),
        },
      );
  }

  Future<void> _storageDetails() async {
    await _measureDisk();
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
    final previous = storageEvidence;
    if (previous != null &&
        previous['schoolId'] == school &&
        DateTime.now().millisecondsSinceEpoch -
                (previous['measuredAt'] as int) >=
            0 &&
        DateTime.now().millisecondsSinceEpoch -
                (previous['measuredAt'] as int) <
            300000)
      return;
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
    final quota = await WindowsDriveQuota.measure(
      authorizedRead: () async {
        final response = widget.quotaProbe != null
            ? await widget.quotaProbe!(school)
            : await ManagedSchoolSession.callForSchool(
                school,
                'managed/storage/quota',
                {},
              );
        if (response['success'] != true ||
            response['schoolId'] != school ||
            response['driveQuotaVersion'] != 1) {
          throw StateError('School quota response unverified');
        }
        return response;
      },
    );
    if (db.activeProfileId != origin ||
        db.activeProfileIdentity['schoolSyncId'] != school) {
      throw StateError('School changed during quota read');
    }
    if (mounted)
      setState(() {
        storageEvidence = result;
        quotaEvidence = quota;
      });
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

  Future<void> _administratorBinaryRetry() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) { WindowsAppearance.watch(context); return  AlertDialog(
        title: const Text('Review file recovery retry'),
        content: const Text(
          'Retry one retained file with a new bounded attempt budget? Original usable files and record operations remain unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Administrator: retry'),
          ),
        ],
      ); },
    );
    if (approved == true && mounted) await _run(() => _binaryAction('retry'));
  }

  Future<void> _exportVerifiedBinary(Map<String, dynamic> row) async {
    final downloads = binaryDownloads;
    if (downloads == null || db.activeProfileId != origin)
      throw StateError('Verified own-school cache required');
    final source = await downloads.verifiedPath(row['fileId'] as String);
    if (source == null)
      throw StateError(
        'Verified file bytes unavailable. Recover the file first.',
      );
    final raw = row['name'] as String? ?? 'verified-school-file';
    final name = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final target = await files.getSaveLocation(suggestedName: name);
    if (target == null || db.activeProfileId != origin) return;
    await files.XFile(source).saveTo(target.path);
    if (mounted && db.activeProfileId == origin)
      setState(
        () => notice = 'Verified copy saved. The retained original and cloud file are unchanged.',
      );
  }

  Future<void> _measureDisk() async {
    Map<String, dynamic> result;
    String? dataPath;
    String? filesPath;
    try {
      final directory = await WindowsLocalStorage.dataDirectory();
      dataPath = directory.absolute.path;
      filesPath =
          (await WindowsLocalStorage.localFilesDirectory()).absolute.path;
      result = await (widget.diskProbe != null
          ? widget.diskProbe!(dataPath)
          : diskStorage.measure(dataPath));
    } catch (_) {
      result = {'status': 'Unknown'};
    }
    if (mounted && db.activeProfileId == origin)
      setState(() {
        diskEvidence = result;
        localDataPath = dataPath;
        localFilesPath = filesPath;
      });
  }

  Future<void> _openLocalFolder() async {
    if (db.activeProfileId != origin) return;
    try {
      await WindowsLocalStorage.openFolder();
    } catch (_) {
      if (mounted && db.activeProfileId == origin) {
        setState(
          () => notice = 'Could not open the local data folder. Copy the path and open it in File Explorer.',
        );
      }
    }
  }

  String get diskLabel => diskEvidence?['status'] == 'Measured'
      ? 'Used: ${bytesLabel(diskEvidence!['usedBytes'] as int)} / Total: ${bytesLabel(diskEvidence!['totalBytes'] as int)}\nFree: ${bytesLabel(diskEvidence!['freeBytes'] as int)} • volume ${diskEvidence!['volume']}\nWhole volume; measured ${stamp(diskEvidence!['measuredAt'])}'
      : 'Unknown — local volume capacity not measured';

  String get quotaLabel => quotaEvidence?['status'] == 'Measured'
      ? 'Google account quota: ${bytesLabel(quotaEvidence!['usageBytes'] as int)} used / ${quotaEvidence!['limitBytes'] == null ? 'no reported limit' : bytesLabel(quotaEvidence!['limitBytes'] as int)}'
      : 'Google account quota: Unknown — ${quotaEvidence?['reason'] ?? 'Owner quota reporting has not been authorized or measured'}';
  String get driveLabel => storageEvidence == null
      ? 'School application files: Unknown\n$quotaLabel'
      : '${storageEvidence!['partial'] == true ? 'Partial — at least ' : ''}${bytesLabel(storageEvidence!['driveBytes'] as int)} in school application files\nVerified measurement: ${stamp(storageEvidence!['measuredAt'])}\n$quotaLabel';

  String bytesLabel(int bytes) => bytes >= 1099511627776
      ? '${(bytes / 1099511627776).toStringAsFixed(2)} TB'
      : bytes >= 1073741824
      ? '${(bytes / 1073741824).toStringAsFixed(2)} GB'
      : bytes >= 1048576
      ? '${(bytes / 1048576).toStringAsFixed(2)} MB'
      : '${(bytes / 1024).toStringAsFixed(2)} KB';

  @override
  void initState() {
    super.initState();
    unawaited(_measureDisk());
    pauseDisplayTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if(mounted && showHistory)unawaited(engine.refreshDetails());
      if (mounted &&
          (showHistory || engine.isPaused || engine.nextRetryAt != null ||
              (engine.details.value['pending'] as num? ?? 0) > 0 ||
              (engine.details.value['activity'] as List? ?? const []).any(
                (row) => row is Map && row['retryAt'] is int,
              )))
        setState(() {});
    });
    _run(
      () => (widget.refreshOnOpen ?? engine.refreshDetails)().timeout(
        const Duration(seconds: 30),
      ),
    );
  }

  @override
  void dispose() {
    pauseDisplayTimer?.cancel();
    super.dispose();
  }

  Future<void> _startManualSync() async {
    if (syncCommandRunning && !engine.isPaused) return;
    if (syncCommandRunning) {
      await _run(widget.syncRequest ?? engine.requestSync);
      return;
    }
    setState(() {
      syncCommandRunning = true;
      notice = '';
    });
    try {
      if (db.activeProfileId != origin)
        throw StateError('School changed. Reopen this page.');
      await (widget.syncRequest ?? engine.requestSync)();
    } catch (error) {
      if (mounted && db.activeProfileId == origin) {
        setState(() => notice = windowsSyncRecovery(error).message);
      }
    } finally {
      if (mounted) setState(() => syncCommandRunning = false);
    }
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
      builder: (context) { WindowsAppearance.watch(context); return  AlertDialog(
        title: const Text('Verify backup restore?'),
        content: const Text(
          'Copy the backup into restore_rehearsal in the selected folder and verify every file hash. An interrupted copy of this same backup can resume. Pending operations and original files remain unchanged. This does not activate restored data, send cloud records, or replace the current school database.',
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
      ); },
    );
    if (approved != true || db.activeProfileId != origin) return;
    final target = Directory(
      '$parent${Platform.pathSeparator}restore_rehearsal',
    );
    final count = await WindowsBackupIntegrity.resumeRestore(
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

  static const _cyan = Color(0xFF19DCE5);
  static const _panel = Color(0xFF10273E);
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _overviewKey = GlobalKey();
  final _queueKey = GlobalKey();
  final _backupKey = GlobalKey();
  final _activityKey = GlobalKey();
  final _settingsKey = GlobalKey();
  final _statusKey = GlobalKey();

  Widget _panelBox(Widget child) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      gradient:  LinearGradient(
        colors: [WindowsAppearance.resolve(Color(0xFF132D46)), WindowsAppearance.resolve(Color(0xFF0C1F34))],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: WindowsAppearance.outline(const Color(0xFF21475D))),
    ),
    child: child,
  );

  Widget metric(String name, String value) => SizedBox(
    width: 248,
    child: Card(
      margin: EdgeInsets.zero,
      color: WindowsAppearance.background(Colors.transparent),
      child: _panelBox(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style:  TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Color(0xFF9AB4C9)), fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(fontFamily: 'Segoe UI', fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ),
  );

  void _jump(GlobalKey key) {
    setState(() {
      showHistory = key == _activityKey;
      showDiagnostics = key != _overviewKey && !showHistory;
      showQueue = key == _queueKey;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = key.currentContext;
      if (target != null)
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 350),
        );
    });
  }

  Widget _nav(IconData icon, String title, VoidCallback? action) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: OutlinedButton.icon(
      onPressed: action,
      icon: Icon(icon, size: 18),
      label: Text(title),
    ),
  );

  Widget _activityRow(Map<String, dynamic> event, bool active) {
    const labels = {
      'localSave': 'Durable local save',
      'cloudRequest': 'Cloud request',
      'waitingForAck': 'Waiting for authoritative ACK',
      'verified': 'Verified sync',
      'retry': 'Retry scheduled',
      'conflict': 'Conflict — administrator review',
      'duplicateReconciled': 'Duplicate reconciled — original cloud record retained',
      'unauthorized': 'Unauthorized — authentication required',
      'needsAttention': 'Administrator attention required',
      'waitingForResponse': 'Waiting for provider response',
      'requestCompleted': 'Request completed — authoritative ACK unverified',
      'repairDiagnosed': 'Repair diagnosis recorded — check outcome',
      'automaticRepair': 'Original operation safely reopened — ACK pending',
      'personCardJob': 'Person and ID-card dependency pass',
      'changeFeedUnavailable': 'Change feed unavailable — fallback retained',
      'networkRecoveryDeferred': 'Network recovery deferred',
      'changeDiscoveryFailed': 'Cloud change check failed',
    };
    final stage = event['stage']?.toString() ?? '';
    final retryAt = event['retryAt'];
    final remaining = retryAt is int
        ? retryAt - DateTime.now().millisecondsSinceEpoch
        : null;
    final eligible =
        stage == 'retry' &&
        event['isRetryable'] == true &&
        event['schoolId'] == db.activeProfileIdentity['schoolSyncId'] &&
        event['operationId'] is String &&
        (event['operationId'] as String).isNotEmpty &&
        event['queueId'] is String &&
        (event['queueId'] as String).isNotEmpty &&
        event['queueCollection'] == '_windows_firebase_outbox';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        stage == 'verified' ? Icons.check_circle_outline : Icons.sync,
        color: stage == 'verified' ? Colors.greenAccent : _cyan,
      ),
      title: Text(labels[stage] ?? 'Unrecognized diagnostic event (no verified result)'),
      subtitle: Text(
        'Observed: ${stamp(event['at'])}'
        '${remaining != null ? '\nRetry: ${remaining > 0 ? '${(remaining / 1000).ceil()} seconds remaining' : 'due when permitted'}' : ''}',
      ),
      trailing: eligible
          ? TextButton(
              onPressed: active || engine.isPaused
                  ? null
                  : () => _run(() async {
                      if (db.activeProfileId != origin)
                        throw StateError('School changed');
                      await engine.retryRecoverableOperation(
                        queueCollection: event['queueCollection'] as String,
                        queueId: event['queueId'] as String,
                        expectedOperationId: event['operationId'] as String,
                        expectedSchoolId: event['schoolId'] as String,
                      );
                    }),
              child: const Text('Smart Repair — Safe Retry'),
            )
          : null,
    );
  }

  Widget _alerts({required bool ownSchool}) {
    final messages = <String>{
      if (!ownSchool) 'School changed. Close and reopen this page.',
      if (ownSchool && notice.isNotEmpty) notice,
      if (ownSchool && engine.recoveryDecision != null)
        engine.recoveryDecision!.message,
      if (ownSchool && engine.lastError != null && engine.recoveryDecision == null)
        windowsSyncRecovery(engine.lastError!).message,
    };
    return CloudflareTransferStatus(
      messages: messages.toList(),
      showTransfers: ownSchool,
      panelBuilder: (messages) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: _panelBox(
        Column(
          key: const ValueKey('sync-errors-alerts'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Sync Errors & Alerts',
              style: TextStyle(fontFamily: 'Segoe UI', fontSize: 16,
                fontWeight: FontWeight.w600)),
            for (final message in messages)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(message,
                  style: TextStyle(fontFamily: 'Segoe UI',
                    color: WindowsAppearance.foreground(Colors.orangeAccent))),
              ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _hero(Map<String, dynamic> details, List<dynamic> items, bool active) {
    final rows = details['liveQueue'] is List
        ? (details['liveQueue'] as List).whereType<Map>().map((r) => Map<String,dynamic>.from(r)).toList()
        : <Map<String,dynamic>>[];
    final lanes = details['lanes'] is Map ? details['lanes'] as Map
        : windowsSyncLanes(rows, DateTime.now().millisecondsSinceEpoch);
    final other = lanes['other'] is Map ? lanes['other'] as Map : const {};
    final hasUploads = (details['pending'] as num? ?? 0) > 0 ||
        (details['incomingPending'] as num? ?? 0) > 0;
    final checkingOnly = engine.isSyncing && !engine.isPaused && !hasUploads;
    final checking = !engine.isPaused && (checkingOnly || engine.isCheckingCloud);
    final syncing = engine.isSyncing && !engine.isPaused && !engine.isCheckingCloud && hasUploads && ManagedSchoolSession.activeTransfers.value>0;
    final phase = engine.isPaused ? 'paused' : checking ? 'checking' :
        engine.isSyncing && !engine.isPaused && !syncing ? 'preparing' :
        details['displayState']?.toString() ??
        (syncing
            ? 'syncing'
            : engine.isPaused
            ? 'paused'
            : (details['needsAttention'] is num &&
                  details['needsAttention'] > 0)
            ? 'needsAttention'
            : (details['pending'] is num && details['pending'] > 0)
            ? 'pending'
            : 'idle');
    final phaseLabels = {
      'checking': 'Checking cloud',
      'preparing': 'Preparing changed data',
      'syncing': engine.isCheckingCloud ? 'Checking cloud' : 'Syncing',
      'needsAttention': 'Needs Attention',
      'offline': 'Offline',
      'waiting': 'Waiting',
      'pending': 'Pending',
      'idle': 'Idle',
      'paused': 'Paused',
    };
    final phaseLabel = busy ? 'Checking' : (phaseLabels[phase] ?? 'Unknown');
    final phaseColor = phase == 'needsAttention'
        ? const Color(0xFFFFC153)
        : _cyan;
    final ack = details['lastCloudAckMillis'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            InkWell(
              onTap: () => _jump(_queueKey),
              child: metric(
                'Pending Uploads',
                "${details['pending'] ?? 'Unknown'} Pending · ${details['needsAttention'] ?? 'Unknown'} Need Attention\n${details['conflictCount'] ?? (details['items'] is List ? items.where((row) => row is Map && (row['syncState'] ?? row['state']) == 'conflict').length : 'Unknown')} Conflicts · ${details['items'] is List ? items.where((row) => row is Map && row['syncState'] == 'failed').length : 'Unknown'} Failed\n${rows.where((r)=>r['_queueCollection']=='_windows_document_outbox'&&r['deleted']==true).length} file cleanup operations included",
              ),
            ),
            metric('Adaptive Sync', adaptiveSyncCard(details['batchTransport'] is Map
                ? details['batchTransport'] as Map : null)),
            if (other['pending'] is num && other['pending'] > 0)
              metric('Restore & legacy work',
                "${other['pending']} outstanding · ${other['retry']} retry · ${other['review']} need review"),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {WindowsAppearance.watch(context);
            final progress = _panelBox(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sync Progress',
                    style: TextStyle(fontFamily: 'Segoe UI', fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  WindowsSyncFlow(
                    phase:phase,label:phaseLabel,
                    local:diskEvidence?['status']=='Measured'
                      ? '${diskEvidence!['volume']}\n${bytesLabel(diskEvidence!['usedBytes'] as int)} / ${bytesLabel(diskEvidence!['totalBytes'] as int)}'
                      : localDataPath==null?'Unknown':RegExp(r'^[A-Za-z]:[\\/]').firstMatch(localDataPath!)?.group(0)??'Unknown',
                    cloud:checking?'Checking cloud changes':ack is num&&ack>0?'Last ACK: ${stamp(ack)}':'No verified ACK yet',
                    drive:driveLabel,
                    pending:((details['pending'] as num? ?? 0)+(details['incomingPending'] as num? ?? 0)).toInt(),
                    lastMicros:details['lastVerifiedTransferMicros'] as int?,
                    active:engine.isPaused?const {}:WindowsSyncEvidence.lanes(db.activeProfileIdentity['schoolSyncId']?.toString()??'')
                      .where((lane)=>lane=='local'||!checking&&hasUploads).toSet(),
                  ),
                  const SizedBox(height: 12),
                   Text(
                    'Live state from the durable queue • No estimated percentages',
                    style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Color(0xFF9AB4C9)), fontSize: 12),
                  ),
                ],
              ),
            );
            final activity = _panelBox(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.insights, color: _cyan),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Live Queue Activity',
                          style: TextStyle(fontFamily: 'Segoe UI', 
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if ((details['liveQueue'] as List? ?? items).isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No pending operations in this school.'),
                    ),
                  for (final raw
                      in (details['liveQueue'] as List? ?? items).take(8))
                    if (raw is Map)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.sync, color: _cyan),
                        title: Text(
                          '${raw['collection'] ?? (raw['_queueCollection']=='_windows_document_outbox' ? raw['deleted']==true?'Document cleanup':'Document upload':'School record')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${raw['documentId'] ?? raw['id'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: (raw['syncState'] ?? raw['state']) == 'conflict'
                          ? TextButton(onPressed: active ? null : () => _run(() async {
                              await showWindowsConflictReview(context, Map<String,dynamic>.from(raw));
                              await engine.refreshDetails();
                            }), child: const Text('Review conflict'))
                          : Text('${raw['syncState'] ?? raw['state'] ?? 'pending'}',
                              style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Color(0xFFFFC153)))),
                      ),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: () => _jump(_queueKey),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('View full queue'),
                  ),
                ],
              ),
            );
            if (constraints.maxWidth < 960)
              return Column(
                children: [progress, const SizedBox(height: 12), activity],
              );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: progress),
                const SizedBox(width: 18),
                Expanded(flex: 2, child: activity),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _tool(Future<void> Function() action) async {
    _scaffoldKey.currentState?.closeDrawer();
    setState(() {
      showHistory = false;
      showDiagnostics = true;
      showQueue = false;
    });
    await _run(action);
  }

  Widget _controls(bool active) => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      OutlinedButton(
        onPressed: () => _jump(_backupKey),
        child: const Text('Measured Status'),
      ),
      OutlinedButton(
        onPressed: active
            ? null
            : () => _tool(() => _binaryAction('inventory')),
        child: const Text('Check / continue file inventory'),
      ),
      OutlinedButton(
        onPressed: active ? null : () => _tool(() => _binaryAction('restart')),
        child: const Text('Restart file inventory check'),
      ),
      OutlinedButton(
        onPressed: active ? null : _administratorBinaryRetry,
        child: const Text('Review capped file retry'),
      ),
      OutlinedButton(
        onPressed: active ? null : () => _tool(() => _binaryAction('inspect')),
        child: const Text('Verify local file bytes'),
      ),
      OutlinedButton(
        onPressed: active ? null : () => _tool(() => _binaryAction('repair')),
        child: const Text('Recover next missing file'),
      ),
      OutlinedButton(
        onPressed: active ? null : () => _tool(engine.reportCurrentSyncMonitor),
        child: const Text('Report current measured sync status'),
      ),
      OutlinedButton(
        onPressed: active
            ? null
            : () => _tool(() => openCleanInstallRestore(context)),
        child: const Text('Restore Existing School — fresh install only'),
      ),
      OutlinedButton(
        onPressed: busy ? null : () => _tool(_checkCloudHealth),
        child: const Text('Check Cloud Health'),
      ),
      OutlinedButton(
        onPressed: active ? null : () => _tool(_verifyStudentRecords),
        child: const Text('Verify student cloud records'),
      ),
      OutlinedButton(
        onPressed: busy ? null : () => _tool(_storageDetails),
        child: const Text('Local Storage Details'),
      ),
      OutlinedButton(
        onPressed: busy ? null : () => _tool(_cloudStorageDetails),
        child: const Text('School Drive Usage'),
      ),
      OutlinedButton(
        onPressed: active ? null : () => _tool(_exportDiagnostics),
        child: const Text('Export Sanitized Report'),
      ),
      OutlinedButton(
        onPressed: active
            ? null
            : () => _run(
                widget.backupRequest ??
                    () async {
                      throw StateError(
                        'Secure school backup export is unavailable in this build.',
                      );
                    },
              ),
        child: const Text('Backup School Data'),
      ),
      OutlinedButton(
        onPressed: active ? null : () => _tool(_restoreRehearsal),
        child: const Text('Verify Backup Restore'),
      ),
      if (db.activeProfileIdentity['schoolSyncId'] ==
          'vs-db8afb01a3be46a983c8284714d06e5d')
        OutlinedButton(
          onPressed: active ? null : () => _tool(_cloudRecordBackup),
          child: const Text('TEST Cloud Record Backup'),
        ),
      if (db.activeProfileIdentity['schoolSyncId'] ==
          'vs-db8afb01a3be46a983c8284714d06e5d')
        OutlinedButton(
          onPressed: active
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (appearanceContext) { WindowsAppearance.watch(appearanceContext); return  const WindowsDisasterRehearsal(); },
                  ),
                ),
          child: const Text('TEST Disaster Recovery'),
        ),
      OutlinedButton(
        onPressed: active
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (appearanceContext) { WindowsAppearance.watch(appearanceContext); return  const WindowsRecycleBin(); },
                ),
              ),
        child: const Text('Recycle Bin'),
      ),
      OutlinedButton(
        onPressed: active
            ? null
            : () => _tool(() async {
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
            : () => _tool(() async {
                final report = await engine.safeQueueDiagnostics();
                if (mounted && db.activeProfileId == origin)
                  setState(() => diagnostics = report);
              }),
        child: const Text('Diagnostic Report'),
      ),
    ],
  );

  Widget _navigation(bool active) => Wrap(
    spacing: 10,
    runSpacing: 6,
    children: [
      _nav(Icons.dashboard_outlined, 'Overview', () => _jump(_overviewKey)),
      _nav(Icons.history, 'Smart Repair History', () => _jump(_activityKey)),
      _nav(
        Icons.delete_outline,
        'Recycle Bin',
        () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (appearanceContext) { WindowsAppearance.watch(appearanceContext); return  const WindowsRecycleBin(); }),
        ),
      ),
      _nav(
        Icons.lock_outline,
        'Backup School Data',
        active
            ? null
            : () => _run(
                widget.backupRequest ??
                    () async {
                      throw StateError(
                        'Secure school backup export is unavailable in this build.',
                      );
                    },
              ),
      ),
    ],
  );

  Widget _connection(
    IconData icon,
    String title,
    String status,
    Color accent, {
    Widget? details,
  }) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: WindowsAppearance.resolve(_panel),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: WindowsAppearance.outline(const Color(0xFF21475D))),
    ),
    child: Row(
      children: [
        Icon(icon, color: accent, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontFamily: 'Segoe UI', fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                status,
                style:  TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Color(0xFF9AB4C9)), fontSize: 12),
              ),
              if (details != null) details,
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) { WindowsAppearance.watch(context); return  Theme(
    data: Theme.of(context).copyWith(
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10))),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8))),
    ),
    child: Scaffold(
      key: _scaffoldKey,
      backgroundColor: WindowsAppearance.background(const Color(0xFF071626)),

      appBar: AppBar(
        backgroundColor: WindowsAppearance.background(const Color(0xFF0A1D30)),
        automaticallyImplyLeading: false,
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
        title: const Text('Sync Engine 3.0'),
        actions: [
          AnimatedBuilder(
            animation: Listenable.merge([engine.state, engine.details,ManagedSchoolSession.activeTransfers,WindowsSyncEvidence.active]),
            builder: (context, _) { WindowsAppearance.watch(context); return  Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: FilledButton.icon(
                onPressed: busy || db.activeProfileId != origin
                    ? null
                    : () =>
                          (engine.isSyncing || syncCommandRunning) &&
                              !engine.isPaused
                          ? _run(
                              () => (widget.pauseRequest ?? engine.pauseSync)(
                                const Duration(hours: 24),
                              ),
                            )
                          : _startManualSync(),
                icon: Icon(
                  (engine.isSyncing || syncCommandRunning) && !engine.isPaused
                      ? Icons.pause
                      : Icons.sync,
                ),
                label: Text(
                  (engine.isSyncing || syncCommandRunning) && !engine.isPaused
                      ? 'Pause Sync'
                      : 'Sync Now',
                ),
              ),
            ); },
          ),
          PopupMenuButton<int>(
            tooltip: 'Schedule sync pause',
            enabled: !busy && db.activeProfileId == origin,
            onSelected: (hours) {
              if(hours==0){setState((){showDiagnostics=true;showHistory=false;showQueue=false;});return;}
              _run(
              () => (widget.pauseRequest ?? engine.pauseSync)(
                Duration(hours: hours),
              ),
            );},
            itemBuilder: (_) => const [
              PopupMenuItem(value:0,child:Text('Advanced checks')),
              PopupMenuItem(value: 1, child: Text('Pause Sync for 1 Hour')),
              PopupMenuItem(value: 12, child: Text('Pause Sync for 12 Hours')),
              PopupMenuItem(value: 24, child: Text('Pause Sync for 1 Day')),
            ],
          ),
          const SizedBox(width: 20),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) { WindowsAppearance.watch(context); return  Row(
          children: [
            Expanded(
              child: AnimatedBuilder(
                animation: Listenable.merge([engine.state, engine.details,ManagedSchoolSession.activeTransfers,WindowsSyncEvidence.active]),
                builder: (context, _) {WindowsAppearance.watch(context);
                  final details = engine.details.value;
                  final ownSchool = db.activeProfileId == origin;
                  final items = ownSchool
                      ? (details['items'] as List? ?? [])
                      : <dynamic>[];
                  final active = busy || engine.isSyncing || syncCommandRunning;
                  return ListView(
                    key: _overviewKey,
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Text(
                        'Sync & Backup Control Center',
                        style: TextStyle(fontFamily: 'Segoe UI', 
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Your school records, cloud transfers and recovery — together in one live workspace.',
                      ),
                      _alerts(ownSchool: ownSchool),
                      if (ownSchool) ...[
                        _navigation(active),
                        const SizedBox(height: 12),
                        if (showHistory) ...[
                          const Text(
                            'Smart Repair History',
                            style: TextStyle(fontFamily: 'Segoe UI', 
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          for (final memory in engine.repairMemory.entries.reversed.where((e)=>recentRepairEvent(e,DateTime.now().millisecondsSinceEpoch)))
                            ListTile(
                              leading: Icon(memory['status'] == 'resolved'
                                ? Icons.check_circle_outline : Icons.history),
                              title: Text('${memory['collection']} • ${memory['category']} • ${repairMemoryStatusText(memory['status'])}'),
                              subtitle: Text('Record: ${memory['recordId']}\n'
                                '${memory['observations']} observations • ${memory['verifiedRepairs']} verified resolutions • '
                                '${memory['recurrences']} recurrences\n'
                                'First version: ${memory['firstAppVersion'] ?? 'Unknown'} • Latest: ${memory['lastAppVersion'] ?? 'Unknown'}\n'
                                '${memory['resolvedInVersion'] == null ? '' : 'Verified in: ${memory['resolvedInVersion']}\n'}'
                                'Safe response: ${repairMemoryActionText(memory['learnedAction'])}'),
                            ),
                          if (recentRepairHistory(engine.recoveryHistory,DateTime.now().millisecondsSinceEpoch).isEmpty && !engine.repairMemory.entries.any((e)=>recentRepairEvent(e,DateTime.now().millisecondsSinceEpoch)))
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 20),
                              child: Text(
                                'No recovery events recorded for this school.',
                              ),
                            ),
                          for (final event in recentRepairHistory(engine.recoveryHistory,DateTime.now().millisecondsSinceEpoch).reversed)
                            ListTile(
                              title: Text(
                                '${event['category']} • ${event['outcome']}',
                              ),
                              subtitle: Text(
                                '${event['atUtc']}${event['attempt'] is num ? ' • attempt ${event['attempt']}' : ''}'
                                '${event['collection'] == null ? '' : '\n${event['collection']} • ${event['documentId'] ?? 'record not identified'}'}',
                              ),
                            ),
                          for (final raw
                              in (details['activity'] as List? ?? const []).where(
                                (row) =>
                                    row is Map &&
                                    row['schoolId'] ==
                                        db.activeProfileIdentity['schoolSyncId'] && recentRepairEvent(row,DateTime.now().millisecondsSinceEpoch),
                              ))
                            _activityRow(
                              Map<String, dynamic>.from(raw as Map),
                              active,
                            ),
                        ],
                        if (!showDiagnostics && !showHistory) ...[
                          _hero(details, items, active),
                          const SizedBox(height: 18),
                          if (engine.isPaused)
                            Text(
                              'Paused on this PC: ${engine.pausedUntil?.difference(DateTime.now()).inMinutes ?? 0} minutes remaining (until ${engine.pausedUntil?.toLocal()})${engine.isSyncing ? ' — finishing the accepted operation' : ''}',
                            ),
                        ],
                        if (showDiagnostics) ...[
                          _controls(active),
                          if (showQueue) ...[
                            SizedBox(key: _queueKey),
                            const Text(
                              'Pending Queue & Conflict Review',
                              style: TextStyle(fontFamily: 'Segoe UI', fontSize: 20),
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
                                builder: (context) {WindowsAppearance.watch(context);
                                  final item = Map<String, dynamic>.from(
                                    raw as Map,
                                  );
                                  final decision = smartSyncDecision(
                                    item,
                                    school:
                                        db.activeProfileIdentity['schoolSyncId']
                                            ?.toString() ??
                                        '',
                                    nowMillis:
                                        DateTime.now().millisecondsSinceEpoch,
                                  );
                                  return Card(
                                    child: ListTile(
                                      title: Text(
                                        '${item['collection'] ?? item['_queueCollection'] ?? 'documents'} • ${item['documentId'] ?? item['id']}',
                                      ),
                                      subtitle: Text(
                                        'Status: ${item['syncState'] ?? item['state'] ?? 'pending'} • Attempts: ${item['retryCount'] ?? 0} • ${item['failureCategory'] ?? 'No classified failure'}${item['lastError'] == null ? '' : '\n${syncFailureReason(item)}'}${item['failureCode'] == null ? '' : '\nCode: ${item['failureCode']}'}\n${pendingSyncDiagnostic(item, now: DateTime.now(), providerRetry: engine.providerQuotaRetryAt, pausedUntil: engine.pausedUntil, automatic: engine.automaticSyncEnabled, syncing: engine.isSyncing)}\nNext step: ${decision['action']}\n${decision['reason']}',
                                      ),
                                      trailing:
                                          (item['syncState'] ??
                                                  item['state']) ==
                                              'conflict'
                                          ? TextButton(
                                              onPressed: active
                                                  ? null
                                                  : () => _run(() async {
                                                      if (item['_queueCollection'] ==
                                                          '_windows_recycle_requests') {
                                                        await Navigator.of(
                                                          context,
                                                        ).push(
                                                          MaterialPageRoute<
                                                            void
                                                          >(
                                                            builder: (appearanceContext) { WindowsAppearance.watch(appearanceContext); return
                                                                const WindowsRecycleBin(); },
                                                          ),
                                                        );
                                                      } else {
                                                        await showWindowsConflictReview(
                                                          context,
                                                          item,
                                                        );
                                                      }
                                                      await engine
                                                          .refreshDetails();
                                                    }),
                                              child: const Text('Review'),
                                            )
                                          : item['_queueCollection'] == '_windows_firebase_outbox' &&
                                              item['syncState'] == 'needsAttention' &&
                                              (item['failureCategory'] == null || item['failureCategory'] == '')
                                          ? TextButton(
                                              onPressed: active ? null : () => _run(engine.requestSync),
                                              child: const Text('Diagnose saved request'),
                                            )
                                          : null,
                                    ),
                                  );
                                },
                              ),
                          ],
                          if (!showQueue) ...[
                            SizedBox(key: _statusKey),
                            const Text(
                              'Measured status & recovery',
                              style: TextStyle(fontFamily: 'Segoe UI', fontSize: 22),
                            ),
                            WindowsSyncPerformance(summary: engine.performanceSummary),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                metric(
                                  'Pending uploads',
                                  '${details['pending'] ?? 'Not measured'}',
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
                                  engine.lastVerifiedCheckpoint
                                          ?.toLocal()
                                          .toString() ??
                                      'Not yet verified',
                                ),
                                metric(
                                  'Internet connectivity',
                                  cloudEvidence == null
                                      ? 'Not independently verified'
                                      : 'Authenticated school API network path verified in this session',
                                ),
                                metric(
                                  'Next record batch window',
                                  details['batchTransport'] is Map
                                      ? '${details['batchTransport']['nextLimit']} records (max 10)'
                                      : 'Not measured',
                                ),
                                metric(
                                  'Last broker batch request',
                                  details['batchTransport'] is Map
                                      ? '${((details['batchTransport']['requestMicros'] as num) / 1000).toStringAsFixed(1)} ms · ${details['batchTransport']['successfulReceipts']}/${details['batchTransport']['submitted']} successful receipts'
                                      : 'Not measured',
                                ),
                                metric(
                                  'Batch measurement time',
                                  stamp(details['batchTransport'] is Map
                                      ? details['batchTransport']['observedAt'] : null),
                                ),
                                metric(
                                  'Last Sheet audit page',
                                  details['sheetIntegrity'] is Map
                                      ? '${details['sheetIntegrity']['collection']}: ${details['sheetIntegrity']['checked']} checked, ${(details['sheetIntegrity']['findings'] as List).length} findings · ${details['sheetIntegrity']['coverage']}'
                                      : 'Not measured / capability unavailable',
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
                                  'Partial — observed record inventories below; unmeasured categories are Unknown',
                                ),
                                metric(
                                  'Binary inventory',
                                  binaryEvidence?['inventory']?.toString() ??
                                      'UNKNOWN',
                                ),
                                metric(
                                  'Known files / verified locally',
                                  binaryEvidence == null
                                      ? 'Unknown'
                                      : '${binaryEvidence!['knownFiles']} / ${binaryEvidence!['verifiedFiles']}',
                                ),
                                metric(
                                  'Pending / failed / interrupted files',
                                  binaryEvidence == null
                                      ? 'Unknown'
                                      : '${binaryEvidence!['pending']} / ${binaryEvidence!['failed']} / ${binaryEvidence!['interrupted']}',
                                ),
                                metric(
                                  'Missing / damaged files',
                                  binaryEvidence == null
                                      ? 'Unknown'
                                      : '${binaryEvidence!['missing']} / ${binaryEvidence!['damaged']}',
                                ),
                                metric(
                                  'Verified local cloud-copy bytes',
                                  binaryEvidence == null
                                      ? 'Unknown'
                                      : bytesLabel(
                                          binaryEvidence!['verifiedBytes']
                                              as int,
                                        ),
                                ),
                                metric(
                                  'Last verified binary download',
                                  stamp(
                                    binaryEvidence?['lastVerifiedDownloadAt'],
                                  ),
                                ),
                                metric(
                                  'Next file retry / capped files',
                                  binaryEvidence == null
                                      ? 'Unknown'
                                      : '${stamp(binaryEvidence!['retryAt'])} / ${binaryEvidence!['retryBlocked']}',
                                ),
                                metric(
                                  'Media inventory scope',
                                  'Application media folders; archives/native documents excluded',
                                ),
                                metric(
                                  'Pending protected restores',
                                  '${details['pendingRestores'] ?? 'Unknown'}',
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
                                metric('Local PC volume usage', diskLabel),
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
                                metric(
                                  'Last local backup',
                                  stamp(lastBackupAt),
                                ),
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
                                    cloudEvidence!['sheetsAccessVerified'] ==
                                            true
                                        ? 'Existing tab read verified'
                                        : 'Not independently verified',
                                  ),
                                  metric(
                                    'Cloud record backup',
                                    cloudEvidence!['recordBackupVersion'] ==
                                                4 &&
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
                            SizedBox(key: _backupKey),
                            SizedBox(key: _settingsKey),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Automatic sync'),
                              subtitle: const Text(
                                'Local edits remain durable when automatic sync is paused.',
                              ),
                              value: engine.automaticSyncEnabled,
                              onChanged: active
                                  ? null
                                  : (enabled) => _run(
                                      () => engine.setAutomaticSync(enabled),
                                    ),
                            ),
                            if (active)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Text(
                                  'Operation in progress. Cloud requests have bounded timeouts; local records stay accessible.',
                                ),
                              ),
                            const Divider(height: 32),
                            if (studentAudit != null) ...[
                              const Text(
                                'Student cloud snapshot — current school',
                                style: TextStyle(fontFamily: 'Segoe UI', fontSize: 20),
                              ),
                              Text(
                                'Local: ${studentAudit!['localCount']} • Cloud: ${studentAudit!['cloudCount']} • Matching: ${(studentAudit!['matched'] as List).length}',
                              ),
                              for (final key in [
                                'missingCloud',
                                'different',
                                'cloudOnly',
                                'pendingIds',
                              ])
                                SelectableText(
                                  '$key (${(studentAudit![key] as List).length}): ${(studentAudit![key] as List).take(100).join(', ')}',
                                ),
                              Text(
                                'Measured: ${studentAudit!['measuredAt']}. Metadata snapshot only; lists show up to 100 IDs. No records changed.',
                              ),
                              const Divider(height: 32),
                            ],
                            if (categoryCounts != null) ...[
                              const Text(
                                'Local records by category — current school',
                                style: TextStyle(fontFamily: 'Segoe UI', fontSize: 20),
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
                            if (ownSchool && binaryDownloads != null) ...[
                              const Text(
                                'Verified cloud file copies — current school',
                                style: TextStyle(fontFamily: 'Segoe UI', fontSize: 20),
                              ),
                              const Text(
                                'Showing up to 50 known application files. Export requires actual hash-verified bytes; metadata alone is never an available file.',
                              ),
                              for (final row in binaryDownloads!.entries.take(
                                50,
                              ))
                                ListTile(
                                  title: Text('${row['name']}'),
                                  subtitle: Text(
                                    '${row['state']} • ${row['sizeBytes']} bytes',
                                  ),
                                  trailing: OutlinedButton(
                                    onPressed: active
                                        ? null
                                        : () => _run(
                                            () => _exportVerifiedBinary(row),
                                          ),
                                    child: const Text('Save verified copy'),
                                  ),
                                ),
                            ],
                            const Text(
                              'Observed downloads — current school',
                              style: TextStyle(fontFamily: 'Segoe UI', fontSize: 20),
                            ),
                            const Text(
                              'Local readback verifies stored record content, not a server upload ACK. File bytes and cloud-wide completeness remain Unknown. In-progress observations retained after a stopped sync require retry.',
                            ),
                            for (final raw
                                in (details['downloads'] as List? ??
                                        <dynamic>[])
                                    .where(
                                      (row) =>
                                          row is Map &&
                                          row['schoolId'] ==
                                              db.activeProfileIdentity['schoolSyncId'],
                                    ))
                              Builder(
                                builder: (context) {WindowsAppearance.watch(context);
                                  final row = Map<String, dynamic>.from(
                                    raw as Map,
                                  );
                                  return ListTile(
                                    title: Text(
                                      '${row['collection']} • ${row['state'] == 'downloading' && !engine.isSyncing ? 'Interrupted / retry required' : row['state']}',
                                    ),
                                    subtitle: Text(
                                      'Observed: ${stamp(row['observedAt'])}\nAwaiting verified storage: ${row['remaining']} • Verified records: ${row['verified']} • Local edits / review: ${row['blocked']}\nLast verified local download readback: ${stamp(row['lastVerifiedLocalReadbackAt'])}',
                                    ),
                                  );
                                },
                              ),
                            const Divider(height: 32),
                            const Divider(height: 32),
                            const Text(
                              'Recovery History — this school',
                              style: TextStyle(fontFamily: 'Segoe UI', fontSize: 20),
                            ),
                            if (engine.recoveryHistory.isEmpty)
                              const Text(
                                'No recovery events recorded for this school.',
                              ),
                            SizedBox(key: _activityKey),
                            for (final event in recentRepairHistory(engine.recoveryHistory,DateTime.now().millisecondsSinceEpoch).reversed)
                              ListTile(
                                title: Text(
                                  '${event['category']} • ${event['outcome']}',
                                ),
                                subtitle: Text(
                                  '${event['atUtc']}${event['attempt'] is num ? ' • attempt ${event['attempt']}' : ''}'
                                '${event['collection'] == null ? '' : '\n${event['collection']} • ${event['documentId'] ?? 'record not identified'}'}',
                                ),
                              ),
                            if (diagnostics != null) ...[
                              const Divider(height: 32),
                              const Text('Sanitized diagnostic evidence'),
                              SelectableText(
                                const JsonEncoder.withIndent('  ')
                                    .convert(diagnostics),
                              ),
                            ],
                          ],
                        ],
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ); },
      ),
    ),
  ); }
}

String syncFailureReason(Map item) {
  final specific = documentFailureExplanation(item);
  if (specific.isNotEmpty) return specific;
  final kind = failure_policy.SyncFailureKind.values.where(
    (kind) => kind.name == item['failureCategory'],
  );
  return failure_policy.SyncRecoveryDecision(
    kind.isEmpty ? failure_policy.SyncFailureKind.unknown : kind.first,
  ).message;
}

/// Cloudflare acceptance and final Google Drive delivery are separate receipts.
class CloudflareTransferStatus extends StatefulWidget {
  const CloudflareTransferStatus({super.key, this.messages = const [],
    this.showTransfers = true, this.panelBuilder});
  final List<String> messages;
  final bool showTransfers;
  final Widget Function(List<String>)? panelBuilder;
  @override State<CloudflareTransferStatus> createState() => _CloudflareTransferStatusState();
}
class _CloudflareTransferStatusState extends State<CloudflareTransferStatus> {
  Timer? _timer;
  Map<String, dynamic>? _status;
  String? _profile;
  bool _busy = false;
  @override void initState() { super.initState(); if (widget.showTransfers && ManagedSchoolSession.enabled) { _refresh(); _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh()); } }
  @override void dispose() { _timer?.cancel(); super.dispose(); }
  Future<void> _refresh() async {
    if (_busy || !widget.showTransfers) return;
    _busy = true;
    final origin = FirebaseFirestore.instance.activeProfileId;
    try {
      final status = await WindowsSyncEngine.instance.refreshTransferStatus();
      if (status == null) return;
      if (!mounted || FirebaseFirestore.instance.activeProfileId != origin) return;
      if (status['enabled'] == false && status['unavailable'] != true) _timer?.cancel();
      setState(() { _status = status; _profile = origin; });
    } catch (_) { if (mounted && _status?['enabled'] == true) setState(() => _status = {..._status!, 'unavailable': true}); }
    finally { _busy = false; }
  }
  @override Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    final message = widget.showTransfers && _profile == FirebaseFirestore.instance.activeProfileId
      ? cloudTransferMessage(_status) : null;
    if (widget.panelBuilder != null) {
      final messages = <String>{...widget.messages, if (message != null) message}.toList();
      return messages.isEmpty ? const SizedBox.shrink() : widget.panelBuilder!(messages);
    }
    if (message == null) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top: 10), child: Text(message,
      style: TextStyle(fontFamily: 'Segoe UI', fontSize: 14,
        color: WindowsAppearance.foreground(Colors.orangeAccent))));
  }
}
