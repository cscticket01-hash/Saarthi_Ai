import 'windows_connect/central_school_cloud.dart';
import 'package:flutter/foundation.dart';

import 'windows_firebase_sync.dart';
import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';
import 'windows_sync_engine.dart';
import 'windows_runtime_flags.dart';

class WindowsConnectionSnapshot {
  const WindowsConnectionSnapshot({
    required this.firebaseLink,
    required this.firebaseProjectId,
    required this.firebaseAuthenticated,
    required this.googleScriptUrl,
    required this.googleEmail,
    required this.activeProfileId,
    required this.localStorageEnabled,
  });

  final String firebaseLink;
  final String firebaseProjectId;
  final bool firebaseAuthenticated;
  final String googleScriptUrl;
  final String googleEmail;
  final String activeProfileId;
  final bool localStorageEnabled;

  bool get firebaseConfigured => firebaseLink.isNotEmpty;
  bool get googleConfigured => googleScriptUrl.isNotEmpty;
  bool get remoteReady => firebaseConfigured &&
      firebaseAuthenticated &&
      firebaseProjectId.isNotEmpty &&
      googleConfigured &&
      !WindowsSyncEngine.instance.syncBlocked;
  bool get fullyConfigured => remoteReady;

  static const empty = WindowsConnectionSnapshot(
    firebaseLink: '',
    firebaseProjectId: '',
    firebaseAuthenticated: false,
    googleScriptUrl: '',
    googleEmail: '',
    activeProfileId: 'unbound',
    localStorageEnabled: true,
  );
}

/// App-wide single source of truth for the two school connections.
///
/// IMPORTANT:
/// - Firebase configuration is always read from WindowsExternalConnections.
/// - Google Apps Script URL is always read from WindowsExternalConnections.
/// - WindowsSyncEngine is initialized once here so all local Firestore-backed
///   screens follow the active Firebase + Google school profile.
/// - Feature screens should never read school_config/google_drive_account
///   directly to decide which Google backend is active.
class WindowsConnectionCenter {
  WindowsConnectionCenter._();

  static final ValueNotifier<WindowsConnectionSnapshot> state =
      ValueNotifier<WindowsConnectionSnapshot>(WindowsConnectionSnapshot.empty);

  static Future<void>? _initializing;

  static Future<void> finishInitialization() async {
    final pending = _initializing;
    if (pending != null) await pending;
  }

  static Future<void> initialize() {
    final existing = _initializing;
    if (existing != null) return existing;

    final future = _initializeInternal();
    _initializing = future;
    future.then<void>(
      (_) {
        if (identical(_initializing, future)) {
          _initializing = null;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_initializing, future)) {
          _initializing = null;
        }
      },
    );
    return future;
  }

  static Future<void> _initializeInternal() async {
    await reload();

    try {
      await WindowsSyncEngine.instance.initialize();
    } catch (e) {
      // Connection/network problems must never stop the Windows app from
      // opening. The engine registers its callbacks before remote activation,
      // so a later Connect/Verify or Drive Save can recover automatically.
      debugPrint('Windows connection center startup sync warning: $e');
    }

    await reload();
  }

  static Future<WindowsConnectionSnapshot> reload() async {
    final saved = await WindowsExternalConnections.load();
    final central = await CentralSchoolCloud.saved();
    final firebaseStatus = await WindowsFirebaseRemote.status();
    final localEnabled = await WindowsRuntimeFlags.localStorageEnabled();

    final snapshot = WindowsConnectionSnapshot(
      firebaseLink: central.isNotEmpty ? 'central:${central['schoolId']}' : saved['firebaseLink']?.toString().trim() ?? '',
      firebaseProjectId: firebaseStatus.projectId.trim(),
      firebaseAuthenticated: firebaseStatus.authenticated,
      googleScriptUrl: await WindowsExternalConnections.googleScriptUrl(),
      googleEmail: await WindowsExternalConnections.googleEmail(),
      activeProfileId: FirebaseFirestore.instance.activeProfileId.trim().isEmpty
          ? 'unbound'
          : FirebaseFirestore.instance.activeProfileId.trim(),
      localStorageEnabled: localEnabled,
    );

    state.value = snapshot;
    return snapshot;
  }

  static Future<String> googleScriptUrl({bool required = true}) async {
    await initialize();
    final snapshot = await reload();
    final url = snapshot.googleScriptUrl;

    if (required && !snapshot.remoteReady) {
      throw StateError(
        'Remote school connection ready nahi hai. Firebase + Google Drive dono connect/verify karein.',
      );
    }

    return snapshot.remoteReady ? url : '';
  }

  static Future<String> firebaseLink({bool required = true}) async {
    await initialize();
    final snapshot = await reload();
    final link = snapshot.firebaseLink;

    if (required && !snapshot.remoteReady) {
      throw StateError(
        'Remote school connection ready nahi hai. Firebase + Google Drive dono connect/verify karein.',
      );
    }

    return snapshot.remoteReady ? link : '';
  }

  static Future<void> refreshProfileAndSync() async {
    await WindowsSyncEngine.instance.activateCurrentConnections(
      allowPairing: false,
    );
    await reload();
    await WindowsSyncEngine.instance.syncNow();
    await reload();
  }

  static Future<void> localStorageModeChanged() async {
    await WindowsSyncEngine.instance.localStorageModeChanged();
    await reload();
  }
}
