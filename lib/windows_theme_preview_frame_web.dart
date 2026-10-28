// Browser-only frame. No developer credentials or school records cross this bridge.
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js;
import 'dart:ui_web' as ui;
import 'package:flutter/material.dart';
class WindowsThemePreviewFrame extends StatefulWidget {
 const WindowsThemePreviewFrame({super.key,required this.seed,required this.brightness,required this.page,this.navigation=0});
 final Color seed;final Brightness brightness;final String page;final int navigation;
 @override State<WindowsThemePreviewFrame> createState()=>_PreviewFrameState();
}
class _PreviewFrameState extends State<WindowsThemePreviewFrame>{
 static int counter=0;
 late final String view='windows-theme-preview-${counter++}';
 late final html.IFrameElement frame;
 StreamSubscription<html.MessageEvent>? events;Timer? timeout;
 bool ready=false,failed=false;
 @override void initState(){super.initState();
  frame=html.IFrameElement()..src=Uri.base.resolve('/windows-preview/').toString()..title='Interactive Windows app preview with demo data'..style.border='0'..style.width='100%'..style.height='100%';
  frame.setAttribute('sandbox','allow-scripts allow-same-origin');
  frame.setAttribute('referrerpolicy','no-referrer');
  ui.platformViewRegistry.registerViewFactory(view,(_)=>frame);
  events=html.window.onMessage.listen((event){
   if(event.origin!=Uri.base.origin||!identical(js.getProperty(event,'source'),js.getProperty(frame,'contentWindow'))||event.data is! String)return;
   try{final data=jsonDecode(event.data as String);if(data is Map&&data['type']=='vidya-preview-ready'){
    timeout?.cancel();if(mounted)setState((){ready=true;failed=false;});send();
   }}catch(_){}
  });
  timeout=Timer(const Duration(seconds:45),(){if(mounted&&!ready)setState(()=>failed=true);});
 }
 void send()=>frame.contentWindow?.postMessage(jsonEncode({'type':'vidya-preview-theme','red':(widget.seed.r*255).round(),'green':(widget.seed.g*255).round(),'blue':(widget.seed.b*255).round(),'mode':widget.brightness==Brightness.dark?'dark':'light','page':widget.page,'navigation':widget.navigation}),Uri.base.origin);
 @override void didUpdateWidget(covariant WindowsThemePreviewFrame old){super.didUpdateWidget(old);if(ready)send();}
 @override void dispose(){events?.cancel();timeout?.cancel();frame.src='about:blank';super.dispose();}
 @override Widget build(BuildContext context)=>Stack(children:[Positioned.fill(child:HtmlElementView(viewType:view)),if(!ready)Positioned.fill(child:ColoredBox(color:Theme.of(context).colorScheme.surface,child:Center(child:failed?Column(mainAxisSize:MainAxisSize.min,children:[const Text('Preview could not load. Reload this page to retry.'),TextButton(onPressed:(){setState(()=>failed=false);frame.src=Uri.base.resolve('/windows-preview/?reload=${DateTime.now().millisecondsSinceEpoch}').toString();},child:const Text('Retry preview'))]):const Column(mainAxisSize:MainAxisSize.min,children:[CircularProgressIndicator(),SizedBox(height:16),Text('Loading Windows app preview…')]))))]);
}
