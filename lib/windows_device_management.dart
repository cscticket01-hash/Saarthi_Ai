import 'package:flutter/material.dart';
import 'windows_connect/managed_school_session.dart';

String deviceActivityLabel(Object? value) => value == 'recently_seen'
    ? 'Recently seen (online status not confirmed)'
    : value == 'revoked' ? 'Revoked' : 'Activity unknown';
String deviceTimeLabel(Object? value) => value is num && value > 0
    ? DateTime.fromMillisecondsSinceEpoch(value.toInt()).toLocal().toString()
    : 'Unknown';

class WindowsDeviceManagement extends StatefulWidget {
  const WindowsDeviceManagement({super.key});
  @override
  State<WindowsDeviceManagement> createState() => _WindowsDeviceManagementState();
}
class _WindowsDeviceManagementState extends State<WindowsDeviceManagement> {
  List<Map<String,dynamic>> devices = [];
  String? current, error;
  bool busy = false;
  @override
  void initState() { super.initState(); load(); }
  Future<void> load() async {
    setState(() { busy = true; error = null; });
    try {
      final response = await ManagedSchoolSession.call('managed/device/list');
      if (response['success'] != true || response['devices'] is! List) {
        throw StateError('Device list could not be verified.');
      }
      if (!mounted) return;
      setState(() {
        devices = (response['devices'] as List).whereType<Map>().map((r) => Map<String,dynamic>.from(r)).toList();
        final marked=devices.where((r)=>r['current']==true).toList();
        current = marked.length==1 ? marked.single['deviceIdentity']?.toString() : null;
      });
    } catch (e) { if (mounted) setState(() => error = e.toString()); }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> revoke(Map<String,dynamic> row) async {
    final identity = row['deviceIdentity'];
    if (identity == current || identity is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(identity)) return;
    final approved = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Revoke this PC?'),
      content: Text('${row['name'] ?? 'PC'} will lose online school access. An offline PC cannot receive immediate logout; its bounded authorization must expire. Its pending local records remain preserved.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context,false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context,true), child: const Text('Revoke other PC'))],
    ));
    if (approved != true || !mounted) return;
    setState(() { busy = true; error = null; });
    try {
      final result = await ManagedSchoolSession.call('managed/device/revoke', {'targetDeviceIdentity':identity});
      if (result['success'] != true) throw StateError('Revocation not verified.');
      await load();
    } catch(e) { if(mounted) setState(() { error=e.toString(); busy=false; }); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Device Management'), actions:[IconButton(onPressed:busy?null:load,icon:const Icon(Icons.refresh))]),
    body: ListView(padding:const EdgeInsets.all(24),children:[
      const Text('Up to five authorized PCs. Revoked devices remain in recent history for 24 hours. A missing heartbeat does not prove a PC is offline.'),
      if(busy) const LinearProgressIndicator(),
      if(error!=null) Padding(padding:const EdgeInsets.symmetric(vertical:16),child:Text(error!)),
      for(final row in devices) Card(child:ListTile(
        title:Text('${row['name'] ?? 'PC'}${row['deviceIdentity']==current?' · This PC':''}'),
        subtitle:Text('Identity: ${row['deviceIdentity']}\n${row['os'] ?? 'Unknown OS'} · ${row['type'] ?? 'Unknown type'} · ${row['status'] ?? 'Unknown'}\n${deviceActivityLabel(row['activity'])}\nAuthorized: ${deviceTimeLabel(row['authorizedAt'])}\nLast seen: ${deviceTimeLabel(row['lastSeenAt'])}'),
        trailing:row['status']=='active' && current!=null && row['deviceIdentity']!=current
          ? TextButton(onPressed:busy?null:()=>revoke(row),child:const Text('Revoke')):null,
      )),
    ]),
  );
}
