import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_local_settings.dart';
import 'windows_local_auth.dart' as local;
import 'windows_sync_engine.dart';
class WindowsManagedSchoolGate extends StatefulWidget {
  const WindowsManagedSchoolGate({super.key,required this.child,required this.legacy});
  final Widget child,legacy;
  @override State<WindowsManagedSchoolGate> createState()=>_WindowsManagedSchoolGateState();
}
class _WindowsManagedSchoolGateState extends State<WindowsManagedSchoolGate> {
  Map<String,dynamic>? session;bool checking=true,legacy=false;String? error;Timer? timer;
  final licence=TextEditingController();
  @override void initState(){super.initState();ManagedSchoolSession.changed.addListener(check);check();timer=Timer.periodic(const Duration(seconds:30),(_)=>check());}
  @override void dispose(){timer?.cancel();ManagedSchoolSession.changed.removeListener(check);licence.dispose();super.dispose();}
  Future<void> check() async {
    try {
      final saved=await CentralSchoolCloud.saved();
      if(saved['managed']!=true){final required=await const FlutterSecureStorage().read(key:'vidya_saarthi_managed_required')=='true';if(!mounted)return;setState((){legacy=!required&&(!ManagedSchoolSession.enabled||saved.isNotEmpty||WindowsLocalSecurity.configured);checking=false;session=null;});return;}
      final result=await ManagedSchoolSession.call('managed/session');
      if(!mounted)return;local.FirebaseAuth.instance.useManagedIdentity(saved['email']);
      if(session==null)await WindowsSyncEngine.instance.activateCurrentConnections(allowPairing:false);
      if(!mounted)return;setState((){session=result;legacy=false;checking=false;error=null;});
    }catch(e){if(mounted)setState((){legacy=false;checking=false;error='$e';session=null;});}
  }
  @override Widget build(BuildContext context){
    if(checking)return const Scaffold(body:Center(child:CircularProgressIndicator()));
    if(legacy)return widget.legacy;
    if(session==null)return WindowsManagedSchoolLogin(error:error);
    final s=session!,trial=s['status']=='trial';
    if(s['allowed']!=true||!trial&&s['activated']!=true)return Scaffold(body:Center(child:SizedBox(width:430,child:Column(mainAxisSize:MainAxisSize.min,children:[Text('School ${s['schoolId']} • ${s['status']}'),const Text('A valid school licence is required after the five-day trial.'),TextField(controller:licence,decoration:const InputDecoration(labelText:'School licence key')),FilledButton(onPressed:()async{try{await ManagedSchoolSession.call('managed/licence/activate',{'key':licence.text});await check();}catch(e){if(mounted)setState(()=>error='$e');}},child:const Text('Verify licence')),if(error!=null)Text(error!),TextButton(onPressed:ManagedSchoolSession.logout,child:const Text('Sign out'))]))));
    return Column(children:[if(trial)Material(color:Colors.red.shade900,child:ListTile(title:Text('Five-day trial • Ends ${DateTime.fromMillisecondsSinceEpoch((s['expiresAt'] as num).toInt()).toLocal()}'),trailing:TextButton(onPressed:ManagedSchoolSession.logout,child:const Text('Sign out')))),Expanded(child:widget.child)]);
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
