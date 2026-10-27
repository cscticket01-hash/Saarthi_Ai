import 'package:flutter/material.dart';
import 'platform/managed_developer_service.dart';

class DeveloperWindowsTheme extends StatefulWidget {
  const DeveloperWindowsTheme({super.key});
  @override State<DeveloperWindowsTheme> createState()=>_DeveloperWindowsThemeState();
}
class _DeveloperWindowsThemeState extends State<DeveloperWindowsTheme> {
  final values=<int>[0,140,120];
  String revision='default';
  String? error;
  bool busy=true,loaded=false;
  @override void initState(){super.initState();load();}
  void apply(Map theme){for(var i=0;i<3;i++) values[i]=(theme[['red','green','blue'][i]] as num).toInt();revision=theme['revision'] as String;}
  Future<void> load() async {
    setState(()=>busy=true);
    try{final r=await ManagedDeveloperService.call('theme/get',{});if(mounted)setState((){apply(r['theme'] as Map);loaded=true;error=null;});}
    catch(e){if(mounted)setState(()=>error='$e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> save() async {
    setState(()=>busy=true);
    try{final r=await ManagedDeveloperService.call('theme/save',{'theme':{'schemaVersion':1,'red':values[0],'green':values[1],'blue':values[2],'expectedRevision':revision}});
      if(mounted){setState((){apply(r['theme'] as Map);error=null;});ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Windows theme saved. Each school receives it after all its Windows PCs reach App Lock, then unlock.')));}}
    catch(e){if(mounted)setState(()=>error='$e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    const Text('Windows app theme',style:TextStyle(fontSize:24,fontWeight:FontWeight.w700)),
    const Text('One brand colour for every school. Windows users keep their own Dark / Light choice. Saved changes wait until every Windows PC for a school reaches App Lock. Users see the colour when they unlock. An open or unconfirmed PC keeps the previous colour.'),
    if(busy)const LinearProgressIndicator(),
    if(error!=null)Text(error!,style:const TextStyle(color:Colors.orangeAccent)),
    for(var i=0;i<3;i++) Row(children:[SizedBox(width:75,child:Text('${['Red','Green','Blue'][i]} ${values[i]}')),
      Expanded(child:Slider(min:0,max:255,divisions:255,value:values[i].toDouble(),onChanged:busy||!loaded?null:(v)=>setState(()=>values[i]=v.round())))]),
    const Text('Preview • readable shades are generated from your RGB colour'),
    Wrap(spacing:16,runSpacing:16,children:[for(final brightness in [Brightness.dark,Brightness.light])Builder(builder:(context){
      final scheme=ColorScheme.fromSeed(seedColor:Color.fromARGB(255,values[0],values[1],values[2]),brightness:brightness);
      return Theme(data:ThemeData(colorScheme:scheme,useMaterial3:true),child:Card(child:SizedBox(width:300,child:Padding(padding:const EdgeInsets.all(20),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Text(brightness==Brightness.dark?'Dark mode':'Light mode',style:TextStyle(color:scheme.onSurface,fontWeight:FontWeight.bold)),
        const SizedBox(height:12),Text('Student records and staff salary',style:TextStyle(color:scheme.onSurface)),const SizedBox(height:12),
        FilledButton(onPressed:(){},child:const Text('Primary action')),const TextField(decoration:InputDecoration(labelText:'Example field')),const SizedBox(height:12),
        Chip(label:const Text('Selected item')),Text('Hints, borders and icons share the same palette.',style:TextStyle(color:scheme.onSurfaceVariant)),
      ])))));
    })]),
    const SizedBox(height:20),Wrap(spacing:12,children:[FilledButton.icon(onPressed:busy||!loaded?null:save,icon:const Icon(Icons.save),label:const Text('Save Windows theme')),
      OutlinedButton(onPressed:busy?null:load,child:const Text('Reload saved theme'))]),
  ]);
}
