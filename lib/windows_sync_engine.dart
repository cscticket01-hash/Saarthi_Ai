import 'windows_document_templates.dart';
import 'windows_connect/managed_school_session.dart';
import 'school_cloud_engine.dart';
import 'windows_pending_school_sync.dart';
import 'platform/platform_config.dart';
import 'windows_connect/central_school_cloud.dart';

import 'dart:async';
import 'windows_sync_schedule.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'school_cloud_state.dart';

import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'school_backend_transport.dart';

import 'dart:math';

import 'package:http/http.dart' as http;

import 'windows_backend_bridge.dart';
import 'windows_firebase_sync.dart';
import 'windows_html_shim.dart' as windows_html;
import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';
import 'windows_runtime_flags.dart';
import 'windows_sync_recovery.dart';
import 'sync_recovery_policy.dart';
import 'windows_platform_client.dart';

class WindowsSyncEngine with WidgetsBindingObserver {
  WindowsSyncEngine._();

  static final WindowsSyncEngine instance = WindowsSyncEngine._();

  static const List<String> _firebaseCollections = <String>[
    'students_directory',
    'school_notices',
    'teachers_directory',
    'school_config',
    'fee_payments',
    'fee_ledger',
    'fee_settings',
    'school_settings',
    'school_calendar',
    'attendance_records',
    'exam_results',
    'teacher_salary',
    'school_expenses',
    'attendance_logs',
    'teacher_attendance',
    'teacher_schedules',
    'student_scan_index',
    'scanner_devices',
    'documents',
    'backups',
    'exams',
    'exam_center_results',
  ];

  static const reconciliationInterval = Duration(minutes: 4);
  late final _schedule = WindowsSyncSchedule((delay) => scheduleSoon(delay: delay));
  Timer? _debounceTimer;
  bool _initialized = false;
  bool _syncing = false;
  bool _resetPaused = false;
  int _activating = 0;
  bool _syncBlocked = false;
  DateTime? _lastMonitorReport;
  String? _lastMonitorProfile;

  DateTime? lastSuccessfulSync;
  DateTime? lastVerifiedCheckpoint;
  bool get _checkpointDue => syncCheckpointDue(lastVerifiedCheckpoint, DateTime.now());
  SyncRecoveryDecision? recoveryDecision;
  bool automaticSyncEnabled = true;
  final recoveryHistory = <Map<String, dynamic>>[];
  DateTime? get nextRetryAt => _nextRetry;
  bool get isSyncing => _syncing;
  String? _protocolIdentity;
  DateTime? _protocolVerifiedAt;
  bool _deltaBatchSupported = false;
  final metrics = <String, int>{
    'recordReadRequests': 0,
    'recordWriteRequests': 0,
    'storageChecks': 0,
    'reconciliationMicros': 0,
  };
  final details = ValueNotifier<Map<String, dynamic>>({});
  static Duration retryDelayForFailure(int failures, {bool quotaLimited = false}) {
    final exponent = (failures - 1).clamp(0, 6).toInt();
    return Duration(seconds: ((quotaLimited ? 60 : 5) * (1 << exponent)).clamp(5, quotaLimited ? 900 : 300).toInt());
  }

  int _failures = 0;
  DateTime? _nextRetry, _lastPull;
  final _samples = <String, List<int>>{};
  void _sample(String name, int value) {
    final values = _samples.putIfAbsent(name, () => <int>[]);
    if (values.length >= 256) values.removeAt(0);
    values.add(value);
  }
  Map<String, dynamic> get performanceSummary => {
    for (final entry in _samples.entries)
      entry.key: (() {
        final sorted = entry.value.toList()..sort();
        int percentile(double p) => sorted[((sorted.length - 1) * p).ceil()];
        return {'samples': sorted.length, 'p50': percentile(0.5), 'p95': percentile(0.95)};
      })(),
  };
  void recordLocalSave(String entity, int micros) {
    metrics['${entity}SaveMicros'] = micros;
    _sample('${entity}SaveMicros', micros);
  }

  Future<void> refreshDetails() async {
    final db = FirebaseFirestore.instance,
        origin = FirebaseFirestore.instance.activeProfileId;
    final general = await db.collection('_windows_firebase_outbox').get();
    final documents = await db.collection('_windows_document_outbox').get();
    final receipts = await db.collection('_windows_sync_receipts').get();
    final backup = await db.collection('_windows_sync_status').doc('backup').get();
    final downloads = await db.collection('_windows_sync_downloads').get();
    if (db.activeProfileId != origin) return;
    final items = [...general.docs, ...documents.docs];
    details.value = {
      'pending': items.length,
      'conflictCount': items.where((d)=>d.data()['syncState']=='conflict').length,
      'documentPending': documents.docs.length + general.docs.where((d)=>d.data()['collection']=='documents').length,
      'lastLocalBackupMillis': backup.data()?['createdAt'] is int ? backup.data()!['createdAt'] : 0,
      'verifiedReceiptCount': receipts.docs.length,
      'lastCloudAckMillis': receipts.docs.fold<int>(0, (latest, row) {
        final stamp = row.data()['acknowledgedAt'];
        return stamp is num && stamp.toInt() > latest ? stamp.toInt() : latest;
      }),
      'needsAttention': items
          .where(
            (d) =>
                {'conflict', 'needsAttention'}.contains(d.data()['syncState']),
          )
          .length,
      'items': [for(final d in general.docs){'id':d.id,...d.data(),'_queueCollection':'_windows_firebase_outbox'},
        for(final d in documents.docs){'id':d.id,...d.data(),'_queueCollection':'_windows_document_outbox'}],
      'metrics': Map<String, int>.from(metrics),
      'performance': performanceSummary,
      'downloads': [for (final row in downloads.docs)
        if (row.data()['schoolId'] == db.activeProfileIdentity['schoolSyncId']) row.data()],
    };
    if (_initialized) unawaited(_reportSyncMonitor(origin, Map<String,dynamic>.from(details.value)));
  }

  Future<void> _reportSyncMonitor(String origin, Map<String,dynamic> observed) async {
    if (_lastMonitorProfile == origin && _lastMonitorReport != null && DateTime.now().difference(_lastMonitorReport!) < const Duration(minutes:5)) return;
    _lastMonitorProfile=origin;_lastMonitorReport=DateTime.now();
    try {
      final central=await CentralSchoolCloud.saved();
      if (FirebaseFirestore.instance.activeProfileId!=origin || central['managed']!=true || central['schoolId']!=_activeSchoolSyncId) return;
      await ManagedSchoolSession.callForSchool(_activeSchoolSyncId,'managed/sync/status',{'report':{
        'pending':observed['pending'],'needsAttention':observed['needsAttention'],
        'appVersion':WindowsPlatformClient.version,'conflictCount':observed['conflictCount'],'documentPending':observed['documentPending'],
        'lastReconciliationMillis':lastVerifiedCheckpoint?.millisecondsSinceEpoch??0,
        'lastLocalBackupMillis':observed['lastLocalBackupMillis'],
        'verifiedReceiptCount':observed['verifiedReceiptCount'],'lastCloudAckMillis':observed['lastCloudAckMillis'],
      }}).timeout(const Duration(seconds:25));
    } catch (_) {/* Aggregate monitoring cannot clear queues or change sync success. */}
  }

  String? lastError;

  /// Read-only evidence for support. Never exports record bodies or raw errors.
  Future<Map<String, dynamic>> safeQueueDiagnostics() async {
    final db = FirebaseFirestore.instance, origin = FirebaseFirestore.instance.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId'];
    final general = await db.collection('_windows_firebase_outbox').get();
    final documents = await db.collection('_windows_document_outbox').get();
    final receipts = await db.collection('_windows_sync_receipts').get();
    if (db.activeProfileId != origin) throw StateError('School changed. Reopen Sync details.');
    String? token(dynamic value) => value is String && RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(value) ? value : null;
    Map<String, dynamic> errorMetadata(dynamic value) {
      final text = value is String ? value : '';
      final candidate = RegExp(r'\[([A-Z_]+)\]').firstMatch(text)?.group(1);
      final code = {'RECORD_REVISION_CONFLICT','OPERATION_ID_CONFLICT','SCHOOL_STORAGE_NOT_CONNECTED','TEST_ENVIRONMENT_MISMATCH',
        'SCRIPT_HTTP_ERROR','SCRIPT_INVALID_RESPONSE','SCRIPT_IDENTITY_MISMATCH','SCRIPT_OPERATION_FAILED',
        'SCRIPT_TRANSPORT_ERROR','SCRIPT_RESPONSE_READ_FAILED',
        'SCRIPT_MIGRATION_PENDING','SCRIPT_MIGRATION_CONFLICT','SCRIPT_MISSING_MIGRATED_TAB',
        'SCRIPT_RECORD_VERIFY_FAILED','SCRIPT_STORAGE_NOT_PREPARED','SCRIPT_PERMISSION_DENIED',
        'SCRIPT_QUOTA_EXCEEDED','SCRIPT_TIMEOUT','SCRIPT_TYPE_ERROR','SCRIPT_PARSE_ERROR'}.contains(candidate) ? candidate : null;
      final reference = RegExp(r'Ref: ([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\.').firstMatch(text)?.group(1);
      final status = RegExp(r'HTTP (400|401|403|409|429|502|503|504)').firstMatch(text)?.group(1);
      return {if (code != null) 'code': code, if (reference != null) 'referenceId': reference,
        if (status != null) 'httpStatus': int.parse(status)};
    }
    final rows = <Map<String, dynamic>>[];
    for (final queue in ['records', 'documents']) {
    for (final entry in queue == 'records' ? general.docs : documents.docs) {
      final item = entry.data(), state = item['syncState'];
      final collection = item['collection'];
      final queuedAt = item['queuedAt'];
      rows.add({
        'queue': queue,
        'collection': collection is String && _firebaseCollections.contains(collection) ? collection : queue == 'documents' ? 'documents' : 'unknown',
        'recordFingerprint': sha256.convert(utf8.encode('${collection ?? 'documents'}/${item['documentId'] ?? entry.id}')).toString(),
        if (token(item['operationId']) != null) 'operationId': token(item['operationId']),
        if (token(item['baseCloudRevision']) != null) 'baseCloudRevision': token(item['baseCloudRevision']),
        'state': state == null ? 'pending' : {'pending','leased','retry','failed','accepted','acknowledged','conflict','needsAttention'}.contains(state) ? state : 'unknown',
        if (queuedAt is Timestamp) 'queuedAtMillis': queuedAt.millisecondsSinceEpoch,
        if (queuedAt is num && queuedAt.isFinite) 'queuedAtMillis': queuedAt.toInt(),
        ...errorMetadata(item['lastError']),
      });
    }
    }
    return {'schemaVersion': 1, 'capturedAtUtc': DateTime.now().toUtc().toIso8601String(),
      if (school is String && RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school)) 'schoolId': school,
      'pendingCount': rows.length, 'items': rows,
      'retainedVerifiedReceiptCount': receipts.docs.length,
      'historicalCountChange': 'Cannot infer ACK for missing historical items without their operation receipts', 'latestError': errorMetadata(lastError),
      'cloudVerification': 'Not performed by this read-only report'};
  }
  String _activeProfileId = 'unbound';
  String _activeSchoolSyncId = '';
  String _activeFirebaseProject = '';
  String _activeGoogleUrl = '';

  final state = ValueNotifier<SchoolCloudState>(SchoolCloudState.localReady);
  String get activeProfileId => _activeProfileId;
  String get activeSchoolSyncId => _activeSchoolSyncId;
  bool get syncBlocked => _syncBlocked;

  Future<void> initialize() async {
    if (_initialized) return;
    _resetPaused = false;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);

    WindowsLocalFirestoreSyncControl.onTrackedMutation = () async {
      scheduleSoon(localMutation: true);
      unawaited(refreshDetails());
    };

    WindowsFirebaseRemote.onConnectionChanged = () async {
      await _handleFirebaseConnectionChanged();
    };

    WindowsBackendBridge.onLocalDocumentCommitted = () {
      scheduleSoon(localMutation: true);
      unawaited(refreshDetails());
    };
    WindowsBackendBridge.onRemoteAvailable = () async {
      _schedule.reconnected();
    };

    await activateCurrentConnections(allowPairing: false);

    if (_resetPaused) return;

    _schedule.start(reconciliationInterval);

    scheduleSoon(delay: const Duration(milliseconds: 800));
  }

  Future<void> _handleFirebaseConnectionChanged() async {
    final status = await WindowsFirebaseRemote.status();
    final nextProject = status.authenticated ? status.projectId.trim() : '';

    final previousProject = _activeFirebaseProject.trim();
    final selectedDrive = await WindowsExternalConnections.googleScriptUrl();

    // Switching an already-active School A Firebase to School B must never
    // silently keep School A Drive. First-time Firebase connection is
    // different: if the user already entered a Drive link, both explicit
    // settings may be paired now.
    if (previousProject.isNotEmpty &&
        nextProject.isNotEmpty &&
        nextProject != previousProject &&
        selectedDrive.isNotEmpty) {
      await WindowsExternalConnections.save(
        googleScriptUrl: '',
        googleEmail: '',
      );
    }

    final mayPairFirstFirebase =
        previousProject.isEmpty &&
        nextProject.isNotEmpty &&
        selectedDrive.isNotEmpty;

    await activateCurrentConnections(allowPairing: mayPairFirstFirebase);
  }

  Future<void> localStorageModeChanged() async {
    final enabled = await WindowsRuntimeFlags.localStorageEnabled();
    if (!enabled) {
      // Forget only the OFF-mode in-memory mirror. Existing disk data stays
      // untouched and will be available again when Local Data is turned ON.
      await FirebaseFirestore.instance.resetVolatileSession();
    }
    await activateCurrentConnections(allowPairing: false);
    if (!_syncBlocked) {
      await syncNow();
    }
  }

  void scheduleSoon({Duration delay = const Duration(milliseconds: 250), bool localMutation = false}) {
    if (!_initialized || _syncBlocked || _resetPaused || !automaticSyncEnabled) return;
    if (recoveryDecision != null && !recoveryDecision!.retry) {
      if (!localMutation || !recoveryDecision!.independentRecords) return;
      recoveryDecision = null;
      _failures = 0;
    }
    if (_syncing) {
      _rerunRequested = true;
      return;
    }

    if (lastError == null) state.value = SchoolCloudState.syncPending;
    if (_nextRetry != null && _nextRetry!.isAfter(DateTime.now()))
      delay = _nextRetry!.difference(DateTime.now());
    // Coalesce a burst without postponing the first durable operation forever.
    if (_debounceTimer?.isActive == true) return;
    _debounceTimer = Timer(delay, () {
      unawaited(syncNow());
    });
  }

  Future<void> changeGoogleConnection({
    required String email,
    required String scriptUrl,
  }) async {
    final cleanEmail = email.trim();
    final cleanUrl = scriptUrl.trim();

    if (cleanEmail.isEmpty ||
        !cleanEmail.toLowerCase().endsWith('@gmail.com')) {
      throw const FormatException('Valid School Gmail ID daalein.');
    }

    WindowsExternalConnections.validateGoogleScriptUrl(cleanUrl);

    final healthy = await WindowsBackendBridge.testRemote(Uri.parse(cleanUrl));
    if (!healthy) {
      throw StateError(
        'Google Drive / Apps Script actual health check fail hua.',
      );
    }

    final firebaseStatus = await WindowsFirebaseRemote.status();
    final firebaseReady =
        firebaseStatus.authenticated &&
        firebaseStatus.projectId.trim().isNotEmpty;

    // User may enter Google first. Save it as a pending connection, but do
    // not expose/sync any school data until Firebase is also verified.
    if (!firebaseReady) {
      await WindowsExternalConnections.save(
        googleScriptUrl: cleanUrl,
        googleEmail: cleanEmail,
      );
      await activateCurrentConnections(allowPairing: false);
      return;
    }

    // Explicit Drive Save is the pairing event. This is important: changing
    // Firebase alone while an old school's Drive is still saved can NEVER
    // pair the two sources or move data between them.
    final profile = await _resolveProfile(
      googleUrlOverride: cleanUrl,
      allowPairing: true,
    );

    if (profile.blocked) {
      throw StateError(profile.message);
    }

    await WindowsExternalConnections.save(
      googleScriptUrl: cleanUrl,
      googleEmail: cleanEmail,
    );

    await _applyProfile(
      profile.copyWith(googleEmail: cleanEmail),
      seedGoogleConfig: false,
    );

    // Save the currently selected Drive link inside THIS isolated profile.
    // Normal tracking is intentional so the same school's website can learn
    // the current Apps Script URL through Firestore.
    await FirebaseFirestore.instance
        .collection('school_config')
        .doc('google_drive_account')
        .set(<String, dynamic>{
          'email': cleanEmail,
          'scriptUrl': cleanUrl,
          'status': 'connected',
          'linkedAt': FieldValue.serverTimestamp(),
        }, const SetOptions(merge: true));

    scheduleSoon(delay: const Duration(milliseconds: 250));
  }

  Future<void> disconnectGoogle() async {
    await WindowsExternalConnections.save(googleScriptUrl: '', googleEmail: '');

    await activateCurrentConnections(allowPairing: false);

    // Delete only in the newly active Firebase-only/unbound profile. The old
    // Drive profile remains preserved so reconnecting its link restores its
    // own cache, never another school's cache.
    final ref = FirebaseFirestore.instance
        .collection('school_config')
        .doc('google_drive_account');
    final existing = await ref.get();
    if (existing.exists) {
      await ref.delete();
    }

    scheduleSoon(delay: const Duration(milliseconds: 250));
  }

  Future<void> activateCurrentConnections({required bool allowPairing}) async {
    if (_resetPaused) return;
    _activating++;
    try {
      while (_syncing) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final profile = await _resolveProfile(allowPairing: allowPairing);
      if (_resetPaused) return;

      await _applyProfile(profile, seedGoogleConfig: !profile.blocked);

      if (!profile.blocked) {
        scheduleSoon(delay: const Duration(milliseconds: 350));
      }
    } finally {
      _activating--;
    }
  }

  Future<void> pauseForAppReset() async {
    _resetPaused = true;
    _schedule.stop();
    _debounceTimer?.cancel();
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (_syncing || _activating > 0) {
      if (DateTime.now().isAfter(deadline)) {
        _resetPaused = false;
        throw StateError(
          'School sync is still finishing. Retry reset shortly.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    WindowsLocalFirestoreSyncControl.onTrackedMutation = null;
    WindowsFirebaseRemote.onConnectionChanged = null;
    WindowsBackendBridge.onRemoteAvailable = null;
    WindowsBackendBridge.onLocalDocumentCommitted = null;
    WidgetsBinding.instance.removeObserver(this);
    _initialized = false;
    _activeFirebaseProject = '';
    _activeGoogleUrl = '';
    _activeSchoolSyncId = '';
    _syncBlocked = true;
  }

  Future<_ResolvedSyncProfile> _resolveProfile({
    String? googleUrlOverride,
    bool allowPairing = false,
  }) async {
    final central = await CentralSchoolCloud.saved();
    if (central.isNotEmpty) {
      return _ResolvedSyncProfile(
        profileId: 'central_${central['schoolId']}',
        schoolSyncId: central['schoolId'],
        firebaseProjectId: central['projectId'],
        googleUrl: await WindowsExternalConnections.googleScriptUrl(),
        googleEmail: central['email'],
        googleBackendId: central['folderId'],
        blocked: false,
        message: '',
      );
    }
    final firebaseStatus = await WindowsFirebaseRemote.status();
    final projectId = firebaseStatus.authenticated
        ? firebaseStatus.projectId.trim()
        : '';

    final savedConnections = await WindowsExternalConnections.load();
    final googleUrl =
        (googleUrlOverride ??
                savedConnections['googleScriptUrl']?.toString() ??
                '')
            .trim();
    final googleEmail =
        savedConnections['googleEmail']?.toString().trim() ?? '';

    // REMOTE SCHOOL GATE:
    // Firebase + Google are one pair. A single connection is never allowed
    // to populate the Windows school UI. If Local Storage is ON, only the
    // independent local_device profile is visible; if OFF, the app uses an
    // empty volatile profile and writes nothing to disk.
    if (projectId.isEmpty || googleUrl.isEmpty) {
      final localEnabled = await WindowsRuntimeFlags.localStorageEnabled();
      return _ResolvedSyncProfile(
        profileId: localEnabled ? 'local_device' : 'remote_gate_empty',
        schoolSyncId: '',
        firebaseProjectId: '',
        googleUrl: '',
        googleEmail: '',
        googleBackendId: '',
        blocked: true,
        message: localEnabled
            ? 'Remote school data hidden: Firebase + Google dono connect karein. Local Data ON hai.'
            : 'Remote school data hidden: Firebase + Google dono connect karein. Local Data OFF hai.',
      );
    }

    String idToken = '';
    String firebaseSyncId = '';

    if (projectId.isNotEmpty) {
      idToken = await WindowsFirebaseRemote.freshIdToken();
      firebaseSyncId = await _firebaseSyncId(
        projectId: projectId,
        idToken: idToken,
      );
    }

    _GoogleIdentity? googleIdentity;
    if (googleUrl.isNotEmpty) {
      googleIdentity = await _googleIdentity(googleUrl);
    }

    var schoolSyncId = '';

    if (projectId.isNotEmpty && googleUrl.isNotEmpty) {
      var driveSyncId = googleIdentity?.schoolSyncId ?? '';

      if (firebaseSyncId.isNotEmpty &&
          driveSyncId.isNotEmpty &&
          firebaseSyncId != driveSyncId) {
        return _blockedProfile(
          projectId: projectId,
          googleUrl: googleUrl,
          googleEmail: googleEmail,
          message: 'School isolation BLOCKED: Firebase aur Google Drive alag school identity ke hain. Koi data sync nahi hua.',
        );
      }

      if (!allowPairing && (firebaseSyncId.isEmpty || driveSyncId.isEmpty)) {
        return _blockedProfile(
          projectId: projectId,
          googleUrl: googleUrl,
          googleEmail: googleEmail,
          message: 'School isolation pending: current Firebase + Drive pair verify/claim nahi hua. Advanced Settings me correct Drive link Save karein.',
        );
      }

      if (allowPairing) {
        if (firebaseSyncId.isEmpty && driveSyncId.isEmpty) {
          schoolSyncId = _newSchoolSyncId();
          await _claimFirebaseSyncId(
            projectId: projectId,
            idToken: idToken,
            schoolSyncId: schoolSyncId,
          );
          googleIdentity = await _claimGoogleSyncId(googleUrl, schoolSyncId);
          firebaseSyncId = schoolSyncId;
          driveSyncId = schoolSyncId;
        } else if (firebaseSyncId.isNotEmpty && driveSyncId.isEmpty) {
          schoolSyncId = firebaseSyncId;
          googleIdentity = await _claimGoogleSyncId(googleUrl, schoolSyncId);
          driveSyncId = schoolSyncId;
        } else if (firebaseSyncId.isEmpty && driveSyncId.isNotEmpty) {
          schoolSyncId = driveSyncId;
          await _claimFirebaseSyncId(
            projectId: projectId,
            idToken: idToken,
            schoolSyncId: schoolSyncId,
          );
          firebaseSyncId = schoolSyncId;
        } else {
          schoolSyncId = firebaseSyncId;
        }
      } else {
        schoolSyncId = firebaseSyncId;
      }

      if (firebaseSyncId != driveSyncId || schoolSyncId.isEmpty) {
        return _blockedProfile(
          projectId: projectId,
          googleUrl: googleUrl,
          googleEmail: googleEmail,
          message: 'School isolation verify nahi hua. Koi cross-source sync nahi hua.',
        );
      }
    } else if (projectId.isNotEmpty) {
      // Firebase-only mode is safe because there is no second source to mix.
      schoolSyncId = firebaseSyncId;
    } else if (googleUrl.isNotEmpty) {
      // Drive-only mode is also safe. URL/backend identity becomes its own
      // isolated monitor profile.
      schoolSyncId = googleIdentity?.schoolSyncId ?? '';
    }

    final backendId = googleIdentity?.backendInstanceId ?? '';
    final profileId = _profileId(
      schoolSyncId: schoolSyncId,
      projectId: projectId,
      googleIdentity: backendId.isNotEmpty ? backendId : googleUrl,
    );

    return _ResolvedSyncProfile(
      profileId: profileId,
      schoolSyncId: schoolSyncId,
      firebaseProjectId: projectId,
      googleUrl: googleUrl,
      googleEmail: googleEmail,
      googleBackendId: backendId,
      blocked: false,
      message: '',
    );
  }

  _ResolvedSyncProfile _blockedProfile({
    required String projectId,
    required String googleUrl,
    required String googleEmail,
    required String message,
  }) {
    return _ResolvedSyncProfile(
      profileId: _profileId(
        schoolSyncId: 'BLOCKED',
        projectId: projectId,
        googleIdentity: googleUrl,
      ),
      schoolSyncId: '',
      firebaseProjectId: projectId,
      googleUrl: googleUrl,
      googleEmail: googleEmail,
      googleBackendId: '',
      blocked: true,
      message: message,
    );
  }

  Future<void> _applyProfile(
    _ResolvedSyncProfile profile, {
    required bool seedGoogleConfig,
  }) async {
    if (_activeProfileId != profile.profileId) {
      _lastPull = null;
      _failures = 0;
      _nextRetry = null;
      recoveryDecision = null;
      recoveryHistory.clear();
      lastSuccessfulSync = null;
      lastVerifiedCheckpoint = null;
      metrics.clear();
      _samples.clear();
      metrics.addAll({
        'recordReadRequests': 0,
        'recordWriteRequests': 0,
        'storageChecks': 0,
        'reconciliationMicros': 0,
      });
    }
    _syncBlocked = profile.blocked;
    _activeProfileId = profile.profileId;
    _activeSchoolSyncId = profile.schoolSyncId;
    _activeFirebaseProject = profile.firebaseProjectId;
    _activeGoogleUrl = profile.googleUrl;
    lastError = profile.blocked ? profile.message : null;

    await FirebaseFirestore.instance.switchProfile(
      profile.profileId,
      identity: <String, dynamic>{
        'schoolSyncId': profile.schoolSyncId,
        'firebaseProjectId': profile.firebaseProjectId,
        if (profile.profileId.startsWith('central_'))
          'schoolId': profile.schoolSyncId,
        'googleScriptUrl': profile.googleUrl,
        'googleBackendId': profile.googleBackendId,
        'blocked': profile.blocked,
      },
    );

    windows_html.setSchoolStorageNamespace(profile.profileId);
    final preferences = (await FirebaseFirestore.instance.collection('_windows_sync_status').doc('settings').get()).data();
    automaticSyncEnabled = preferences?['automaticSync'] != false;
    final storedHistory = (await FirebaseFirestore.instance.collection('_windows_sync_status').doc('recovery').get()).data()?['events'];
    recoveryHistory.clear();
    if (storedHistory is List) {
      for (final event in storedHistory.take(100)) {
        if (event is Map && SyncFailureKind.values.any((kind) => kind.name == event['category']) &&
            {'retained_for_retry', 'retained_for_review'}.contains(event['outcome']) &&
            event['atUtc'] is String && DateTime.tryParse(event['atUtc'] as String) != null && event['attempt'] is num) {
          recoveryHistory.add({'atUtc': event['atUtc'], 'category': event['category'],
            'outcome': event['outcome'], 'attempt': (event['attempt'] as num).toInt()});
        }
      }
    }
    final savedStatus =
        (await FirebaseFirestore.instance
                .collection('_windows_sync_status')
                .doc('last')
                .get())
            .data();
    if (savedStatus?['successfulAt'] is num)
      lastSuccessfulSync = DateTime.fromMillisecondsSinceEpoch(
        (savedStatus!['successfulAt'] as num).toInt(),
      );
    if (savedStatus?['checkpointAt'] is num) lastVerifiedCheckpoint = DateTime.fromMillisecondsSinceEpoch((savedStatus!['checkpointAt'] as num).toInt());
    await refreshDetails();

    if (seedGoogleConfig && profile.googleUrl.isNotEmpty) {
      await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
        () => FirebaseFirestore.instance
            .collection('school_config')
            .doc('google_drive_account')
            .set(<String, dynamic>{
              'email': profile.googleEmail,
              'scriptUrl': profile.googleUrl,
              'status': 'connected',
            }, const SetOptions(merge: true)),
      );
    }
  }

  Future<String> _firebaseSyncId({
    required String projectId,
    required String idToken,
  }) async {
    final schoolConfig = await WindowsFirebaseRemote.readCollection(
      projectId: projectId,
      idToken: idToken,
      collection: 'school_config',
    );

    return schoolConfig['windows_sync_identity']?['schoolSyncId']
            ?.toString()
            .trim() ??
        '';
  }

  Future<void> _claimFirebaseSyncId({
    required String projectId,
    required String idToken,
    required String schoolSyncId,
  }) async {
    final current = await _firebaseSyncId(
      projectId: projectId,
      idToken: idToken,
    );

    if (current.isNotEmpty && current != schoolSyncId) {
      throw StateError('Firebase already dusre School Sync ID se locked hai.');
    }

    if (current == schoolSyncId) return;

    await WindowsFirebaseRemote.writeDocument(
      projectId: projectId,
      idToken: idToken,
      collection: 'school_config',
      documentId: 'windows_sync_identity',
      data: <String, dynamic>{
        'schoolSyncId': schoolSyncId,
        'source': 'windows-master-sync',
        'updatedAtMs': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
    );
  }

  Future<_GoogleIdentity> _googleIdentity(String scriptUrl) async {
    final result = await _googleDirectPost(scriptUrl, const <String, dynamic>{
      'action': 'sync_identity_get',
    });

    return _GoogleIdentity(
      schoolSyncId: result['schoolSyncId']?.toString().trim() ?? '',
      backendInstanceId: result['backendInstanceId']?.toString().trim() ?? '',
    );
  }

  Future<_GoogleIdentity> _claimGoogleSyncId(
    String scriptUrl,
    String schoolSyncId,
  ) async {
    final result = await _googleDirectPost(scriptUrl, <String, dynamic>{
      'action': 'sync_identity_claim',
      'schoolSyncId': schoolSyncId,
    });

    final claimed = result['schoolSyncId']?.toString().trim() ?? '';
    if (claimed != schoolSyncId) {
      throw StateError('Google Drive School Sync ID claim verify nahi hua.');
    }

    return _GoogleIdentity(
      schoolSyncId: claimed,
      backendInstanceId: result['backendInstanceId']?.toString().trim() ?? '',
    );
  }

  Future<Map<String, dynamic>> _googleDirectPost(
    String scriptUrl,
    Map<String, dynamic> body,
  ) async {
    final status = await WindowsFirebaseRemote.status();
    if (!status.authenticated || status.projectId.isEmpty) {
      throw StateError('Connect this school Firebase administrator first.');
    }
    final proof = <String, dynamic>{
      ...body,
      'schoolProjectId': status.projectId,
      'schoolAdminIdToken': await WindowsFirebaseRemote.freshIdToken(),
    };
    final client = http.Client();
    try {
      Future<http.Response> sendPost(Uri target) async {
        requireSchoolBackendUri(target);
        final request = http.Request('POST', target)
          ..headers.addAll(const <String, String>{
            'Content-Type': 'text/plain;charset=utf-8',
            'Cache-Control': 'no-cache',
          })
          ..body = jsonEncode(proof)
          ..followRedirects = false;
        final streamed = await client.send(request);
        return http.Response.fromStream(streamed);
      }

      Future<http.Response> sendGet(Uri target) async {
        requireSchoolBackendUri(target);
        final request = http.Request('GET', target)
          ..headers.addAll(const <String, String>{
            'Accept': 'application/json,text/plain,*/*',
            'Cache-Control': 'no-cache',
          })
          ..followRedirects = false;
        final streamed = await client.send(request);
        return http.Response.fromStream(streamed);
      }

      var current = Uri.parse(scriptUrl);
      var response = await sendPost(current)
          .timeout(const Duration(seconds: 30));

      for (var redirectCount = 0; redirectCount < 8; redirectCount++) {
        final code = response.statusCode;
        final isRedirect =
            code == 301 ||
            code == 302 ||
            code == 303 ||
            code == 307 ||
            code == 308;
        if (!isRedirect) break;

        final location = response.headers['location']?.trim() ?? '';
        if (location.isEmpty) break;

        current = current.resolve(location);
        response = (code == 301 || code == 302 || code == 303)
            ? await sendGet(current).timeout(const Duration(seconds: 30))
            : await sendPost(current).timeout(const Duration(seconds: 30));
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Google sync identity HTTP ${response.statusCode}.');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw StateError('Google sync identity JSON invalid hai.');
      }

      final result = Map<String, dynamic>.from(decoded);
      if (result['success'] != true) {
        throw StateError(
          result['message']?.toString() ??
              result['error']?.toString() ??
              'Google sync identity request fail hua.',
        );
      }

      if (result['projectId'] != status.projectId) {
        throw StateError(
          'Google backend belongs to another school or needs the secure backend update.',
        );
      }
      return result;
    } finally {
      client.close();
    }
  }

  String _newSchoolSyncId() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    final token = base64Url.encode(bytes).replaceAll('=', '');
    return 'VS-${DateTime.now().toUtc().millisecondsSinceEpoch}-$token';
  }

  String _profileId({
    required String schoolSyncId,
    required String projectId,
    required String googleIdentity,
  }) {
    final raw = '$schoolSyncId\n$projectId\n$googleIdentity';
    final a = _fnv32(raw, 0x811C9DC5);
    final b = _fnv32(
      String.fromCharCodes(raw.runes.toList().reversed),
      0x9E3779B9,
    );
    return 'p_${a.toRadixString(16).padLeft(8, '0')}'
        '${b.toRadixString(16).padLeft(8, '0')}';
  }

  int _fnv32(String value, int seed) {
    var hash = seed & 0xFFFFFFFF;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  Future<void> prepareDriveBackup() async {
    final profile = FirebaseFirestore.instance.activeProfileId;
    final until = DateTime.now().add(const Duration(seconds: 90));
    while (_syncing || _activating > 0) {
      if (DateTime.now().isAfter(until))
        throw StateError('School sync is busy; retry Drive backup.');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_syncBlocked ||
        _resetPaused ||
        FirebaseFirestore.instance.activeProfileId != profile)
      throw StateError('Resolve school sync before creating a Drive backup.');
    await syncNow();
    if (lastError != null ||
        FirebaseFirestore.instance.activeProfileId != profile)
      throw StateError('School sync did not complete; retry Drive backup.');
  }

  Future<void> syncNow() async {
    if (_syncing || _activating > 0 || _syncBlocked || _resetPaused) return;

    _syncing = true;
    state.value = SchoolCloudState.syncing;
    final syncOrigin = _activeProfileId;
    final watch = Stopwatch()..start();
    bool completedReconciliation = false;
    lastError = null;
    recoveryDecision = null;

    try {
      final central = await CentralSchoolCloud.saved();
      if (central.isNotEmpty && central['schoolId'] != _activeSchoolSyncId) {
        unawaited(activateCurrentConnections(allowPairing: false));
        return;
      }
      if (central['managed'] == true) {
        ManagedSchoolSession.verifyBuildEndpoint(central['endpoint']?.toString()??'');
        if (SchoolCloudEngine.instance.identity != null &&
            !SchoolCloudEngine.instance.canOpen)
          throw StateError('School access requires verification.');
        if (central['storageReady'] != true)
          throw StateError(
            'School Drive connection pending. Local data retained.',
          );
        final protocolIdentity = jsonEncode([_activeProfileId, _activeSchoolSyncId, _activeGoogleUrl, central['scriptUrl']]);
        if (_manualSync || _checkpointDue || _protocolIdentity != protocolIdentity ||
            _protocolVerifiedAt == null || DateTime.now().difference(_protocolVerifiedAt!) >= const Duration(minutes: 5)) {
        final health = await ManagedSchoolSession.callForSchool(
          _activeSchoolSyncId,
          'managed/storage/check',
          {},
        );
        metrics['storageChecks'] = metrics['storageChecks']! + 1;
        if (health['recordSyncVersion'] != 2 ||
            health['brokerRecordSyncVersion'] != 2)
          throw StateError(
            'School sync protocol mismatch: broker ${health['brokerRecordSyncVersion'] ?? 'unknown'}, school Script ${health['recordSyncVersion'] ?? 'unknown'}; required 2/2. Update the existing school Script deployment to the supplied bundle version; keep School ID/root/secret and /exec URL. Pending data retained.',
          );
          _deltaBatchSupported = health['recordDeltaBatchVersion'] == 1;
          _protocolIdentity = protocolIdentity;
          _protocolVerifiedAt = DateTime.now();
        }
        try {
          await _pushManagedOutbox();
        } catch (e) {
          if (!isRecordSyncConflict(e)) rethrow;
        }
        await WindowsDocumentTemplates.publishChangedIdCards();
        // ID preparation may create credential metadata; drain only those new
        // durable operations before uploading their published files.
        try { await _pushManagedOutbox(); }
        catch (e) { if (!isRecordSyncConflict(e)) rethrow; }
        try {
          await WindowsBackendBridge.flushDocumentPending();
        } catch (e) {
          if (!e.toString().toLowerCase().contains('conflict')) rethrow;
        }
        if (_lastPull == null ||
            DateTime.now().difference(_lastPull!) >=
                reconciliationInterval ||
            _manualSync || _checkpointDue) {
          await _pullManagedChanges();
          _lastPull = DateTime.now();
          completedReconciliation = true;
        }
        await refreshDetails();
        if ((details.value['needsAttention'] as num? ?? 0) > 0)
          throw StateError(
            'Items need conflict review; both versions retained.',
          );
        if ((details.value['pending'] as num? ?? 0) > 0) {
          _rerunRequested = true;
          state.value = SchoolCloudState.syncPending;
          return;
        }
        await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
          () => FirebaseFirestore.instance
              .collection('_windows_sync_status')
              .doc('last')
              .set({'successfulAt': DateTime.now().millisecondsSinceEpoch,
                if (completedReconciliation) 'checkpointAt': DateTime.now().millisecondsSinceEpoch,
                if (!completedReconciliation && lastVerifiedCheckpoint != null) 'checkpointAt': lastVerifiedCheckpoint!.millisecondsSinceEpoch}),
        );
        lastSuccessfulSync = DateTime.now();
        if (completedReconciliation) lastVerifiedCheckpoint = lastSuccessfulSync;
        _failures = 0;
        _nextRetry = null;
        state.value = SchoolCloudState.synced;
        return;
      }
      final firebaseStatus = await WindowsFirebaseRemote.status();

      String? projectId;
      String? idToken;

      if (firebaseStatus.authenticated &&
          firebaseStatus.projectId.trim().isNotEmpty) {
        projectId = firebaseStatus.projectId.trim();
        idToken = await WindowsFirebaseRemote.freshIdToken();

        // Never sync into a profile that no longer matches the live Firebase
        // connection. This protects against a connection switch racing a timer.
        if (_activeFirebaseProject.isNotEmpty &&
            projectId != _activeFirebaseProject) {
          unawaited(activateCurrentConnections(allowPairing: false));
          return;
        }

        await _pushFirebaseOutbox(projectId: projectId, idToken: idToken);
        await _pullFirebase(projectId: projectId, idToken: idToken);
      }

      final scriptUrl = await _googleScriptUrl();
      if (_activeGoogleUrl.isNotEmpty && scriptUrl != _activeGoogleUrl) {
        unawaited(activateCurrentConnections(allowPairing: false));
        return;
      }

      if (scriptUrl.isNotEmpty && central.isEmpty) {
        await _pullGoogleSnapshot(scriptUrl);
      }

      if (scriptUrl.isNotEmpty && central.isEmpty) {
        await WindowsBackendBridge.flushPending();
      }

      if (central['managed'] == true)
        await WindowsBackendBridge.flushDocumentPending();

      lastSuccessfulSync = DateTime.now();
      if (_activeProfileId == syncOrigin) state.value = SchoolCloudState.synced;
    } catch (e) {
      if (_activeProfileId != syncOrigin) return;
      lastError = e.toString();
      recoveryDecision = windowsSyncRecovery(e);
      _failures++;
      _nextRetry = recoveryDecision!.retry ? DateTime.now().add(recoveryDecision!.delay(_failures)) : null;
      if (recoveryHistory.length >= 100) recoveryHistory.removeAt(0);
      recoveryHistory.add({'atUtc': DateTime.now().toUtc().toIso8601String(),
        'category': recoveryDecision!.kind.name, 'attempt': _failures,
        'outcome': recoveryDecision!.retry ? 'retained_for_retry' : 'retained_for_review'});
      try {
        await FirebaseFirestore.instance.collection('_windows_sync_status').doc('recovery').set({'events': List<Map<String, dynamic>>.from(recoveryHistory)});
      } catch (_) { /* A failed diagnostic write never removes the durable queue. */ }
      if (_activeProfileId == syncOrigin)
        state.value = SchoolCloudState.syncError;
    } finally {
      watch.stop();
      metrics['reconciliationMicros'] = watch.elapsedMicroseconds;
      _syncing = false;
      await refreshDetails();
      if ((lastError != null && recoveryDecision?.retry == true && _failures <= 5) || _rerunRequested) {
        final independentMutation = _rerunRequested && recoveryDecision?.independentRecords == true;
        _rerunRequested = false;
        scheduleSoon(localMutation: independentMutation, delay: lastError == null ? const Duration(milliseconds: 250) : schoolRetryDelay(_failures));
      }
    }
  }

  bool _manualSync = false;
  Future<void> setAutomaticSync(bool enabled) async {
    final origin = _activeProfileId;
    await FirebaseFirestore.instance.collection('_windows_sync_status').doc('settings').set({'automaticSync': enabled});
    if (_activeProfileId != origin) return;
    automaticSyncEnabled = enabled;
    if (!enabled) { _debounceTimer?.cancel(); _rerunRequested = false; }
    else scheduleSoon();
    await refreshDetails();
  }
  bool _rerunRequested = false;
  Future<void> requestSync() async {
    _debounceTimer?.cancel();
    _nextRetry = null;
    recoveryDecision = null;
    _failures = 0;
    _manualSync = true;
    try {
      await SchoolCloudEngine.instance.verify();
      await syncNow();
    } finally {
      _manualSync = false;
    }
  }

  Future<void> _pushManagedOutbox() => WindowsPendingSchoolSync.flush(
    profileId: _activeProfileId,
    send: (c, id, op, data) async {},
    sendVersioned: (item) async {
      metrics['recordWriteRequests'] = metrics['recordWriteRequests']! + 1;
      final queuedAt = item['queuedAt'];
      final queuedMillis = queuedAt is Timestamp ? queuedAt.millisecondsSinceEpoch
          : queuedAt is num ? queuedAt.toInt() : null;
      if (queuedMillis != null) metrics['lastQueueWaitMillis'] =
          (DateTime.now().millisecondsSinceEpoch - queuedMillis).clamp(0, 1 << 53).toInt();
      final watch = Stopwatch()..start();
      final reply = await WindowsFirebaseRemote.syncManagedRecord(
        item,
        _activeSchoolSyncId,
      );
      watch.stop();
      metrics['lastRecordAckMicros'] = watch.elapsedMicroseconds;
      _sample('cloudAckMicros', watch.elapsedMicroseconds);
      if (queuedMillis != null) _sample('queueWaitMillis', metrics['lastQueueWaitMillis']!);
      final timing = reply['syncTiming'];
      if (timing is Map && timing['scriptRoundTripMillis'] is num) {
        metrics['lastScriptRoundTripMillis'] = (timing['scriptRoundTripMillis'] as num).toInt();
        _sample('scriptRoundTripMillis', metrics['lastScriptRoundTripMillis']!);
      }
      return reply['recordRevision'] as String;
    },
  );

  @visibleForTesting
  Future<void> reconcileManagedCacheForTesting(String school,
      Future<Map<String, dynamic>> Function(Map<String, String>) read) =>
      _pullManagedChanges(schoolOverride: school, batchReader: read, verifyInventory: true);

  Future<void> _pullManagedChanges({String? schoolOverride,
      Future<Map<String, dynamic>> Function(Map<String, String>)? batchReader,
      bool? verifyInventory}) async {
    final db = FirebaseFirestore.instance,
        origin = db.activeProfileId,
        school = schoolOverride ?? _activeSchoolSyncId;
    if (db.activeProfileIdentity['schoolSyncId'] != school) throw StateError('School identity changed before recovery.');
    final audit = verifyInventory ?? (_manualSync || _checkpointDue);
    final pendingAtRead = (await db.collection('_windows_firebase_outbox').get()).docs;
    final revisions = <String, String>{};
    for (final collection in _firebaseCollections.where((c) => c != 'backups')) {
      final prior = (await db.collection('_windows_sync_manifest').doc(_manifestId('managed', collection)).get()).data();
      revisions[collection] = audit ? managedRecoveryRevision(prior,
          (await db.collection(collection).get()).docs.map((d) => d.id).toSet(),
          {...pendingAtRead.where((d) => d.data()['collection'] == collection).map((d) => d.data()['documentId']).whereType<String>(), if (collection == 'school_config') 'google_drive_account'})
          : prior?['revision']?.toString() ?? '';
    }
    if (db.activeProfileId != origin) throw StateError('School changed during recovery inventory.');
    Map<String,dynamic>? batch;
    if (_deltaBatchSupported || batchReader != null) {
      metrics['recordReadRequests']=metrics['recordReadRequests']!+1;
      batch=await (batchReader != null ? batchReader(revisions) : WindowsFirebaseRemote.readManagedBatch(school,revisions));
      if(db.activeProfileId!=origin)throw StateError('School changed during reconciliation.');
    }
    for (final collection in _firebaseCollections.where(
      (c) => c != 'backups',
    )) {
      // A new durable notice must not wait for every startup collection read.
      if (_rerunRequested) {
        _rerunRequested = false;
        await _pushManagedOutbox();
      }
      final manifest = db
          .collection('_windows_sync_manifest')
          .doc(_manifestId('managed', collection));
      if(batch==null)metrics['recordReadRequests'] = metrics['recordReadRequests']! + 1;
      final result = batch!=null?Map<String,dynamic>.from(batch[collection] as Map):await WindowsFirebaseRemote.readManagedChanges(
        school,collection,revisions[collection] ?? '',
      );
      if (db.activeProfileId != origin)
        throw StateError('School changed during reconciliation.');
      if (result['syncProtocol'] != 2 || result['collectionRevision'] is! String || result['records'] is! Map) throw StateError('Invalid authoritative recovery response.');
      if (result['unchanged'] == true) continue;
      final records = Map<String, dynamic>.from(result['records'] as Map);
      // Validate the whole response before recording any inventory or applying it.
      if (records.values.any((value) => value is! Map || value['schoolId'] != school))
        throw StateError('Foreign or invalid school inventory rejected.');
      final downloadable = records.entries.where((entry) => collection != 'school_config' || entry.key != 'google_drive_account').length;
      final progress = db.collection('_windows_sync_downloads').doc(collection);
      var remaining = downloadable, verifiedDownloads = 0, blockedDownloads = 0;
      await progress.set({'schoolId':school,'collection':collection,
        'collectionRevision':result['collectionRevision'],'observedAt':DateTime.now().millisecondsSinceEpoch,
        'inventoryScope':'records_only','state':'downloading','remaining':remaining,
        'verified':0,'blocked':0});
      final pending =
          (await db.collection('_windows_firebase_outbox').get()).docs;
      if (db.activeProfileId != origin)
        throw StateError('School changed during reconciliation.');
      for (final entry in records.entries) {
        if (db.activeProfileId != origin)
          throw StateError('School changed during reconciliation.');
        final data = Map<String, dynamic>.from(entry.value as Map);
        if (data['schoolId'] != school)
          throw StateError('Foreign school manifest rejected.');
        if (collection == 'school_config' &&
            entry.key == 'google_drive_account')
          continue;
        final queued = pending
            .where(
              (d) =>
                  d.data()['collection'] == collection &&
                  d.data()['documentId'] == entry.key,
            )
            .toList();
        if (queued.isNotEmpty &&
            (data['_syncRevision'] ?? '') !=
                (queued.first.data()['baseCloudRevision'] ?? '')) {
          final ref = db.collection(collection).doc(entry.key);
          final batch = db.batch();
          batch.set(
            db.collection('_windows_sync_conflicts').doc('${queued.first.data()['operationId'] ?? queued.first.id}-${sha256.convert(utf8.encode(data['_syncRevision']?.toString() ?? ''))}'),
            {
              'schoolId': school,
              'collection': collection,
              'documentId': entry.key,
              'local': (await ref.get()).data(),
              'remote': data,
              'detectedAt': DateTime.now().millisecondsSinceEpoch,
            },
          );
          batch.set(queued.first.reference, {
            'syncState': 'conflict',
            'lastError': 'Record revision conflict',
          }, const SetOptions(merge: true));
          await batch.commit();
        }
        await db.applySyncedDocument(
          db.collection(collection).doc(entry.key),
          data['_syncDeleted'] == true ? null : data,
        );
        if (await db.syncedDocumentMatches(db.collection(collection).doc(entry.key),
            data['_syncDeleted'] == true ? null : data)) {
          verifiedDownloads++;
          remaining--;
        } else {
          // A local edit/conflict is retained. It is not a successful download.
          blockedDownloads++;
        }
        await progress.set({'remaining':remaining,'verified':verifiedDownloads,'blocked':blockedDownloads,
          if (verifiedDownloads > 0) 'lastVerifiedLocalReadbackAt':DateTime.now().millisecondsSinceEpoch},
          const SetOptions(merge:true));
      }
      // Missing IDs are not deletions: only explicit server tombstones delete.
      if (db.activeProfileId != origin)
        throw StateError('School changed during reconciliation.');
      await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
        () => manifest.set({
          'revision': result['collectionRevision'],
          'collection': collection,
          'ids': records.keys.toList(),
          'deletedIds': records.entries
              .where((e) => (e.value as Map)['_syncDeleted'] == true)
              .map((e) => e.key)
              .toList(),
        }),
      );
      await progress.set({'state':remaining == 0 ? 'verified' : 'needsReview',
        'finishedAt':DateTime.now().millisecondsSinceEpoch},const SetOptions(merge:true));
    }
  }

  Future<void> _pullFirebase({
    required String projectId,
    required String idToken,
  }) async {
    final pullProfile = FirebaseFirestore.instance.activeProfileId;
    final pending = await _firebasePendingKeys();

    for (final collection in _firebaseCollections) {
      if (projectId != platformProjectId &&
          _firebaseCollections.indexOf(collection) >= 12)
        continue;
      if (FirebaseFirestore.instance.activeProfileId != pullProfile)
        throw StateError('School profile changed during sync.');
      final remote = await WindowsFirebaseRemote.readCollection(
        projectId: projectId,
        idToken: idToken,
        collection: collection,
      );

      if (FirebaseFirestore.instance.activeProfileId != pullProfile)
        throw StateError('School profile changed during sync.');
      final localSnapshot = await FirebaseFirestore.instance
          .collection(collection)
          .get();

      final local = <String, Map<String, dynamic>>{
        for (final doc in localSnapshot.docs)
          doc.id: Map<String, dynamic>.from(doc.data()),
      };

      final manifestRef = FirebaseFirestore.instance
          .collection('_windows_sync_manifest')
          .doc(_manifestId('firebase', collection));

      final manifest = await manifestRef.get();

      final oldIds = _stringSet(manifest.data()?['ids']);

      final remoteIds = remote.keys.toSet();

      for (final entry in remote.entries) {
        if (FirebaseFirestore.instance.activeProfileId != pullProfile)
          throw StateError('School profile changed during sync.');
        // Windows connection selector is authoritative for its own Drive URL.
        // A stale Firestore copy must never switch the active backend behind
        // the user's back or revive another school's Drive link.
        if (collection == 'school_config' &&
            entry.key == 'google_drive_account') {
          continue;
        }

        final key = _pendingKey(collection, entry.key);

        final localData = local[entry.key];

        if (pending.contains(key)) {
          // Local unsynced change wins until its
          // outbox has been pushed.
          continue;
        }

        if (localData == null) {
          await _remoteSetLocal(collection, entry.key, entry.value);
          continue;
        }

        final localMs = _modifiedMillis(localData);
        final remoteMs = _modifiedMillis(entry.value);

        if (localMs > 0 && remoteMs > 0 && localMs > remoteMs) {
          // Local is clearly newer. Re-writing the
          // same document records it in the outbox.
          await FirebaseFirestore.instance
              .collection(collection)
              .doc(entry.key)
              .set(localData);
          pending.add(key);
          continue;
        }

        final merged = <String, dynamic>{...localData, ...entry.value};

        await _remoteSetLocal(collection, entry.key, merged);
      }

      // A document that existed on Firebase in an
      // earlier successful snapshot but is absent now
      // is a confirmed remote deletion.
      final deletedRemote = oldIds.difference(remoteIds);

      for (final id in deletedRemote) {
        if (collection == 'school_config' && id == 'google_drive_account') {
          continue;
        }

        final key = _pendingKey(collection, id);

        if (pending.contains(key)) {
          continue;
        }

        await _remoteDeleteLocal(collection, id);
      }

      // Existing local-only documents on the first
      // sync must not be lost. Queue them to Firebase.
      for (final entry in local.entries) {
        if (remoteIds.contains(entry.key) || oldIds.contains(entry.key)) {
          continue;
        }

        final key = _pendingKey(collection, entry.key);

        if (pending.contains(key)) {
          continue;
        }

        await FirebaseFirestore.instance
            .collection(collection)
            .doc(entry.key)
            .set(entry.value);

        pending.add(key);
      }

      await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
        () => manifestRef.set(<String, dynamic>{
          'source': 'firebase',
          'collection': collection,
          'ids': remoteIds.toList()..sort(),
          'updatedAt': FieldValue.serverTimestamp(),
        }),
      );
    }
  }

  Future<Set<String>> _firebasePendingKeys() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('_windows_firebase_outbox')
        .get();

    return snapshot.docs
        .map((doc) {
          final data = doc.data();
          return _pendingKey(
            data['collection']?.toString() ?? '',
            data['documentId']?.toString() ?? '',
          );
        })
        .where((value) {
          return !value.startsWith('\u0000');
        })
        .toSet();
  }

  Future<void> _pushFirebaseOutbox({
    required String projectId,
    required String idToken,
  }) => WindowsPendingSchoolSync.flush(
    profileId: FirebaseFirestore.instance.activeProfileId,
    send: (collection, id, operation, data) async {
      if (operation == 'delete') {
        await WindowsFirebaseRemote.deleteDocument(
          projectId: projectId,
          idToken: idToken,
          collection: collection,
          documentId: id,
        );
      } else {
        await WindowsFirebaseRemote.writeDocument(
          projectId: projectId,
          idToken: idToken,
          collection: collection,
          documentId: id,
          data: data!,
        );
      }
    },
  );

  Future<String> _googleScriptUrl() {
    return WindowsExternalConnections.googleScriptUrl();
  }

  Future<void> _pullGoogleSnapshot(String scriptUrl) async {
    final response = await WindowsBackendBridge.post(
      Uri.parse(scriptUrl),
      headers: const <String, String>{
        'Content-Type': 'text/plain;charset=utf-8',
      },
      body: jsonEncode(const <String, dynamic>{
        'action': 'windows_sync_snapshot',
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return;
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map) {
      return;
    }

    final result = Map<String, dynamic>.from(decoded);

    if (result['success'] != true || result['windowsLocalFallback'] == true) {
      return;
    }

    await _importGoogleList(
      sourceName: 'students',
      collection: 'students_directory',
      rawList: result['students'],
      idFor: (item) => _canonicalStudentDocumentId(item),
      coreFirebaseCollection: true,
    );

    await _importGoogleList(
      sourceName: 'teachers',
      collection: 'teachers_directory',
      rawList: result['teachers'],
      idFor: (item) => item['teacherId']?.toString().trim() ?? '',
      coreFirebaseCollection: true,
    );

    await _importGoogleList(
      sourceName: 'feePayments',
      collection: 'fee_payments',
      rawList: result['feePayments'],
      idFor: (item) => item['paymentId']?.toString().trim() ?? '',
      coreFirebaseCollection: true,
    );

    await _importGoogleList(
      sourceName: 'documents',
      collection: '_local_student_documents',
      rawList: result['documents'],
      idFor: (item) => item['documentId']?.toString().trim() ?? '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'studentAttendance',
      collection: '_local_student_attendance',
      rawList: result['studentAttendance'],
      idFor: (item) => item['attendanceId']?.toString().trim() ?? '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'teacherAttendance',
      collection: '_local_teacher_attendance',
      rawList: result['teacherAttendance'],
      idFor: (item) => item['attendanceId']?.toString().trim() ?? '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'exams',
      collection: '_local_exam_center_exams',
      rawList: result['exams'],
      idFor: (item) => item['examId']?.toString().trim() ?? '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'results',
      collection: '_local_exam_center_results',
      rawList: result['results'],
      idFor: (item) {
        final examId = item['examId']?.toString().trim() ?? '';
        final studentId = item['studentId']?.toString().trim() ?? '';

        if (examId.isEmpty || studentId.isEmpty) {
          return '';
        }

        return '${examId}_$studentId';
      },
      deleteMissing: true,
    );

    final profile = result['schoolProfile'];

    if (profile is Map) {
      await _mergeGoogleDocument(
        collection: 'school_config',
        documentId: 'school_profile_cache',
        remote: Map<String, dynamic>.from(profile),
        coreFirebaseCollection: true,
      );
    }
  }

  Future<void> _importGoogleList({
    required String sourceName,
    required String collection,
    required dynamic rawList,
    required String Function(Map<String, dynamic> item) idFor,
    bool coreFirebaseCollection = false,
    bool deleteMissing = false,
  }) async {
    if (rawList is! List) return;

    final remoteIds = <String>{};

    for (final raw in rawList) {
      if (raw is! Map) continue;

      final item = Map<String, dynamic>.from(raw);

      final id = idFor(item);

      if (id.isEmpty) continue;

      remoteIds.add(id);

      await _mergeGoogleDocument(
        collection: collection,
        documentId: id,
        remote: item,
        coreFirebaseCollection: coreFirebaseCollection,
      );
    }

    if (collection == 'students_directory' && remoteIds.isNotEmpty) {
      await _cleanupStudentAliases(remoteIds);
    }

    if (!deleteMissing) {
      return;
    }

    final manifestRef = FirebaseFirestore.instance
        .collection('_windows_sync_manifest')
        .doc(_manifestId('google', sourceName));

    final manifest = await manifestRef.get();

    final oldIds = _stringSet(manifest.data()?['ids']);

    for (final id in oldIds.difference(remoteIds)) {
      await _remoteDeleteLocal(collection, id);
    }

    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
      () => manifestRef.set(<String, dynamic>{
        'source': 'google',
        'collection': collection,
        'ids': remoteIds.toList()..sort(),
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  String _normalizeStudentRoll(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '';

    if (RegExp(r'^\d+$').hasMatch(raw)) {
      final normalized = raw.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      return normalized.isEmpty ? '0' : normalized;
    }

    return raw.toLowerCase();
  }

  int _studentClassNumber(dynamic value) {
    final raw = value?.toString() ?? '';
    return int.tryParse(raw.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  String _canonicalStudentDocumentId(Map<String, dynamic> item) {
    final classValue = item['class'] ?? item['studentClass'];
    final rollValue = item['rollNo'] ?? item['roll'];
    final classNumber = _studentClassNumber(classValue);
    final roll = _normalizeStudentRoll(rollValue);

    if (classNumber <= 0 || roll.isEmpty) {
      return '';
    }

    return 'Class ${classNumber}_Roll_$roll';
  }

  Future<void> _cleanupStudentAliases(Set<String> canonicalRemoteIds) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('students_directory')
        .get();

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final canonicalId = _canonicalStudentDocumentId(data);

      if (canonicalId.isEmpty ||
          !canonicalRemoteIds.contains(canonicalId) ||
          doc.id == canonicalId) {
        continue;
      }

      // This is a real tracked delete on purpose. It removes old Firebase
      // aliases such as Class 1_Roll_01 after the canonical Roll_1 record
      // has been imported from Google.
      await doc.reference.delete();
    }
  }

  Future<void> _mergeGoogleDocument({
    required String collection,
    required String documentId,
    required Map<String, dynamic> remote,
    required bool coreFirebaseCollection,
  }) async {
    final ref = FirebaseFirestore.instance
        .collection(collection)
        .doc(documentId);

    final current = await ref.get();
    final local = current.data();

    if (local == null) {
      if (coreFirebaseCollection) {
        await ref.set(remote);
      } else {
        await _remoteSetLocal(collection, documentId, remote);
      }
      return;
    }

    final localMs = _modifiedMillis(local);
    final remoteMs = _modifiedMillis(remote);

    if (remoteMs > 0 && localMs > 0 && remoteMs < localMs) {
      return;
    }

    final merged = <String, dynamic>{...local, ...remote};

    if (coreFirebaseCollection) {
      // Only create a Firebase outbox entry when
      // Google is actually newer or fills a missing
      // record/field set.
      if (_jsonStable(local) != _jsonStable(merged)) {
        await ref.set(merged);
      }
    } else {
      await _remoteSetLocal(collection, documentId, merged);
    }
  }

  Future<void> _remoteSetLocal(
    String collection,
    String documentId,
    Map<String, dynamic> data,
  ) {
    final db = FirebaseFirestore.instance;
    return db.applySyncedDocument(
      db.collection(collection).doc(documentId),
      data,
    );
  }

  Future<void> _remoteDeleteLocal(String collection, String documentId) {
    final db = FirebaseFirestore.instance;
    return db.applySyncedDocument(
      db.collection(collection).doc(documentId),
      null,
    );
  }

  String _pendingKey(String collection, String documentId) {
    return '$collection\u0000$documentId';
  }

  String _manifestId(String source, String collection) {
    return base64Url
        .encode(utf8.encode('$source\n$collection'))
        .replaceAll('=', '');
  }

  Set<String> _stringSet(dynamic value) {
    if (value is! Iterable) {
      return <String>{};
    }

    return value
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  int _modifiedMillis(Map<String, dynamic> data) {
    const keys = <String>[
      'updatedAt',
      'lastEdited',
      'timestamp',
      'paidAt',
      'uploadedAt',
      'createdAt',
      'queuedAt',
    ];

    for (final key in keys) {
      final value = data[key];

      if (value is Timestamp) {
        return value.millisecondsSinceEpoch;
      }

      if (value is DateTime) {
        return value.millisecondsSinceEpoch;
      }

      if (value is num) {
        return value.toInt();
      }

      if (value is String) {
        final asInt = int.tryParse(value);
        if (asInt != null) {
          return asInt;
        }

        final parsed = DateTime.tryParse(value);
        if (parsed != null) {
          return parsed.millisecondsSinceEpoch;
        }
      }
    }

    return 0;
  }

  String _jsonStable(Map<String, dynamic> value) {
    dynamic clean(dynamic input) {
      if (input is Timestamp) {
        return input.millisecondsSinceEpoch;
      }

      if (input is DateTime) {
        return input.millisecondsSinceEpoch;
      }

      if (input is Map) {
        final keys = input.keys.map((key) => key.toString()).toList()..sort();

        return <String, dynamic>{
          for (final key in keys) key: clean(input[key]),
        };
      }

      if (input is Iterable) {
        return input.map(clean).toList();
      }

      return input;
    }

    return jsonEncode(clean(value));
  }

  void dispose() {
    _schedule.stop();
    _debounceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _initialized = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) _schedule.wake();
  }
}

class _GoogleIdentity {
  const _GoogleIdentity({
    required this.schoolSyncId,
    required this.backendInstanceId,
  });

  final String schoolSyncId;
  final String backendInstanceId;
}

class _ResolvedSyncProfile {
  const _ResolvedSyncProfile({
    required this.profileId,
    required this.schoolSyncId,
    required this.firebaseProjectId,
    required this.googleUrl,
    required this.googleEmail,
    required this.googleBackendId,
    required this.blocked,
    required this.message,
  });

  final String profileId;
  final String schoolSyncId;
  final String firebaseProjectId;
  final String googleUrl;
  final String googleEmail;
  final String googleBackendId;
  final bool blocked;
  final String message;

  _ResolvedSyncProfile copyWith({String? googleEmail}) {
    return _ResolvedSyncProfile(
      profileId: profileId,
      schoolSyncId: schoolSyncId,
      firebaseProjectId: firebaseProjectId,
      googleUrl: googleUrl,
      googleEmail: googleEmail ?? this.googleEmail,
      googleBackendId: googleBackendId,
      blocked: blocked,
      message: message,
    );
  }
}
