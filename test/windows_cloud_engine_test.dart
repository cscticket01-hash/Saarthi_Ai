import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/platform/platform_config.dart';
import '../lib/main_windows.dart';
import '../lib/windows_local_settings.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/school_cloud_engine.dart';
import '../lib/windows_secure_storage.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_managed_school_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 6);
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  Map<String, dynamic> access({
    String status = 'licensed',
    bool allowed = true,
    bool activated = true,
  }) => {
    'success': true,
    'schoolId': school,
    'uid': 'A',
    'projectId': platformProjectId,
    'allowed': allowed,
    'activated': activated,
    'status': status,
    'expiresAt': now.add(const Duration(days: 5)).millisecondsSinceEpoch,
    'serverTime': now.millisecondsSinceEpoch,
  };
  Map<String, dynamic> identity(Map<String, dynamic>? lease) => {
    'managed': true,
    'schoolId': school,
    'uid': 'A',
    'projectId': platformProjectId,
    if (lease != null) 'verifiedAccess': lease,
  };
  SchoolCloudEngine engine(
    Map<String, dynamic> saved, {
    Future<Map<String, dynamic>> Function()? verify,
    Future<void> Function(Map<String, dynamic>, Map<String, dynamic>)? persist,
  }) => SchoolCloudEngine(
    readIdentity: () async => saved,
    clock: () => now,
    activateLocal: () async {},
    legacyAccess: () async => null,
    touchClock: (a, b) async {},
    verify: verify ?? () async => throw const SocketException('offline'),
    persist: persist ?? (a, b) async {},
  );
  test('enforced device access never falls back to unsigned offline cache', () async {
    final saved={...identity({...access(),'deviceEnforced':true}), 'deviceEnforced':true};
    final e=engine(saved);
    await e.restore();
    expect(e.localReady,true);
    expect(e.canOpen,false);
    e.dispose();
  });
  test('trial skip works on day four and stops at original day-five expiry', () async {
    var time = now.add(const Duration(days: 4));
    final saved = identity(access(status: 'trial', activated: false));
    final e = SchoolCloudEngine(readIdentity: () async => saved, clock: () => time,
      activateLocal: () async {}, legacyAccess: () async => null,
      touchClock: (a,b) async {}, persist: (a,b) async {},
      verify: () async => throw const SocketException('offline'));
    await e.restore();
    await Future<void>.delayed(Duration.zero);
    expect(await e.continueTrial(), true);
    time = now.add(const Duration(days: 5));
    expect(e.canOpen, false);
    expect(await e.continueTrial(), false);
    e.dispose();
  });
  test('Skip awaits the existing verification and replaces future-dated cache', () async {
    final pending = Completer<Map<String,dynamic>>();
    var calls = 0;
    final cached = {...access(status:'trial',activated:false),
      'serverTime':now.add(const Duration(hours:1)).millisecondsSinceEpoch};
    final e = engine(identity(cached),verify:(){calls++;return pending.future;});
    await e.restore();
    var completed = false;
    final skip = e.continueTrial().then((result){completed=true;return result;});
    await Future<void>.delayed(Duration.zero);
    expect(completed,false);expect(calls,1);
    pending.complete(access(status:'trial',activated:false));
    expect(await skip,true);
    expect(e.access?['serverTime'],now.millisecondsSinceEpoch);
    e.dispose();
  });
  test('authenticated server clock admits a wrong-clock PC without extending trial expiry', () async {
    var pcTime=now.subtract(const Duration(days:1));
    var elapsed=Duration.zero;
    final snapshot=access(status:'trial',activated:false);
    final saved={...identity(snapshot),'lastLocalSeenAt':now.millisecondsSinceEpoch};
    final e=SchoolCloudEngine(readIdentity:()async=>saved,clock:()=>pcTime,elapsed:()=>elapsed,
      activateLocal:()async{},legacyAccess:()async=>null,touchClock:(a,b)async{},
      persist:(a,b)async{},verify:()async=>snapshot);
    await e.restore();await e.verify();
    expect(await e.continueTrial(),true);
    pcTime=pcTime.subtract(const Duration(days:10));
    elapsed=const Duration(days:5);
    expect(e.canOpen,false);
    e.dispose();
  });
  test('Skip cannot bypass blocked, foreign-school or device-proof access', () async {
    for (final lease in [access(status:'blocked',allowed:false),
      {...access(status:'trial'), 'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
      {...access(status:'trial'), 'deviceEnforced':true}]) {
      final e = engine(identity(lease));
      await e.restore();
      await Future<void>.delayed(Duration.zero);
      expect(await e.continueTrial(), false);
      e.dispose();
    }
  });
  testWidgets('valid trial reaches setup content without a separate licence gate', (tester) async {
    final e = engine(identity(access(status:'trial',activated:false)));
    await tester.pumpWidget(MaterialApp(home: WindowsManagedSchoolGate(engine:e,
      child:const Text('Trial Console'),legacy:const Text('Legacy'))));
    await tester.pump();await tester.pump();
    expect(find.text('Skip'),findsNothing);
    expect(find.text('Retry school verification'),findsNothing);
    expect(find.text('Trial Console'),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  test('signed device lease expires and enforcement cannot downgrade in memory', () async {
    var time=now;
    final expiry=now.add(const Duration(minutes:15)).millisecondsSinceEpoch;
    final token='${base64UrlEncode(utf8.encode(jsonEncode({'expiresAt':expiry})))}.test-signature';
    var saved=identity({...access(),'deviceEnforced':true,'offlineLease':token});
    var response=<String,dynamic>{...access(),'deviceEnforced':false};
    final e=SchoolCloudEngine(readIdentity:()async=>saved,clock:()=>time,
      activateLocal:()async{},legacyAccess:()async=>null,touchClock:(a,b)async{},
      verifyDeviceLease:(a,b,c)async=>b['offlineLease']==token,
      verify:()async=>response,persist:(a,b)async{saved={...saved,'verifiedAccess':b,'deviceEnforced':true};});
    await e.restore();
    await Future<void>.delayed(Duration.zero);
    expect(e.canOpen,true);
    await e.verify();
    expect(e.access?['deviceEnforced'],true);
    expect(e.canOpen,true);
    time=time.add(const Duration(minutes:15));
    expect(e.canOpen,false);
    e.dispose();
  });
  test(
    'existing authenticated school restores locally without waiting for cloud',
    () async {
      final cloud = Completer<Map<String, dynamic>>();
      final e = engine(identity(access()), verify: () => cloud.future);
      await e.restore();
      expect(e.canOpen, true);
      expect(e.restoring, false);
      cloud.completeError(const SocketException('offline'));
      await Future<void>.delayed(Duration.zero);
      expect(e.canOpen, true);
      expect(e.state, SchoolCloudState.offline);
      e.dispose();
    },
  );
  test(
    'trial works offline, expired, blocked and unactivated leases never open',
    () async {
      for (final lease in [
        access(status: 'trial', activated: false),
        access(),
      ]) {
        final e = engine(identity(lease));
        await e.restore();
        expect(e.canOpen, true);
        e.dispose();
      }
      for (final lease in [
        access(allowed: false, status: 'blocked'),
        access(activated: false),
        {...access(), 'expiresAt': now.millisecondsSinceEpoch},
        {
          ...access(),
          'serverTime': now
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        },
      ]) {
        final e = engine(identity(lease));
        await e.restore();
        expect(e.canOpen, false);
        e.dispose();
      }
    },
  );
  test(
    'first install and foreign school/UID caches cannot authenticate locally',
    () async {
      for (final saved in [
        <String, dynamic>{},
        identity(null),
        identity({...access(), 'uid': 'B'}),
        identity({
          ...access(),
          'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        }),
        {
          ...identity(access()),
          'lastLocalSeenAt': now
              .add(const Duration(hours: 2))
              .millisecondsSinceEpoch,
        },
      ]) {
        final e = engine(saved);
        await e.restore();
        expect(e.canOpen, false);
        e.dispose();
      }
    },
  );
  test('staged 24-hour daily verification becomes read-only without deleting school access',()async{
    var clock=now.add(const Duration(hours:23));
    var allowOnline=false;
    final snapshot=identity(access());
    final e=SchoolCloudEngine(
      readIdentity:()async=>snapshot,clock:()=>clock,requireDailyOnline:true,
      activateLocal:()async{},legacyAccess:()async=>null,
      touchClock:(a,b)async{},persist:(a,b)async{},
      verify:()async{
        if(!allowOnline)throw const SocketException('offline');
        return {...access(),'serverTime':clock.millisecondsSinceEpoch};
      },
    );
    await e.restore();
    expect(e.canOpen,true);
    expect(e.dailyOnlineReadOnly,false);
    clock=now.add(const Duration(hours:24));
    expect(e.canOpen,false);
    expect(e.dailyOnlineReadOnly,true);
    allowOnline=true;
    await e.verifyNow();
    expect(e.canOpen,true);
    expect(e.dailyOnlineReadOnly,false);
    e.dispose();
  });

  testWidgets('24-hour offline mode displays disclaimer and disables school controls', (tester)async{
    var clock=now.add(const Duration(hours:24));
    var clicked=0;
    final e=SchoolCloudEngine(
      readIdentity:()async=>identity(access()),clock:()=>clock,
      requireDailyOnline:true,activateLocal:()async{},
      legacyAccess:()async=>null,touchClock:(a,b)async{},
      persist:(a,b)async{},verify:()async=>throw const SocketException('offline'),
    );
    await tester.pumpWidget(MaterialApp(home:WindowsManagedSchoolGate(
      engine:e,legacy:const Text('Legacy'),
      child:ElevatedButton(onPressed:()=>clicked++,child:const Text('Collect payment')),
    )));
    await tester.pump();await tester.pump();
    // Dashboard opens straight away. First 3 seconds are still read-only:
    // showing the warning later does not grant an unauthorized grace period.
    expect(find.text('Collect payment'),findsOneWidget);
    expect(find.byKey(const ValueKey('daily-online-verification-disclaimer')),findsNothing);
    await tester.tap(find.text('Collect payment'),warnIfMissed:false);
    await tester.pump();
    expect(clicked,0);
    await tester.pump(const Duration(milliseconds: 2900));
    expect(find.byKey(const ValueKey('daily-online-verification-disclaimer')),findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('daily-online-verification-disclaimer')),findsOneWidget);
    expect(find.textContaining('Internet unavailable, please connect internet'),findsOneWidget);
    expect(find.text('Verify online'),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('online during the 24-hour window automatically renews authenticated server lease',()async{
    var clock=now.add(const Duration(hours:23));
    var online=false;
    var verified=0;
    var snapshot=identity(access());
    final e=SchoolCloudEngine(
      readIdentity:()async=>snapshot,clock:()=>clock,requireDailyOnline:true,
      activateLocal:()async{},legacyAccess:()async=>null,touchClock:(a,b)async{},
      persist:(a,b)async{snapshot={...snapshot,'verifiedAccess':b};},
      verify:()async{
        verified++;
        if(!online)throw const SocketException('network is down');
        return {...access(),'serverTime':clock.millisecondsSinceEpoch};
      },
    );
    await e.restore();
    await Future<void>.delayed(Duration.zero);
    expect(e.canOpen,true);
    // No full sync needed: ordinary authenticated network activity is enough.
    online=true;
    clock=clock.add(const Duration(minutes:2));
    await e.refreshAfterNetworkUse();
    expect(e.canOpen,true);
    expect(e.dailyOnlineReadOnly,false);
    expect(e.access?['serverTime'],clock.millisecondsSinceEpoch);
    expect(verified,greaterThanOrEqualTo(2));
    online=false;
    clock=clock.add(const Duration(hours:23));
    expect(e.canOpen,true);
    clock=clock.add(const Duration(hours:1));
    expect(e.canOpen,false);
    expect(e.dailyOnlineReadOnly,true);
    e.dispose();
  });

  test('ping or failed cloud verification never reset the 24-hour server deadline',()async{
    var clock=now.add(const Duration(hours:23));
    var responses=0;
    final saved=identity(access());
    final e=SchoolCloudEngine(
      readIdentity:()async=>saved,clock:()=>clock,requireDailyOnline:true,
      activateLocal:()async{},legacyAccess:()async=>null,touchClock:(a,b)async{},
      persist:(a,b)async{},
      verify:()async{responses++;throw const SocketException('dns failure');},
    );
    await e.restore();
    await Future<void>.delayed(Duration.zero);
    clock=clock.add(const Duration(hours:1));
    expect(e.canOpen,false);
    await e.verifyNow();
    expect(responses,greaterThanOrEqualTo(1));
    expect(e.dailyOnlineReadOnly,true);
    e.dispose();
  });

  test('cached paid licence cannot remain offline indefinitely',()async {
    final lease={...access(),'serverTime':now.subtract(const Duration(hours:73)).millisecondsSinceEpoch};
    final e=engine(identity(lease));await e.restore();expect(e.canOpen,false);e.dispose();
  });
  test('real central denial persists while network failures preserve last verified access', () async {
    for (final status in [401, 403]) {
      Map<String, dynamic>? persisted;
      final e = engine(
        identity(access()),
        verify: () async =>
            throw CentralCloudException(status, 'school_cloud', 'denied'),
        persist: (a, b) async {
          persisted = b;
        },
      );
      await e.restore();
      await Future<void>.delayed(Duration.zero);
      expect(e.canOpen, false);
      expect(persisted?['allowed'], false);
      e.dispose();
      final restart = engine(identity(persisted!));
      await restart.restore();
      expect(restart.canOpen, false);
      restart.dispose();
    }
    final e = engine(
      identity(access()),
      verify: () async =>
          throw CentralCloudException(503, 'school_cloud', 'unavailable'),
    );
    await e.restore();
    await Future<void>.delayed(Duration.zero);
    expect(e.canOpen, true);
    e.dispose();
  });
  test(
    'failed verification retries and refreshes real licence status',
    () async {
      var calls = 0;
      final e = engine(
        identity(access()),
        verify: () async {
          if (calls++ == 0) throw const SocketException('offline');
          return access(status: 'trial', activated: false);
        },
      );
      await e.restore();
      await Future<void>.delayed(Duration.zero);
      expect(e.state, SchoolCloudState.offline);
      await e.verify();
      expect(e.canOpen, true);
      expect(e.access?['status'], 'trial');
      e.dispose();
    },
  );
  test('an older school verification cannot install access in a newer school session', () async {
    final pending = Completer<Map<String, dynamic>>();
    var writes = 0;
    var saved = identity(access());
    final e = SchoolCloudEngine(
      readIdentity: () async => saved,
      verify: () => pending.future,
      activateLocal: () async {},
      legacyAccess: () async => null,
      touchClock: (a, b) async {},
      clock: () => now,
      persist: (a, b) async {
        writes++;
      },
    );
    await e.restore();
    saved = {
      'managed': true,
      'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'uid': 'B',
      'projectId': platformProjectId,
    };
    await e.restore();
    pending.complete(access());
    await Future<void>.delayed(Duration.zero);
    expect(e.canOpen, false);
    expect(e.identity?['uid'], 'B');
    expect(writes, 0);
    e.dispose();
  });
  test(
    'secure storage queue serializes operations and recovers after an error',
    () async {
      final held = Completer<void>();
      final order = <String>[];
      final first = WindowsSecureStorage.run(() async {
        order.add('first');
        await held.future;
        throw StateError('failure');
      });
      final failure = expectLater(first, throwsStateError);
      final second = WindowsSecureStorage.run(() async {
        order.add('second');
        return 'saved';
      });
      await Future<void>.delayed(Duration.zero);
      expect(order, ['first']);
      held.complete();
      await failure;
      expect(await second, 'saved');
      expect(order, ['first', 'second']);
    },
  );
  test(
    'sharing violation retries safely without deleting credentials',
    () async {
      var attempts = 0;
      expect(
        await WindowsSecureStorage.run(() async {
          if (attempts++ < 2)
            throw const FileSystemException(
              'sharing violation',
              'credential-file',
              OSError('busy', 32),
            );
          return 'retained';
        }),
        'retained',
      );
      expect(attempts, 3);
      expect(
        WindowsSecureStorage.sharingViolation(
          const FileSystemException('denied', 'path', OSError('denied', 5)),
        ),
        false,
      );
    },
  );
  testWidgets(
    'cached school stays in local UI after cloud fails; no login or blocking connection screen',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final e = engine(identity(access()), verify: () => pending.future);
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsManagedSchoolGate(
            engine: e,
            child: const Text('Local School Console'),
            legacy: const Text('Legacy'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Local School Console'), findsOneWidget);
      pending.completeError(const SocketException('offline'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Local School Console'), findsOneWidget);
      expect(find.text('School Login'), findsNothing);
      expect(find.textContaining('Offline / Sync pending'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'App Lock rejects wrong password then animates success and directly opens console',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.runAsync(() async {
        await WindowsLocalSecurity.initialize();
        await WindowsLocalSecurity.create(
          adminId: 'School app',
          password: 'saved-app-lock',
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsStartupGate(
            prepareLock: () async => true,
            completeUnlock: () async {},
            child: const Text('Unlocked Console'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final field = find.byType(TextField);
      await tester.enterText(field, 'wrong-password');
      await tester.tap(find.text('Unlock App'));
      await tester.pump();
      expect(find.text('Unlocked Console'), findsNothing);
      expect(find.text('Galat App Password.'), findsOneWidget);
      await tester.enterText(field, 'saved-app-lock');
      await tester.tap(find.text('Unlock App'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Login Successful'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      expect(find.text('Unlocked Console'), findsOneWidget);
      expect(find.text('Open Admin Panel'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'Windows OS sharing lock retries across a separate process without reset',
    () async {
      final base = Platform.environment['APPDATA']!;
      final directory = Directory('$base${Platform.pathSeparator}VidyaSaarthi');
      await directory.create(recursive: true);
      final path =
          '${directory.path}${Platform.pathSeparator}secure_storage.lock';
      final process = await Process.start(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "\$f=[IO.File]::Open(\$env:SAARTHI_TEST_LOCK,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); [Console]::WriteLine('locked'); Start-Sleep -Milliseconds 1500; \$f.Dispose()",
        ],
        environment: {'SAARTHI_TEST_LOCK': path},
      );
      await process.stdout.transform(systemEncoding.decoder).first;
      FlutterSecureStorage.setMockInitialValues({
        'crossprocess_credential': 'retained-credential',
      });
      WindowsSecureStorage.forceCrossProcessLock = true;
      final watch = Stopwatch()..start();
      try {
        expect(
          await const WindowsSecureStorage().read(
            key: 'crossprocess_credential',
          ),
          'retained-credential',
        );
        expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(400));
        expect(await process.exitCode, 0);
      } finally {
        WindowsSecureStorage.forceCrossProcessLock = null;
      }
    },
    skip: !Platform.isWindows,
  );
  test(
    'credential transaction retains newer denial and monotonic clock',
    () async {
      final saved = {
        ...identity(access(allowed: false, status: 'blocked')),
        'firebaseRefreshToken': 'refresh-A',
        'folderId': 'managed',
        'endpoint': 'https://school.example/school-cloud',
        'lastLocalSeenAt': now.millisecondsSinceEpoch,
      };
      FlutterSecureStorage.setMockInitialValues({
        CentralSchoolCloud.key: jsonEncode(saved),
      });
      await CentralSchoolCloud.updateSession(school, {
        'verifiedAccess': {
          ...access(),
          'serverTime': now
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
        },
        'lastLocalSeenAt': now
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      }, expectedUid: 'A');
      final result = await CentralSchoolCloud.saved();
      expect(result['verifiedAccess']['allowed'], false);
      expect(result['lastLocalSeenAt'], now.millisecondsSinceEpoch);
      await expectLater(
        CentralSchoolCloud.updateSession(school, {
          'verifiedAccess': access(),
        }, expectedUid: 'B'),
        throwsStateError,
      );
      expect((await CentralSchoolCloud.saved())['uid'], 'A');
    },
  );
  test(
    'failed tenant activation cannot expose a previous school console',
    () async {
      var fails = true;
      final e = SchoolCloudEngine(
        readIdentity: () async => identity(access()),
        verify: () async => throw const SocketException('offline'),
        persist: (a, b) async {},
        touchClock: (a, b) async {},
        legacyAccess: () async => null,
        clock: () => now,
        activateLocal: () async {
          if (fails) throw StateError('local storage busy');
        },
      );
      await e.restore();
      expect(e.canOpen, false);
      expect(e.localReady, false);
      fails = false;
      await e.restore();
      expect(e.canOpen, true);
      e.dispose();
    },
  );
}
