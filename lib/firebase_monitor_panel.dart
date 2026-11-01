import 'dart:async';
import 'package:flutter/material.dart';
import 'platform/managed_developer_service.dart';
import 'platform/firebase_metric_samples.dart';

/// Read-only developer Cloud Services dashboard: real provider samples only.
/// A missing IAM grant, token, sample or metric must never become a made-up 0.
class FirebaseMonitorPanel extends StatefulWidget {
  const FirebaseMonitorPanel({super.key});
  @override
  State<FirebaseMonitorPanel> createState() => _FirebaseMonitorPanelState();
}
class _FirebaseMonitorPanelState extends State<FirebaseMonitorPanel> {
  Timer? timer;
  bool busy=false;
  Map<String,dynamic>? data;
  String? error;
  @override
  void initState(){super.initState();load();
    timer=Timer.periodic(const Duration(seconds:60),(_)=>load());}
  @override
  void dispose(){timer?.cancel();super.dispose();}
  Future<void> load()async{
    if(busy)return;
    setState(()=>busy=true);
    try{
      final d=await ManagedDeveloperService.call('monitor',{});
      if(mounted)setState((){data=d;error=null;});
    }catch(e){if(mounted)setState(()=>error='Cloud monitor unavailable: $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  String format(dynamic sample,{bool bits=false,required String key}){
    if(sample is! Map){
      final raw=data?['metrics'];
      return firebaseMetricMissingStatus(raw is Map?raw:null,key,
        loading:busy,apiError:error!=null);
    }
    final v=sample['value'];
    if(v is! num||!v.toDouble().isFinite)return 'Invalid provider sample';
    final n=v.toDouble();
    if(bits){
      if(n>=1e9)return '${(n/1e9).toStringAsFixed(2)} Gbps';
      if(n>=1e6)return '${(n/1e6).toStringAsFixed(2)} Mbps';
      if(n>=1000)return '${(n/1000).toStringAsFixed(2)} Kbps';
      return '${n.toStringAsFixed(0)} bit/s';
    }
    if(sample['unit']=='By'){
      for(final x in [(1073741824,'GB'),(1048576,'MB'),(1024,'KB')]){
        if(n>=x.$1)return '${(n/x.$1).toStringAsFixed(2)} ${x.$2}';
      }
      return '${n.toStringAsFixed(0)} B';
    }
    return '${n.toStringAsFixed(2)} ${sample['unit']=='1'?'ops/s':sample['unit']??''}';
  }
  Widget metric(String name,String value,{String? sub}){
    return SizedBox(width:242,child:Card(child:Padding(
      padding:const EdgeInsets.all(16),child:Column(
        crossAxisAlignment:CrossAxisAlignment.start,
        children:[
          Text(name,style:const TextStyle(fontWeight:FontWeight.w600)),
          const SizedBox(height:10),
          Text(value,style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),
          if(sub!=null)Padding(padding:const EdgeInsets.only(top:5),
            child:Text(sub,style:const TextStyle(fontSize:11,color:Colors.white60))),
        ],
      ))));
  }
  @override
  Widget build(BuildContext context){
    final firebase=data?['metrics'];
    final cards=firebase is Map?firebaseMetricCards(firebase):<String,dynamic>{};
    final cf=data?['cloudflare'];
    final cloudflare=cf is Map?cf:<String,dynamic>{};
    final enabled=cloudflare['available']==true;
    final d1=cloudflare['d1'] is Map?cloudflare['d1'] as Map:<String,dynamic>{};
    final d1Enabled=d1['available']==true;
    String cfValue(String field)=>enabled&&cloudflare[field] is num
      ? '${cloudflare[field]}':'Not available';
    String d1Value(String field)=>d1Enabled&&d1[field] is num
      ? '${d1[field]}':'Not available';
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[
        const Expanded(child:Text('Cloud Services — Developer Only',
          style:TextStyle(fontSize:23,fontWeight:FontWeight.bold))),
        IconButton(onPressed:busy?null:load,tooltip:'Refresh measured cloud data',
          icon:const Icon(Icons.refresh)),
      ]),
      const Text('Measured provider samples only • Automatic refresh every 60 seconds • No estimated usage or speed.'),
      if(busy)const LinearProgressIndicator(),
      if(error!=null)Text(error!,style:const TextStyle(color:Colors.orangeAccent)),
      const SizedBox(height:18),
      const Text('Firebase / Firestore',style:TextStyle(fontSize:19,fontWeight:FontWeight.w700)),
      if(firebase is Map&&firebase['available']!=true)
        Padding(padding:const EdgeInsets.only(top:7,bottom:7),
          child:Text('${firebase['reason']??'Monitoring not configured'}. Grant the Render service account Cloud Monitoring Viewer and enable the Cloud Monitoring API; this developer page cannot override IAM.',
            style:const TextStyle(color:Colors.orangeAccent))),
      const SizedBox(height:9),
      Wrap(spacing:10,runSpacing:10,children:[
        for(final entry in [
          ('Firestore storage','storageBytes',false),
          ('Outbound traffic','outboundBitsPerSecond',true),
          ('Inbound traffic','inboundBitsPerSecond',true),
          ('Reads / second','readsPerSecond',false),
          ('Writes / second','writesPerSecond',false),
          ('Firestore latency','latency',false),
        ])
          metric(entry.$1,format(cards[entry.$2],bits:entry.$3,key:entry.$2),
            sub:cards[entry.$2] is Map&&cards[entry.$2]['sampledAt'] is num
              ? 'Sampled: ${DateTime.fromMillisecondsSinceEpoch((cards[entry.$2]['sampledAt'] as num).toInt()).toLocal()}'
              : 'Google Cloud Monitoring'),
      ]),
      const SizedBox(height:22),
      const Text('Cloudflare Worker & D1',style:TextStyle(fontSize:19,fontWeight:FontWeight.w700)),
      if(!enabled)
        Padding(padding:const EdgeInsets.only(top:7,bottom:7),
          child:Text('${cloudflare['reason']??'Cloudflare analytics not configured'}. Use a separate account Analytics Read token on Render, never the sync secret or a browser key.',
            style:const TextStyle(color:Colors.orangeAccent))),
      if(enabled)Text('Worker: ${cloudflare['workerName']} • ${cloudflare['window']}; measured ${cloudflare['sampledAt'] is num?DateTime.fromMillisecondsSinceEpoch((cloudflare['sampledAt'] as num).toInt()).toLocal():'unknown'}',
        style:const TextStyle(fontSize:12,color:Colors.white70)),
      const SizedBox(height:9),
      Wrap(spacing:10,runSpacing:10,children:[
        metric('Worker requests',cfValue('requests'),sub:'Provider-reported 5-minute window'),
        metric('Worker errors',cfValue('errors'),sub:'Provider-reported 5-minute window'),
        metric('D1 read queries',d1Value('readQueries'),
          sub:d1Enabled?'${d1['window']}':'${d1['reason']??'D1 analytics unavailable'}'),
        metric('D1 write queries',d1Value('writeQueries'),
          sub:d1Enabled?'${d1['window']}':'${d1['reason']??'D1 analytics unavailable'}'),
        metric('Cloudflare network in/out','Not reported',
          sub:'Bandwidth is not in this authorized Worker/D1 sample'),
      ]),
      const SizedBox(height:14),
      const Text('Firebase and Cloudflare provider metrics are sampled and may lag. D1 query counts are not school Drive reads/writes. School-specific Drive usage is available under Schools after verified summary retrieval.',
        style:TextStyle(fontSize:12,color:Colors.white70)),
    ]);
  }
}
