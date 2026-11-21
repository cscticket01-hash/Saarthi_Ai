import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'document_pipeline.dart';
import 'document_scan_editor.dart';

/// A PDF edit is a reversible plan against the exact original page indices.
/// No page deletion overwrites the original file.
class DocumentPdfEditor extends StatefulWidget {
  const DocumentPdfEditor({super.key,required this.bytes,required this.scope,
    required this.initialEdits,required this.isCurrent});
  final Uint8List bytes;
  final String scope;
  final Map<String,dynamic> initialEdits;
  final bool Function() isCurrent;
  @override
  State<DocumentPdfEditor> createState()=>_DocumentPdfEditorState();
}
class _DocumentPdfEditorState extends State<DocumentPdfEditor> {
  List<Uint8List>? pages;
  List<Map<String,dynamic>> plan=[];
  final undo=<List<Map<String,dynamic>>>[],redo=<List<Map<String,dynamic>>>[];
  bool busy=true;
  String? error;
  int selected=0;
  @override
  void initState(){super.initState();load();}
  Future<void> load() async {
    try {
      final result=await DocumentPipeline.pdfEditorPages(widget.bytes,scope:widget.scope);
      if(!mounted)return;
      if(!widget.isCurrent())throw StateError('School changed.');
      final saved=DocumentPipeline.checkedEdits(widget.initialEdits)['pdfPages'] as List?;
      setState((){
        pages=result;
        plan=saved==null?[for(var i=0;i<result.length;i++){'index':i,'edits':<String,dynamic>{}}]:
          saved.map((e)=>Map<String,dynamic>.from(e as Map)).toList();
        busy=false;
      });
    }catch(e){if(mounted)setState((){error=e.toString();busy=false;});}
  }
  List<Map<String,dynamic>> snapshot()=>plan.map((e)=>Map<String,dynamic>.from(e)).toList();
  void change(VoidCallback fn){
    setState(() {undo.add(snapshot());redo.clear();fn();selected=selected.clamp(0,plan.length-1).toInt();});
  }
  void history(bool forward){
    final from=forward?redo:undo,to=forward?undo:redo;
    if(busy||from.isEmpty)return;
    setState((){to.add(snapshot());plan=from.removeLast();selected=selected.clamp(0,plan.length-1).toInt();});
  }
  Future<void> edit() async {
    final row=plan[selected],index=row['index'] as int;
    final result=await showDialog<Map<String,dynamic>>(context:context,builder:(_)=>DocumentScanEditor(
      bytes:pages![index],mime:'image/png',scope:widget.scope,
      initialEdits:Map<String,dynamic>.from(row['edits'] as Map),
      isCurrent:widget.isCurrent,initialTool:'crop',deferFullApply:true));
    if(!mounted||result==null)return;
    // Return the declarative edit, never the already compressed preview.
    change(()=>plan[selected]={'index':index,'edits':result});
  }
  void apply(){
    if(!widget.isCurrent()){setState(()=>error='School changed. Reopen document.');return;}
    Navigator.pop(context,DocumentPipeline.checkedEdits({'pdfPages':plan}));
  }
  @override
  Widget build(BuildContext context)=>AlertDialog(
    title:const Text('Smart Scan • PDF pages'),
    content:SizedBox(width:800,height:510,child:busy?const Center(child:CircularProgressIndicator()):
      pages==null?Center(child:Text(error??'PDF unavailable.')):
      Column(children:[
        Text('Page ${selected+1} of ${plan.length} • Original PDF protected'),
        Expanded(child:InteractiveViewer(minScale:1,maxScale:5,child:Center(
          child:Image.memory(pages![plan[selected]['index'] as int],fit:BoxFit.contain,
           gaplessPlayback:true)))),
        SizedBox(height:76,child:ListView.builder(scrollDirection:Axis.horizontal,itemCount:plan.length,
          itemBuilder:(_,i)=>Padding(padding:const EdgeInsets.all(3),child:OutlinedButton(
            onPressed:()=>setState(()=>selected=i),
            child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
              Text('Page ${i+1}'),if((plan[i]['edits'] as Map).isNotEmpty)const Text('Edited'),
              if(i==selected)const Icon(Icons.check,size:14),
            ]))))),
        Wrap(spacing:6,runSpacing:4,children:[
          OutlinedButton.icon(onPressed:edit,icon:const Icon(Icons.crop),label:const Text('Edit page')),
          OutlinedButton.icon(onPressed:selected==0?null:()=>change((){
            final row=plan.removeAt(selected);plan.insert(--selected,row);
          }),icon:const Icon(Icons.arrow_back),label:const Text('Move left')),
          OutlinedButton.icon(onPressed:selected+1==plan.length?null:()=>change((){
            final row=plan.removeAt(selected);plan.insert(++selected,row);
          }),icon:const Icon(Icons.arrow_forward),label:const Text('Move right')),
          OutlinedButton.icon(onPressed:plan.length<=1?null:()=>change(()=>plan.removeAt(selected)),
            icon:const Icon(Icons.delete_outline),label:const Text('Remove page')),
          IconButton(tooltip:'Undo page change',onPressed:undo.isEmpty?null:()=>history(false),icon:const Icon(Icons.undo)),
          IconButton(tooltip:'Redo page change',onPressed:redo.isEmpty?null:()=>history(true),icon:const Icon(Icons.redo)),
        ]),
        if(error!=null)Text(error!),
      ])),
    actions:[
      TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),
      FilledButton(onPressed:busy||plan.isEmpty?null:apply,child:const Text('Apply pages')),
    ]);
}
