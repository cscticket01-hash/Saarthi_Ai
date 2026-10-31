import 'package:flutter/material.dart' hide Text;
import 'windows_ui_localization.dart';

/// One measured local volume and only evidence-backed active transfer links.
class WindowsSyncFlow extends StatefulWidget {
  const WindowsSyncFlow({super.key, required this.phase, required this.label,
    required this.local, required this.cloud, required this.drive,
    required this.pending, this.pendingText, this.lastMicros, this.active = const {}});
  final String phase, label, local, cloud, drive;
  final int pending;
  final String? pendingText;
  final int? lastMicros;
  final Set<String> active;
  @override State<WindowsSyncFlow> createState() => _WindowsSyncFlowState();
}
class _WindowsSyncFlowState extends State<WindowsSyncFlow> with SingleTickerProviderStateMixin {
  late final AnimationController clock = AnimationController(vsync:this,duration:const Duration(milliseconds:1200));
  void updateAnimation() {
    if (widget.phase != 'paused' && widget.active.isNotEmpty) { if(!clock.isAnimating) clock.repeat(); }
    else { clock.stop(); clock.value=0; }
  }
  @override void initState(){super.initState();updateAnimation();}
  @override void didUpdateWidget(covariant WindowsSyncFlow old){super.didUpdateWidget(old);updateAnimation();}
  @override void dispose(){clock.dispose();super.dispose();}
  @override Widget build(BuildContext context) => LayoutBuilder(builder:(context,space){
    final small=space.maxWidth<500;
    final scale=MediaQuery.textScalerOf(context).scale(1);
    final circle=(small?96.0:144.0)*scale.clamp(1.0,1.35);
    final rowHeight=94.0*scale.clamp(1.0,2.0), height=rowHeight*3+24;
    final gap=small?32.0:70.0;
    final color=Theme.of(context).colorScheme.primary;
    Widget card(String title,String text,IconData icon) => Container(
      height:rowHeight, padding:const EdgeInsets.all(10),
      decoration:BoxDecoration(border:Border.all(color:color.withValues(alpha:.5)),borderRadius:BorderRadius.circular(14)),
      child:Row(children:[Icon(icon,color:color,size:small?18:24),const SizedBox(width:10),Expanded(child:Column(
        mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,
        children:[Text(title,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold)),const SizedBox(height:5),
          Text(text,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:12))]))]));
    return SizedBox(height:height,child:Row(children:[
      SizedBox(width:circle,height:circle,child:Stack(alignment:Alignment.center,children:[
        SizedBox(width:circle-4,height:circle-4,child:CircularProgressIndicator(
          value:widget.phase!='paused'&&widget.active.isNotEmpty?null:0,strokeWidth:4,color:color,backgroundColor:color.withValues(alpha:.15))),
        SizedBox(width:circle-20,height:circle-20,child:FittedBox(fit:BoxFit.scaleDown,child:SizedBox(width:circle-20,child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(widget.phase=='idle'?Icons.check_circle_outline:Icons.sync,color:color),
          Text(widget.label,maxLines:2,overflow:TextOverflow.ellipsis,style:TextStyle(fontSize:small?12:15,fontWeight:FontWeight.bold),textAlign:TextAlign.center),
          if(widget.phase=='idle') Text(widget.lastMicros==null?'—':'${(widget.lastMicros!/1000000).toStringAsFixed(2)} sec',key:const ValueKey('last-verified-transfer'),style:const TextStyle(fontWeight:FontWeight.bold)),
          Text(widget.pendingText ?? '${widget.pending} pending',style:const TextStyle(fontSize:11),textAlign:TextAlign.center),
        ]))))])),
      SizedBox(width:gap,height:height,child:AnimatedBuilder(animation:clock,builder:(_,__)=>CustomPaint(
        painter:_TransferLinks(color,widget.phase=='paused'?const {}:widget.active,clock.value,rowHeight)))),
      Expanded(child:Column(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
        card('Local Storage',widget.local,Icons.storage_outlined),
        card('School Cloud',widget.cloud,Icons.cloud_outlined),
        card('Google Drive',widget.drive,Icons.folder_outlined),
      ])),
    ]));
  });
}
class _TransferLinks extends CustomPainter {
  _TransferLinks(this.color,this.active,this.position,this.rowHeight);
  final Color color; final Set<String> active; final double position,rowHeight;
  @override void paint(Canvas canvas,Size size){
    for(var i=0;i<3;i++){
      final lane=['local','cloud','drive'][i]; final y=[rowHeight/2,size.height/2,size.height-rowHeight/2][i];
      final path=Path()..moveTo(0,size.height/2)..cubicTo(size.width*.5,size.height/2,size.width*.5,y,size.width,y);
      canvas.drawPath(path,Paint()..color=color.withValues(alpha:active.contains(lane)?1:.25)..strokeWidth=2..style=PaintingStyle.stroke);
      if(active.contains(lane)){
        final metric=path.computeMetrics().first, p=metric.getTangentForOffset(metric.length*position)!.position;
        canvas.drawCircle(p,4,Paint()..color=color);
      }
    }
  }
  @override bool shouldRepaint(covariant _TransferLinks old)=>old.position!=position||old.color!=color||old.active!=active;
}
