import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'school_password_panel.dart';
class DeveloperAccountProfile extends StatelessWidget {
  const DeveloperAccountProfile({super.key});
  @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(FirebaseAuth.instance.currentUser?.email??'',style:const TextStyle(fontSize:20)),const Text('Developer administrator'),SchoolPasswordPanel(change:(current,next)async{final user=FirebaseAuth.instance.currentUser;if(user==null||user.email==null)throw StateError('Sign in again');await user.reauthenticateWithCredential(EmailAuthProvider.credential(email:user.email!,password:current));await user.updatePassword(next);await FirebaseAuth.instance.signOut();})]);
}
class DeveloperIdleSession extends StatefulWidget {
  const DeveloperIdleSession({super.key,required this.child,this.idle=const Duration(minutes:30)});
  final Widget child;final Duration idle;
  @override State<DeveloperIdleSession> createState()=>_DeveloperIdleSessionState();
}
class _DeveloperIdleSessionState extends State<DeveloperIdleSession> with WidgetsBindingObserver{
  Timer? timer;DateTime activity=DateTime.now(),persisted=DateTime.fromMillisecondsSinceEpoch(0);bool ready=false;
  String get key=>'vs_developer_activity_${FirebaseAuth.instance.currentUser?.uid}';
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);restore();timer=Timer.periodic(const Duration(seconds:1),(_)=>check());}
  Future<void> restore()async{final p=await SharedPreferences.getInstance();final prior=p.getInt(key);final user=FirebaseAuth.instance.currentUser;final signed=user?.metadata.lastSignInTime?.millisecondsSinceEpoch??0;activity=DateTime.fromMillisecondsSinceEpoch(prior!=null&&prior>=signed?prior:signed);if(activity.millisecondsSinceEpoch==0)activity=DateTime.now();ready=true;await p.setInt(key,activity.millisecondsSinceEpoch);check();if(mounted)setState((){});}
  void touch(){if(!ready)return;check();if(DateTime.now().difference(activity)>=widget.idle)return;activity=DateTime.now();if(activity.difference(persisted)>const Duration(seconds:15)){persisted=activity;unawaited(SharedPreferences.getInstance().then((p)=>p.setInt(key,activity.millisecondsSinceEpoch)));}setState((){});}
  void check(){if(!ready)return;if(DateTime.now().difference(activity)>=widget.idle){ready=false;unawaited(FirebaseAuth.instance.signOut());}else if(mounted)setState((){});}
  @override void didChangeAppLifecycleState(AppLifecycleState state){if(state==AppLifecycleState.resumed)check();}
  @override void dispose(){timer?.cancel();WidgetsBinding.instance.removeObserver(this);super.dispose();}
  @override Widget build(BuildContext context){if(!ready)return const Scaffold(body:Center(child:CircularProgressIndicator()));final seconds=(widget.idle-DateTime.now().difference(activity)).inSeconds.clamp(0,widget.idle.inSeconds);return Listener(onPointerDown:(_)=>touch(),onPointerSignal:(_)=>touch(),child:Focus(onKeyEvent:(_,__) {touch();return KeyEventResult.ignored;},child:Stack(children:[widget.child,Positioned(right:20,bottom:10,child:IgnorePointer(child:Material(color:const Color(0xFF16242E),child:Padding(padding:const EdgeInsets.all(8),child:Text('Auto logout ${seconds~/60}:${(seconds%60).toString().padLeft(2,'0')}')))))])));}
}
class AppDownloadButtons extends StatefulWidget{
 const AppDownloadButtons({super.key});
 @override State<AppDownloadButtons> createState()=>_AppDownloadButtonsState();
}
class _AppDownloadButtonsState extends State<AppDownloadButtons>{
 String? busy,error;
 Future<void> download(String platform)async{if(busy!=null)return;setState(()=>busy=platform);try{final response=await http.get(Uri.parse('https://api.github.com/repos/cscticket01-hash/Saarthi_Ai/releases?per_page=100')).timeout(const Duration(seconds:20));if(response.statusCode!=200)throw StateError('Download list unavailable');final list=jsonDecode(response.body) as List;Uri? selected;for(final r in list){if(r['draft']==true||r['prerelease']==true||!r['tag_name'].toString().startsWith('$platform-v'))continue;for(final a in r['assets'] as List){if(a['name'].toString().endsWith(platform=='windows'?'.exe':'.apk')){final u=Uri.parse(a['browser_download_url']);if(u.scheme=='https'&&u.host=='github.com'&&u.path.startsWith('/cscticket01-hash/Saarthi_Ai/releases/download/')){selected=u;break;}}}if(selected!=null)break;}if(selected==null)throw StateError('No released installer available');if(!await launchUrl(selected,mode:LaunchMode.externalApplication))throw StateError('Download unavailable');}catch(_){if(mounted)setState(()=>error='Download unavailable. Try again shortly.');}finally{if(mounted)setState(()=>busy=null);}}
 @override Widget build(BuildContext context)=>Column(children:[Wrap(spacing:10,runSpacing:10,children:[OutlinedButton.icon(onPressed:busy!=null?null:()=>download('windows'),icon:const Icon(Icons.desktop_windows),label:const Text('Windows Download')),OutlinedButton.icon(onPressed:busy!=null?null:()=>download('android'),icon:const Icon(Icons.android),label:const Text('Student Android Download'))]),if(busy!=null)const LinearProgressIndicator(),if(error!=null)Text(error!)]);
}
