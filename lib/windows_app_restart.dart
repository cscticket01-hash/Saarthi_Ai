import 'dart:io';
import 'windows_runtime_diagnostics.dart';

class WindowsAppRestart {
  WindowsAppRestart._();

  static bool _restarting=false;
  static Future<void> restart({String reason = ''}) async {
    if(_restarting)return;
    _restarting=true;
    try{
      final executable=Platform.resolvedExecutable;
      // The generated runner waits only for an explicit restart.
      await Process.start(executable,const <String>['--saarthi-restart'],
        mode:ProcessStartMode.detached);
      WindowsRuntimeDiagnostics.record('exit.requested_restart');
      await Future<void>.delayed(const Duration(milliseconds:350));
      exit(0);
    }catch(error,stack){
      _restarting=false;
      WindowsRuntimeDiagnostics.record('restart.launch_failed',error:error,stack:stack);
      rethrow;
    }
  }
}
