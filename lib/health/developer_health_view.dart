import 'package:flutter/material.dart';
import '../platform/managed_developer_service.dart';

class DeveloperHealthView extends StatefulWidget {
  const DeveloperHealthView({super.key,required this.schoolId});
  final String schoolId;
  @override State<DeveloperHealthView> createState()=>_DeveloperHealthViewState();
}
class _DeveloperHealthViewState extends State<DeveloperHealthView>{
  Map<String,dynamic>? evidence;String? error;bool loading=false;
  @override void initState(){super.initState();load();}
  Future<void> load() async {
    setState(()=>loading=true);
    try{final value=await ManagedDeveloperService.call('health/summary',{'schoolId':widget.schoolId}).timeout(const Duration(seconds:15));if(value['schoolId']!=widget.schoolId||value['success']!=true)throw StateError('School mismatch');if(mounted)setState((){evidence=value;error=null;});}
    catch(_){if(mounted)setState(()=>error='Authorized health evidence unavailable. No school operation was changed.');}
    finally{if(mounted)setState(()=>loading=false);}
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Health Command Center')),body:ListView(padding:const EdgeInsets.all(24),children:[const Text('Authenticated developer view. Client reports are observational, not server-certified application health. No remote repair commands.'),OutlinedButton(onPressed:loading?null:load,child:const Text('Refresh verified report reception')),if(loading)const LinearProgressIndicator(),if(error!=null)Text(error!),if(evidence?['available']==true)...[Text('Reporting installations: ${evidence!['reporting']} • Fresh: ${evidence!['fresh']} • Unknown/stale: ${evidence!['unknown']}'),Text('Reported healthy: ${evidence!['healthy']} • Needs attention: ${evidence!['needsAttention']}'),Text('Repair success rate in retained diagnostic window: ${evidence!['repairSuccessRate']==null?'Unknown':((evidence!['repairSuccessRate'] as num)*100).toStringAsFixed(1)+'%'}'),Text('Versions: ${evidence!['versions']}'),Text('Repeated categories: ${evidence!['failures']}'),for(final raw in evidence!['reports'] as List)ListTile(title:Text('${raw['platform']} ${raw['version']} — ${raw['state']}'),subtitle:Text('Pseudonymous installation ${raw['installation']}\nReceived ${DateTime.fromMillisecondsSinceEpoch(raw['receivedAt'] as int)}'))]else if(!loading)const Text('Health totals: Unknown. No complete current evidence available.') ]));
}
