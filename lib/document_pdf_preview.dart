import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Display-only horizontal page strip. Preview rasters are never saved as the
/// document; Save continues to use the original or approved compressed PDF.
class DocumentPdfPreview extends StatefulWidget {
  const DocumentPdfPreview({super.key,required this.pages});
  final List<Uint8List> pages;
  @override
  State<DocumentPdfPreview> createState()=>_DocumentPdfPreviewState();
}
class _DocumentPdfPreviewState extends State<DocumentPdfPreview>{
  int selected=0;
  @override
  void didUpdateWidget(covariant DocumentPdfPreview oldWidget){
    super.didUpdateWidget(oldWidget);
    if(oldWidget.pages!=widget.pages)selected=0;
  }
  @override
  Widget build(BuildContext context){
    if(widget.pages.isEmpty)return const Center(child:Text('PDF has no pages.'));
    selected=selected.clamp(0,widget.pages.length-1).toInt();
    return Column(children:[
      Padding(padding:const EdgeInsets.symmetric(vertical:6),child:Row(
        mainAxisAlignment:MainAxisAlignment.center,
        children:[
          const Icon(Icons.picture_as_pdf,color:Colors.redAccent,size:18),
          const SizedBox(width:8),
          Text('Page ${selected+1} of ${widget.pages.length}',
            style:Theme.of(context).textTheme.titleSmall),
        ])),
      Expanded(child:InteractiveViewer(
        minScale:1,maxScale:4,
        child:Center(child:ColoredBox(color:Colors.white,
          child:Image.memory(widget.pages[selected],fit:BoxFit.contain,
            gaplessPlayback:true,semanticLabel:'PDF page ${selected+1}'))))),
      SizedBox(height:104,child:ListView.separated(
        scrollDirection:Axis.horizontal,
        padding:const EdgeInsets.symmetric(horizontal:8,vertical:6),
        itemCount:widget.pages.length,
        separatorBuilder:(_,__)=>const SizedBox(width:8),
        itemBuilder:(context,index)=>InkWell(
          key:ValueKey('pdf-page-thumbnail-$index'),
          borderRadius:BorderRadius.circular(6),
          onTap:()=>setState(()=>selected=index),
          child:Container(
            width:66,
            padding:const EdgeInsets.all(3),
            decoration:BoxDecoration(
              color:Colors.white,
              borderRadius:BorderRadius.circular(6),
              border:Border.all(
                color:selected==index?Theme.of(context).colorScheme.primary:Colors.black26,
                width:selected==index?2:1)),
            child:Column(children:[
              Expanded(child:Image.memory(widget.pages[index],fit:BoxFit.contain,
                gaplessPlayback:true)),
              Text('${index+1}',style:const TextStyle(color:Colors.black87,fontSize:11)),
            ])),
        ),
      )),
    ]);
  }
}
