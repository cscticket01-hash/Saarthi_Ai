import 'platform/platform_config.dart';
import 'windows_connect/central_school_cloud.dart';
import 'dart:async';
import 'dart:convert';
import 'school_backend_transport.dart';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'windows_backend_bridge.dart';
import 'windows_firebase_sync.dart';
import 'windows_html_shim.dart' as windows_html;
import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';
import 'windows_runtime_flags.dart';
import 'windows_platform_client.dart';

class WindowsSyncEngine {
  WindowsSyncEngine._();

  static final WindowsSyncEngine instance =
      WindowsSyncEngine._();

  static const List<String> _firebaseCollections =
      <String>[
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

  Timer? _periodicTimer;
  Timer? _debounceTimer;
  bool _initialized = false;
  bool _syncing = false;
  bool _resetPaused = false;
  int _activating = 0;
  bool _syncBlocked = false;

  DateTime? lastSuccessfulSync;
  String? lastError;
  String _activeProfileId = 'unbound';
  String _activeSchoolSyncId = '';
  String _activeFirebaseProject = '';
  String _activeGoogleUrl = '';

  String get activeProfileId => _activeProfileId;
  String get activeSchoolSyncId => _activeSchoolSyncId;
  bool get syncBlocked => _syncBlocked;

  Future<void> initialize() async {
    if (_initialized) return;
    _resetPaused = false;
    _initialized = true;

    WindowsLocalFirestoreSyncControl.onTrackedMutation = () async {
      scheduleSoon();
      WindowsPlatformClient.instance.scheduleRefresh();
    };

    WindowsFirebaseRemote.onConnectionChanged = () async {
      await _handleFirebaseConnectionChanged();
    };

    WindowsBackendBridge.onRemoteAvailable = () async {
      scheduleSoon(
        delay: const Duration(seconds: 2),
      );
    };

    await activateCurrentConnections(
      allowPairing: false,
    );

    if (_resetPaused) return;

    _periodicTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => scheduleSoon(),
    );

    scheduleSoon(
      delay: const Duration(milliseconds: 800),
    );
  }

  Future<void> _handleFirebaseConnectionChanged() async {
    final status = await WindowsFirebaseRemote.status();
    final nextProject = status.authenticated
        ? status.projectId.trim()
        : '';

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

    final mayPairFirstFirebase = previousProject.isEmpty &&
        nextProject.isNotEmpty &&
        selectedDrive.isNotEmpty;

    await activateCurrentConnections(
      allowPairing: mayPairFirstFirebase,
    );
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

  void scheduleSoon({
    Duration delay = const Duration(seconds: 2),
  }) {
    if (!_initialized || _syncBlocked || _resetPaused) return;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      delay,
      () {
        unawaited(syncNow());
      },
    );
  }

  Future<void> changeGoogleConnection({
    required String email,
    required String scriptUrl,
  }) async {
    final cleanEmail = email.trim();
    final cleanUrl = scriptUrl.trim();

    if (cleanEmail.isEmpty ||
        !cleanEmail.toLowerCase().endsWith('@gmail.com')) {
      throw const FormatException(
        'Valid School Gmail ID daalein.',
      );
    }

    WindowsExternalConnections.validateGoogleScriptUrl(cleanUrl);

    final healthy = await WindowsBackendBridge.testRemote(
      Uri.parse(cleanUrl),
    );
    if (!healthy) {
      throw StateError(
        'Google Drive / Apps Script actual health check fail hua.',
      );
    }

    final firebaseStatus = await WindowsFirebaseRemote.status();
    final firebaseReady = firebaseStatus.authenticated &&
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
      profile.copyWith(
        googleEmail: cleanEmail,
      ),
      seedGoogleConfig: false,
    );

    // Save the currently selected Drive link inside THIS isolated profile.
    // Normal tracking is intentional so the same school's website can learn
    // the current Apps Script URL through Firestore.
    await FirebaseFirestore.instance
        .collection('school_config')
        .doc('google_drive_account')
        .set(
      <String, dynamic>{
        'email': cleanEmail,
        'scriptUrl': cleanUrl,
        'status': 'connected',
        'linkedAt': FieldValue.serverTimestamp(),
      },
      const SetOptions(merge: true),
    );

    scheduleSoon(
      delay: const Duration(milliseconds: 250),
    );
  }

  Future<void> disconnectGoogle() async {
    await WindowsExternalConnections.save(
      googleScriptUrl: '',
      googleEmail: '',
    );

    await activateCurrentConnections(
      allowPairing: false,
    );

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

    scheduleSoon(
      delay: const Duration(milliseconds: 250),
    );
  }

  Future<void> activateCurrentConnections({
    required bool allowPairing,
  }) async {
    if (_resetPaused) return;
    _activating++;
    try {
    while (_syncing) { await Future<void>.delayed(const Duration(milliseconds:50)); }
    final profile = await _resolveProfile(
      allowPairing: allowPairing,
    );
    if (_resetPaused) return;

    await _applyProfile(
      profile,
      seedGoogleConfig: !profile.blocked,
    );

    if (!profile.blocked) {
      scheduleSoon(
        delay: const Duration(milliseconds: 350),
      );
    }
    } finally { _activating--; }
  }

  Future<void> pauseForAppReset() async {
    _resetPaused = true;
    _periodicTimer?.cancel();
    _debounceTimer?.cancel();
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (_syncing || _activating > 0) {
      if (DateTime.now().isAfter(deadline)) {
        _resetPaused = false;
        throw StateError('School sync is still finishing. Retry reset shortly.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    WindowsLocalFirestoreSyncControl.onTrackedMutation = null;
    WindowsFirebaseRemote.onConnectionChanged = null;
    WindowsBackendBridge.onRemoteAvailable = null;
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
      await CentralSchoolCloud.firebaseToken();
      return _ResolvedSyncProfile(profileId:'central_${central['schoolId']}',
        schoolSyncId:central['schoolId'], firebaseProjectId:central['projectId'],
        googleUrl:await WindowsExternalConnections.googleScriptUrl(), googleEmail:central['email'],
        googleBackendId:central['folderId'], blocked:false, message:'');
    }
    final firebaseStatus = await WindowsFirebaseRemote.status();
    final projectId = firebaseStatus.authenticated
        ? firebaseStatus.projectId.trim()
        : '';

    final savedConnections = await WindowsExternalConnections.load();
    final googleUrl = (googleUrlOverride ??
            savedConnections['googleScriptUrl']?.toString() ?? '')
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
          message:
              'School isolation BLOCKED: Firebase aur Google Drive alag school identity ke hain. Koi data sync nahi hua.',
        );
      }

      if (!allowPairing &&
          (firebaseSyncId.isEmpty || driveSyncId.isEmpty)) {
        return _blockedProfile(
          projectId: projectId,
          googleUrl: googleUrl,
          googleEmail: googleEmail,
          message:
              'School isolation pending: current Firebase + Drive pair verify/claim nahi hua. Advanced Settings me correct Drive link Save karein.',
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
          googleIdentity = await _claimGoogleSyncId(
            googleUrl,
            schoolSyncId,
          );
          firebaseSyncId = schoolSyncId;
          driveSyncId = schoolSyncId;
        } else if (firebaseSyncId.isNotEmpty && driveSyncId.isEmpty) {
          schoolSyncId = firebaseSyncId;
          googleIdentity = await _claimGoogleSyncId(
            googleUrl,
            schoolSyncId,
          );
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
          message:
              'School isolation verify nahi hua. Koi cross-source sync nahi hua.',
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
        if (profile.profileId.startsWith('central_')) 'schoolId':profile.schoolSyncId,
        'googleScriptUrl': profile.googleUrl,
        'googleBackendId': profile.googleBackendId,
        'blocked': profile.blocked,
      },
    );

    windows_html.setSchoolStorageNamespace(
      profile.profileId,
    );

    if (seedGoogleConfig && profile.googleUrl.isNotEmpty) {
      await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
        () => FirebaseFirestore.instance
            .collection('school_config')
            .doc('google_drive_account')
            .set(
          <String, dynamic>{
            'email': profile.googleEmail,
            'scriptUrl': profile.googleUrl,
            'status': 'connected',
          },
          const SetOptions(merge: true),
        ),
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
      throw StateError(
        'Firebase already dusre School Sync ID se locked hai.',
      );
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

  Future<_GoogleIdentity> _googleIdentity(
    String scriptUrl,
  ) async {
    final result = await _googleDirectPost(
      scriptUrl,
      const <String, dynamic>{
        'action': 'sync_identity_get',
      },
    );

    return _GoogleIdentity(
      schoolSyncId:
          result['schoolSyncId']?.toString().trim() ?? '',
      backendInstanceId:
          result['backendInstanceId']?.toString().trim() ?? '',
    );
  }

  Future<_GoogleIdentity> _claimGoogleSyncId(
    String scriptUrl,
    String schoolSyncId,
  ) async {
    final result = await _googleDirectPost(
      scriptUrl,
      <String, dynamic>{
        'action': 'sync_identity_claim',
        'schoolSyncId': schoolSyncId,
      },
    );

    final claimed =
        result['schoolSyncId']?.toString().trim() ?? '';
    if (claimed != schoolSyncId) {
      throw StateError(
        'Google Drive School Sync ID claim verify nahi hua.',
      );
    }

    return _GoogleIdentity(
      schoolSyncId: claimed,
      backendInstanceId:
          result['backendInstanceId']?.toString().trim() ?? '',
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

      for (var redirectCount = 0;
          redirectCount < 8;
          redirectCount++) {
        final code = response.statusCode;
        final isRedirect = code == 301 ||
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
        throw StateError(
          'Google sync identity HTTP ${response.statusCode}.',
        );
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
        throw StateError('Google backend belongs to another school or needs the secure backend update.');
      }
      return result;
    } finally {
      client.close();
    }
  }

  String _newSchoolSyncId() {
    final random = Random.secure();
    final bytes = List<int>.generate(
      12,
      (_) => random.nextInt(256),
    );
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
    final b = _fnv32(String.fromCharCodes(raw.runes.toList().reversed), 0x9E3779B9);
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
    final profile=FirebaseFirestore.instance.activeProfileId;
    final until=DateTime.now().add(const Duration(seconds:90));
    while(_syncing||_activating>0){if(DateTime.now().isAfter(until))throw StateError('School sync is busy; retry Drive backup.');await Future<void>.delayed(const Duration(milliseconds:50));}
    if(_syncBlocked||_resetPaused||FirebaseFirestore.instance.activeProfileId!=profile)throw StateError('Resolve school sync before creating a Drive backup.');
    await syncNow();
    if(lastError!=null||FirebaseFirestore.instance.activeProfileId!=profile)throw StateError('School sync did not complete; retry Drive backup.');
  }

  Future<void> syncNow() async {
    if (_syncing || _activating > 0 || _syncBlocked || _resetPaused) return;

    _syncing = true;
    lastError = null;

    try {
      final central = await CentralSchoolCloud.saved();
      if (central.isNotEmpty && central['schoolId'] != _activeSchoolSyncId) {
        unawaited(activateCurrentConnections(allowPairing:false)); return;
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

        await _pushFirebaseOutbox(projectId:projectId,idToken:idToken);
        await _pullFirebase(
          projectId: projectId,
          idToken: idToken,
        );
      }

      final scriptUrl = await _googleScriptUrl();
      if (_activeGoogleUrl.isNotEmpty &&
          scriptUrl != _activeGoogleUrl) {
        unawaited(activateCurrentConnections(allowPairing: false));
        return;
      }

      if (scriptUrl.isNotEmpty && central.isEmpty) {
        await _pullGoogleSnapshot(scriptUrl);
      }

      if (scriptUrl.isNotEmpty && central.isEmpty) {
        await WindowsBackendBridge.flushPending();
      }

      lastSuccessfulSync = DateTime.now();
    } catch (e) {
      lastError = e.toString();
    } finally {
      _syncing = false;
    }
  }

  Future<void> _pullFirebase({
    required String projectId,
    required String idToken,
  }) async {
    final pullProfile = FirebaseFirestore.instance.activeProfileId;
    final pending =
        await _firebasePendingKeys();

    for (final collection
        in _firebaseCollections) {
      if (projectId != platformProjectId && _firebaseCollections.indexOf(collection) >= 12) continue;
      if (FirebaseFirestore.instance.activeProfileId != pullProfile) throw StateError('School profile changed during sync.');
      final remote =
          await WindowsFirebaseRemote
              .readCollection(
        projectId: projectId,
        idToken: idToken,
        collection: collection,
      );

      if (FirebaseFirestore.instance.activeProfileId != pullProfile) throw StateError('School profile changed during sync.');
      final localSnapshot =
          await FirebaseFirestore.instance
              .collection(collection)
              .get();

      final local = <String,
          Map<String, dynamic>>{
        for (final doc in localSnapshot.docs)
          doc.id: Map<String, dynamic>.from(
            doc.data(),
          ),
      };

      final manifestRef =
          FirebaseFirestore.instance
              .collection(
                '_windows_sync_manifest',
              )
              .doc(
                _manifestId(
                  'firebase',
                  collection,
                ),
              );

      final manifest =
          await manifestRef.get();

      final oldIds = _stringSet(
        manifest.data()?['ids'],
      );

      final remoteIds =
          remote.keys.toSet();

      for (final entry
          in remote.entries) {
        if (FirebaseFirestore.instance.activeProfileId != pullProfile) throw StateError('School profile changed during sync.');
        // Windows connection selector is authoritative for its own Drive URL.
        // A stale Firestore copy must never switch the active backend behind
        // the user's back or revive another school's Drive link.
        if (collection == 'school_config' &&
            entry.key == 'google_drive_account') {
          continue;
        }

        final key = _pendingKey(
          collection,
          entry.key,
        );

        final localData =
            local[entry.key];

        if (pending.contains(key)) {
          // Local unsynced change wins until its
          // outbox has been pushed.
          continue;
        }

        if (localData == null) {
          await _remoteSetLocal(
            collection,
            entry.key,
            entry.value,
          );
          continue;
        }

        final localMs =
            _modifiedMillis(localData);
        final remoteMs =
            _modifiedMillis(entry.value);

        if (localMs > 0 &&
            remoteMs > 0 &&
            localMs > remoteMs) {
          // Local is clearly newer. Re-writing the
          // same document records it in the outbox.
          await FirebaseFirestore.instance
              .collection(collection)
              .doc(entry.key)
              .set(localData);
          pending.add(key);
          continue;
        }

        final merged =
            <String, dynamic>{
          ...localData,
          ...entry.value,
        };

        await _remoteSetLocal(
          collection,
          entry.key,
          merged,
        );
      }

      // A document that existed on Firebase in an
      // earlier successful snapshot but is absent now
      // is a confirmed remote deletion.
      final deletedRemote =
          oldIds.difference(remoteIds);

      for (final id in deletedRemote) {
        if (collection == 'school_config' &&
            id == 'google_drive_account') {
          continue;
        }

        final key =
            _pendingKey(collection, id);

        if (pending.contains(key)) {
          continue;
        }

        await _remoteDeleteLocal(
          collection,
          id,
        );
      }

      // Existing local-only documents on the first
      // sync must not be lost. Queue them to Firebase.
      for (final entry in local.entries) {
        if (remoteIds.contains(entry.key) ||
            oldIds.contains(entry.key)) {
          continue;
        }

        final key = _pendingKey(
          collection,
          entry.key,
        );

        if (pending.contains(key)) {
          continue;
        }

        await FirebaseFirestore.instance
            .collection(collection)
            .doc(entry.key)
            .set(entry.value);

        pending.add(key);
      }

      await WindowsLocalFirestoreSyncControl
          .runWithoutSyncTracking(
        () => manifestRef.set(
          <String, dynamic>{
            'source': 'firebase',
            'collection': collection,
            'ids': remoteIds.toList()
              ..sort(),
            'updatedAt':
                FieldValue.serverTimestamp(),
          },
        ),
      );
    }
  }

  Future<Set<String>>
      _firebasePendingKeys() async {
    final snapshot =
        await FirebaseFirestore.instance
            .collection(
              '_windows_firebase_outbox',
            )
            .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      return _pendingKey(
        data['collection']?.toString() ?? '',
        data['documentId']?.toString() ?? '',
      );
    }).where((value) {
      return !value.startsWith('\u0000');
    }).toSet();
  }

  Future<void> _pushFirebaseOutbox({
    required String projectId,
    required String idToken,
  }) async {
    final origin=FirebaseFirestore.instance.activeProfileId;
    final snapshot =
        await FirebaseFirestore.instance
            .collection(
              '_windows_firebase_outbox',
            )
            .get();

    if(FirebaseFirestore.instance.activeProfileId != origin) throw StateError('School changed during sync.');
    final docs = snapshot.docs.toList()
      ..sort((a, b) {
        return _modifiedMillis(a.data())
            .compareTo(
          _modifiedMillis(b.data()),
        );
      });

    for (final queued in docs) {
      queued.reference.requireOriginProfile();
      final data = queued.data();

      final collection =
          data['collection']
                  ?.toString()
                  .trim() ??
              '';

      final documentId =
          data['documentId']
                  ?.toString()
                  .trim() ??
              '';

      final operation =
          data['operation']
                  ?.toString()
                  .trim() ??
              '';

      if (collection.isEmpty ||
          documentId.isEmpty) {
        await queued.reference.delete();
        continue;
      }

      if (operation == 'delete') {
        await WindowsFirebaseRemote
            .deleteDocument(
          projectId: projectId,
          idToken: idToken,
          collection: collection,
          documentId: documentId,
        );
      } else {
        final raw = data['data'];

        if (raw is! Map) {
          await queued.reference.delete();
          continue;
        }

        await WindowsFirebaseRemote
            .writeDocument(
          projectId: projectId,
          idToken: idToken,
          collection: collection,
          documentId: documentId,
          data:
              Map<String, dynamic>.from(raw),
        );
      }

      await FirebaseFirestore.instance.acknowledgeOutbox(queued.reference, data);
    }
  }

  Future<String> _googleScriptUrl() {
    return WindowsExternalConnections.googleScriptUrl();
  }

  Future<void> _pullGoogleSnapshot(
    String scriptUrl,
  ) async {
    final response =
        await WindowsBackendBridge.post(
      Uri.parse(scriptUrl),
      headers: const <String, String>{
        'Content-Type':
            'text/plain;charset=utf-8',
      },
      body: jsonEncode(
        const <String, dynamic>{
          'action': 'windows_sync_snapshot',
        },
      ),
    );

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      return;
    }

    final decoded =
        jsonDecode(response.body);

    if (decoded is! Map) {
      return;
    }

    final result =
        Map<String, dynamic>.from(decoded);

    if (result['success'] != true ||
        result['windowsLocalFallback'] == true) {
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
      idFor: (item) =>
          item['teacherId']
              ?.toString()
              .trim() ??
          '',
      coreFirebaseCollection: true,
    );

    await _importGoogleList(
      sourceName: 'feePayments',
      collection: 'fee_payments',
      rawList: result['feePayments'],
      idFor: (item) =>
          item['paymentId']
              ?.toString()
              .trim() ??
          '',
      coreFirebaseCollection: true,
    );

    await _importGoogleList(
      sourceName: 'documents',
      collection:
          '_local_student_documents',
      rawList: result['documents'],
      idFor: (item) =>
          item['documentId']
              ?.toString()
              .trim() ??
          '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'studentAttendance',
      collection:
          '_local_student_attendance',
      rawList:
          result['studentAttendance'],
      idFor: (item) =>
          item['attendanceId']
              ?.toString()
              .trim() ??
          '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'teacherAttendance',
      collection:
          '_local_teacher_attendance',
      rawList:
          result['teacherAttendance'],
      idFor: (item) =>
          item['attendanceId']
              ?.toString()
              .trim() ??
          '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'exams',
      collection:
          '_local_exam_center_exams',
      rawList: result['exams'],
      idFor: (item) =>
          item['examId']
              ?.toString()
              .trim() ??
          '',
      deleteMissing: true,
    );

    await _importGoogleList(
      sourceName: 'results',
      collection:
          '_local_exam_center_results',
      rawList: result['results'],
      idFor: (item) {
        final examId =
            item['examId']
                    ?.toString()
                    .trim() ??
                '';
        final studentId =
            item['studentId']
                    ?.toString()
                    .trim() ??
                '';

        if (examId.isEmpty ||
            studentId.isEmpty) {
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
        documentId:
            'school_profile_cache',
        remote:
            Map<String, dynamic>.from(
          profile,
        ),
        coreFirebaseCollection: true,
      );
    }
  }

  Future<void> _importGoogleList({
    required String sourceName,
    required String collection,
    required dynamic rawList,
    required String Function(
      Map<String, dynamic> item,
    ) idFor,
    bool coreFirebaseCollection = false,
    bool deleteMissing = false,
  }) async {
    if (rawList is! List) return;

    final remoteIds = <String>{};

    for (final raw in rawList) {
      if (raw is! Map) continue;

      final item =
          Map<String, dynamic>.from(raw);

      final id = idFor(item);

      if (id.isEmpty) continue;

      remoteIds.add(id);

      await _mergeGoogleDocument(
        collection: collection,
        documentId: id,
        remote: item,
        coreFirebaseCollection:
            coreFirebaseCollection,
      );
    }

    if (collection == 'students_directory' && remoteIds.isNotEmpty) {
      await _cleanupStudentAliases(remoteIds);
    }

    if (!deleteMissing) {
      return;
    }

    final manifestRef =
        FirebaseFirestore.instance
            .collection(
              '_windows_sync_manifest',
            )
            .doc(
              _manifestId(
                'google',
                sourceName,
              ),
            );

    final manifest =
        await manifestRef.get();

    final oldIds = _stringSet(
      manifest.data()?['ids'],
    );

    for (final id
        in oldIds.difference(remoteIds)) {
      await _remoteDeleteLocal(
        collection,
        id,
      );
    }

    await WindowsLocalFirestoreSyncControl
        .runWithoutSyncTracking(
      () => manifestRef.set(
        <String, dynamic>{
          'source': 'google',
          'collection': collection,
          'ids': remoteIds.toList()
            ..sort(),
          'updatedAt':
              FieldValue.serverTimestamp(),
        },
      ),
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
        await _remoteSetLocal(
          collection,
          documentId,
          remote,
        );
      }
      return;
    }

    final localMs =
        _modifiedMillis(local);
    final remoteMs =
        _modifiedMillis(remote);

    if (remoteMs > 0 &&
        localMs > 0 &&
        remoteMs < localMs) {
      return;
    }

    final merged =
        <String, dynamic>{
      ...local,
      ...remote,
    };

    if (coreFirebaseCollection) {
      // Only create a Firebase outbox entry when
      // Google is actually newer or fills a missing
      // record/field set.
      if (_jsonStable(local) !=
          _jsonStable(merged)) {
        await ref.set(merged);
      }
    } else {
      await _remoteSetLocal(
        collection,
        documentId,
        merged,
      );
    }
  }

  Future<void> _remoteSetLocal(
    String collection,
    String documentId,
    Map<String, dynamic> data,
  ) {
    return WindowsLocalFirestoreSyncControl
        .runWithoutSyncTracking(
      () => FirebaseFirestore.instance
          .collection(collection)
          .doc(documentId)
          .set(data),
    );
  }

  Future<void> _remoteDeleteLocal(
    String collection,
    String documentId,
  ) {
    return WindowsLocalFirestoreSyncControl
        .runWithoutSyncTracking(
      () => FirebaseFirestore.instance
          .collection(collection)
          .doc(documentId)
          .delete(),
    );
  }

  String _pendingKey(
    String collection,
    String documentId,
  ) {
    return '$collection\u0000$documentId';
  }

  String _manifestId(
    String source,
    String collection,
  ) {
    return base64Url
        .encode(
          utf8.encode(
            '$source\n$collection',
          ),
        )
        .replaceAll('=', '');
  }

  Set<String> _stringSet(
    dynamic value,
  ) {
    if (value is! Iterable) {
      return <String>{};
    }

    return value
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  int _modifiedMillis(
    Map<String, dynamic> data,
  ) {
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
        final asInt =
            int.tryParse(value);
        if (asInt != null) {
          return asInt;
        }

        final parsed =
            DateTime.tryParse(value);
        if (parsed != null) {
          return parsed
              .millisecondsSinceEpoch;
        }
      }
    }

    return 0;
  }

  String _jsonStable(
    Map<String, dynamic> value,
  ) {
    dynamic clean(dynamic input) {
      if (input is Timestamp) {
        return input
            .millisecondsSinceEpoch;
      }

      if (input is DateTime) {
        return input
            .millisecondsSinceEpoch;
      }

      if (input is Map) {
        final keys = input.keys
            .map((key) => key.toString())
            .toList()
          ..sort();

        return <String, dynamic>{
          for (final key in keys)
            key: clean(input[key]),
        };
      }

      if (input is Iterable) {
        return input
            .map(clean)
            .toList();
      }

      return input;
    }

    return jsonEncode(clean(value));
  }

  void dispose() {
    _periodicTimer?.cancel();
    _debounceTimer?.cancel();
    _initialized = false;
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

  _ResolvedSyncProfile copyWith({
    String? googleEmail,
  }) {
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
