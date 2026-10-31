import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'windows_document_templates.dart';
import 'windows_local_firestore.dart';
import 'windows_template_import_engine.dart';

/// One reusable editor, opened only from the three supported document tabs.
/// Uploads are local drafts; no school-wide selection is mutated.
class SchoolTemplateImportEditor {
  static Future<void> pickAndEdit(
      BuildContext context,SchoolTemplateKind kind,Map<String,dynamic> example) async {
    final db=FirebaseFirestore.instance;
    final origin=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
    try {
      SchoolTemplateImportEngine.verifySchool(school);
      const types=XTypeGroup(label:'PDF or Image',
        extensions:['pdf','png','jpg','jpeg']);
      final file=await openFile(acceptedTypeGroups:[types]);
      if(file==null || !context.mounted) return;
      if(origin!=db.activeProfileId ||
        db.activeProfileIdentity['schoolSyncId']!=school) {
        throw StateError('School changed while choosing a template.');
      }
      final bytes=await file.readAsBytes();
      final draft=await SchoolTemplateImportEngine.importBytes(
        kind:kind,schoolId:school,filename:file.name,
        bytes:Uint8List.fromList(bytes),
      );
      if(!context.mounted || origin!=db.activeProfileId ||
        db.activeProfileIdentity['schoolSyncId']!=school) {
        throw StateError('School changed during import.');
      }
      await showDialog<void>(context:context,barrierDismissible:false,
        builder:(_)=>_TemplateEditor(draft:draft,example:example,
          originProfile:origin));
    } catch(error) {
      if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text('Template import not completed: '+error.toString())));
    }
  }
}

class _TemplateEditor extends StatefulWidget {
  const _TemplateEditor({required this.draft,required this.example,
    required this.originProfile});
  final SchoolTemplateDraft draft;
  final Map<String,dynamic> example;
  final String originProfile;
  @override
  State<_TemplateEditor> createState()=>_TemplateEditorState();
}

class _TemplateEditorState extends State<_TemplateEditor> {
  late SchoolTemplateDraft draft=widget.draft;
  bool saving=false;
  String? message;
  String? selectedKey;
  bool get schoolVerified {
    final db=FirebaseFirestore.instance;
    return db.activeProfileId==widget.originProfile &&
      db.activeProfileIdentity['schoolSyncId']==draft.schoolId;
  }
  @override
  void initState() {
    super.initState();
    selectedKey=draft.kind.fields.first;
  }
  void changeField(int index,SchoolTemplateField next) {
    if(!mounted) return;
    final fields=[...draft.fields];
    fields[index]=next;
    setState(()=>draft=draft.copyWith(fields:fields));
  }
  void addField() {
    if(draft.fields.length>=35 || selectedKey==null) return;
    if(draft.fields.any((f)=>f.key==selectedKey)) {
      setState(()=>message='That data field is already on this page.');
      return;
    }
    final i=draft.fields.length;
    final next=SchoolTemplateField(key:selectedKey!,x:.1,
      y:math.min(.82,.1+i*.065),width:.32);
    setState((){
      draft=draft.copyWith(fields:[...draft.fields,next]);
      message=null;
    });
  }
  Future<void> saveDraft() async {
    if(saving) return;
    setState((){saving=true;message=null;});
    try {
      await SchoolTemplateImportEngine.saveLocalDraft(draft,
        currentSchoolId:()=>schoolVerified?draft.schoolId:'');
      if(mounted) setState(()=>message=
        'Draft saved locally for this school. NOT active on other PCs or publications.');
    } catch(error) {
      if(mounted) setState(()=>message='Could not save draft: '+error.toString());
    } finally {
      if(mounted) setState(()=>saving=false);
    }
  }
  Future<void> preview() async {
    if(saving) return;
    try {
      if(!schoolVerified) throw StateError('School changed.');
      final pdf=await SchoolTemplateImportEngine.previewPdf(draft,widget.example);
      if(!mounted || !schoolVerified) return;
      await WindowsDocumentTemplates.preview(context,pdf,
        title:draft.kind.title+' • Imported PDF draft',
        notice:'Original design + mapped sample data. Inspect EVERY field before using. '
          'This is not a published school template.');
    } catch(error) {
      if(mounted) setState(()=>message='Preview unavailable: '+error.toString());
    }
  }
  Widget previewArea() => LayoutBuilder(builder:(context,constraints) {
    final scale=math.min(
      math.min((constraints.maxWidth-16)/draft.width,
        (constraints.maxHeight-16)/draft.height),1.0);
    final w=draft.width*scale,h=draft.height*scale;
    return Center(child:SizedBox(
      width:w,height:h,
      child:Stack(children:[
        Positioned.fill(child:Image.memory(draft.png,fit:BoxFit.fill)),
        for(var i=0;i<draft.fields.length;i++)
          Positioned(
            left:draft.fields[i].x*w,
            top:draft.fields[i].y*h,
            width:draft.fields[i].width*w,
            child:GestureDetector(
              key:ValueKey('template-field-drag-'+draft.fields[i].key),
              onPanUpdate:(detail){
                final current=draft.fields[i];
                changeField(i,current.copyWith(
                  x:(current.x+detail.delta.dx/w).clamp(0.0,1-current.width),
                  y:(current.y+detail.delta.dy/h).clamp(0.0,.96)));
              },
              child:Container(
                decoration:BoxDecoration(
                  color:draft.fields[i].mask?Colors.white:const Color(0xCC062329),
                  border:Border.all(color:const Color(0xFF00D9A5))),
                padding:const EdgeInsets.all(3),
                child:Text(
                  SchoolTemplateImportEngine.valueFor(draft.fields[i].key,widget.example)
                    .isEmpty?draft.fields[i].key:
                    SchoolTemplateImportEngine.valueFor(draft.fields[i].key,widget.example),
                  maxLines:1,overflow:TextOverflow.ellipsis,
                  style:TextStyle(
                    color:draft.fields[i].mask?Colors.black:Colors.white,
                    fontSize:math.max(10,w*draft.fields[i].size),
                    fontWeight:FontWeight.w600)),
              ),
            ),
          ),
      ]),
    ));
  });
  Widget fieldControls()=>Column(children:[
    Row(children:[
      Expanded(child:DropdownButton<String>(
        key:const ValueKey('template-import-field'),
        isExpanded:true,value:selectedKey,
        items:draft.kind.fields.map((e)=>DropdownMenuItem(
          value:e,child:Text(e))).toList(),
        onChanged:saving?null:(value)=>setState(()=>selectedKey=value))),
      const SizedBox(width:8),
      FilledButton.icon(onPressed:saving?null:addField,
        icon:const Icon(Icons.add),label:const Text('Add field')),
    ]),
    const SizedBox(height:8),
    for(var i=0;i<draft.fields.length;i++)
      Card(child:Padding(padding:const EdgeInsets.all(9),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Row(children:[
            Expanded(child:Text(draft.fields[i].key,
              style:const TextStyle(fontWeight:FontWeight.w700))),
            IconButton(tooltip:'Remove field',
              onPressed:saving?null:(){
                setState((){
                  final fields=[...draft.fields]..removeAt(i);
                  draft=draft.copyWith(fields:fields);
                });
              },icon:const Icon(Icons.close,size:18)),
          ]),
          Row(children:[
            Text('X '+(draft.fields[i].x*100).round().toString()+'%'),
            Expanded(child:Slider(value:draft.fields[i].x.clamp(0,1-draft.fields[i].width),
              min:0,max:1-draft.fields[i].width,
              onChanged:(v)=>changeField(i,draft.fields[i].copyWith(x:v)))),
          ]),
          Row(children:[
            Text('Y '+(draft.fields[i].y*100).round().toString()+'%'),
            Expanded(child:Slider(value:draft.fields[i].y.clamp(0,.96),
              min:0,max:.96,
              onChanged:(v)=>changeField(i,draft.fields[i].copyWith(y:v)))),
          ]),
          CheckboxListTile(
            dense:true,contentPadding:EdgeInsets.zero,
            title:const Text('Mask old printed value with white'),
            value:draft.fields[i].mask,
            onChanged:(v)=>changeField(i,draft.fields[i].copyWith(mask:v==true))),
        ]),
      )),
  ]);
  @override
  Widget build(BuildContext context)=>Dialog(
    child:SizedBox(width:1100,height:720,child:Padding(
      padding:const EdgeInsets.all(18),
      child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Row(children:[
          const Icon(Icons.auto_awesome,color:Color(0xFF00D9A5)),
          const SizedBox(width:10),
          Expanded(child:Text('Import '+draft.kind.title+' template',
            style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold))),
          IconButton(tooltip:'Close import without publication',
            onPressed:saving?null:()=>Navigator.pop(context),
            icon:const Icon(Icons.close)),
        ]),
        const Text('Imported background is preserved. Drag or adjust mapped data fields. '
          'A scanned JPG/PDF cannot be assumed to have editable text or correct automatic field positions. '
          'Only a local draft is saved; school-wide selection is untouched.'),
        const SizedBox(height:12),
        Expanded(child:Row(children:[
          Expanded(flex:7,child:DecoratedBox(
            decoration:BoxDecoration(border:Border.all(color:Colors.white24)),
            child:previewArea())),
          const SizedBox(width:14),
          Expanded(flex:5,child:ListView(children:[
            Text('Source: '+draft.filename),
            const SizedBox(height:8),
            Text('Page: '+draft.width.toString()+' × '+draft.height.toString()),
            const SizedBox(height:12),
            const Text('Data-linked fields (review placement)',
              style:TextStyle(fontWeight:FontWeight.bold)),
            fieldControls(),
          ])),
        ])),
        if(message!=null) Padding(padding:const EdgeInsets.only(top:8),
          child:Text(message!,style:const TextStyle(color:Colors.amberAccent))),
        const SizedBox(height:12),
        Row(mainAxisAlignment:MainAxisAlignment.end,children:[
          OutlinedButton.icon(onPressed:saving?null:preview,
            icon:const Icon(Icons.picture_as_pdf),label:const Text('Preview PDF')),
          const SizedBox(width:12),
          FilledButton.icon(
            key:const ValueKey('save-school-template-draft'),
            onPressed:saving||!schoolVerified?null:saveDraft,
            icon:const Icon(Icons.save_outlined),
            label:const Text('Save draft locally')),
        ]),
      ]),
    )),
  );
}
