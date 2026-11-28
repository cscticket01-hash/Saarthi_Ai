import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'global_id_card_review.dart';

class DeveloperGlobalIdReviewEditor extends StatefulWidget {
  const DeveloperGlobalIdReviewEditor({super.key,required this.id,required this.analysis,required this.rasters,this.loadCleanPdf});
  final String id;
  final Map<String,dynamic> analysis,rasters;
  final Future<Map<String,Uint8List>> Function(Uint8List)? loadCleanPdf;
  @override State<DeveloperGlobalIdReviewEditor> createState()=>_ReviewState();
}
class _ReviewState extends State<DeveloperGlobalIdReviewEditor>{
  late final List<Map<String,dynamic>> pages;
  late final Map<String,Uint8List> images;
  final slots=<Map<String,dynamic>>[];
  String side='front';
  String? error;
  bool busy=false,allowSmoothGradient=true,allowApproximateRepair=true,showAdvanced=false;
  final cleanArtwork=<String,Uint8List>{};
  final cleanCompanion=<String,Uint8List>{};
  Map<String,dynamic> withMask(Map<String,dynamic> row)=>{...row,for(final k in ['x','y','width','height'])'sample_$k':row['sample_$k']??row[k]};
  @override void initState(){
    super.initState();
    pages=(widget.analysis['pages'] as List).map((v)=>Map<String,dynamic>.from(v as Map)).toList();
    images={for(final e in widget.rasters.entries)e.key:base64Decode(e.value as String)};
    for(final page in pages){
      for(final item in (page['candidates'] as List? ?? const [])){
        final r=Map<String,dynamic>.from(item as Map);
        if(GlobalIdCardReview.textFields.contains(r['key']))slots.add(withMask(r));
      }
      for(final item in (page['imageCandidates'] as List? ?? const [])){
        final r=Map<String,dynamic>.from(item as Map);
        final role=r['suggestedRole'];
        final recognized=(GlobalIdCardReview.imageFields.contains(role)||role=='qr')&&!slots.any((s)=>s['side']==r['side']&&s['key']==role);
        slots.add(withMask({...r,'key':recognized?role:''}));
      }
    }
    GlobalIdCardReview.suggestQr(pages,slots,images);
    GlobalIdCardReview.suggestPlaceholderSlots(pages,slots,images);
  }
  Map<String,dynamic> get page=>pages.firstWhere((p)=>p['side']==side);
  double n(Map<String,dynamic> row,String key)=>(row[key] as num?)?.toDouble()??0;
  Future<void> chooseCleanPdf() async{
    if(busy||widget.loadCleanPdf==null)return;
    final picked=await openFile(acceptedTypeGroups:[const XTypeGroup(label:'Clean companion PDF',extensions:['pdf'],mimeTypes:['application/pdf'])]);
    if(picked==null||!mounted)return;
    setState((){busy=true;error=null;});
    try{
      if(await picked.length()>8*1024*1024)throw const FormatException('PDF exceeds 8 MiB');
      final bytes=await picked.readAsBytes();
      if(bytes.length>8*1024*1024)throw const FormatException('PDF exceeds 8 MiB');
      final result=await widget.loadCleanPdf!(bytes);
      if(!mounted)return;
      if(result.length!=images.length||!images.keys.every(result.containsKey))throw const FormatException('Companion sides differ.');
      setState((){cleanCompanion.clear();cleanCompanion.addAll(result);cleanArtwork.clear();});
    }catch(e){if(mounted)setState(()=>error=e.toString());}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> chooseCleanArtwork() async{
    if(busy)return;
    final target=side;
    final picked=await openFile(acceptedTypeGroups:[const XTypeGroup(label:'Clean PNG artwork',extensions:['png'],mimeTypes:['image/png'])]);
    if(picked==null||!mounted)return;
    if(await picked.length()>8*1024*1024){if(mounted)setState(()=>error='Clean PNG exceeds 8 MiB');return;}
    final bytes=await picked.readAsBytes();
    if(!mounted)return;
    if(bytes.length>8*1024*1024){setState(()=>error='Clean PNG exceeds 8 MiB');return;}
    setState((){cleanCompanion.remove(target);cleanArtwork[target]=bytes;});
  }
  Future<void> buildPackage() async{
    if(busy)return;
    setState((){busy=true;error=null;});
    try{
      // Render a frame before the bounded synchronous PNG preparation.
      await Future<void>.delayed(Duration.zero);
      final result=GlobalIdCardReview.package(widget.id,pages,slots,images,allowSmoothGradient:allowSmoothGradient,allowApproximateRepair:allowApproximateRepair,cleanArtwork:cleanArtwork,cleanCompanion:cleanCompanion);
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
      title:const Text('Automatic ID card analysis'),
      content:SizedBox(width:820,child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('${slots.where((r)=>r['key']!=''&&r['key']!='__static').length} fields detected • ${slots.where((r)=>r['key']=='').length} unresolved'),
        const Text('Review the detected fields. Prepare clean review automatically where the original artwork can be preserved. Uncertain fields and complex backgrounds need correction before publication.'),
        Wrap(spacing:6,runSpacing:4,children:[for(final role in ['schoolName','logo','photo','confirmedUniversalStudentUid','qr','name','parentName','dob','class','rollNo','contact','address','signature','seal'])
          Chip(label:Text(role),avatar:Icon(slots.any((r)=>r['key']==role)?Icons.check_circle_outline:Icons.help_outline,size:16))]),
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
        CheckboxListTile(value:allowApproximateRepair,onChanged:busy?null:(v)=>setState(()=>allowApproximateRepair=v==true),
          title:const Text('Automatic background repair'),
          subtitle:const Text('For hidden complex patterns, reconstructed pixels are approximate. Check the final artwork before publishing.')),
        CheckboxListTile(value:allowSmoothGradient,onChanged:busy?null:(v)=>setState(()=>allowSmoothGradient=v==true),title:const Text('Try smooth gradient cleanup (review required)')),
        if(widget.loadCleanPdf!=null)TextButton.icon(onPressed:busy?null:chooseCleanPdf,icon:const Icon(Icons.picture_as_pdf),label:const Text('Use matching clean original PDF (preserve complex artwork)')),
        if(cleanCompanion[side]!=null)...[Image.memory(cleanCompanion[side]!,height:120,fit:BoxFit.contain),const Text('Companion will be compared against the filled source outside all sample masks.'),TextButton(onPressed:busy?null:()=>setState(()=>cleanCompanion.clear()),child:const Text('Remove clean PDF companion'))],
        TextButton.icon(onPressed:busy?null:chooseCleanArtwork,icon:const Icon(Icons.image),label:Text(cleanArtwork.containsKey(side)?'Replace clean $side PNG':'Use clean original $side PNG')),
        if(cleanArtwork[side]!=null)...[Image.memory(cleanArtwork[side]!,height:120,fit:BoxFit.contain),TextButton(onPressed:busy?null:()=>setState(()=>cleanArtwork.remove(side)),child:const Text('Remove clean artwork override'))],
        Text('${page['printWidthMm']} × ${page['printHeightMm']} mm • original PDF geometry'),
        TextButton.icon(onPressed:busy?null:()=>setState(()=>showAdvanced=!showAdvanced),icon:Icon(showAdvanced?Icons.expand_less:Icons.expand_more),label:Text(showAdvanced?'Hide field corrections':'Show field corrections')),
        if(showAdvanced)TextButton.icon(onPressed:busy||slots.length>=128?null:()=>setState(()=>slots.add({'side':side,'key':'','x':w*.1,'y':h*.1,'width':w*.25,'height':h*.1})),
          icon:const Icon(Icons.add),label:const Text('Add missing field / QR / image slot')),
        for(final row in visible.where((r)=>showAdvanced||r['key']==''))Card(child:Padding(padding:const EdgeInsets.all(8),child:Column(children:[
          Row(children:[
            Expanded(child:DropdownButtonFormField<String>(key:ObjectKey(row),value:roles.contains(row['key'])?row['key'] as String:'',
              isExpanded:true,items:[for(final role in roles)DropdownMenuItem(value:role,child:Text(role==''?'Unclassified — select role':role=='__static'?'Static decoration (keep)':role))],
              onChanged:busy?null:(v)=>setState(()=>row['key']=v??''))),
            IconButton(tooltip:'Remove incorrect candidate',onPressed:busy?null:()=>setState(()=>slots.remove(row)),icon:const Icon(Icons.close)),
          ]),
          if(row['roleConfidence']=='low')
            Text('Possible role from layout: ${row['suggestedRole']=='__static'?'static decoration':row['suggestedRole']}. Confirm the role before continuing.'),
          if(row['key']!='__static')Wrap(spacing:8,runSpacing:8,children:[
            for(final key in ['x','y','width','height'])number(row,key),
            if(row.containsKey('sample_x'))...[
              const Text('Original sample removal rectangle (independent of output field)'),
              for(final key in ['sample_x','sample_y','sample_width','sample_height'])number(row,key),
            ],
            if(GlobalIdCardReview.textFields.contains(row['key']))...[
              number(row,'fontSize'),
              FilterChip(label:const Text('Bold'),selected:row['bold']==true,onSelected:busy?null:(v)=>setState(()=>row['bold']=v)),
              Text(row['sourceFont']==null
                ? 'Source font could not be verified. Review the bundled DejaVu/Noto output.'
                : 'Detected source font: ${row['sourceFont']}. Output uses the bundled DejaVu/Noto fonts. Review the rendered text.'),
              if(row['sourceItalic']==true)
                const Text('The source uses italic text. Review the upright fallback before publishing.'),
              DropdownButton<String>(
                value: row['align'] as String? ?? 'left',
                items: const [
                  DropdownMenuItem(value:'left',child:Text('Align left')),
                  DropdownMenuItem(value:'center',child:Text('Align center')),
                  DropdownMenuItem(value:'right',child:Text('Align right')),
                ],
                onChanged:busy?null:(value)=>setState(()=>row['align']=value),
              ),
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
        FilledButton(onPressed:busy?null:buildPackage,child:const Text('Generate clean preview'))]));
  }
}
