import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'platform/managed_developer_service.dart';

/// Source library only. Mapping review must finish before a school can use a PDF.
class DeveloperGlobalIdLibrary extends StatefulWidget {
  const DeveloperGlobalIdLibrary({super.key});
  @override State<DeveloperGlobalIdLibrary> createState()=>_DeveloperGlobalIdLibraryState();
}
class _DeveloperGlobalIdLibraryState extends State<DeveloperGlobalIdLibrary> {
  List<Map<String,dynamic>> rows=[];
  bool busy=false, storageReady=false;
  String kind='studentId';
  String? message;
  static const categories={'studentId':'Student','teacherId':'Teacher','otherStaffId':'Other Staff'};
  @override void initState(){super.initState();refresh();}
  Future<void> refresh() async {
    if(busy)return;
    setState(()=>busy=true);
    try {
      final result=await ManagedDeveloperService.call('id-library/list',{});
      if(!mounted)return;
      setState((){rows=(result['templates'] as List).map((v)=>Map<String,dynamic>.from(v as Map)).toList();
        storageReady=result['storageConfigured']==true;message=null;});
    }catch(e){if(mounted)setState(()=>message='Library unavailable: $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> upload() async {
    if(busy||!storageReady)return;
    final category=kind;
    final picked=await openFile(acceptedTypeGroups:[const XTypeGroup(label:'PDF',extensions:['pdf'],mimeTypes:['application/pdf'])]);
    if(picked==null||!mounted)return;
    if(await picked.length()>8*1024*1024){if(mounted)setState(()=>message='PDF must be at most 8 MiB.');return;}
    if(!mounted)return;
    final name=TextEditingController(text:picked.name.replaceFirst(RegExp(r'\.pdf$',caseSensitive:false),''));
    bool synthetic=false;
    final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,update)=>AlertDialog(
      title:Text('Upload ${categories[category]} ID Card'),
      content:SizedBox(width:420,child:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:name,maxLength:100,decoration:const InputDecoration(labelText:'Template name')),
        CheckboxListTile(value:synthetic,onChanged:(v)=>update(()=>synthetic=v==true),
          title:const Text('Fictional sample data only; I have artwork redistribution rights.')),
        const Text('PDF stays private until mapping and sample removal are verified. All designs are free for now.'),
      ])),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
        FilledButton(onPressed:synthetic?()=>Navigator.pop(ctx,true):null,child:const Text('Upload draft'))],
    )));
    final title=name.text.trim();name.dispose();
    if(confirmed!=true||!mounted)return;
    setState(()=>busy=true);
    try {
      final bytes=await picked.readAsBytes();
      if(bytes.length>8*1024*1024)throw StateError('PDF exceeds size limit');
      await ManagedDeveloperService.call('id-library/upload',{
        'name':title,'kind':category,'syntheticSampleConfirmed':true,'pdfBase64':base64Encode(bytes),
      });
    }catch(e){if(mounted)setState(()=>message='Upload failed: $e');return;}
    finally{if(mounted)setState(()=>busy=false);}
    await refresh();
  }
  Future<void> review(Map<String,dynamic> row) async {
    if(busy||!storageReady||row['state']!='draft')return;
    setState(()=>busy=true);
    try{
      final result=await ManagedDeveloperService.call('id-library/analyze',{'id':row['id']});
      if(!mounted)return;
      final analysis=Map<String,dynamic>.from(result['analysis'] as Map);
      final proceed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Mapping review required'),
        content:SizedBox(width:560,child:SingleChildScrollView(child:Column(
          crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('Template ID: ${row['id']}'),
            const Text('These are text candidates, not an automatically cleaned card. Review every field and remove all fictional text, QR and images.'),
            SelectableText(const JsonEncoder.withIndent('  ').convert(analysis)),
            const Text('Select a reviewed JSON package containing the matching manifest and clean front/back PNG artwork (base64).'),
          ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Close')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Choose reviewed package'))]));
      if(proceed!=true||!mounted)return;
      final file=await openFile(acceptedTypeGroups:[const XTypeGroup(label:'Reviewed package',extensions:['json'])]);
      if(file==null||!mounted)return;
      if(await file.length()>8*1024*1024)throw StateError('Package exceeds 8 MiB.');
      final package=Map<String,dynamic>.from(jsonDecode(await file.readAsString()) as Map);
      final backgrounds=Map<String,dynamic>.from(package['backgrounds'] as Map);
      if(!mounted)return;
      bool checked=false;
      final approve=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,update)=>AlertDialog(
        title:const Text('Review clean artwork before publishing'),
        content:SizedBox(width:560,child:SingleChildScrollView(child:Column(children:[
          for(final side in ['front','back'])if(backgrounds[side] is String)...[
            Text(side),Image.memory(base64Decode(backgrounds[side] as String),height:180,fit:BoxFit.contain),
          ],
          SelectableText(const JsonEncoder.withIndent('  ').convert(package['manifest'])),
          CheckboxListTile(value:checked,onChanged:(v)=>update(()=>checked=v==true),
            title:const Text('I verified all sample values, photo, logo, signature, seal and QR are removed; mapping, fonts and physical size are correct.')),
        ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
          FilledButton(onPressed:checked?()=>Navigator.pop(ctx,true):null,child:const Text('Publish free template'))])));
      if(approve!=true||!mounted)return;
      await ManagedDeveloperService.call('id-library/publish',{'id':row['id'],'sourceSha256':result['sourceSha256'],
        'reviewConfirmed':true,'package':package});
    }catch(e){if(mounted)setState(()=>message='Mapping / publication failed: $e');return;}
    finally{if(mounted)setState(()=>busy=false);}
    await refresh();
  }
  Future<void> change(Map<String,dynamic> row) async {
    if(busy)return;
    final restore=row['state']=='archived';
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:Text(restore?'Restore as draft?':'Archive template?'),
      content:const Text('Source and version history are retained. No school ID records are deleted.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:Text(restore?'Restore':'Archive'))]));
    if(ok!=true||!mounted)return;
    setState(()=>busy=true);
    try{await ManagedDeveloperService.call('id-library/${restore?'restore':'archive'}',{'id':row['id']});}
    catch(e){if(mounted)setState(()=>message='Operation failed: $e');return;}
    finally{if(mounted)setState(()=>busy=false);}
    await refresh();
  }
  @override Widget build(BuildContext context)=>Card(child:Padding(padding:const EdgeInsets.all(20),child:Column(
    crossAxisAlignment:CrossAxisAlignment.start,children:[
      Wrap(spacing:12,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[
        Text('Global ID Card Library',style:Theme.of(context).textTheme.titleLarge),
        const Chip(label:Text('FREE • Payments disabled')),
        IconButton(onPressed:busy?null:refresh,tooltip:'Refresh library',icon:const Icon(Icons.refresh)),
        FilledButton.icon(onPressed:busy||!storageReady?null:upload,icon:const Icon(Icons.upload_file),label:const Text('Upload PDF')),
      ]),
      const SizedBox(height:12),
      Wrap(spacing:8,children:[for(final e in categories.entries)ChoiceChip(label:Text(e.value),
        selected:kind==e.key,onSelected:busy?null:(_)=>setState(()=>kind=e.key))]),
      if(busy)const LinearProgressIndicator(),
      if(!storageReady&&!busy)const Text('Private Firebase template storage is not configured. Upload disabled.'),
      if(message!=null)Text(message!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
      for(final row in rows.where((r)=>r['kind']==kind))
        ListTile(title:Text('${row['name']}'),subtitle:Text('v${row['version']} • ${row['state']} • ${row['mappingState']}'),
          trailing:PopupMenuButton<String>(enabled:!busy,onSelected:(v)=>v=='review'?review(row):change(row),itemBuilder:(_)=>[
            if(row['state']=='draft')const PopupMenuItem(value:'review',child:Text('Analyze / review / publish')),
            PopupMenuItem(value:'change',child:Text(row['state']=='archived'?'Restore draft':'Archive')),
          ])),
      if(!busy&&!rows.any((r)=>r['kind']==kind))const Padding(padding:EdgeInsets.all(12),child:Text('No templates in this category.')),
      const Text('Drafts are private. Text mapping candidates require reviewed clean artwork before publication.'),
    ],
  )));
}
