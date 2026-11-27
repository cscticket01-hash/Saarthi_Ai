import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'global_id_card_review.dart';

class DeveloperGlobalIdReviewEditor extends StatefulWidget {
  const DeveloperGlobalIdReviewEditor({super.key,required this.id,required this.analysis,required this.rasters});
  final String id;
  final Map<String,dynamic> analysis,rasters;
  @override State<DeveloperGlobalIdReviewEditor> createState()=>_ReviewState();
}
class _ReviewState extends State<DeveloperGlobalIdReviewEditor>{
  late final List<Map<String,dynamic>> pages;
  late final Map<String,Uint8List> images;
  final slots=<Map<String,dynamic>>[];
  String side='front';
  String? error;
  bool busy=false,allowSmoothGradient=false;
  final cleanArtwork=<String,Uint8List>{};
  @override void initState(){
    super.initState();
    pages=(widget.analysis['pages'] as List).map((v)=>Map<String,dynamic>.from(v as Map)).toList();
    images={for(final e in widget.rasters.entries)e.key:base64Decode(e.value as String)};
    for(final page in pages){
      for(final item in (page['candidates'] as List? ?? const [])){
        final r=Map<String,dynamic>.from(item as Map);
        if(GlobalIdCardReview.textFields.contains(r['key']))slots.add(r);
      }
      for(final item in (page['imageCandidates'] as List? ?? const [])){
        final r=Map<String,dynamic>.from(item as Map);
        final role=r['suggestedRole'];
        slots.add({...r,'key':GlobalIdCardReview.imageFields.contains(role)||role=='qr'?role:''});
      }
    }
    GlobalIdCardReview.suggestQr(pages,slots,images);
  }
  Map<String,dynamic> get page=>pages.firstWhere((p)=>p['side']==side);
  double n(Map<String,dynamic> row,String key)=>(row[key] as num?)?.toDouble()??0;
  Future<void> chooseCleanArtwork() async{
    if(busy)return;
    final target=side;
    final picked=await openFile(acceptedTypeGroups:[const XTypeGroup(label:'Clean PNG artwork',extensions:['png'],mimeTypes:['image/png'])]);
    if(picked==null||!mounted)return;
    if(await picked.length()>8*1024*1024){if(mounted)setState(()=>error='Clean PNG exceeds 8 MiB');return;}
    final bytes=await picked.readAsBytes();
    if(!mounted)return;
    if(bytes.length>8*1024*1024){setState(()=>error='Clean PNG exceeds 8 MiB');return;}
    setState(()=>cleanArtwork[target]=bytes);
  }
  Future<void> buildPackage() async{
    if(busy)return;
    setState((){busy=true;error=null;});
    try{
      // Render a frame before the bounded synchronous PNG preparation.
      await Future<void>.delayed(Duration.zero);
      final result=GlobalIdCardReview.package(widget.id,pages,slots,images,allowSmoothGradient:allowSmoothGradient,cleanArtwork:cleanArtwork);
      if(mounted)Navigator.pop(context,result);
    }catch(e){if(mounted)setState(()=>error=e.toString());}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Widget number(Map<String,dynamic> row,String key)=>SizedBox(width:85,child:TextFormField(
    key:ValueKey('${identityHashCode(row)}:$key'),initialValue:row[key]?.toString()??'',
    keyboardType:const TextInputType.numberWithOptions(decimal:true),
    decoration:InputDecoration(labelText:key,isDense:true),
    onChanged:(v)=>setState(()=>row[key]=double.tryParse(v))));
  @override Widget build(BuildContext context){
    final w=n(page,'canvasWidth'),h=n(page,'canvasHeight');
    final visible=slots.where((r)=>r['side']==side).toList();
    final roles=['','__static',...GlobalIdCardReview.textFields,...GlobalIdCardReview.imageFields,'qr'];
    return PopScope(canPop:!busy,child:AlertDialog(
      title:const Text('Map fields and remove sample artwork'),
      content:SizedBox(width:820,child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('Automatic candidates are suggestions. Map every sample field/image, mark only genuine decoration static, and check the whole card. Flat and optional smooth-gradient cleanup are supported. Complex patterns require verified clean artwork.'),
        Wrap(spacing:8,children:[for(final p in pages)ChoiceChip(label:Text(p['side'].toString()),selected:p['side']==side,
          onSelected:busy?null:(_)=>setState(()=>side=p['side'].toString()))]),
        AspectRatio(aspectRatio:w/h,child:LayoutBuilder(builder:(context,c)=>Stack(fit:StackFit.expand,children:[
          Image.memory(images[side]!,fit:BoxFit.fill),
          for(final r in visible.where((r)=>r['key']!='__static'&&n(r,'width')>0&&n(r,'height')>0))
            Positioned(left:n(r,'x')/w*c.maxWidth,top:n(r,'y')/h*c.maxHeight,
              width:n(r,'width')/w*c.maxWidth,height:n(r,'height')/h*c.maxHeight,
              child:IgnorePointer(child:Container(decoration:BoxDecoration(border:Border.all(color:r['key']==''?Colors.orange:Colors.red,width:2)),child:Align(alignment:Alignment.topLeft,child:Text(r['key']==''?'?':r['key'].toString(),style:const TextStyle(fontSize:10,color:Colors.red,backgroundColor:Colors.white)))))),
        ]))),
        const SizedBox(height:8),
        CheckboxListTile(value:allowSmoothGradient,onChanged:busy?null:(v)=>setState(()=>allowSmoothGradient=v==true),title:const Text('Try smooth gradient cleanup (review required)')),
        TextButton.icon(onPressed:busy?null:chooseCleanArtwork,icon:const Icon(Icons.image),label:Text(cleanArtwork.containsKey(side)?'Replace clean $side PNG':'Use clean original $side PNG')),
        if(cleanArtwork[side]!=null)...[Image.memory(cleanArtwork[side]!,height:120,fit:BoxFit.contain),TextButton(onPressed:busy?null:()=>setState(()=>cleanArtwork.remove(side)),child:const Text('Remove clean artwork override'))],
        Text('${page['printWidthMm']} × ${page['printHeightMm']} mm • original PDF geometry'),
        TextButton.icon(onPressed:busy||slots.length>=128?null:()=>setState(()=>slots.add({'side':side,'key':'','x':w*.1,'y':h*.1,'width':w*.25,'height':h*.1})),
          icon:const Icon(Icons.add),label:const Text('Add missing field / QR / image slot')),
        for(final row in visible)Card(child:Padding(padding:const EdgeInsets.all(8),child:Column(children:[
          Row(children:[
            Expanded(child:DropdownButtonFormField<String>(key:ObjectKey(row),value:roles.contains(row['key'])?row['key'] as String:'',
              isExpanded:true,items:[for(final role in roles)DropdownMenuItem(value:role,child:Text(role==''?'Unclassified — select role':role=='__static'?'Static decoration (keep)':role))],
              onChanged:busy?null:(v)=>setState(()=>row['key']=v??''))),
            IconButton(tooltip:'Remove incorrect candidate',onPressed:busy?null:()=>setState(()=>slots.remove(row)),icon:const Icon(Icons.close)),
          ]),
          if(row['key']!='__static')Wrap(spacing:8,runSpacing:8,children:[
            for(final key in ['x','y','width','height'])number(row,key),
            if(GlobalIdCardReview.textFields.contains(row['key']))...[
              number(row,'fontSize'),
              FilterChip(label:const Text('Bold'),selected:row['bold']==true,onSelected:busy?null:(v)=>setState(()=>row['bold']=v)),
              if(row['sourceFont']!=null)Text('Source: ${row['sourceFont']} • output uses bundled DejaVu/Noto'),
              SizedBox(width:110,child:TextFormField(initialValue:row['textColor']?.toString()??'#000000',decoration:const InputDecoration(labelText:'Text colour'),
                onChanged:(v)=>row['textColor']=v)),
              FilterChip(label:const Text('Wrap'),selected:row['wrap']==true,onSelected:busy?null:(v)=>setState(()=>row['wrap']=v)),
            ],
            if(row['key']=='photo')FilterChip(label:const Text('Oval'),selected:row['oval']==true,onSelected:busy?null:(v)=>setState(()=>row['oval']=v)),
          ]),
        ]))),
        if(error!=null)Text(error!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
        if(busy)const LinearProgressIndicator(),
      ]))),
      actions:[TextButton(onPressed:busy?null:()=>Navigator.pop(context),child:const Text('Cancel')),
        FilledButton(onPressed:busy?null:buildPackage,child:const Text('Prepare clean review'))]));
  }
}
