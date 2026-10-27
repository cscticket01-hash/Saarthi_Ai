import 'dart:io';
import 'package:file_selector/file_selector.dart' as files;
import 'package:flutter/material.dart';
import 'windows_clean_install_recovery.dart';

/// The existing authenticated login supplies the service. The integration must
/// stop local writers before activation and reopen storage only after restart.
class WindowsCleanInstallRestoreScreen extends StatefulWidget {
  const WindowsCleanInstallRestoreScreen({super.key,required this.recovery,
    required this.beforeActivation,required this.afterActivation});
  final WindowsCleanInstallRecovery recovery;
  final Future<void> Function() beforeActivation;
  final Future<void> Function() afterActivation;
  @override
  State<WindowsCleanInstallRestoreScreen> createState()=>_RestoreState();
}
class _RestoreState extends State<WindowsCleanInstallRestoreScreen> {
  bool busy=false;
  Map<String,dynamic>? prepared;
  String message='Select a sealed local backup. Never-uploaded operations can only be recovered from that backup. Central account authentication is required.';
  Future<void> _prepare() async {
    if(busy) return;
    final source=await files.getDirectoryPath(confirmButtonText:'Select School Backup');
    if(source==null || !mounted) return;
    final parent=await files.getDirectoryPath(confirmButtonText:'Select Separate Restore Parent');
    if(parent==null || !mounted) return;
    setState(()=>busy=true);
    try {
      final result=await widget.recovery.prepare(Directory(source),Directory('$parent/clean_install_restore'),
        onFileVerified:(count)async {if(mounted)setState(()=>message='Verified $count copied files. Activation has not occurred.');});
      if(mounted)setState(() {prepared=result;message='School-bound backup verified. ${result['recordCount']} database entries and ${result['pendingCount']} pending record operations, ${result['documentPendingCount']} pending document generations and ${result['restorePendingCount']} pending restore intents retained. Media references and original record identities verified. No cloud ACK was created.';});
    } catch(_) {if(mounted)setState(()=>message='Backup recovery requires review: wrong school, existing data, missing media, corrupt contents or mismatched checkpoint. Original backup and current storage are retained.');}
    finally {if(mounted)setState(()=>busy=false);}
  }
  Future<void> _activate() async {
    if(busy || prepared==null) return;
    final approved=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
      title:const Text('Activate verified school backup?'),
      content:const Text('Only this fresh installation will switch to the verified staged copy. Original backup, queue operation IDs and previous storage remain retained. Cloud authentication is verified again. The app must reopen after activation. This does not upload or acknowledge pending data.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Administrator: Activate'))]));
    if(approved!=true || !mounted)return;
    setState(()=>busy=true);
    try {
      await widget.beforeActivation();
      await widget.recovery.activate(administratorConfirmed:true);
      if(mounted)setState(()=>message='Verified local recovery activated. Pending operations remain pending. Reopening school storage...');
      await widget.afterActivation();
    } catch(_) {if(mounted)setState(()=>message='Activation not certified. Existing and staged data are retained. Reopen the app to verify or roll back the storage pointer.');}
    finally {if(mounted)setState(()=>busy=false);}
  }
  @override
  Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Restore Existing School')),
    body:Padding(padding:const EdgeInsets.all(24),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('Clean-install local disaster recovery',style:TextStyle(fontFamily: 'Segoe UI', fontSize:22,fontWeight:FontWeight.bold)),
      const SizedBox(height:16),Text(message),const SizedBox(height:24),
      FilledButton(onPressed:busy?null:_prepare,child:const Text('Select and verify local backup')),
      const SizedBox(height:12),OutlinedButton(onPressed:busy || prepared==null?null:_activate,child:const Text('Review and activate verified copy')),
      if(busy)const Padding(padding:EdgeInsets.only(top:16),child:LinearProgressIndicator()),
    ])));
}
