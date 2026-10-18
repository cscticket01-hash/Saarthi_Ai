import 'dart:async';
import 'package:flutter/material.dart';
import 'windows_connect/managed_school_session.dart';

String deviceActivityLabel(Object? value) => value == 'recently_seen'
    ? 'Recently active (online status not confirmed)'
    : value == 'revoked' ? 'Revoked' : 'Activity unknown';
String deviceTimeLabel(Object? value) => value is num && value > 0
    ? DateTime.fromMillisecondsSinceEpoch(value.toInt()).toLocal().toString()
    : 'Unknown';

class WindowsDeviceManagement extends StatefulWidget {
  const WindowsDeviceManagement({super.key, this.request});
  final Future<Map<String,dynamic>> Function(String action, Map<String,dynamic> body)? request;
  @override
  State<WindowsDeviceManagement> createState() => _WindowsDeviceManagementState();
}
class _WindowsDeviceManagementState extends State<WindowsDeviceManagement>
    with WidgetsBindingObserver {
  List<Map<String,dynamic>> devices = [];
  String? current, error;
  bool busy = false, verified = false;
  Timer? refreshTimer;
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
    if(age<86400000) return '${age~/3600000} hours ago';
    if(age<172800000) return 'Yesterday';
    return deviceTimeLabel(seen);
  }
  static final identityPattern = RegExp(r'^[a-f0-9]{64}$');
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ManagedSchoolSession.changed.addListener(sessionChanged);
    load();
    refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed && ModalRoute.of(context)?.isCurrent == true) load();
    });
  }
  void sessionChanged() {
    if (!mounted) return;
    setState(() { devices = []; current = null; verified = false; });
    // A response from the previous session must never populate this page.
    Navigator.of(context).maybePop();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }
  @override
  void dispose() {
    refreshTimer?.cancel();
    ManagedSchoolSession.changed.removeListener(sessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  Future<Map<String,dynamic>> request(String action, Map<String,dynamic> body) =>
      widget.request?.call(action, body) ?? ManagedSchoolSession.call(action, body);
  Future<void> load() async {
    if (busy) return;
    final session = ManagedSchoolSession.changed.value;
    setState(() { busy = true; error = null; });
    try {
      final response = await request('managed/device/list', {});
      if (response['success'] != true || response['devices'] is! List) {
        throw StateError('Device list could not be verified.');
      }
      final rows = <Map<String,dynamic>>[];
      final ids = <String>{};
      for (final item in response['devices'] as List) {
        if (item is! Map) throw StateError('Invalid device response.');
        final row = Map<String,dynamic>.from(item);
        final id = row['deviceIdentity'];
        if (id is! String || !identityPattern.hasMatch(id) || !ids.add(id) ||
            !['active','revoked'].contains(row['status']) ||
            row['lastSeenAt'] is! int || (row['lastSeenAt'] as int) <= 0 ||
            (row['lastSeenAt'] as int) > 8640000000000000) {
          throw StateError('Invalid device response.');
        }
        rows.add(row);
      }
      final marked = rows.where((r) => r['current'] == true && r['status'] == 'active').toList();
      if (marked.length != 1 || rows.where((r) => r['status'] == 'active').length > 5) {
        throw StateError('Current PC authorization could not be verified.');
      }
      if (!mounted || session != ManagedSchoolSession.changed.value) return;
      setState(() {
        serverTime = response['serverTime'] is int ? response['serverTime'] as int : null;
        freshness..reset()..start();
        devices = rows;
        current = marked.single['deviceIdentity'] as String;
        verified = true;
      });
    } catch (e) {
      if (mounted && session == ManagedSchoolSession.changed.value) {
        setState(() { error = e.toString(); verified = false; });
      }
    } finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> revoke(Map<String,dynamic> row) async {
    final identity = row['deviceIdentity'];
    final session = ManagedSchoolSession.changed.value;
    if (!verified || busy || identity == current || identity is! String || !identityPattern.hasMatch(identity)) return;
    final approved = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Revoke this PC?'),
      content: Text('${row['name'] ?? 'PC'} will lose online school access. An offline PC receives this change when it reconnects; its existing offline authorization policy still applies. Local records will remain preserved.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context,false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context,true), child: const Text('Revoke'))],
    ));
    if (approved != true || !mounted || session != ManagedSchoolSession.changed.value || !verified || busy) return;
    setState(() { busy = true; error = null; });
    try {
      final result = await request('managed/device/revoke', {'targetDeviceIdentity':identity});
      if (result['success'] != true || result['device'] is! Map ||
          result['device']['deviceIdentity'] != identity || result['device']['status'] != 'revoked') {
        throw StateError('Revocation not verified. Refresh before retrying.');
      }
      if (!mounted || session != ManagedSchoolSession.changed.value) return;
      setState(() { busy = false; verified = false; });
      await load();
    } catch(e) {
      if(mounted) setState(() { error=e.toString(); busy=false; verified=false; });
    }
  }
  @override
  Widget build(BuildContext context) {
    const muted = Color(0xff9caac0);
    final active = devices.where((r) => r['status'] == 'active').length;
    final recent = devices.where(recentlyActive).length;
    return Scaffold(
      backgroundColor: const Color(0xff0b1425),
      appBar: AppBar(backgroundColor: const Color(0xff0b1425), title: const Text('Device Management'), actions:[
        IconButton(tooltip:'Refresh devices', onPressed:busy?null:load,icon:const Icon(Icons.refresh)),
      ]),
      body: Align(alignment: Alignment.topCenter, child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth:1100),
        child: ListView(padding:const EdgeInsets.all(24), children:[
          Text('Authorized PCs: ${verified ? active : '—'} / 5   |   Recently active: ${verified ? recent : '—'}',
            style: const TextStyle(color:Colors.white,fontSize:15)),
          const SizedBox(height:20),
          if(busy) const LinearProgressIndicator(minHeight:2),
          if(error!=null) Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Text(error!,style:const TextStyle(color:Color(0xffffb4ab)))),
          Container(decoration:BoxDecoration(color:const Color(0xff121f34),borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xff26364f))),
            child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
              const Padding(padding:EdgeInsets.all(20),child:Text('Devices',style:TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.w600))),
              LayoutBuilder(builder:(context,constraints) {
                final compact = constraints.maxWidth < 700 || MediaQuery.textScalerOf(context).scale(14) > 21;
                Widget name(Map<String,dynamic> row) => Row(children:[
                  const Icon(Icons.computer_outlined,color:Color(0xff8aade8),size:22),const SizedBox(width:12),
                  Expanded(child:Text(row['name'] is String && (row['name'] as String).isNotEmpty ? row['name'] as String : 'Unnamed PC',style:const TextStyle(color:Colors.white))),
                  if(row['deviceIdentity']==current) Container(margin:const EdgeInsets.only(left:8),padding:const EdgeInsets.symmetric(horizontal:8,vertical:4),decoration:BoxDecoration(color:const Color(0xff233d64),borderRadius:BorderRadius.circular(6)),child:const Text('This PC',style:TextStyle(color:Color(0xffa6caff),fontSize:11))),
                ]);
                Widget activity(Map<String,dynamic> row) => Text(recentlyActive(row) ? 'Recently active' : row['status']=='revoked' ? 'Revoked' : 'Activity unknown',style:TextStyle(color:recentlyActive(row) ? const Color(0xff6ed6aa):muted));
                Widget action(Map<String,dynamic> row) => row['status']=='active' && row['deviceIdentity']!=current
                  ? TextButton(onPressed:busy || !verified ? null:()=>revoke(row),child:const Text('Revoke'))
                  : const Text('—',style:TextStyle(color:muted));
                return Column(children:[
                  if(!compact) const Padding(padding:EdgeInsets.symmetric(horizontal:20,vertical:12),child:Row(children:[
                    Expanded(flex:4,child:Text('Device name',style:TextStyle(color:muted))),Expanded(flex:3,child:Text('Activity',style:TextStyle(color:muted))),Expanded(flex:3,child:Text('Last seen',style:TextStyle(color:muted))),SizedBox(width:80,child:Text('Action',style:TextStyle(color:muted))),
                  ])),
                  for(final row in devices) Container(padding:const EdgeInsets.symmetric(horizontal:20,vertical:14),decoration:const BoxDecoration(border:Border(top:BorderSide(color:Color(0xff26364f)))),child:compact
                    ? Column(crossAxisAlignment:CrossAxisAlignment.start,children:[name(row),const SizedBox(height:12),activity(row),const SizedBox(height:6),Text('Last seen: ${lastSeen(row)}',style:const TextStyle(color:muted)),Align(alignment:Alignment.centerRight,child:action(row))])
                    : Row(children:[Expanded(flex:4,child:name(row)),Expanded(flex:3,child:activity(row)),Expanded(flex:3,child:Text(lastSeen(row),style:const TextStyle(color:muted))),SizedBox(width:80,child:action(row))])),
                  if(devices.isEmpty) Padding(padding:const EdgeInsets.all(24),child:Text(busy ? 'Loading devices…' : 'No verified device list available.',style:const TextStyle(color:muted))),
                ]);
              }),
            ])),
          const Padding(padding:EdgeInsets.only(top:14),child:Text('Activity is based on the last heartbeat. A missing heartbeat does not confirm a PC is offline.',style:TextStyle(color:muted,fontSize:12))),
        ]),
      )),
    );
  }
}
