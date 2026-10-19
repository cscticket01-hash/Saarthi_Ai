import 'windows_appearance.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_device_directory_cache.dart';

String deviceActivityLabel(Object? value) => value == 'recently_seen'
    ? 'Recently active (online status not confirmed)'
    : value == 'revoked' ? 'Revoked' : 'Activity unknown';
String deviceTimeLabel(Object? value) => value is num && value > 0
    ? DateTime.fromMillisecondsSinceEpoch(value.toInt()).toLocal().toString()
    : 'Unknown';

class WindowsDeviceManagement extends StatefulWidget {
  const WindowsDeviceManagement({super.key, this.request, this.cacheScope});
  final Future<Map<String,dynamic>> Function(String action, Map<String,dynamic> body)? request;
  final Future<String?> Function()? cacheScope;
  @override
  State<WindowsDeviceManagement> createState() => _WindowsDeviceManagementState();
}
class _WindowsDeviceManagementState extends State<WindowsDeviceManagement>
    with WidgetsBindingObserver {
  List<Map<String,dynamic>> devices = [];
  String? current, error;
  bool busy = false, verified = false, revoking=false;
  int readGeneration=0;
  Timer? refreshTimer, activityTimer;
  String? cacheScope;
  bool hasSnapshot=false, canRevoke=false;
  String activityFrame='';
  int? serverTime;
  final freshness = Stopwatch();
  int get estimatedNow => serverTime == null ? DateTime.now().millisecondsSinceEpoch : serverTime! + freshness.elapsedMilliseconds;
  bool recentlyActive(Map<String,dynamic> row) {
    final seen=row['lastSeenAt'];
    final age=seen is int ? estimatedNow-seen : -1;
    return verified && row['status']=='active' && row['activity']=='recently_seen' && age>=0 && age<=120000;
  }
  String lastSeen(Map<String,dynamic> row) {
    final seen=row['lastSeenAt'];
    if(seen is! int) return 'Unknown';
    final age=estimatedNow-seen;
    if(age<0) return deviceTimeLabel(seen);
    if(age<60000) return 'Just now';
    if(age<3600000) return '${age~/60000} min ago';
    if(age<86400000) return '${age~/3600000} ${age<7200000 ? 'hour' : 'hours'} ago';
    if(age<172800000) return 'Yesterday';
    return deviceTimeLabel(seen);
  }
  static final identityPattern = RegExp(r'^[a-f0-9]{64}$');
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ManagedSchoolSession.changed.addListener(sessionChanged);
    initialize();
    refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed && ModalRoute.of(context)?.isCurrent == true) load(silent:true);
    });
  }
  Future<void> initialize() async {
    final session=ManagedSchoolSession.changed.value;
    try {
      final scope=widget.cacheScope!=null ? await widget.cacheScope!() : widget.request!=null ? null :
          WindowsDeviceDirectoryCache.scope(await CentralSchoolCloud.saved());
      if(!mounted || session!=ManagedSchoolSession.changed.value) return;
      cacheScope=scope;
      final cached=scope==null ? <Map<String,dynamic>>[] : await WindowsDeviceDirectoryCache.read(scope);
      if(!mounted || session!=ManagedSchoolSession.changed.value) return;
      if(cached.isNotEmpty) setState(() {
        devices=cached; hasSnapshot=true;
        current=cached.singleWhere((r)=>r['current']==true && r['status']=='active')['deviceIdentity'] as String;
      });
    } catch (_) { /* Display cache failure must never prevent a server read. */ }
    if(mounted && session==ManagedSchoolSession.changed.value) load(silent:hasSnapshot);
    if(!mounted || session!=ManagedSchoolSession.changed.value) return;
    activityTimer=Timer.periodic(const Duration(seconds:5), (_) {
      if(mounted && WidgetsBinding.instance.lifecycleState==AppLifecycleState.resumed && ModalRoute.of(context)?.isCurrent==true && hasSnapshot) {
        final frame=devices.map((row)=>'${recentlyActive(row)}:${lastSeen(row)}').join('|');
        if(frame!=activityFrame) { activityFrame=frame; setState(() {}); }
      }
    });
  }
  void sessionChanged() {
    if (!mounted) return;
    readGeneration++;
    setState(() { busy=false; revoking=false; devices = []; current = null; verified = false; hasSnapshot=false; cacheScope=null; });
    // A response from the previous session must never populate this page.
    Navigator.of(context).maybePop();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load(silent:hasSnapshot);
  }
  @override
  void dispose() {
    refreshTimer?.cancel();
    activityTimer?.cancel();
    ManagedSchoolSession.changed.removeListener(sessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  Future<Map<String,dynamic>> request(String action, Map<String,dynamic> body) =>
      widget.request?.call(action, body) ?? ManagedSchoolSession.call(action, body);
  Future<void> load({bool silent=false}) async {
    if (busy) return;
    final session = ManagedSchoolSession.changed.value;
    final generation=++readGeneration;
    setState(() { busy = true; if(!silent) error = null; });
    try {
      final response = await request('managed/device/list', {});
      if (response['success'] != true || response['devices'] is! List) {
        throw StateError('Device list could not be verified.');
      }
      final rows=WindowsDeviceDirectoryCache.validate(response['devices']);
      final marked=rows.singleWhere((r)=>r['current']==true && r['status']=='active');
      final incoming={for(final row in rows) row['deviceIdentity'] as String:row};
      final ordered=<Map<String,dynamic>>[
        for(final row in devices) if(incoming.containsKey(row['deviceIdentity'])) incoming.remove(row['deviceIdentity'])!,
        ...incoming.values,
      ];
      if (!mounted || session != ManagedSchoolSession.changed.value || generation!=readGeneration) return;
      setState(() {
        serverTime = response['serverTime'] is int ? response['serverTime'] as int : null;
        freshness..reset()..start();
        devices = ordered; hasSnapshot=true; error=null;
        current = marked['deviceIdentity'] as String;
        verified = true;
        canRevoke = response['canRevoke'] != false;
      });
      final scope=cacheScope;
      if(scope!=null) {
        try { await WindowsDeviceDirectoryCache.write(scope,ordered); } catch (_) { /* Cache is optional; server result remains authoritative. */ }
      }
    } catch (e) {
      if (mounted && session == ManagedSchoolSession.changed.value && generation==readGeneration) {
        setState(() { error = e.toString().contains('DEVICE_ROLLOUT_DISABLED')
            ? 'Device management is not enabled on this server. Saved devices remain visible; activity cannot be verified.'
            : e.toString(); verified = false; });
      }
    } finally { if (mounted && generation==readGeneration) setState(() => busy = false); }
  }
  Future<void> revoke(Map<String,dynamic> row) async {
    final identity = row['deviceIdentity'];
    final session = ManagedSchoolSession.changed.value;
    if (!verified || !canRevoke || revoking || identity == current || identity is! String || !identityPattern.hasMatch(identity)) return;
    final approved = await showDialog<bool>(context: context, builder: (context) { WindowsAppearance.watch(context); return  AlertDialog(
      title: const Text('Revoke this PC?'),
      content: Text('${row['name'] ?? 'PC'} will lose online school access. An offline PC receives this change when it reconnects; its existing offline authorization policy still applies. Local records will remain preserved.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context,false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context,true), child: const Text('Revoke'))],
    ); });
    if (approved != true || !mounted || session != ManagedSchoolSession.changed.value || !verified || !canRevoke || revoking || identity==current) return;
    readGeneration++; // A prior list response cannot undo this mutation.
    setState(() { busy = true; revoking=true; error = null; });
    try {
      final result = await request('managed/device/revoke', {'targetDeviceIdentity':identity});
      if (result['success'] != true || result['device'] is! Map ||
          result['device']['deviceIdentity'] != identity || result['device']['status'] != 'revoked') {
        throw StateError('Revocation not verified. Refresh before retrying.');
      }
      if (!mounted || session != ManagedSchoolSession.changed.value) return;
      setState(() { busy = false; revoking=false; verified = false; });
      await load(silent:true);
    } catch(e) {
      if(mounted && session==ManagedSchoolSession.changed.value) setState(() { error=e.toString(); busy=false; revoking=false; verified=false; });
    }
  }
  @override
  Widget build(BuildContext context) {WindowsAppearance.watch(context);
    const muted = Color(0xff9caac0);
    final active = devices.where((r) => r['status'] == 'active').length;
    final recent = devices.where(recentlyActive).length;
    return Scaffold(
      backgroundColor: WindowsAppearance.resolve(const Color(0xff0b1425)),
      appBar: AppBar(backgroundColor: WindowsAppearance.resolve(const Color(0xff0b1425)), title: const Text('Device Management'), actions:[
        IconButton(tooltip:'Refresh devices', onPressed:busy?null:load,icon:const Icon(Icons.refresh)),
      ]),
      body: Align(alignment: Alignment.topCenter, child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth:1100),
        child: ListView(padding:const EdgeInsets.all(24), children:[
          Text('Authorized PCs: ${hasSnapshot ? active : '—'} / 5   |   Recently active: ${verified ? recent : '—'}',
            style:  TextStyle(color:WindowsAppearance.resolve(Colors.white),fontSize:15)),
          const SizedBox(height:20),
          if(busy && !hasSnapshot) const LinearProgressIndicator(minHeight:2),
          if(hasSnapshot && !verified)  Padding(padding:EdgeInsets.only(bottom:10),child:Text('Saved device list • Activity not verified',style:TextStyle(color:WindowsAppearance.resolve(muted),fontSize:12))),
          if(error!=null) Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Text(error!,style:const TextStyle(color:Color(0xffffb4ab)))),
          Container(key:const ValueKey('device-directory-panel'),decoration:BoxDecoration(color:WindowsAppearance.resolve(const Color(0xff121f34)),borderRadius:BorderRadius.circular(16),border:Border.all(color:WindowsAppearance.resolve(const Color(0xff26364f)))),
            child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
               Padding(padding:EdgeInsets.all(20),child:Text('Devices',style:TextStyle(color:WindowsAppearance.resolve(Colors.white),fontSize:18,fontWeight:FontWeight.w600))),
              LayoutBuilder(builder:(context,constraints) {WindowsAppearance.watch(context);
                final compact = constraints.maxWidth < 700 || MediaQuery.textScalerOf(context).scale(14) > 21;
                Widget name(Map<String,dynamic> row) => Row(children:[
                  const Icon(Icons.computer_outlined,color:Color(0xff8aade8),size:22),const SizedBox(width:12),
                  Expanded(child:Text(row['name'] is String && (row['name'] as String).isNotEmpty ? row['name'] as String : 'Unnamed PC',style: TextStyle(color:WindowsAppearance.resolve(Colors.white)))),
                  if(row['deviceIdentity']==current) Container(margin:const EdgeInsets.only(left:8),padding:const EdgeInsets.symmetric(horizontal:8,vertical:4),decoration:BoxDecoration(color:WindowsAppearance.resolve(const Color(0xff233d64)),borderRadius:BorderRadius.circular(6)),child:const Text('This PC',style:TextStyle(color:Color(0xffa6caff),fontSize:11))),
                ]);
                Widget activity(Map<String,dynamic> row) => Row(children:[
                  Icon(Icons.circle,key:ValueKey('activity-${row['deviceIdentity']}'),size:8,color:recentlyActive(row)?const Color(0xff6ed6aa):WindowsAppearance.resolve(muted)),
                  const SizedBox(width:8),Expanded(child:Text(recentlyActive(row)?'Recently active':row['status']=='revoked'?'Revoked':'Activity unknown',style:TextStyle(color:recentlyActive(row)?const Color(0xff6ed6aa):WindowsAppearance.resolve(muted)))),
                ]);
                Widget action(Map<String,dynamic> row) => row['status']=='active' && row['deviceIdentity']!=current
                  ? TextButton(onPressed:revoking || !verified || !canRevoke ? null:()=>revoke(row),child:const Text('Revoke'))
                  :  Text('—',style:TextStyle(color:WindowsAppearance.resolve(muted)));
                return Column(children:[
                  if(!compact)  Padding(padding:EdgeInsets.symmetric(horizontal:20,vertical:12),child:Row(children:[
                    Expanded(flex:4,child:Text('Device name',style:TextStyle(color:WindowsAppearance.resolve(muted)))),Expanded(flex:3,child:Text('Activity',style:TextStyle(color:WindowsAppearance.resolve(muted)))),Expanded(flex:3,child:Text('Last seen',style:TextStyle(color:WindowsAppearance.resolve(muted)))),SizedBox(width:80,child:Text('Action',style:TextStyle(color:WindowsAppearance.resolve(muted)))),
                  ])),
                  for(final row in devices) Container(key:ValueKey('device-${row['deviceIdentity']}'),padding:const EdgeInsets.symmetric(horizontal:20,vertical:14),decoration: BoxDecoration(border:Border(top:BorderSide(color:WindowsAppearance.resolve(Color(0xff26364f))))),child:compact
                    ? Column(crossAxisAlignment:CrossAxisAlignment.start,children:[name(row),const SizedBox(height:12),activity(row),const SizedBox(height:6),Text('Last seen: ${lastSeen(row)}',style: TextStyle(color:WindowsAppearance.resolve(muted))),Align(alignment:Alignment.centerRight,child:action(row))])
                    : Row(children:[Expanded(flex:4,child:Padding(padding:const EdgeInsets.only(right:16),child:name(row))),Expanded(flex:3,child:activity(row)),Expanded(flex:3,child:Text(lastSeen(row),style: TextStyle(color:WindowsAppearance.resolve(muted)))),SizedBox(width:80,child:action(row))])),
                  if(devices.isEmpty) Padding(padding:const EdgeInsets.all(24),child:Text(busy ? 'Loading devices…' : 'No verified device list available.',style: TextStyle(color:WindowsAppearance.resolve(muted)))),
                ]);
              }),
            ])),
          if(verified && !canRevoke)  Padding(padding:EdgeInsets.only(top:12),child:Text("Device enrollment is active. Revoke will be available after this school's device-access setup is completed.",style:TextStyle(color:WindowsAppearance.resolve(muted),fontSize:12))),
           Padding(padding:EdgeInsets.only(top:14),child:Text('Activity is based on the last heartbeat. A missing heartbeat does not confirm a PC is offline.',style:TextStyle(color:WindowsAppearance.resolve(muted),fontSize:12))),
        ]),
      )),
    );
  }
}
