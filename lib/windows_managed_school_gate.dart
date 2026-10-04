import 'dart:async';
import 'package:flutter/material.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';
import 'main_dashboard_screen_windows.dart' show WindowsLicenseSettingsPanel;
import 'windows_platform_client.dart';
import 'windows_local_auth.dart' as local;
import 'windows_sync_engine.dart';
class WindowsManagedSchoolGate extends StatefulWidget {
  const WindowsManagedSchoolGate({super.key,required this.child,required this.legacy});
  final Widget child,legacy;
  @override State<WindowsManagedSchoolGate> createState()=>_WindowsManagedSchoolGateState();
}
class _WindowsManagedSchoolGateState extends State<WindowsManagedSchoolGate> {
  Map<String,dynamic>? session;bool checking=true;String? error;Timer? timer,expiryTimer;DateTime? verifiedAt;
  int checkVersion=0;
  final licence=TextEditingController();
  @override void initState(){super.initState();ManagedSchoolSession.changed.addListener(sessionChanged);check();timer=Timer.periodic(const Duration(seconds:30),(_)=>check());expiryTimer=Timer.periodic(const Duration(seconds:1),(_){if(mounted&&session!=null)setState((){});});}
  @override void dispose(){unawaited(ManagedSchoolSession.call('managed/disconnect').catchError((_)=> <String,dynamic>{}));timer?.cancel();expiryTimer?.cancel();ManagedSchoolSession.changed.removeListener(sessionChanged);licence.dispose();super.dispose();}
  void sessionChanged(){checkVersion++;if(mounted)setState((){session=null;checking=true;error=null;});check();}
  Future<void> check() async {
    final version=++checkVersion;
    try {
      final saved=await CentralSchoolCloud.saved();
      if(saved['managed']!=true){if(!mounted||version!=checkVersion)return;setState((){checking=false;session=null;});return;}
      final result=await ManagedSchoolSession.call('managed/session');
      if(!mounted||version!=checkVersion)return;local.FirebaseAuth.instance.useManagedIdentity(saved['email']);
      if(session?['schoolId']!=result['schoolId'])await WindowsSyncEngine.instance.activateCurrentConnections(allowPairing:false);
      if(!mounted||version!=checkVersion)return;WindowsPlatformClient.instance.state.value=WindowsLicenseState(allowed:result['allowed']==true,status:result['status']??'expired',expiresAt:DateTime.fromMillisecondsSinceEpoch((result['expiresAt'] as num).toInt()));
      setState((){session=result;verifiedAt=DateTime.now();checking=false;error=null;});
      unawaited(ManagedSchoolSession.call('managed/summary').catchError((_)=> <String,dynamic>{}));
    }catch(e){if(mounted&&version==checkVersion)setState((){checking=false;error='$e';session=null;});}
  }
  @override Widget build(BuildContext context){
    if(checking)return const Scaffold(body:Center(child:CircularProgressIndicator()));
    if(session==null)return WindowsManagedSchoolLogin(error:error);
    if(verifiedAt==null||DateTime.now().difference(verifiedAt!)>const Duration(seconds:90))return const Scaffold(body:Center(child:Text('Unable to verify school connection. Reconnecting…')));
    final s=session!,trial=s['status']=='trial';
    if(s['allowed']!=true||DateTime.now().millisecondsSinceEpoch>=(s['expiresAt'] as num)||!trial&&s['activated']!=true)return Scaffold(body:Center(child:SizedBox(width:430,child:Column(mainAxisSize:MainAxisSize.min,children:[Text('School ${s['schoolId']} • ${s['status']}'),const Text('A valid school licence is required after the five-day trial.'),TextField(controller:licence,decoration:const InputDecoration(labelText:'School licence key')),FilledButton(onPressed:()async{try{await ManagedSchoolSession.call('managed/licence/activate',{'key':licence.text});await check();}catch(e){if(mounted)setState(()=>error='$e');}},child:const Text('Verify licence')),if(error!=null)Text(error!),TextButton(onPressed:ManagedSchoolSession.logout,child:const Text('Sign out'))]))));
    return Column(children:[if(trial)Material(color:Colors.red.shade900,child:ListTile(title:Text('Five-day trial • Ends ${DateTime.fromMillisecondsSinceEpoch((s['expiresAt'] as num).toInt()).toLocal()}'),onTap:()=>showDialog<void>(context:context,builder:(ctx)=>Dialog(child:SizedBox(width:650,child:SingleChildScrollView(child:WindowsLicenseSettingsPanel())))),trailing:TextButton(onPressed:ManagedSchoolSession.logout,child:const Text('Sign out')))),Expanded(child:KeyedSubtree(key:ValueKey(s['schoolId']),child:widget.child))]);
  }
}
class WindowsManagedSchoolLogin extends StatefulWidget {
  const WindowsManagedSchoolLogin({super.key,this.error});final String? error;
  @override State<WindowsManagedSchoolLogin> createState()=>_WindowsManagedSchoolLoginState();
}
class _WindowsManagedSchoolLoginState extends State<WindowsManagedSchoolLogin>{
  final email=TextEditingController(),password=TextEditingController();bool busy=false;String? error;
  @override void dispose(){email.dispose();password.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Vidya Saarthi • School Login')),body:Center(child:SizedBox(width:430,child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,children:[const Text('Use the school account created by your developer.'),TextField(controller:email,decoration:const InputDecoration(labelText:'School login email')),TextField(controller:password,obscureText:true,enableSuggestions:false,autocorrect:false,decoration:const InputDecoration(labelText:'Password')),if((error??widget.error)!=null)Text(error??widget.error??''),FilledButton(onPressed:busy?null:()async{setState(()=>busy=true);try{await ManagedSchoolSession.login(email.text,password.text);password.clear();await WindowsSyncEngine.instance.activateCurrentConnections(allowPairing:false);if(mounted&&Navigator.of(context).canPop())Navigator.pop(context);}catch(e){if(mounted)setState(()=>error='$e');}finally{if(mounted)setState(()=>busy=false);}},child:Text(busy?'Signing in…':'School Login'))])))));
}
