import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'school_session.dart';

class SchoolNotifications {
  static final _opened=StreamController<void>.broadcast();
  static Stream<void> get opened=>_opened.stream;
  static final _plugin = FlutterLocalNotificationsPlugin();
  static Future<void> initialize() async {
    await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse:(response){
        final session=SchoolSession.instance;
        if(session.loggedIn && response.payload==session.link?.projectId) _opened.add(null);
      });
  }
  static bool belongsToSession(Map<String, dynamic> data, String? project) =>
      project != null && data['schoolId'] == project &&
      data['type'] == 'school_notice';

  static Future<void> show(RemoteMessage message) async {
    final session = SchoolSession.instance;
    if (!session.loggedIn || !belongsToSession(message.data, session.link?.projectId)) return;
    // A broadcast causes no Apps Script/Firestore request on sleeping phones.
    // Private content is loaded through the school session when the app opens.
    await initialize();
    await _plugin.show(
      (message.data['noticeId']?.hashCode ?? message.hashCode) & 0x7fffffff,
      'New school notice',
      'Open Vidya Saarthi to read the notice from your school.',
      const NotificationDetails(android: AndroidNotificationDetails(
        'school_notices', 'School notices',
        channelDescription: 'Notices from your verified school',
        importance: Importance.high, priority: Priority.high)),
      payload: session.link!.projectId);
  }
  static Future<void> clear() => _plugin.cancelAll();
}
