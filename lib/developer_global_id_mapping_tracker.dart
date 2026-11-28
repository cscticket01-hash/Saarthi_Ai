import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'global_id_card_review.dart';

/// Read-only snapshot of the same detection pipeline used by the editor.
/// Published templates display their actual approved manifest, not guesses.
class DeveloperGlobalIdMappingTracker extends StatefulWidget {
  const DeveloperGlobalIdMappingTracker({super.key,required this.name,required this.kind,required this.data});
  final String name,kind;
  final Future<Map<String,dynamic>> data;
  @override State<DeveloperGlobalIdMappingTracker> createState()=>_TrackerState();
}
class _TrackerState extends State<DeveloperGlobalIdMappingTracker>{
  String side='front';
  late final Future<_Mapping> mapping;
  static const labels=<String,String>{
    'schoolName':'School Name','logo':'Logo','photo':'Photo',
    'confirmedUniversalStudentUid':'Student ID','qr':'QR','name':'Name',
    'parentName':'Father / Guardian','dob':'D.O.B','class':'Class',
    'rollNo':'Roll','contact':'Contact No.','address':'Address',
    'signature':'Principal Signature','seal':'School Seal',
    'employeeId':'Employee ID','designation':'Designation','subject':'Subject',
    'section':'Section','schoolAddress':'School Address','schoolContactNo':'School Contact',
  };
  @override void initState(){super.initState();mapping=widget.data.then(_Mapping.fromData);}
  double n(Map<String,dynamic> row,String key)=>(row[key] as num?)?.toDouble()??0;
  String label(Object? key)=>labels[key]??(key==null||key==''?'Unclassified':key.toString());
  Color color(Map<String,dynamic> row,bool verified)=>row['key']==''||row['roleConfidence']=='low'?Colors.orange.shade800:verified?Colors.green.shade700:Colors.red.shade700;
  List<String> get checklist=>[
    'schoolName','logo','photo',widget.kind=='studentId'?'confirmedUniversalStudentUid':'employeeId','qr','name',
    if(widget.kind=='studentId')...['parentName','dob','class','rollNo']else...['designation',if(widget.kind=='teacherId')'subject'],
    'contact','address','signature','seal',
  ];
  @override Widget build(BuildContext context)=>AlertDialog(
    title:const Text('Track Mapping Data'),
    content:SizedBox(width:860,child:FutureBuilder<_Mapping>(future:mapping,builder:(ctx,snapshot){
      if(snapshot.hasError)return const Text('Mapping data unavailable. Refresh the library and retry.');
      if(!snapshot.hasData)return const SizedBox(height:180,child:Center(child:CircularProgressIndicator()));
      final data=snapshot.data!;
      final current=data.pages.firstWhere((p)=>p['side']==side,orElse:()=>data.pages.first);
      final active=current['side'].toString(),w=n(current,'canvasWidth'),h=n(current,'canvasHeight');
      final visible=data.slots.where((r)=>r['side']==active&&r['key']!='__static').toList();
      final tracked=data.slots.where((r)=>r['key']!=''&&r['key']!='__static'&&r['roleConfidence']!='low').map((r)=>r['key']).toSet();
      final tentative=data.slots.where((r)=>r['roleConfidence']=='low').map((r)=>r['key']).toSet();
      final uncertain=data.slots.where((r)=>r['key']==''||r['roleConfidence']=='low').length;
      bool found(String key)=>tracked.contains(key);
      final image=data.images[active];
      return SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(widget.name,style:Theme.of(context).textTheme.titleMedium),
        Text(data.verified?'Approved template mapping • read only':'Automatic detection candidates • read only, not yet approved'),
        const SizedBox(height:8),
        Text(checklist.where(found).length.toString()+' / '+checklist.length.toString()+' reference fields located • '+uncertain.toString()+' uncertain candidates'),
        if(data.category!=null)Text('Detected category: '+({'studentId':'Student','teacherId':'Teacher','otherStaffId':'Other Staff'}[data.category]??data.category!)),
        const SizedBox(height:8),
        Wrap(spacing:8,children:[for(final p in data.pages)ChoiceChip(
          label:Text(p['side']=='front'?'Front':'Back'),selected:active==p['side'],
          onSelected:(_)=>setState(()=>side=p['side'].toString()))]),
        const SizedBox(height:8),
        if(image!=null&&w>0&&h>0)AspectRatio(aspectRatio:w/h,child:LayoutBuilder(builder:(ctx,c)=>Stack(
          clipBehavior:Clip.hardEdge,fit:StackFit.expand,children:[
            Image.memory(image,fit:BoxFit.fill),
            for(final row in visible.where((r)=>n(r,'width')>0&&n(r,'height')>0))
              Positioned(left:n(row,'x')/w*c.maxWidth,top:n(row,'y')/h*c.maxHeight,
                width:n(row,'width')/w*c.maxWidth,height:n(row,'height')/h*c.maxHeight,
                child:Tooltip(message:label(row['key']),child:Container(
                  decoration:BoxDecoration(border:Border.all(color:color(row,data.verified),width:1.8)),
                  child:Align(alignment:Alignment.topLeft,child:Text(label(row['key']),
                    maxLines:1,overflow:TextOverflow.ellipsis,
                    style:TextStyle(fontSize:10,color:color(row,data.verified),backgroundColor:Colors.white)))))),
          ]))),
        const SizedBox(height:12),
        Text('Field tracking',style:Theme.of(context).textTheme.titleSmall),
        Wrap(spacing:6,runSpacing:4,children:[for(final key in checklist)Chip(
          label:Text(label(key)+(found(key)?'':tentative.contains(key)?' · Uncertain':' · Not found')),avatar:Icon(found(key)?Icons.check_circle_outline:Icons.help_outline,size:17,
            color:found(key)?(data.verified?Colors.green.shade700:Colors.red.shade700):Colors.orange.shade800))]),
        const SizedBox(height:8),
        const Text('Red: detected candidate • Orange: uncertain • Green: approved. A missing field may simply not exist on this design.'),
        ExpansionTile(title:const Text('Mapping coordinates'),children:[
          for(final row in visible)ListTile(dense:true,title:Text(label(row['key'])),
            subtitle:Text('X '+n(row,'x').toStringAsFixed(1)+' • Y '+n(row,'y').toStringAsFixed(1)+' • W '+n(row,'width').toStringAsFixed(1)+' • H '+n(row,'height').toStringAsFixed(1)+(row['roleEvidence']!=null?' • '+row['roleEvidence'].toString():'')+(row['evidence']!=null?' • '+row['evidence'].toString():''))),
        ]),
      ]));
    })),
    actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Close'))]);
}
class _Mapping{
  _Mapping(this.verified,this.pages,this.slots,this.images,this.category);
  final bool verified;
  final List<Map<String,dynamic>> pages,slots;
  final Map<String,Uint8List> images;
  final String? category;
  static _Mapping fromData(Map<String,dynamic> raw){
    final rasters=Map<String,dynamic>.from(raw['rasters'] as Map);
    final images=<String,Uint8List>{for(final e in rasters.entries)e.key:base64Decode(e.value as String)};
    if(raw['mode']=='verified'){
      final manifest=Map<String,dynamic>.from(raw['manifest'] as Map);
      final pages=[for(final side in images.keys)<String,dynamic>{'side':side,'canvasWidth':manifest['canvasWidth'],'canvasHeight':manifest['canvasHeight']}];
      final slots=(manifest['regions'] as List).map((r)=>Map<String,dynamic>.from(r as Map)).toList();
      return _Mapping(true,pages,slots,images,null);
    }
    final analysis=Map<String,dynamic>.from(raw['analysis'] as Map);
    final pages=(analysis['pages'] as List).map((r)=>Map<String,dynamic>.from(r as Map)).toList();
    if(pages.isEmpty)throw const FormatException('No analyzed pages');
    return _Mapping(false,pages,GlobalIdCardReview.detectSlots(pages,images),images,(analysis['category'] as Map?)?['kind']?.toString());
  }
}
