import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'school_session.dart';

class SchoolNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static Future<void> initialize() async {
    await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher')));
  }
  static bool belongsToSession(Map<String, dynamic> data, String? project) =>
      project != null && data['schoolId'] == project &&
      data['type'] == 'school_notice';

  static Future<void> show(RemoteMessage message) async {
    final session = SchoolSession.instance;
    if (!session.loggedIn || !belongsToSession(message.data, session.link?.projectId)) return;
    await initialize();
    await _plugin.show(
      (message.data['noticeId']?.hashCode ?? message.hashCode) & 0x7fffffff,
      message.data['title'] ?? 'School notice',
      message.data['body'] ?? '',
      const NotificationDetails(android: AndroidNotificationDetails(
        'school_notices', 'School notices',
        channelDescription: 'Notices from your verified school',
        importance: Importance.high, priority: Priority.high)),
      payload: session.link!.projectId);
  }
  static Future<void> clear() => _plugin.cancelAll();
}
