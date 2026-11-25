import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_developer_notifications.dart';
import '../lib/windows_local_firestore.dart' as local;
import '../lib/windows_runtime_flags.dart';
import '../lib/platform/platform_config.dart';

const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Map<String, dynamic> note(
  String audience,
  String id, {
  String title = 'Developer message',
}) => {
  'name':
      'projects/$platformProjectId/databases/(default)/documents/platform_developer_notifications/$audience/messages/$id',
  'fields': {
    'audience': {'stringValue': audience},
    'title': {'stringValue': title},
    'message': {'stringValue': 'Synthetic developer notification body'},
    'createdAt': {'timestampValue': '2026-10-18T11:00:00Z'},
  },
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = local.FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile(
      'notification-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school},
    );
  });
  test(
    'broadcast and own notifications deduplicate, paginate and retain read status offline without creating sync work',
    () async {
      var offline = false;
      final inbox = DeveloperInbox(
        readPage: (audience, cursor) async {
          if (offline) throw StateError('Offline');
          return {
            'documents': [note(audience, cursor == null ? 'first' : 'older')],
            if (cursor == null) 'nextPageToken': 'next',
          };
        },
      );
      await inbox.initialize();
      expect(inbox.unread, 2);
      expect(inbox.hasMore, true);
      await inbox.refresh();
      expect(inbox.messages.length, 2);
      await inbox.refresh(more: true);
      expect(inbox.messages.length, 4);
      await inbox.markRead(inbox.messages.first);
      expect(inbox.unread, 3);
      expect(
        (await db.collection('_windows_firebase_outbox').get()).docs,
        isEmpty,
      );
      inbox.dispose();
      final cached = DeveloperInbox(
        readPage: (a, c) async => throw StateError('Offline'),
      );
      await cached.initialize();
      expect(cached.messages.length, 4);
      expect(cached.unread, 3);
      expect(cached.error, isNotNull);
      cached.dispose();
    },
  );
  test('Warm Bell plays only for new unread revisions after startup, not refresh, paging or restart', () async {
    var newest = false, sounds = 0;
    final inbox = DeveloperInbox(
      playNotificationSound: () async { sounds++; },
      readPage: (audience, cursor) async => {
        'documents': [note(audience, cursor == null ? 'first' : 'older'),
          if (newest && cursor == null) note(audience, 'new')],
        if (cursor == null) 'nextPageToken': 'next',
      },
    );
    await inbox.initialize();
    expect(sounds, 0);
    await inbox.refresh();
    expect(sounds, 0);
    newest = true;
    await inbox.refresh();
    expect(sounds, 1);
    await inbox.refresh();
    await inbox.refresh(more: true);
    expect(sounds, 1);
    await inbox.markAllLoadedRead();
    expect(inbox.unread, 0);
    expect(inbox.messages.length, 6);
    inbox.dispose();
    final restarted = DeveloperInbox(
      playNotificationSound: () async { sounds++; },
      readPage: (audience, cursor) async => {
        'documents': [note(audience, 'first'), note(audience, 'new')],
      },
    );
    await restarted.initialize();
    expect(restarted.unread, 0);
    expect(sounds, 1);
    restarted.dispose();
  });
  testWidgets('notification inbox opens full developer message', (
    tester,
  ) async {
    final inbox = DeveloperInbox(
      readPage: (audience, cursor) async => {
        'documents': [note(audience, 'message')],
      },
    );
    await tester.runAsync(inbox.initialize);
    await tester.pumpWidget(
      MaterialApp(home: DeveloperInboxScreen(inbox: inbox)),
    );
    try {
      await tester.runAsync(() async {
        await tester.tap(find.text('Developer message').first);
        // The receipt uses actual asynchronous local-storage I/O.
        for (var i = 0; i < 100 && inbox.unread != 1; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        // Verify durable receipt, not just an optimistic badge.
        final reads = await db.collection('_windows_developer_inbox_read').get();
        expect(reads.docs, hasLength(1));
      });
      await tester.pumpAndSettle();
      expect(find.text('Synthetic developer notification body'), findsOneWidget);
      expect(inbox.unread, 1); // The detail is still open.
    } finally {
      await tester.pumpWidget(const SizedBox());
      inbox.dispose();
    }
  });
  test(
    'student complaints share the bell with class/device details and stale cached complaints disappear',
    () async {
      bool deleted = false;
      final inbox = DeveloperInbox(
        readPage: (a, c) async => {'documents': []},
        readComplaints: (cursor) async => {
          'complaints': deleted
              ? []
              : [
                  {
                    'id': 'student-case',
                    'schoolId': school,
                    'audience': 'school',
                    'studentName': 'Pupil',
                    'studentClass': '7',
                    'rollNo': '4',
                    'device': 'Samsung Android 15',
                    'deviceId': 'test-device',
                    'version': 'test',
                    'message': 'Cannot see ID',
                    'status': 'open',
                    'createdAt': DateTime.now().millisecondsSinceEpoch,
                  },
                ],
          'cursor': null,
        },
      );
      await inbox.initialize();
      expect(inbox.unread, 1);
      expect(inbox.messages.single['title'], contains('Class 7'));
      expect(inbox.messages.single['message'], contains('Samsung Android 15'));
      deleted = true;
      await inbox.refresh();
      expect(inbox.messages, isEmpty);
      expect(
        (await db.collection('_windows_developer_inbox').get()).docs,
        isEmpty,
      );
      inbox.dispose();
    },
  );
  test('resolved ticket from another PC is not unread; a new developer reply can reopen it', () async {
    var resolved=false,revision=1,sounds=0;
    final now=DateTime.now().millisecondsSinceEpoch;
    final inbox=DeveloperInbox(readPage:(a,c)async=>{'documents':[]},
      playNotificationSound:()async{sounds++;},
      readComplaints:(_)async=>{'complaints':[
        {'id':'school-ticket','schoolId':school,'message':'App issue','status':resolved?'resolved':'in_progress',
          'createdAt':now,'developerNote':'Reply $revision','developerUpdatedAt':now+revision},
      ],'cursor':null});
    try{
      await inbox.initialize();expect(inbox.unread,1);
      resolved=true;await inbox.refresh();expect(inbox.unread,0);expect(sounds,0);
      expect(inbox.supportTickets!.single['status'],'resolved');
      resolved=false;revision++;await inbox.refresh();expect(inbox.unread,1);expect(sounds,1);
    }finally{inbox.dispose();}
  });
  test('developer ticket replies and student complaint updates become unread separately', () async {
    var revision = 1;
    final inbox = DeveloperInbox(readPage: (a,c) async => {'documents': []},
      readComplaints: (_) async => {'complaints': [
        {'id':'own-ticket','schoolId':school,'message':'App issue','status':'in_progress',
          'developerNote':'Reply $revision','createdAt':1700000000000,'developerUpdatedAt':1700000000000+revision},
        {'id':'student-ticket','schoolId':school,'audience':'school','message':'Student problem',
          'status':revision == 1 ? 'open' : 'in_progress','createdAt':1700000000001},
      ],'cursor':null});
    await inbox.initialize();
    expect(inbox.unreadFor('support'),1);
    expect(inbox.unreadFor('student'),1);
    for(final row in inbox.messages) { await inbox.markRead(row); }
    expect(inbox.unread,0);
    revision++;
    await inbox.refresh();
    expect(inbox.unreadFor('support'),1);
    expect(inbox.unreadFor('student'),1);
    inbox.dispose();
  });
  test(
    'foreign path and changed profile during a response cannot write cache or expose another school',
    () async {
      final bad = DeveloperInbox(
        readPage: (a, c) async => {
          'documents': [note('foreign-school', 'bad')],
        },
      );
      await bad.initialize();
      expect(bad.error, isNotNull);
      expect(bad.messages, isEmpty);
      expect(
        (await db.collection('_windows_developer_inbox').get()).docs,
        isEmpty,
      );
      bad.dispose();
      final response = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      final switched = DeveloperInbox(
        readPage: (a, c) {
          if (!started.isCompleted) started.complete();
          return response.future;
        },
      );
      final loading = switched.initialize();
      await started.future;
      await db.switchProfile(
        'another-school',
        identity: {'schoolSyncId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
      );
      response.complete({
        'documents': [note('all', 'late')],
      });
      await loading;
      expect(switched.current, false);
      expect(switched.messages, isEmpty);
      expect(
        (await db.collection('_windows_developer_inbox').get()).docs,
        isEmpty,
      );
      switched.dispose();
    },
  );
}
