import 'dart:io';

class WindowsAppRestart {
  WindowsAppRestart._();

  static Future<void> restart({String reason = ''}) async {
    final executable = Platform.resolvedExecutable;
    await Process.start(
      executable,
      const <String>[],
      mode: ProcessStartMode.detached,
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));
    exit(0);
  }
}
