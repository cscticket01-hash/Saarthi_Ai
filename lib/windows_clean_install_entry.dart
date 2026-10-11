import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'windows_clean_install_recovery.dart';
import 'windows_clean_install_restore_screen.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_local_firestore.dart';
import 'windows_local_storage.dart';
import 'windows_sync_engine.dart';

Future<String> verifiedRecoverySchool({bool refresh=false}) async {
  final saved=await CentralSchoolCloud.saved();
  final school=saved['schoolId'];
  if(saved['managed']!=true || school is! String || saved['uid'] is! String) {
    throw StateError('Sign in to the correct central school account first.');
  }
  final access=refresh
      ? await ManagedSchoolSession.callForSchool(school,'managed/session',{}).timeout(const Duration(seconds:25))
      : saved['verifiedAccess'];
  if(access is! Map || access['success']!=true || access['allowed']!=true ||
      access['schoolId']!=school || access['uid']!=saved['uid']) {
    throw StateError('Verified central school administrator identity required.');
  }
  return school;
}

Future<WindowsCleanInstallRecovery> localRecoveryService({bool refresh=false}) async =>
    WindowsCleanInstallRecovery(controlDirectory:WindowsLocalStorage.controlDirectory,
      currentDataDirectory:await WindowsLocalStorage.dataDirectory(),
      authenticateSchool:()=>verifiedRecoverySchool(refresh:refresh));

/// No network or database write is needed when there is no recovery journal.
Future<void> recoverLocalActivationBeforeStorage() async {
  final recovery=await localRecoveryService();
  await recovery.recoverInterruptedActivation();
}

Future<void> openCleanInstallRestore(BuildContext context) async {
  final recovery=await localRecoveryService(refresh:true);
  if(!context.mounted)return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>
    WindowsCleanInstallRestoreScreen(recovery:recovery,beforeActivation:()async {
      await WindowsSyncEngine.instance.pauseForAppReset();
      await FirebaseFirestore.instance.resetVolatileSession();
    },afterActivation:()async {
      // Reopen the exact running application; first startup verifies the journal
      // before opening either the previous or staged school database.
      await Process.start(Platform.resolvedExecutable,Platform.executableArguments,
        mode:ProcessStartMode.detached);
      exit(0);
    })));
}
