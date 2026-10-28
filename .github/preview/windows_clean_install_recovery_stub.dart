import 'dart:io';
class WindowsCleanInstallRecovery{
 WindowsCleanInstallRecovery({required this.controlDirectory,required this.currentDataDirectory,required this.authenticateSchool});
 final Directory controlDirectory,currentDataDirectory;final Future<String> Function() authenticateSchool;
 Future<bool> isFreshInstallation()async=>false;
 Future<Map<String,dynamic>> prepare(Directory backup,Directory staging,{Future<void> Function(int)? onFileVerified})async=>throw UnsupportedError('Recovery is unavailable in demo preview');
 Future<void> activate({required bool administratorConfirmed,Future<void> Function(String)? checkpoint})async=>throw UnsupportedError('Recovery is unavailable in demo preview');
 Future<String?> recoverInterruptedActivation()async=>null;
}
