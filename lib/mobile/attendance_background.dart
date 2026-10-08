import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'school_session.dart';

@pragma('vm:entry-point')
void attendanceBackgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (task != 'vs_attendance_reconcile_v2') return true;
    try {
      final session = SchoolSession();
      await session.restore();
      if (!session.loggedIn) return true;
      await session.flushAttendance();
      return true;
    } catch (_) {
      // SQLite leases recover unfinished attempts; no queue/data/session clearing.
      return false;
    }
  });
}

Future<void> initializeAttendanceBackground() async {
  if (!Platform.isAndroid) return;
  try {
    await Workmanager().initialize(attendanceBackgroundDispatcher);
    await Workmanager().registerPeriodicTask(
      'vs_attendance_reconcile_v2', 'vs_attendance_reconcile_v2',
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (_) {
    SchoolSession.instance.attendanceFailure =
        'Background scheduling unavailable. Reopen the app to retry pending attendance.';
    SchoolSession.instance.attendanceChanges.value++;
  }
}
