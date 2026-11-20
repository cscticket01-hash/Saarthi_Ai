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
      final started=DateTime.now();
      final d=await ManagedDeveloperService.call('monitor',{});
      final elapsed=DateTime.now().difference(started).inMilliseconds;
      if(mounted)setState((){data={...d,'responseMs':elapsed};error=null;});
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
    final raw=data?['metrics'];
    final firebase=raw is Map?raw:<String,dynamic>{};
    final cf=data?['cloudflare'];
    final cloudflare=cf is Map?cf:<String,dynamic>{};
    final samples=firebaseMetricCards(firebase);
    final measured=data?['success']==true && data?['responseMs'] is num;
    final cloudflareAvailable=cloudflare['available']==true;
    final firebaseAvailable=firebase['available']==true;
    Widget service(String name,IconData icon,String status,String description,Color accent){
      return Card(
        elevation:0,
        color:const Color(0xFFF9FBFF),
        shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(18),
          side:const BorderSide(color:Colors.white,width:1.5)),
        child:Padding(
          padding:const EdgeInsets.all(17),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Row(children:[
              Icon(icon,color:accent,size:24),
              const SizedBox(width:9),
              Expanded(child:Text(name,style:const TextStyle(fontSize:15,fontWeight:FontWeight.w800))),
            ]),
            const SizedBox(height:8),
            Text(status,style:TextStyle(color:accent,fontWeight:FontWeight.w700,fontSize:12)),
            const SizedBox(height:7),
            Text(description,style:const TextStyle(color:Color(0xFF637DA4),fontSize:11)),
          ]),
        ),
      );
    }
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Row(children:[
        const Expanded(child:Text('Cloud Services',style:TextStyle(fontSize:20,fontWeight:FontWeight.w800))),
        IconButton(onPressed:busy?null:load,icon:const Icon(Icons.refresh),tooltip:'Refresh measured service data'),
      ]),
      if(busy)const LinearProgressIndicator(),
      if(error!=null)Text(error!,style:const TextStyle(color:Color(0xFFBD3549))),
      LayoutBuilder(builder:(context,size){
        final w=size.maxWidth>=890?(size.maxWidth-16)/3:size.maxWidth>=520?(size.maxWidth-8)/2:size.maxWidth;
        return Wrap(spacing:8,runSpacing:8,children:[
          SizedBox(width:w,child:service('Cloudflare',Icons.cloud_outlined,
            cloudflareAvailable?'Metrics available':'Status unavailable',
            cloudflareAvailable?'Worker analytics reported by provider':'Cloudflare analytics credentials or sample unavailable',
            cloudflareAvailable?const Color(0xFF058D68):const Color(0xFFAD751C))),
          SizedBox(width:w,child:service('Firebase',Icons.shield_outlined,
            firebaseAvailable?'Metrics available':'Status unavailable',
            firebaseAvailable?'Firebase / Firestore monitoring available':'Cloud Monitoring IAM or sample unavailable',
            firebaseAvailable?const Color(0xFF058D68):const Color(0xFFAD751C))),
          SizedBox(width:w,child:service('Render',Icons.dns_outlined,
            measured?'Broker responded':'Status unavailable',
            measured?'Authenticated request completed in ${data?['responseMs']} ms; not a full uptime guarantee':'Backend monitoring endpoint not verified',
            measured?const Color(0xFF058D68):const Color(0xFFAD751C))),
        ]);
      }),
      const SizedBox(height:10),
      Card(
        elevation:0,color:const Color(0xFFF9FBFF),
        child:ExpansionTile(
          title:const Text('Provider metrics',style:TextStyle(fontSize:14,fontWeight:FontWeight.w700)),
          subtitle:const Text('Measured samples only; expand for details',style:TextStyle(fontSize:11)),
          children:[Padding(padding:const EdgeInsets.all(12),
            child:Wrap(spacing:8,runSpacing:8,children:[
              metric('Firestore storage',format(samples['storageBytes'],key:'storageBytes')),
              metric('Firestore reads/s',format(samples['readsPerSecond'],key:'readsPerSecond')),
              metric('Firestore writes/s',format(samples['writesPerSecond'],key:'writesPerSecond')),
              metric('Worker requests',cloudflareAvailable?'${cloudflare['requests']??'Not available'}':'Not available'),
              metric('Worker errors',cloudflareAvailable?'${cloudflare['errors']??'Not available'}':'Not available'),
            ])),
          ],
        ),
      ),
    ]);
  }
}
