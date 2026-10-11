import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'id_card_bulk_engine.dart';
import 'id_card_bulk_job_store.dart';
import 'id_card_manifest.dart';
import 'id_card_school_source.dart';

/// Explicit local export UI. No QR issuance, cloud publication or print command
/// happens while choosing a class, preparing input, or saving a job.
class IdCardBulkScreen extends StatefulWidget {
  const IdCardBulkScreen({super.key,required this.source,required this.template,
    required this.store,this.backgrounds=const {}});
  final IdCardSchoolSource source;
  final IdCardManifest template;
  final IdCardBulkJobStore store;
  final Map<String,Uint8List> backgrounds;
  @override State<IdCardBulkScreen> createState()=>_BulkState();
}
class _BulkState extends State<IdCardBulkScreen> {
  String? classId,error,phase;
  Set<String> selected={};
  List<Map<String,dynamic>> jobs=[];
  List<Map<String,String>> findings=[];
  bool busy=false,cancel=false,allowMissingPhotos=false;
  int completed=0,total=0;
  IdCardBackPlacement backPlacement=IdCardBackPlacement.mirrorColumns;
  @override void initState(){super.initState();reloadJobs();}
  Future<void> reloadJobs() async {try{widget.source.ensureActive();final list=await widget.store.listJobs();if(mounted)setState(()=>jobs=list);}catch(e){if(mounted)setState(()=>error='Saved jobs require review: $e');}}
  Future<bool> confirm(String title,String message) async => await showDialog<bool>(context:context,builder:(context)=>AlertDialog(title:Text(title),content:Text(message),actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Confirm'))]))??false;
  void progress(int value,int max){if(mounted)setState((){completed=value;total=max;});}
  Future<void> preview(Uint8List bytes) async {
    if(!mounted)return;await Navigator.of(context).push<void>(MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Exact bulk front/back PDF')),body:PdfPreview(build:(_)=>bytes,canChangePageFormat:false,canChangeOrientation:false,allowPrinting:true,allowSharing:true))));
  }
  Future<void> generate() async {
    if(busy||classId==null||selected.isEmpty)return;
    if(!await confirm('Review bulk export','Prepare ${selected.length} selected students from $classId. Existing QR credentials are reused. Legacy references do not prove active/revocation status. No new card is issued.'))return;
    setState((){busy=true;cancel=false;error=null;findings=[];phase='Checking saved school data and photos';completed=0;total=selected.length;});
    try{
      final check=await widget.source.preflight(classId!,Set.from(selected),widget.template,backgrounds:widget.backgrounds,onProgress:progress,isCancelled:()=>cancel);
      if(mounted)setState(()=>findings=check.findings);
      if(check.blocked||(!allowMissingPhotos&&check.findings.any((f)=>f['code']=='MISSING_PHOTO')))throw StateError('Resolve listed input errors, or explicitly allow missing optional photos. No partial selection is exported.');
      widget.source.ensureActive();
      final plan=IdCardBulkPlan(template:widget.template,students:check.students,backPlacement:backPlacement);
      final job='batch-${plan.selectionFingerprint.substring(0,58)}';
      await widget.store.savePending(job,plan);
      if(mounted)setState(()=>phase='Rendering exact saved selection');
      final result=await widget.store.resumeAndRender(job,isCancelled:()=>cancel,onProgress:progress);
      widget.source.ensureActive();await reloadJobs();await preview(result.pdf);
    }catch(e){if(mounted)setState(()=>error='$e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> resume(Map<String,dynamic> job) async {
    if(busy)return;
    try {
    if(job['protection']=='legacy-needs-review'){
      if(!await confirm('Protect legacy saved job','Validate and encrypt this existing local selection and retained PDFs. Original student data and QR identities stay unchanged.'))return;
      await widget.store.migrateLegacy(job['jobId'].toString(),confirmed:true);await reloadJobs();
    }
    } catch(e) {if(mounted)setState(()=>error='$e');return;}
    setState((){busy=true;cancel=false;error=null;phase='Full rerender of exact saved selection, or verified completed output';});
    try{widget.source.ensureActive();final result=await widget.store.resumeAndRender(job['jobId'].toString(),isCancelled:()=>cancel,onProgress:progress);widget.source.ensureActive();await reloadJobs();await preview(result.pdf);}
    catch(e){if(mounted)setState(()=>error='$e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context){
    final rows=classId==null?<Map<String,dynamic>>[]:widget.source.forClass(classId!);
    return PopScope(canPop:!busy,child:Scaffold(appBar:AppBar(title:const Text('Class bulk ID cards')),body:ListView(padding:const EdgeInsets.all(16),children:[
      const Text('Local reviewed export • existing QR only • saved selection recovery rerenders from the beginning. Physical duplex alignment must be calibrated.'),
      DropdownButton<String>(hint:const Text('Choose class'),value:classId,items:widget.source.classes.map((c)=>DropdownMenuItem(value:c,child:Text(c))).toList(),onChanged:busy?null:(v)=>setState((){classId=v;selected={};findings=[];})),
      Text('${selected.length} selected • maximum 500 per saved job'),
      Wrap(spacing:8,children:[TextButton(onPressed:busy||rows.length>500?null:()=>setState(()=>selected=rows.map((r)=>r['_recordId'].toString()).toSet()),child:const Text('Select class')),TextButton(onPressed:busy?null:()=>setState(()=>selected={}),child:const Text('Clear'))]),
      DropdownButton<IdCardBackPlacement>(value:backPlacement,items:IdCardBackPlacement.values.map((m)=>DropdownMenuItem(value:m,child:Text(m==IdCardBackPlacement.mirrorColumns?'Back: mirror columns':m==IdCardBackPlacement.mirrorRows?'Back: mirror rows':'Back: same positions'))).toList(),onChanged:busy?null:(v)=>setState(()=>backPlacement=v!)),
      CheckboxListTile(value:allowMissingPhotos,onChanged:busy?null:(v)=>setState(()=>allowMissingPhotos=v??false),title:const Text('Allow missing optional photos after review')),
      if(error!=null)Text(error!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
      if(busy)...[Text('$phase • $completed / $total'),LinearProgressIndicator(value:total>0?completed/total:null),TextButton(onPressed:()=>setState(()=>cancel=true),child:Text(cancel?'Stopping at safe boundary…':'Cancel and retain saved job'))],
      FilledButton.icon(onPressed:busy||selected.isEmpty?null:generate,icon:const Icon(Icons.picture_as_pdf),label:const Text('Review and generate front/back PDF')),
      for(final finding in findings)Text('${finding['studentId']}: ${finding['code']} (${finding['severity']})'),
      for(final row in rows)CheckboxListTile(value:selected.contains(row['_recordId']),title:Text((row['name']??row['_recordId']).toString()),subtitle:Text('Roll ${row['rollNo']??''}'),onChanged:busy?null:(v)=>setState((){final id=row['_recordId'].toString();if(v==true&&selected.length<500)selected.add(id);else if(v!=true)selected.remove(id);})),
      const Divider(),const Text('Saved jobs and verified outputs'),
      for(final job in jobs)ListTile(title:Text('${job['count']} students • ${job['status']}'),subtitle:Text('${job['jobId']} • ${job['protection']}'),trailing:TextButton(onPressed:busy?null:()=>resume(job),child:const Text('Resume / preview'))),
    ])));
  }
}
