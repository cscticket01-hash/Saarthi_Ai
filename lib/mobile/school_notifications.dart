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
    // FCM carries no private school content. The current school session must
    // authorise the notice before its title/body are displayed.
    final response=await session.schoolCall('mobile_notice',{'noticeId':message.data['noticeId']});
    if(!session.loggedIn || !belongsToSession(message.data,session.link?.projectId)) return;
    final notice=response['notice'] is Map ? response['notice'] as Map : {};
    await initialize();
    await _plugin.show(
      (message.data['noticeId']?.hashCode ?? message.hashCode) & 0x7fffffff,
      notice['title']?.toString() ?? 'School notice',
      (notice['description'] ?? notice['message'] ?? '').toString(),
      const NotificationDetails(android: AndroidNotificationDetails(
        'school_notices', 'School notices',
        channelDescription: 'Notices from your verified school',
        importance: Importance.high, priority: Priority.high)),
      payload: session.link!.projectId);
  }
  static Future<void> clear() => _plugin.cancelAll();
}
