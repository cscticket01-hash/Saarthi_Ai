import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'platform/managed_developer_service.dart';
import 'developer_global_id_review_editor.dart';
import 'developer_global_id_preview.dart';
import 'developer_global_id_mapping_tracker.dart';

/// Source library only. Mapping review must finish before a school can use a PDF.
class DeveloperGlobalIdLibrary extends StatefulWidget {
  const DeveloperGlobalIdLibrary({super.key});
  @override State<DeveloperGlobalIdLibrary> createState()=>_DeveloperGlobalIdLibraryState();
}
class _DeveloperGlobalIdLibraryState extends State<DeveloperGlobalIdLibrary> {
  List<Map<String,dynamic>> rows=[];
  bool busy=false, storageReady=false, analysisReady=false, imageAnalysisReady=false, rasterReady=false;
  String kind='studentId';
  String? uploadingName,uploadingKind;
  final deleting=<String>{};
  final _previews=<String,Future<Map<String,dynamic>>>{};
  Future<void> _previewTail=Future<void>.value();
  int _galleryPage=0;
  static const _pageSize=10;
  String? message;
  String storageReason='not_configured';
  static const categories={'studentId':'Student','teacherId':'Teacher','otherStaffId':'Other Staff'};
  @override void initState(){super.initState();refresh();}
  Future<void> refresh() async {
    if(busy)return;
    setState(()=>busy=true);
    try {
      final result=await ManagedDeveloperService.call('id-library/list',{});
      if(!mounted)return;
      setState((){rows=(result['templates'] as List).map((v)=>Map<String,dynamic>.from(v as Map)).toList();
        final keys=rows.map((r)=>[r['id'],r['updatedAt'],r['state']].join(':')).toSet();
        _previews.removeWhere((k,v)=>!keys.contains(k));
        storageReady=result['storageReady']==true;storageReason=result['storageReason']?.toString()??'unverified';analysisReady=result['analysisConfigured']==true;
        imageAnalysisReady=result['imageAnalysisConfigured']==true;rasterReady=result['reviewRasterizerConfigured']==true;message=null;});
    }catch(e){if(mounted)setState((){storageReady=false;message='Library unavailable: $e';});}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> checkRuntime() async {
    if(busy)return;
    setState(()=>busy=true);
    try{
      final r=await ManagedDeveloperService.call('id-library/runtime-check',{});
      if(!mounted)return;
      final checks=Map<String,dynamic>.from(r['checks'] as Map);
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Global ID runtime checks'),
        content:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('Private storage: ${r['storageReady']==true?'PASS':'NOT VERIFIED'}'),
          for(final key in ['text','imageGeometry','raster'])Text('$key: ${checks[key]==true?'PASS':'NOT VERIFIED'}'),
          const Text('Synthetic PDF probe only. School upload, real template accuracy, security and physical printing still require acceptance.'),
        ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))]));
    }catch(e){if(mounted)setState(()=>message='Runtime check failed: $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> upload([Map<String,dynamic>? previous]) async {
    if(busy||uploadingName!=null||!storageReady)return;
    final category=previous?['kind']?.toString()??kind;
    final picked=await openFile(acceptedTypeGroups:[const XTypeGroup(label:'PDF',extensions:['pdf'],mimeTypes:['application/pdf'])]);
    if(picked==null||!mounted)return;
    if(await picked.length()>8*1024*1024){if(mounted)setState(()=>message='PDF must be at most 8 MiB.');return;}
    if(!mounted)return;
    final name=TextEditingController(text:previous?['name']?.toString()??picked.name.replaceFirst(RegExp(r'\.pdf$',caseSensitive:false),''));
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
    if(uploadingName!=null)return;
    setState((){uploadingName=title;uploadingKind=category;message=null;});
    try {
      final bytes=await picked.readAsBytes();
      if(bytes.length>8*1024*1024)throw StateError('PDF exceeds size limit');
      final payload=<String,dynamic>{'name':title,'kind':category,'syntheticSampleConfirmed':true,
        'pdfBase64':base64Encode(bytes),if(previous!=null)'previousId':previous['id']};
      final preflight=await ManagedDeveloperService.call('id-library/preflight',payload);
      if(!mounted)return;
      final detected=Map<String,dynamic>.from(preflight['category'] as Map? ?? const {});
      final actual=detected['kind']?.toString();
      if(detected['evidence']=='conflicting_headings')throw StateError('PDF contains conflicting card categories.');
      var destination=category;
      if(actual!=null&&actual!=category){
        if(previous!=null)throw StateError('PDF belongs to a different category from this revision.');
        final move=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
          title:const Text('Wrong category detected'),
          content:Text('This PDF is a ${categories[actual]??actual} ID Card, not a ${categories[category]} ID Card. Save it under the correct category? No draft has been uploaded yet.'),
          actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
            FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:Text('Use ${categories[actual]??actual}'))]));
        if(move!=true||!mounted)return;
        destination=actual;
      }else if(actual==null){
        final confirm=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
          title:const Text('Confirm card category'),
          content:Text('The PDF does not contain a clear Student, Teacher or Staff heading. Confirm that it is a ${categories[category]} ID Card.'),
          actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
            FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Confirm category'))]));
        if(confirm!=true||!mounted)return;
      }
      final uploaded=await ManagedDeveloperService.call('id-library/upload',{...payload,'kind':destination,'categoryConfirmed':true});
      if(!mounted)return;
      final draft=Map<String,dynamic>.from(uploaded['template'] as Map);
      setState((){rows=[draft,...rows.where((r)=>r['id']!=draft['id'])];if(kind==destination)_galleryPage=0;});
      // Upload is already durably saved. Clear only upload progress before
      // opening the interactive mapping popup; cancellation keeps the draft.
      setState((){uploadingName=null;uploadingKind=null;});
      if(mounted&&draft['mappingState']=='review_required')await trackMapping(draft);
    }catch(e){if(mounted)setState(()=>message='Upload failed: $e');return;}
    finally{if(mounted)setState((){uploadingName=null;uploadingKind=null;});}
  }
  Future<void> review(Map<String,dynamic> row) async {
    if(busy||!storageReady||row['state']!='draft')return;
    setState(()=>busy=true);
    try{
      final result=await ManagedDeveloperService.call('id-library/analyze',{'id':row['id']});
      if(!mounted)return;
      final analysis=Map<String,dynamic>.from(result['analysis'] as Map);
      final detected=(analysis['category'] as Map?)?['kind']?.toString();
      var reviewedKind=row['kind'].toString();
      if(detected!=null&&detected!=row['kind']){
        final move=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
          title:const Text('Correct the template category'),
          content:Text('This PDF is a ${categories[detected]??detected} ID Card. Move the existing unpublished draft to the correct category without uploading it again?'),
          actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
            FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Move draft'))]));
        if(move!=true||!mounted)return;
        await ManagedDeveloperService.call('id-library/change-category',{'id':row['id'],'kind':detected});
        if(!mounted)return;
        reviewedKind=detected;
        setState((){kind=detected;rows=rows.map((r)=>r['id']==row['id']?{...r,'kind':detected}:r).toList();});
      }
      if((analysis['category'] as Map?)?['evidence']=='conflicting_headings')throw StateError('PDF contains conflicting card categories.');
      // Prefer the visual editor directly rather than showing raw analysis JSON.
      final proceed=rasterReady?'editor':await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Review required'),content:const Text('Visual PDF rendering is unavailable. Use a reviewed clean package or cancel.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,'file'),child:const Text('Choose reviewed package'))]));
      if(proceed==null||!mounted)return;
      Map<String,dynamic>? package;
      Uint8List? validatedDemo;
      Map<String,dynamic> sourceRasters={};
      if(proceed=='editor'){
        final source=await ManagedDeveloperService.call('id-library/review-source',{'id':row['id'],'sourceSha256':result['sourceSha256']});
        if(source['sourceSha256']!=result['sourceSha256'])throw StateError('Draft source changed.');
        if(!mounted)return;
        sourceRasters=Map<String,dynamic>.from(source['rasters'] as Map);
        package=await showDialog<Map<String,dynamic>>(context:context,barrierDismissible:false,builder:(_)=>
          DeveloperGlobalIdReviewEditor(id:row['id'].toString(),analysis:analysis,manualSlots:(result['manualSlots'] as List?)?.map((r)=>Map<String,dynamic>.from(r as Map)).toList(),rasters:Map<String,dynamic>.from(source['rasters'] as Map),
            validatePreview:(candidate)async{validatedDemo=await DeveloperGlobalIdPreview.generate(candidate,reviewedKind,validateQuality:true);},
            loadCleanPdf:(Uint8List bytes) async{
              final reply=await ManagedDeveloperService.call('id-library/review-clean-pdf',{'id':row['id'],'sourceSha256':result['sourceSha256'],
                'syntheticSampleConfirmed':true,'pdfBase64':base64Encode(bytes)});
              if(reply['sourceSha256']!=result['sourceSha256'])throw StateError('Draft source changed.');
              final raw=Map<String,dynamic>.from(reply['rasters'] as Map);
              return {for(final e in raw.entries)e.key:base64Decode(e.value as String)};
            }));
      }else{
        final file=await openFile(acceptedTypeGroups:[const XTypeGroup(label:'Reviewed package',extensions:['json'])]);
        if(file==null||!mounted)return;
        if(await file.length()>8*1024*1024)throw StateError('Package exceeds 8 MiB.');
        package=Map<String,dynamic>.from(jsonDecode(await file.readAsString()) as Map);
      }
      if(package==null||!mounted)return;
      final reviewedPackage=package;
      final backgrounds=Map<String,dynamic>.from(reviewedPackage['backgrounds'] as Map);
      if(!mounted)return;
      // A real final print renderer and an independent QR decode must pass
      // before the human artwork approval. The QR is only a demo string.
      final demo=validatedDemo??await DeveloperGlobalIdPreview.generate(reviewedPackage,reviewedKind,validateQuality:true);
      if(!mounted)return;
      bool checked=false;
      final approve=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,update)=>AlertDialog(
        title:const Text('Final ID card preview'),
        content:SizedBox(width:760,child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('Fictional sample only — not a valid school ID or login QR. Print renderer and QR check passed.'),
          Image.memory(demo,fit:BoxFit.contain),
          const SizedBox(height:12),
          const Text('Compare the original reference and clean artwork. Automatic detection may need corrections.'),
          for(final side in ['front','back'])if(sourceRasters[side] is String)...[
            Text('Original $side — private reference'),Image.memory(base64Decode(sourceRasters[side] as String),height:180,fit:BoxFit.contain),
          ],
          const Text('Clean artwork (check no sample data remains):'),
          for(final side in ['front','back'])if(backgrounds[side] is String)...[
            Text(side),Image.memory(base64Decode(backgrounds[side] as String),height:180,fit:BoxFit.contain),
          ],
          ExpansionTile(title:const Text('Technical mapping'),children:[SelectableText(const JsonEncoder.withIndent('  ').convert(reviewedPackage['manifest']))]),
          CheckboxListTile(value:checked,onChanged:(v)=>update(()=>checked=v==true),
            title:const Text('I verified the final card, all sample data removal, field positions, fonts and physical dimensions.')),
        ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
          FilledButton(onPressed:checked?()=>Navigator.pop(ctx,true):null,child:const Text('Publish free template'))])));
      if(approve!=true||!mounted)return;
      await ManagedDeveloperService.call('id-library/publish',{'id':row['id'],'sourceSha256':result['sourceSha256'],
        'reviewConfirmed':true,'mappingRevision':result['mappingRevision']??0,'package':reviewedPackage});
    }catch(e){if(mounted)setState(()=>message='Mapping / publication failed: $e');return;}
    finally{if(mounted)setState(()=>busy=false);}
    await refresh();
  }
  Future<void> reviseMapping(Map<String,dynamic> row)async{
    if(busy||!storageReady)return;
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Edit mapping in a new revision?'),
      content:const Text('Reuse the private original PDF and run fresh analysis. The published version and existing school selections stay unchanged until a new revision is approved.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Create revision'))]));
    if(ok!=true||!mounted)return;
    setState(()=>busy=true);
    Map<String,dynamic>? draft;
    try{final result=await ManagedDeveloperService.call('id-library/create-revision',{'id':row['id']});
      draft=Map<String,dynamic>.from(result['template'] as Map);}
    catch(e){if(mounted)setState(()=>message='Revision failed: $e');}
    finally{if(mounted)setState(()=>busy=false);}
    if(!mounted||draft==null)return;
    await refresh();
    if(mounted)await trackMapping(draft);
  }
  Future<void> makeCurrent(Map<String,dynamic> row) async {
    if(busy)return;
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Make this verified revision current?'),
      content:const Text('The previous design becomes the current library revision. Existing school selections are not silently changed.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Confirm'))]));
    if(ok!=true||!mounted)return;
    setState(()=>busy=true);
    try{await ManagedDeveloperService.call('id-library/make-current',{'id':row['id']});}
    catch(e){if(mounted)setState(()=>message='Version change failed: $e');return;}
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
  Future<void> deleteDraft(Map<String,dynamic> row) async {
    final id=row['id'].toString();
    if(busy||deleting.contains(id))return;
    final published=row['state']=='published'||row['mappingState']=='verified';
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:Text(published?'Delete published template?':'Delete draft?'),
      content:Text(published?'This template will be removed from the developer and online school libraries. Offline devices learn of revocation when they reconnect. School records and downloaded cards are not deleted. Private audit history is retained.':'This draft will disappear from the library. Private source and deletion history are retained.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Delete template'))]));
    if(ok!=true||!mounted||deleting.contains(id))return;
    setState(()=>deleting.add(id));
    try{
      await ManagedDeveloperService.call('id-library/delete',{'id':id,'confirmed':true,'revokePublished':published});
      if(mounted)setState((){rows=rows.where((r)=>r['id']!=id).toList();_previews.removeWhere((k,v)=>k.startsWith('$id:'));});
    }catch(e){if(mounted)setState(()=>message='Delete failed: $e');return;}
    finally{if(mounted)setState(()=>deleting.remove(id));}
    // Refresh current-family flags without invalidating other thumbnails.
    if(mounted)await refresh();
  }

  Future<Map<String,dynamic>> _preview(Map<String,dynamic> row){
    final key=[row['id'],row['updatedAt'],row['state']].join(':');
    return _previews.putIfAbsent(key,(){
      final request=_previewTail.then((_)async{
        if(!mounted)throw StateError('Gallery closed');
        final raw=await ManagedDeveloperService.call('id-library/preview',{'id':row['id']});
        final rasters=Map<String,dynamic>.from(raw['rasters'] as Map);
        final images=<String,Uint8List>{for(final e in rasters.entries)e.key:base64Decode(e.value as String)};
        return <String,dynamic>{'mode':raw['mode'],'images':images,'manifest':raw['manifest'],'rasters':rasters};
      });
      _previewTail=request.then<void>((_) {},onError:(Object _,StackTrace __){});
      return request;
    });
  }
  Widget _previewImage(Map<String,dynamic> data,{bool large=false}){
    final bytes=(data['images'] as Map<String,Uint8List>)['front'];
    if(bytes==null)return const Center(child:Icon(Icons.badge_outlined,size:42));
    return Image.memory(bytes,fit:BoxFit.contain,cacheWidth:large?null:480,
      errorBuilder:(_,__,___)=>const Center(child:Text('Preview unavailable')));
  }
  Future<void> showPreview(Map<String,dynamic> row)async{
    if(busy)return;
    await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
      title:Text(row['name'].toString()),
      content:SizedBox(width:620,child:FutureBuilder<Map<String,dynamic>>(future:_preview(row),builder:(_,snapshot){
        if(snapshot.hasError)return const Text('Preview unavailable. Close and refresh the library to retry.');
        if(!snapshot.hasData)return const SizedBox(height:160,child:Center(child:CircularProgressIndicator()));
        final data=snapshot.data!,images=data['images'] as Map<String,Uint8List>;
        return SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
          Text(data['mode']=='private_reference'?'Private original PDF • not published':'Verified clean artwork'),
          const SizedBox(height:12),_previewImage(data,large:true),
          if(images['back']!=null)...[const SizedBox(height:12),const Text('Back'),Image.memory(images['back']!,fit:BoxFit.contain)],
          if(data['mode']=='verified')FutureBuilder<Uint8List>(
            future:DeveloperGlobalIdPreview.generate({'manifest':data['manifest'],'backgrounds':data['rasters']},row['kind'].toString()),
            builder:(_,rendered)=>rendered.hasData?Column(children:[const Text('Fictional final print preview'),Image.memory(rendered.data!,fit:BoxFit.contain)]):
              rendered.hasError?const Text('Final print preview unavailable'):const LinearProgressIndicator()),
        ]));
      })),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))]));
  }
  Future<void> trackMapping(Map<String,dynamic> row)async{
    if(busy)return;
    // Serialize with thumbnail work to avoid simultaneous PDF processes.
    final request=_previewTail.then((_)=>ManagedDeveloperService.call('id-library/preview',{'id':row['id'],'trackMapping':true}));
    _previewTail=request.then<void>((_) {},onError:(Object _,StackTrace __){});
    final action=await showDialog<String>(context:context,barrierDismissible:false,builder:(_)=>DeveloperGlobalIdMappingTracker(
      name:row['name'].toString(),kind:row['kind'].toString(),data:request,save:row['state']=='draft'?(payload)=>ManagedDeveloperService.call('id-library/save-mapping',{'id':row['id'],...payload}):null,
      publish:row['state']=='draft'?()=>review(row):null));
    if(!mounted)return;
    if(action=='publish')await review(row);
    else if(action=='draft')await refresh();
  }
  Widget _gallery(BuildContext context){
    final visible=rows.where((r)=>r['kind']==kind).toList();
    final pending=uploadingName!=null&&uploadingKind==kind;
    if(visible.isEmpty&&!pending)return const Padding(padding:EdgeInsets.symmetric(vertical:24),child:Center(child:Text('No templates in this category. Upload PDF to add a design.')));
    final pageCount=visible.isEmpty?1:(visible.length+_pageSize-1)~/_pageSize;
    final page=_galleryPage.clamp(0,pageCount-1).toInt();
    return Column(children:[
      LayoutBuilder(builder:(ctx,constraints){
        final width=constraints.maxWidth;
        final columns=width>=1100?5:width>=840?4:width>=610?3:width>=380?2:1;
        final itemWidth=(width-(columns-1)*16)/columns;
        return Wrap(spacing:16,runSpacing:16,children:[
          if(pending)SizedBox(width:itemWidth,child:Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(children:[const SizedBox(height:96,child:Center(child:CircularProgressIndicator())),Text(uploadingName!,maxLines:2,overflow:TextOverflow.ellipsis),const Text('Uploading / analyzing PDF'),const LinearProgressIndicator()])))),
          for(final row in visible.skip(page*_pageSize).take(_pageSize))
            SizedBox(width:itemWidth,child:_templateCard(row)),
        ]);
      }),
      if(pageCount>1)Row(mainAxisAlignment:MainAxisAlignment.end,children:[
        IconButton(tooltip:'Previous page',onPressed:page==0?null:()=>setState(()=>_galleryPage=page-1),icon:const Icon(Icons.chevron_left)),
        Text((page+1).toString()+' / '+pageCount.toString()),
        IconButton(tooltip:'Next page',onPressed:page+1>=pageCount?null:()=>setState(()=>_galleryPage=page+1),icon:const Icon(Icons.chevron_right)),
      ]),
    ]);
  }
  Widget _templateCard(Map<String,dynamic> row){
    final colors=Theme.of(context).colorScheme;
    final published=row['state']=='published',draft=row['state']=='draft';
    final deletable=['draft','archived','published'].contains(row['state']);
    final removing=deleting.contains(row['id'].toString());
    return Card(margin:EdgeInsets.zero,clipBehavior:Clip.antiAlias,shape:RoundedRectangleBorder(
      borderRadius:BorderRadius.circular(14),side:BorderSide(color:colors.outlineVariant)),
      child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        SizedBox(height:190,child:Stack(children:[
          Positioned.fill(child:ColoredBox(color:colors.surfaceContainerHighest,child:Padding(
            padding:const EdgeInsets.fromLTRB(12,34,12,10),
            child:FutureBuilder<Map<String,dynamic>>(future:_preview(row),builder:(_,snapshot){
              if(snapshot.hasData)return _previewImage(snapshot.data!);
              if(snapshot.hasError)return const Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.picture_as_pdf_outlined,size:36),Text('Preview unavailable')]));
              return const Center(child:SizedBox(width:22,height:22,child:CircularProgressIndicator(strokeWidth:2)));
            })))),
          Positioned(top:8,left:8,child:Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:4),
            decoration:BoxDecoration(color:colors.surface,borderRadius:BorderRadius.circular(8)),
            child:Text(published?'Published':draft?'Draft':'Archived',style:Theme.of(context).textTheme.labelSmall))),
          Positioned(top:1,right:2,child:Material(color:colors.surface,shape:const CircleBorder(),
            child:PopupMenuButton<String>(enabled:!busy&&!removing,tooltip:'Template actions',
              onSelected:(v){if(v=='review'){trackMapping(row);}else if(v=='revision'){upload(row);}else if(v=='edit-mapping'){reviseMapping(row);}else if(v=='current'){makeCurrent(row);}else if(v=='track'){trackMapping(row);}else if(v=='delete'){deleteDraft(row);}else{change(row);}},
              itemBuilder:(_)=>[
                if(draft)const PopupMenuItem(value:'review',child:ListTile(dense:true,contentPadding:EdgeInsets.zero,leading:Icon(Icons.publish),title:Text('Publish'))),
                const PopupMenuItem(value:'track',child:ListTile(dense:true,contentPadding:EdgeInsets.zero,leading:Icon(Icons.track_changes),title:Text('Track Mapping Data'))),
                if(deletable)const PopupMenuItem(value:'delete',child:ListTile(dense:true,contentPadding:EdgeInsets.zero,leading:Icon(Icons.delete_outline),title:Text('Delete'))),
                if(published)const PopupMenuItem(value:'edit-mapping',child:Text('Edit Mapping in new revision')),
                if(published)const PopupMenuItem(value:'revision',child:Text('Upload new revision')),
                if(['published','archived'].contains(row['state'])&&row['mappingState']=='verified'&&row['isCurrent']!=true)const PopupMenuItem(value:'current',child:Text('Restore / make current')),
                PopupMenuItem(value:'change',child:Text(row['state']=='archived'?'Restore draft':'Archive')),
              ]))),
        ])),
        SizedBox(height:54,child:Padding(padding:const EdgeInsets.fromLTRB(12,10,12,4),child:Text(row['name'].toString(),
          maxLines:2,overflow:TextOverflow.ellipsis,style:Theme.of(context).textTheme.titleSmall))),
        Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Text('v'+row['version'].toString()+' • '+(row['isCurrent']==true?'Current • ':'')+'FREE',
          style:Theme.of(context).textTheme.labelSmall)),
        const SizedBox(height:8),
        const Divider(height:1),
        if(removing)const LinearProgressIndicator(),
        TextButton.icon(onPressed:busy||removing?null:()=>showPreview(row),icon:const Icon(Icons.visibility_outlined,size:18),label:const Text('Preview')),
      ]));
  }
  @override Widget build(BuildContext context)=>Card(child:Padding(padding:const EdgeInsets.all(20),child:Column(
    crossAxisAlignment:CrossAxisAlignment.start,children:[
      Wrap(spacing:12,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[
        Text('Global ID Card Library',style:Theme.of(context).textTheme.titleLarge),
        const Chip(label:Text('FREE • Payments disabled')),
        IconButton(onPressed:busy?null:refresh,tooltip:'Refresh library',icon:const Icon(Icons.refresh)),
        TextButton.icon(onPressed:busy?null:checkRuntime,icon:const Icon(Icons.fact_check_outlined),label:const Text('Check runtime')),
        FilledButton.icon(onPressed:busy||uploadingName!=null||!storageReady?null:upload,icon:const Icon(Icons.upload_file),label:const Text('Upload PDF')),
      ]),
      const SizedBox(height:12),
      Wrap(spacing:8,children:[for(final e in categories.entries)ChoiceChip(label:Text(e.value),
        selected:kind==e.key,onSelected:busy?null:(_)=>setState((){kind=e.key;_galleryPage=0;}))]),
      if(busy)const LinearProgressIndicator(),
      if(!storageReady&&!busy)Text('Private template storage is not verified ($storageReason). Upload disabled.'),
      if(storageReady&&!analysisReady)const Text('Central PDF text analysis is not configured; uploads remain private drafts.'),
      if(storageReady&&analysisReady&&!imageAnalysisReady)const Text('Image geometry analysis is not configured; manual image-slot review required.'),
      if(storageReady&&analysisReady&&!rasterReady)const Text('Visual PDF mapper runtime not configured. Reviewed clean packages can still be submitted.'),
      if(message!=null)Text(message!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
      const SizedBox(height:16),
      _gallery(context),
      const SizedBox(height:12),
      const Text('Drafts are private. Text mapping candidates require reviewed clean artwork before publication.'),
    ],
  )));
}
