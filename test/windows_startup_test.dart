import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/rendering.dart';

import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/platform/platform_config.dart';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import '../lib/windows_inactivity_timer.dart';

import '../lib/main_windows.dart';
import '../lib/windows_admin_setup.dart';
import '../lib/windows_local_settings.dart';
import '../lib/windows_connect/managed_school_session.dart';
import '../lib/windows_appearance.dart';
import '../lib/windows_managed_school_gate.dart';
import '../lib/main_dashboard_screen_windows.dart' show WindowsSectionLocks;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets('one-hour idle timer resets on activity and disposal cancels it', (tester) async {
    var locks = 0;
    final idle = WindowsInactivityTimer(onTimeout: () => locks++);
    expect(windowsIdleTimeout, const Duration(hours: 1));
    idle.reset();
    await tester.pump(const Duration(minutes: 59, seconds: 59));
    expect(locks, 0);
    idle.reset();
    await tester.pump(const Duration(minutes: 59, seconds: 59));
    expect(locks, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(locks, 1);
    idle.reset();
    idle.dispose();
    await tester.pump(const Duration(hours: 2));
    expect(locks, 1);
  });

  testWidgets('minimize and app switching do not pause or reset the hour', (tester) async {
    var locks = 0;
    final idle = WindowsInactivityTimer(onTimeout: () => locks++);
    idle.reset();
    await tester.pump(const Duration(minutes: 20));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(minutes: 39, seconds: 59));
    expect(locks, 0);
    expect(idle.remaining, const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(locks, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
    expect(locks, 1);
    idle.dispose();
  });

  testWidgets('only mouse-button clicks reset the activity monitor', (tester) async {
    var activity = 0;
    await tester.pumpWidget(MaterialApp(home: WindowsActivityMonitor(
      onActivity: () => activity++, child: const Scaffold(body: TextField()))));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(activity, 0);
    await tester.tap(find.byType(TextField)); // Touch is not a mouse click.
    expect(activity, 0);
    await tester.tap(find.byType(TextField), kind: PointerDeviceKind.mouse);
    expect(activity, 1);
    await tester.tap(find.byType(TextField), kind: PointerDeviceKind.mouse);
    expect(activity, 2); // Even quick successive clicks count.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    expect(activity, 2);
    await tester.pumpWidget(const SizedBox());
  });
  Map<String, String> trialSchoolIdentity() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {CentralSchoolCloud.key: jsonEncode({
      'managed': true, 'projectId': platformProjectId,
      'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'uid': 'A',
      'endpoint': 'https://school.example/school-cloud',
      'folderId': 'managed', 'firebaseRefreshToken': 'refresh',
      'verifiedAccess': {'success': true, 'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'uid': 'A', 'projectId': platformProjectId, 'status': 'trial',
        'allowed': true, 'serverTime': now, 'expiresAt': now + 5 * 86400000}
    })};
  }
  testWidgets('trial Skip is a selection and the setup has one Submit action', (tester) async {
    FlutterSecureStorage.setMockInitialValues(trialSchoolIdentity());
    var completed = 0;
    await tester.binding.setSurfaceSize(const Size(1400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: WindowsAdminSetupScreen(onFinished: () => completed++)));
    await tester.pump(); await tester.pump();
    expect(find.text('Contact no'), findsOneWidget);
    expect(find.text('Contact no *'), findsNothing);
    expect(find.byKey(const ValueKey('setup-contact')), findsOneWidget);
    expect(find.text('New App lock *'), findsOneWidget);
    expect(find.text('Confirm app lock *'), findsOneWidget);
    expect(find.text('Submit'), findsOneWidget);
    expect(find.text('Save & Open App'), findsNothing);
    expect(find.byType(Checkbox), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, false);
    await tester.ensureVisible(find.byKey(const ValueKey('setup-skip-trial')));
    await tester.tap(find.byKey(const ValueKey('setup-skip-trial')));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, true);
    expect(completed, 0);
    expect(find.byKey(const ValueKey('admin-setup-error')), findsNothing);
    expect(find.text('Submit'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('blank contact passes validation while a licence or explicit trial selection is required', (tester) async {
    FlutterSecureStorage.setMockInitialValues(trialSchoolIdentity());
    await tester.binding.setSurfaceSize(const Size(1400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: WindowsAdminSetupScreen()));
    await tester.pump(); await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('setup-school-name')), 'Example School');
    await tester.enterText(find.byKey(const ValueKey('setup-principal-name')), 'Example Principal');
    await tester.enterText(find.byKey(const ValueKey('setup-app-lock')), 'App-lock-123');
    await tester.enterText(find.byKey(const ValueKey('setup-confirm-lock')), 'App-lock-123');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('setup-contact'))).controller!.text, isEmpty);
    await tester.ensureVisible(find.byKey(const ValueKey('setup-submit')));
    await tester.tap(find.byKey(const ValueKey('setup-submit')));
    await tester.pump();
    expect(find.text('Enter your school licence key, or choose Skip for the valid five-day trial.'), findsOneWidget);
    expect(find.textContaining('contact number and an App Lock'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('setup page renders desktop and laptop review images without overflow', (tester) async {
    FlutterSecureStorage.setMockInitialValues(trialSchoolIdentity());
    await tester.runAsync(() async {
      await (FontLoader('Segoe UI')..addFont(Future.value(ByteData.sublistView(
        await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes())))).load();
      await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final spec in [('desktop', const Size(1280, 1000)), ('laptop', const Size(1280, 800)), ('full', const Size(1280, 1400))]) {
      await tester.binding.setSurfaceSize(spec.$2);
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Segoe UI'),
        home: RepaintBoundary(key: key, child: const WindowsAdminSetupScreen())));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: spec.$1);
      await tester.runAsync(() async {
        final image = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        final file = File('build/settings-preview/setup-${spec.$1}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        final encoded = base64Encode(bytes);
        for (var start = 0; start < encoded.length; start += 16000) {
          final end = (start + 16000).clamp(0, encoded.length);
          print('SETUP_PNG_${spec.$1}:$start:${encoded.substring(start, end)}');
        }
        image.dispose();
      });
      await tester.ensureVisible(find.byKey(const ValueKey('setup-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('setup-submit')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull, reason: spec.$1);
      await tester.pumpWidget(const SizedBox());
    }
  }, skip: !Platform.isWindows);
  testWidgets('legacy Admin lock does not add another password prompt', (
    tester,
  ) async {
    await WindowsSectionLocks.addPassword(
      sectionKey: 'admin_section',
      password: 'admin-only-pass',
    );
    await tester.pumpWidget(
      const MaterialApp(home: WindowsLocalDashboardGate()),
    );
    await tester.pump();
    expect(find.text('Admin Section Password'), findsNothing);
    expect(find.text('Open Admin Panel'), findsNothing);
    expect(
      find.byType(WindowsAdminSessionDashboard, skipOffstage: false),
      findsOneWidget,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Admin Section Password'), findsNothing);
    expect(
      find.byType(WindowsAdminSessionDashboard, skipOffstage: false),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'fresh Windows startup requires central school login and exposes no licence skip',
    (tester) async {
      await tester.pumpWidget(
        VidyaSaarthiWindowsApp(initializeConnections: () async {}),
      );
      await tester.pumpAndSettle();
      expect(find.text('School Login'), findsOneWidget);
      expect(find.text('School login email'), findsOneWidget);
      expect(find.byKey(const ValueKey('license-skip-button')), findsNothing);
      expect(find.text('Save & Open App'), findsNothing);
      expect(find.text('Skip'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('legacy local lock cannot bypass central school login', (
    tester,
  ) async {
    await tester.runAsync(() => WindowsLocalSecurity.initialize());
    await tester.pumpWidget(
      const MaterialApp(
        home: WindowsManagedSchoolGate(
          child: Text('School data'),
          legacy: Text('Legacy bypass'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('School Login'), findsOneWidget);
    expect(find.text('Legacy bypass'), findsNothing);
    expect(find.text('School data'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('setup fields and uploads follow the approved order', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: WindowsAdminSetupScreen()));
    await tester.pump(); await tester.pump();
    const keys = ['setup-school-name', 'setup-principal-name', 'setup-contact',
      'setup-app-lock', 'setup-confirm-lock', 'setup-licence'];
    var previous = -1.0;
    for (final name in keys) {
      final field = find.byKey(ValueKey(name));
      expect(field, findsOneWidget);
      final y = tester.getTopLeft(field).dy;
      expect(y, greaterThan(previous));
      previous = y;
    }
    final logo = tester.getTopLeft(find.text('School logo')).dy;
    final signature = tester.getTopLeft(find.text('School signature')).dy;
    final seal = tester.getTopLeft(find.text('School seal')).dy;
    expect(logo, greaterThan(previous));
    expect(signature, greaterThan(logo));
    expect(seal, greaterThan(signature));
    expect(find.text('Submit'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Submit')).dy, greaterThan(seal));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'tenant connection completes before registration lookup; restore failure shows retry not setup',
    (tester) async {
      final connected = Completer<void>();
      var checked = false;
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsStartupFlow(
            initializeConnections: () => connected.future,
            checkSetup: () async {
              checked = true;
              throw StateError('restore unavailable');
            },
          ),
        ),
      );
      await tester.pump();
      expect(checked, false);
      connected.complete();
      await tester.pump();
      await tester.pump();
      expect(checked, true);
      expect(find.text('Retry school profile restore'), findsOneWidget);
      expect(find.text('Save & Open App'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'existing school with no local App Lock must create it before opening home',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        CentralSchoolCloud.key: jsonEncode({
          'managed': true,
          'projectId': platformProjectId,
          'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'uid': 'A',
          'email': 'a@school.example',
          'folderId': 'managed',
          'firebaseRefreshToken': 'refresh',
          'endpoint': 'https://school.example/school-cloud',
        }),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsStartupFlow(
            initializeConnections: () async {},
            checkSetup: () async => true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('Open Admin Panel'), findsNothing);
      expect(
        find.byType(WindowsFirstRunSecuritySetup, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('Save & Open App'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('existing App Lock password survives reload and stays separate from school login and section locks', () async {
    await WindowsLocalSecurity.initialize();
    await WindowsLocalSecurity.create(
      adminId: 'local-admin',
      password: 'existing-lock-123',
    );
    await WindowsSectionLocks.addPassword(
      sectionKey: 'admin_section',
      password: 'section-only-123',
    );
    await WindowsLocalSecurity.initialize();
    expect(WindowsLocalSecurity.verifyPassword('existing-lock-123'), true);
    expect(WindowsLocalSecurity.verifyPassword('wrong-password'), false);
    expect(WindowsLocalSecurity.verifyPassword('school-login-123'), false);
    expect(WindowsLocalSecurity.verifyPassword('section-only-123'), false);
  });
  testWidgets('fresh authenticated install offers backup before cloud hydration', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key:jsonEncode({
        'managed':true,'projectId':platformProjectId,
        'schoolId':'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','uid':'A',
        'email':'a@school.example','folderId':'managed','firebaseRefreshToken':'refresh',
        'endpoint':'https://school.example/school-cloud',
      }),
    });
    var hydrated=0,checked=0,probed=0;
    await tester.pumpWidget(MaterialApp(home:WindowsStartupFlow(
      offerRestore:true,
      freshInstallationProbe:()async {probed++;return true;},
      initializeConnections:()async {hydrated++;},
      checkSetup:()async {checked++;throw StateError('registration unavailable');},
    )));
    await tester.pump();await tester.pump();await tester.pump();
    expect(probed,1);
    expect(find.text('Restore Existing School'),findsOneWidget);
    expect(find.text('Continue school setup'),findsOneWidget);
    expect(hydrated,0);
    expect(checked,0);
    expect(find.text('Save & Open App'),findsNothing);
    await tester.tap(find.text('Continue school setup'));
    await tester.pump();await tester.pump();await tester.pump();
    expect(hydrated,1);
    expect(checked,1);
    expect(probed,1); // Explicit continue bypasses only the offer, not login.
    expect(find.text('Restore Existing School'),findsNothing);
    expect(find.text('Retry school profile restore'),findsOneWidget);
    expect(find.text('Save & Open App'),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('failed freshness verification shows retry without opening setup or hydrating', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key:jsonEncode({
        'managed':true,'projectId':platformProjectId,
        'schoolId':'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','uid':'A',
        'email':'a@school.example','folderId':'managed','firebaseRefreshToken':'refresh',
        'endpoint':'https://school.example/school-cloud',
      }),
    });
    var hydrated=0,checked=0;
    await tester.pumpWidget(MaterialApp(home:WindowsStartupFlow(
      offerRestore:true,
      freshInstallationProbe:()async {throw StateError('identity not verified');},
      initializeConnections:()async {hydrated++;},
      checkSetup:()async {checked++;return false;},
    )));
    await tester.pump();await tester.pump();await tester.pump();
    expect(hydrated,0);
    expect(checked,0);
    expect(find.text('Restore Existing School'),findsNothing);
    expect(find.text('Save & Open App'),findsNothing);
    expect(find.text('Retry school profile restore'),findsOneWidget);
    expect(find.byType(CircularProgressIndicator),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('theme applies at unlock; reconnect heartbeat and relocked late response preserve open-session colour', () async {
    FlutterSecureStorage.setMockInitialValues(trialSchoolIdentity());
    final original=WindowsAppearance.brandData;
    var revision='first';
    Map<String,dynamic> response() => {'activation':'app-lock-unlock-v2','schoolId':'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'windowsTheme':{'schemaVersion':1,'red':20,'green':100,'blue':180,'revision':revision}};
    ManagedSchoolSession.appearanceRequestForTesting=(_,locked) async => response();
    try {
      await ManagedSchoolSession.reportAppearanceLock(true);
      await ManagedSchoolSession.refreshAppearanceAtUnlock();
      expect(WindowsAppearance.brandRevision,'first');
      revision='second';
      await ManagedSchoolSession.reportAppearanceLock(false);
      expect(WindowsAppearance.brandRevision,'first');
      final entered=Completer<void>(), reply=Completer<Map<String,dynamic>>();
      ManagedSchoolSession.appearanceRequestForTesting=(_,locked) async {
        if(!locked){entered.complete();return reply.future;}
        return response();
      };
      final unlock=ManagedSchoolSession.refreshAppearanceAtUnlock();
      await entered.future;
      final lock=ManagedSchoolSession.reportAppearanceLock(true);
      reply.complete(response());
      await Future.wait([unlock,lock]);
      expect(WindowsAppearance.brandRevision,'first');
      ManagedSchoolSession.appearanceRequestForTesting=(_,locked) async => response();
      await ManagedSchoolSession.refreshAppearanceAtUnlock();
      expect(WindowsAppearance.brandRevision,'second');
    } finally {
      ManagedSchoolSession.appearanceRequestForTesting=null;
      WindowsAppearance.applyBrand(original,persist:false);
    }
  });

  Map<String, dynamic> unlockTheme(String revision) => {
    'activation': 'app-lock-unlock-v2',
    'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'windowsTheme': {
      'schemaVersion': 1,
      'red': 255,
      'green': 112,
      'blue': 91,
      'presetId': 'sunset-ember',
      'revision': revision,
    },
  };
  test('verified unlock bypasses a stalled heartbeat queue', () async {
    FlutterSecureStorage.setMockInitialValues(trialSchoolIdentity());
    final original = WindowsAppearance.brandData,
        entered = Completer<void>(),
        pending = Completer<Map<String, dynamic>>();
    ManagedSchoolSession.appearanceRequestForTesting = (_, locked) async {
      if (locked) {
        entered.complete();
        return pending.future;
      }
      return unlockTheme('heartbeat');
    };
    ManagedSchoolSession.appearanceUnlockRequestForTesting = (_) async =>
        unlockTheme('independent');
    try {
      final heartbeat = ManagedSchoolSession.reportAppearanceLock(true);
      await entered.future;
      expect(
        await ManagedSchoolSession.refreshAppearanceAtUnlock(),
        ThemeUnlockOutcome.applied,
      );
      expect(WindowsAppearance.brandRevision, 'independent');
      pending.complete(unlockTheme('late-heartbeat'));
      await heartbeat;
      expect(WindowsAppearance.brandRevision, 'independent');
    } finally {
      ManagedSchoolSession.appearanceRequestForTesting = null;
      ManagedSchoolSession.appearanceUnlockRequestForTesting = null;
      WindowsAppearance.applyBrand(original, persist: false);
    }
  });
  test(
    'timeout is reported and a late theme cannot recolour the open dashboard',
    () async {
      FlutterSecureStorage.setMockInitialValues(trialSchoolIdentity());
      final original = WindowsAppearance.brandData;
      final reply = Completer<Map<String, dynamic>>();
      ManagedSchoolSession.appearanceUnlockRequestForTesting = (_) =>
          reply.future;
      try {
        expect(
          await ManagedSchoolSession.refreshAppearanceAtUnlock(
            timeout: const Duration(milliseconds: 10),
          ),
          ThemeUnlockOutcome.deferred,
        );
        reply.complete(unlockTheme('too-late'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(WindowsAppearance.brandRevision, original['revision']);
        ManagedSchoolSession.appearanceUnlockRequestForTesting = (_) async =>
            unlockTheme('retry');
        expect(
          await ManagedSchoolSession.refreshAppearanceAtUnlock(),
          ThemeUnlockOutcome.applied,
        );
        expect(WindowsAppearance.brandRevision, 'retry');
      } finally {
        ManagedSchoolSession.appearanceUnlockRequestForTesting = null;
        WindowsAppearance.applyBrand(original, persist: false);
      }
    },
  );
  test(
    'invalid response or changed school preserves the current theme',
    () async {
      FlutterSecureStorage.setMockInitialValues(trialSchoolIdentity());
      final original = WindowsAppearance.brandData;
      ManagedSchoolSession.appearanceUnlockRequestForTesting = (_) async => {
        'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'windowsTheme': {'schemaVersion': 1},
      };
      try {
        expect(
          await ManagedSchoolSession.refreshAppearanceAtUnlock(),
          ThemeUnlockOutcome.deferred,
        );
        final entered = Completer<void>(),
            reply = Completer<Map<String, dynamic>>();
        ManagedSchoolSession.appearanceUnlockRequestForTesting = (_) {
          entered.complete();
          return reply.future;
        };
        final operation = ManagedSchoolSession.refreshAppearanceAtUnlock();
        await entered.future;
        FlutterSecureStorage.setMockInitialValues({
          CentralSchoolCloud.key: jsonEncode({
            ...jsonDecode(trialSchoolIdentity()[CentralSchoolCloud.key]!) as Map,
            'managed': true,
            'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'uid': 'other',
            'endpoint': 'https://school.example/school-cloud',
          }),
        });
        reply.complete(unlockTheme('foreign'));
        expect(await operation, ThemeUnlockOutcome.interrupted);
        expect(WindowsAppearance.brandRevision, original['revision']);
      } finally {
        ManagedSchoolSession.appearanceUnlockRequestForTesting = null;
        WindowsAppearance.applyBrand(original, persist: false);
      }
    },
  );
  testWidgets(
    'exact App Lock screen checks theme only after correct password and waits before dashboard',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues(trialSchoolIdentity());
      final original = WindowsAppearance.brandData;
      await WindowsLocalSecurity.initialize();
      await WindowsLocalSecurity.clearAppLock();
      await WindowsLocalSecurity.create(
        adminId: 'School app',
        password: 'local-password',
      );
      var requests = 0;
      final reply = Completer<Map<String, dynamic>>();
      ManagedSchoolSession.appearanceUnlockRequestForTesting = (_) {
        requests++;
        return reply.future;
      };
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: WindowsStartupGate(
              prepareLock: () async => true,
              completeUnlock: () async {},
              child: const Scaffold(body: Text('Unlocked test dashboard')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'wrong');
        await tester.tap(find.text('Unlock App'));
        await tester.pumpAndSettle();
        expect(requests, 0);
        await tester.enterText(find.byType(TextField), 'local-password');
        await tester.tap(find.text('Unlock App'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Checking saved theme…'), findsOneWidget);
        expect(find.text('Unlocked test dashboard'), findsNothing);
        reply.complete(unlockTheme('password-verified'));
        await tester.pump();
        for(var i=0;i<12 && find.text('Unlocked test dashboard').evaluate().isEmpty;i++) {
          await tester.pump(const Duration(milliseconds:300));
        }
        await tester.pumpAndSettle();
        expect(requests, 1);
        expect(WindowsAppearance.brandRevision, 'password-verified');
        expect(find.text('Unlocked test dashboard'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        ManagedSchoolSession.appearanceUnlockRequestForTesting = null;
        await WindowsLocalSecurity.clearAppLock();
        WindowsAppearance.applyBrand(original, persist: false);
      }
    },
  );
}
