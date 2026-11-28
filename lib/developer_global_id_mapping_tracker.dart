import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'global_id_card_review.dart';

/// Drafts may be corrected visually. Approved immutable versions remain read-only.
class DeveloperGlobalIdMappingTracker extends StatefulWidget {
  const DeveloperGlobalIdMappingTracker({super.key,required this.name,required this.kind,required this.data,this.save});
  final String name,kind;
  final Future<Map<String,dynamic>> data;
  final Future<Map<String,dynamic>> Function(Map<String,dynamic>)? save;
  @override State<DeveloperGlobalIdMappingTracker> createState()=>_TrackerState();
}
class _TrackerState extends State<DeveloperGlobalIdMappingTracker>{
  String side='front',field='logo',shape='rectangle',tool='draw',assignRole='logo';
  bool manual=false,saving=false,dirty=false,syncMask=false;
  String? error;
  late final Future<_Mapping> mapping;
  _Mapping? loaded;
  List<Map<String,dynamic>> slots=[];
  final undo=<List<Map<String,dynamic>>>[],redo=<List<Map<String,dynamic>>>[];
  int selected=-1,revision=0;
  Offset? start,point;
  Rect? original,dragRect;
  List<Map<String,dynamic>>? dragBefore;
  static const labels=<String,String>{
    'schoolName':'School Name','logo':'Logo','photo':'Photo',
    'confirmedUniversalStudentUid':'Student ID','qr':'QR','name':'Name',
    'parentName':'Father / Guardian','dob':'D.O.B','class':'Class',
    'rollNo':'Roll','contact':'Contact No.','address':'Address',
    'signature':'Principal Signature','seal':'School Seal',
    'employeeId':'Employee ID','designation':'Designation','subject':'Subject',
    'section':'Section','schoolAddress':'School Address','schoolContactNo':'School Contact',
    '__static':'Static artwork (keep)','':'Unclassified',
  };
  @override void initState(){
    super.initState();
    mapping=widget.data.then(_Mapping.fromData).then((data){
      loaded=data;slots=copy(data.saved??data.automatic);revision=data.revision;
      return data;
    });
  }
  static List<Map<String,dynamic>> copy(List<Map<String,dynamic>> input)=>input.map((r)=>Map<String,dynamic>.from(r)).toList();
  double n(Map<String,dynamic> row,String key)=>(row[key] as num?)?.toDouble()??0;
  String label(Object? key)=>labels[key]??(key==null?'Unclassified':key.toString());
  bool get validSelection=>selected>=0&&selected<slots.length&&slots[selected]['side']==side;
  Map<String,dynamic>? get selection=>validSelection?slots[selected]:null;
  Color color(Map<String,dynamic> row,bool verified)=>verified?Colors.green.shade700:
    row['key']==''||row['roleConfidence']=='low'?Colors.orange.shade800:row['manual']==true?Colors.blue.shade700:Colors.red.shade700;
  List<String> get checklist=>[
    'schoolName','logo','photo',widget.kind=='studentId'?'confirmedUniversalStudentUid':'employeeId','qr','name',
    if(widget.kind=='studentId')...['parentName','dob','class','rollNo']else...['designation',if(widget.kind=='teacherId')'subject'],
    'contact','address','signature','seal',
  ];
  void checkpoint(){
    undo.add(copy(slots));if(undo.length>40)undo.removeAt(0);redo.clear();dirty=true;
  }
  void history(bool backward){
    final from=backward?undo:redo,to=backward?redo:undo;
    if(from.isEmpty)return;
    setState((){to.add(copy(slots));slots=from.removeLast();selected=-1;dirty=true;});
  }
  void change(void Function() action){setState((){checkpoint();error=null;action();});}
  void selectField(String key){
    setState((){
      field=key;selected=slots.indexWhere((r)=>r['side']==side&&r['key']==key);
      shape=selection?['oval']==true?'oval':'rectangle';tool='draw';
    });
  }
  Rect rect(Map<String,dynamic> r,{String prefix=''})=>Rect.fromLTWH(n(r,prefix+'x'),n(r,prefix+'y'),n(r,prefix+'width'),n(r,prefix+'height'));
  bool get imageRole=>GlobalIdCardReview.imageFields.contains(field);
  Offset bound(Offset p,double w,double h)=>Offset(p.dx.clamp(0,w).toDouble(),p.dy.clamp(0,h).toDouble());
  Offset design(Offset p,BoxConstraints c,double w,double h)=>bound(Offset(p.dx*w/c.maxWidth,p.dy*h/c.maxHeight),w,h);
  void setRect(Map<String,dynamic> row,Rect r,{String prefix=''}){
    row.addAll({prefix+'x':r.left,prefix+'y':r.top,prefix+'width':r.width,prefix+'height':r.height});
  }
  void hit(Offset p){
    for(var i=slots.length-1;i>=0;i--){
      if(slots[i]['side']==side&&rect(slots[i]).contains(p)){
        setState((){selected=i;field=slots[i]['key'].toString();shape=slots[i]['oval']==true?'oval':'rectangle';});
        return;
      }
    }
  }
  void begin(Offset p){
    if(saving)return;
    if(tool=='move'||tool=='resize'){
      if(!validSelection)hit(p);
      if(!validSelection)return;
      original=rect(slots[selected]);
    }else if(tool=='mask'){
      if(!validSelection)return;
    }
    setState((){start=p;point=p;dragRect=null;dragBefore=copy(slots);});
  }
  void update(Offset p,double w,double h){
    final origin=start;if(origin==null)return;
    setState((){
      point=p;
      if(tool=='move'&&original!=null){
        final old=original!,d=p-origin;
        dragRect=Rect.fromLTWH((old.left+d.dx).clamp(0,math.max(0,w-old.width)).toDouble(),
          (old.top+d.dy).clamp(0,math.max(0,h-old.height)).toDouble(),old.width,old.height);
      }else if(tool=='resize'&&original!=null){
        final old=original!;
        var rw=(old.width+p.dx-origin.dx).clamp(.1,w-old.left).toDouble(),rh=(old.height+p.dy-origin.dy).clamp(.1,h-old.top).toDouble();
        if(shape=='square'||shape=='circle'||field=='qr'){final size=math.min(rw,rh);rw=size;rh=size;}
        dragRect=Rect.fromLTWH(old.left,old.top,rw,rh);
      }else{
        var end=p;
        if(tool=='draw'&&(shape=='square'||shape=='circle'||field=='qr')){
          final dx=p.dx-origin.dx,dy=p.dy-origin.dy;
          final size=math.min(dx.abs(),dy.abs());
          end=Offset(origin.dx+(dx<0?-size:size),origin.dy+(dy<0?-size:size));
        }
        dragRect=Rect.fromPoints(origin,end);
      }
    });
  }
  void end(){
    final r=dragRect;
    if(r==null||r.width<.5||r.height<.5){cancelDrag();return;}
    if(!validSelection&&(tool!='draw'||slots.length>=128)){cancelDrag();return;}
    setState((){
      if(dragBefore!=null){undo.add(dragBefore!);if(undo.length>40)undo.removeAt(0);redo.clear();}
      dirty=true;error=null;
      if(tool=='draw'){
        // Replace an existing role on this side, or draw a new role.
        final existing=field.isEmpty||field=='__static'?selected:slots.indexWhere((v)=>v['side']==side&&v['key']==field);
        if(existing>=0&&existing<slots.length&&slots[existing]['side']==side){selected=existing;}
        else{slots.add({'side':side,'key':field});selected=slots.length-1;}
        final row=slots[selected];
        row['key']=field;row['kind']=GlobalIdCardReview.kind(field);row['oval']=imageRole&&(shape=='circle'||shape=='oval');
        row['manual']=true;row['roleConfidence']='medium';
        if(GlobalIdCardReview.textFields.contains(field)){
          row['fontSize']??=math.max(6.0,math.min(72.0,r.height*.8));
          if(field=='address')row['wrap']=true;
        }
        setRect(row,r);setRect(row,r,prefix:'sample_');
      }else if(validSelection){
        final row=slots[selected];
        if(tool=='mask'){setRect(row,r,prefix:'sample_');row['sampleOval']=shape=='circle'||shape=='oval';}
        else{setRect(row,r);if(syncMask)setRect(row,r,prefix:'sample_');}
        row['manual']=true;row['roleConfidence']='medium';
      }
      start=null;point=null;original=null;dragRect=null;dragBefore=null;
    });
  }
  void cancelDrag(){setState((){start=null;point=null;original=null;dragRect=null;dragBefore=null;});}
  int overlaps(){
    final active=slots.where((r)=>r['key']!='__static'&&r['key']!='').toList();var count=0;
    for(var i=0;i<active.length;i++){
      for(final b in active.skip(i+1)){final a=active[i];if(a['side']==b['side']&&rect(a).overlaps(rect(b)))count++;}
    }
    return count;
  }
  Future<void> saveMapping()async{
    if(widget.save==null||saving||loaded==null)return;
    final issue=slots.map(GlobalIdCardReview.readabilityIssue).whereType<String>().firstOrNull;
    if(issue!=null){setState(()=>error=issue);return;}
    setState((){saving=true;error=null;});
    try{
      final result=await widget.save!({'sourceSha256':loaded!.sourceSha256,'mappingRevision':revision,'slots':copy(slots)});
      if(!mounted)return;
      setState((){revision=(result['mappingRevision'] as num).toInt();dirty=false;});
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content:Text('Mapping saved. Publish still requires final review.')));
    }catch(e){if(mounted)setState(()=>error=e.toString());}
    finally{if(mounted)setState(()=>saving=false);}
  }
  Future<void> close()async{
    if(saving)return;
    if(dirty){
      final discard=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Unsaved mapping changes'),content:const Text('Discard unsaved changes? Your last saved mapping is safe.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Keep editing')),TextButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Discard'))]));
      if(discard!=true||!mounted)return;
    }
    if(mounted)Navigator.pop(context);
  }
  Widget overlay(Map<String,dynamic> row,Rect r,BoxConstraints c,double w,double h,bool verified,{bool ghost=false}){
    final ink=ghost?Colors.blue:!verified&&GlobalIdCardReview.readabilityIssue(row)!=null?Colors.red.shade900:color(row,verified),oval=row['oval']==true;
    return Positioned(left:r.left/w*c.maxWidth,top:r.top/h*c.maxHeight,
      width:r.width/w*c.maxWidth,height:r.height/h*c.maxHeight,
      child:IgnorePointer(child:Container(decoration:BoxDecoration(
        borderRadius:oval?BorderRadius.circular(999):null,
        border:Border.all(color:ink,width:ghost?2.5:1.8),
        color:ghost?ink.withOpacity(.12):null),
        child:Align(alignment:Alignment.topLeft,child:Text(label(row['key']),maxLines:1,overflow:TextOverflow.ellipsis,
          style:TextStyle(fontSize:10,color:ink,backgroundColor:Colors.white))))));
  }
  Widget controls(){
    final row=selection;
    final roles=['', '__static',...checklist,...GlobalIdCardReview.textFields,...GlobalIdCardReview.imageFields,'qr'].toSet().toList();
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Wrap(spacing:8,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[
        SizedBox(width:220,child:DropdownButtonFormField<String>(value:roles.contains(field)?field:'logo',isExpanded:true,
          decoration:const InputDecoration(labelText:'Field to select',isDense:true),
          items:[for(final role in roles)DropdownMenuItem(value:role,child:Text(label(role)))],onChanged:saving?null:(v)=>selectField(v!))),
        for(final t in ['draw','move','resize','mask'])ChoiceChip(label:Text({'draw':'Draw','move':'Move','resize':'Resize','mask':'Sample mask'}[t]!),
          selected:tool==t,onSelected:saving?null:(_)=>setState(()=>tool=t)),
        IconButton(tooltip:'Undo',onPressed:saving||undo.isEmpty?null:()=>history(true),icon:const Icon(Icons.undo)),
        IconButton(tooltip:'Redo',onPressed:saving||redo.isEmpty?null:()=>history(false),icon:const Icon(Icons.redo)),
        TextButton(onPressed:saving?null:()=>change((){slots=copy(loaded!.automatic);selected=-1;}),child:const Text('Reset to automatic')),
        TextButton.icon(onPressed:saving?null:()=>change((){slots=GlobalIdCardReview.fitOutputRegions(loaded!.pages,slots);selected=-1;}),icon:const Icon(Icons.fit_screen),label:const Text('Fit readable text boxes')),
      ]),
      Wrap(spacing:8,runSpacing:4,children:[
        for(final s in ['rectangle','square',if(imageRole)...['circle','oval']])ChoiceChip(label:Text(s[0].toUpperCase()+s.substring(1)),
          selected:shape==s,onSelected:saving?null:(_){setState(()=>shape=s);if(row!=null&&imageRole)change((){row['oval']=s=='circle'||s=='oval';row['manual']=true;});}),
        if(row!=null)...[
          TextButton.icon(onPressed:saving?null:()=>change((){row['roleConfidence']='medium';row['manual']=true;}),icon:const Icon(Icons.check),label:const Text('Confirm selection')),
          TextButton.icon(onPressed:saving?null:()=>change((){slots.removeAt(selected);selected=-1;}),icon:const Icon(Icons.delete_outline),label:const Text('Remove selection')),
          if(row['key']=='')...[
            DropdownButton<String>(value:assignRole,items:[for(final role in roles.where((v)=>v.isNotEmpty&&v!='__static'))DropdownMenuItem(value:role,child:Text(label(role)))],
              onChanged:saving?null:(v)=>setState(()=>assignRole=v!)),
            TextButton(onPressed:saving?null:()=>change((){
              if(slots.any((s)=>!identical(s,row)&&s['side']==side&&s['key']==assignRole)){error='That field already exists. Remove or redraw it.';return;}
              row['key']=assignRole;row['kind']=GlobalIdCardReview.kind(assignRole);row['roleConfidence']='medium';row['manual']=true;field=assignRole;
            }),child:const Text('Assign role')),
          ],
          if(row['key']=='')TextButton(onPressed:saving?null:()=>change((){row['key']='__static';row['roleConfidence']='medium';row['manual']=true;}),child:const Text('Keep as decoration')),
        ],
      ]),
      for(final r in slots.where((r)=>GlobalIdCardReview.readabilityIssue(r)!=null))
        Text(GlobalIdCardReview.readabilityIssue(r)!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
      if(row!=null&&tool=='mask')FilterChip(label:const Text('Oval sample removal'),selected:row['sampleOval']==true,onSelected:saving?null:(v)=>change((){row['sampleOval']=v;shape=v?'oval':'rectangle';})),
      if(tool=='move'||tool=='resize')CheckboxListTile(contentPadding:EdgeInsets.zero,dense:true,value:syncMask,
        onChanged:saving?null:(v)=>setState(()=>syncMask=v==true),title:const Text('Move sample-removal mask with the selection')),
      if(row!=null&&GlobalIdCardReview.textFields.contains(row['key']))Wrap(spacing:8,runSpacing:4,crossAxisAlignment:WrapCrossAlignment.center,children:[
        FilterChip(label:const Text('Vertical text'),selected:row['rotation']==-90,onSelected:saving?null:(v)=>change((){row['rotation']=v?-90:0;row['manual']=true;})),
        FilterChip(label:const Text('Wrap text'),selected:row['wrap']==true,onSelected:saving?null:(v)=>change((){row['wrap']=v;row['manual']=true;})),
        FilterChip(label:const Text('Bold'),selected:row['bold']==true,onSelected:saving?null:(v)=>change((){row['bold']=v;row['manual']=true;})),
        DropdownButton<String>(value:row['align'] as String? ?? 'left',items:[for(final v in ['left','center','right'])DropdownMenuItem(value:v,child:Text(v))],
          onChanged:saving?null:(v)=>change((){row['align']=v;row['manual']=true;})),
        SizedBox(width:95,child:TextFormField(key:ValueKey('font:'+identityHashCode(row).toString()),initialValue:(row['fontSize']??12).toString(),
          decoration:const InputDecoration(labelText:'Font size',isDense:true),keyboardType:const TextInputType.numberWithOptions(decimal:true),
          onFieldSubmitted:(v){final size=double.tryParse(v);if(size!=null&&size>=6&&size<=72)change((){row['fontSize']=size;row['manual']=true;});})),
        SizedBox(width:115,child:TextFormField(key:ValueKey('color:'+identityHashCode(row).toString()),initialValue:(row['textColor']??'#000000').toString(),
          decoration:const InputDecoration(labelText:'Text colour',isDense:true),onFieldSubmitted:(v){if(RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v))change((){row['textColor']=v;row['manual']=true;});})),
      ]),
      Text(tool=='draw'?'Choose a field and drag its exact area on the card.':tool=='mask'?'Draw the original sample area to erase, independently of the output field.':tool=='move'?'Select a field and drag to move it.':'Select a field and drag to change its width and height.'),
    ]);
  }
  @override Widget build(BuildContext context)=>PopScope(canPop:!saving&&!dirty,child:AlertDialog(
    title:const Text('Track Mapping Data'),
    content:SizedBox(width:860,child:FutureBuilder<_Mapping>(future:mapping,builder:(ctx,snapshot){
      if(snapshot.hasError)return const Text('Mapping data unavailable. Refresh the library and retry.');
      if(!snapshot.hasData)return const SizedBox(height:180,child:Center(child:CircularProgressIndicator()));
      final data=snapshot.data!;
      final current=data.pages.firstWhere((p)=>p['side']==side,orElse:()=>data.pages.first);
      final active=current['side'].toString(),w=n(current,'canvasWidth'),h=n(current,'canvasHeight');
      final shown=manual?slots:data.automatic;
      final visible=shown.where((r)=>r['side']==active&&r['key']!='__static').toList();
      final tracked=shown.where((r)=>r['key']!=''&&r['key']!='__static'&&r['roleConfidence']!='low').map((r)=>r['key']).toSet();
      final tentative=shown.where((r)=>r['roleConfidence']=='low').map((r)=>r['key']).toSet();
      final uncertain=shown.where((r)=>r['key']==''||r['roleConfidence']=='low').length;
      bool found(String key)=>tracked.contains(key);
      final image=data.images[active],editable=!data.verified&&widget.save!=null;
      return SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(widget.name,style:Theme.of(context).textTheme.titleMedium),
        Text(data.verified?'Approved template mapping • read only':manual&&revision>0?'Saved draft mapping • not published':'Automatic detection candidates • not yet approved'),
        if(!data.verified&&revision>0&&!manual)const Text('Saved corrections are available in Manual Mapping.'),
        if(editable)...[
          const SizedBox(height:8),
          Wrap(spacing:8,children:[
            ChoiceChip(label:const Text('Automatic Mapping'),selected:!manual,onSelected:saving?null:(_)=>setState(()=>manual=false)),
            ChoiceChip(label:const Text('Manual Mapping'),selected:manual,onSelected:saving?null:(_)=>setState(()=>manual=true)),
          ]),
        ],
        Text(checklist.where(found).length.toString()+' / '+checklist.length.toString()+' reference fields located • '+uncertain.toString()+' uncertain candidates'),
        if(data.category!=null)Text('Detected category: '+({'studentId':'Student','teacherId':'Teacher','otherStaffId':'Other Staff'}[data.category]??data.category!)),
        Wrap(spacing:8,children:[for(final p in data.pages)ChoiceChip(label:Text(p['side']=='front'?'Front':'Back'),selected:active==p['side'],
          onSelected:saving?null:(_)=>setState((){side=p['side'].toString();selected=-1;}))]),
        if(manual&&editable)controls(),
        const SizedBox(height:8),
        if(image!=null&&w>0&&h>0)AspectRatio(aspectRatio:w/h,child:LayoutBuilder(builder:(ctx,c)=>GestureDetector(
          behavior:HitTestBehavior.opaque,dragStartBehavior:DragStartBehavior.down,
          onTapUp:manual&&!saving?(e)=>hit(design(e.localPosition,c,w,h)):null,
          onPanStart:manual&&!saving?(e)=>begin(design(e.localPosition,c,w,h)):null,
          onPanUpdate:manual&&!saving?(e)=>update(design(e.localPosition,c,w,h),w,h):null,
          onPanEnd:manual&&!saving?(_)=>end():null,onPanCancel:manual&&!saving?cancelDrag:null,
          child:Stack(clipBehavior:Clip.hardEdge,fit:StackFit.expand,children:[
            Image.memory(image,fit:BoxFit.fill),
            for(final row in visible.where((r)=>n(r,'width')>0&&n(r,'height')>0))
              overlay(row,rect(row),c,w,h,data.verified),
            if(manual&&validSelection)overlay(slots[selected],rect(slots[selected]),c,w,h,false,ghost:true),
            if(manual&&tool=='mask'&&validSelection&&slots[selected]['sample_x']!=null)
              overlay({'key':'Sample mask','oval':slots[selected]['sampleOval']==true},rect(slots[selected],prefix:'sample_'),c,w,h,false,ghost:true),
            if(dragRect!=null)overlay({'key':field,'oval':shape=='circle'||shape=='oval'},dragRect!,c,w,h,false,ghost:true),
          ])))),
        const SizedBox(height:12),
        Text('Field tracking',style:Theme.of(context).textTheme.titleSmall),
        Wrap(spacing:6,runSpacing:4,children:[for(final key in checklist)ActionChip(
          onPressed:manual&&editable&&!saving?()=>selectField(key):null,
          label:Text(label(key)+(found(key)?'':tentative.contains(key)?' · Uncertain':' · Not found')),
          avatar:Icon(found(key)?Icons.check_circle_outline:Icons.help_outline,size:17,color:found(key)?(data.verified?Colors.green.shade700:Colors.red.shade700):Colors.orange.shade800))]),
        if(manual&&overlaps()>0)Text(overlaps().toString()+' overlapping selection pairs. Resolve before publication.',style:TextStyle(color:Theme.of(context).colorScheme.error)),
        const Text('Red: automatic • Blue: manual • Orange: uncertain • Green: approved. Missing fields may not exist in this design.'),
        ExpansionTile(title:const Text('Mapping coordinates'),children:[
          for(final row in visible)ListTile(dense:true,title:Text(label(row['key'])),onTap:manual?()=>hit(rect(row).center):null,
            subtitle:Text('X '+n(row,'x').toStringAsFixed(1)+' • Y '+n(row,'y').toStringAsFixed(1)+' • W '+n(row,'width').toStringAsFixed(1)+' • H '+n(row,'height').toStringAsFixed(1))),
        ]),
        if(error!=null)Text(error!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
        if(saving)const LinearProgressIndicator(),
      ]));
    })),
    actions:[TextButton(onPressed:saving?null:close,child:const Text('Close')),
      if(manual&&widget.save!=null&&loaded?.verified==false)FilledButton(onPressed:saving||!dirty?null:saveMapping,child:const Text('Save Mapping'))]));
}
class _Mapping{
  _Mapping(this.verified,this.pages,this.automatic,this.images,this.category,this.saved,this.sourceSha256,this.revision);
  final bool verified;
  final List<Map<String,dynamic>> pages,automatic;
  final List<Map<String,dynamic>>? saved;
  final Map<String,Uint8List> images;
  final String? category,sourceSha256;
  final int revision;
  static _Mapping fromData(Map<String,dynamic> raw){
    final rasters=Map<String,dynamic>.from(raw['rasters'] as Map);
    final images=<String,Uint8List>{for(final e in rasters.entries)e.key:base64Decode(e.value as String)};
    if(raw['mode']=='verified'){
      final manifest=Map<String,dynamic>.from(raw['manifest'] as Map);
      final pages=[for(final side in images.keys)<String,dynamic>{'side':side,'canvasWidth':manifest['canvasWidth'],'canvasHeight':manifest['canvasHeight']}];
      final slots=(manifest['regions'] as List).map((r)=>Map<String,dynamic>.from(r as Map)).toList();
      for(final row in slots)row['oval']=row['shape']=='oval';
      return _Mapping(true,pages,slots,images,null,null,null,0);
    }
    final analysis=Map<String,dynamic>.from(raw['analysis'] as Map);
    final pages=(analysis['pages'] as List).map((r)=>Map<String,dynamic>.from(r as Map)).toList();
    if(pages.isEmpty)throw const FormatException('No analyzed pages');
    final saved=(raw['manualSlots'] as List?)?.map((r)=>Map<String,dynamic>.from(r as Map)).toList();
    return _Mapping(false,pages,GlobalIdCardReview.detectSlots(pages,images),images,(analysis['category'] as Map?)?['kind']?.toString(),saved,raw['sourceSha256'] as String?,(raw['mappingRevision'] as num?)?.toInt()??0);
  }
}
