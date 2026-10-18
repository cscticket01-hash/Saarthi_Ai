import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Firebase rules remain the authority; the composer never grants permissions.
class DeveloperNotificationPanel extends StatefulWidget {
  const DeveloperNotificationPanel({super.key, required this.schools});
  final List<Map<String,dynamic>> schools;
  @override State<DeveloperNotificationPanel> createState() => _DeveloperNotificationPanelState();
}
class _DeveloperNotificationPanelState extends State<DeveloperNotificationPanel> {
  String _audience = 'all';
  @override void didUpdateWidget(covariant DeveloperNotificationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_audience != 'all' && !widget.schools.any((s) => s['id'] == _audience)) _audience = 'all';
  }
  Future<void> _compose() async {
    final title = TextEditingController(), message = TextEditingController();
    final id = FirebaseFirestore.instance.collection('platform_developer_notifications').doc(_audience).collection('messages').doc().id;
    final audience = _audience;
    final recipient = audience == 'all' ? 'All schools' :
        (widget.schools.firstWhere((s) => s['id'] == audience, orElse: () => {'name': audience})['name'] ?? audience).toString();
    bool busy = false;
    String? error;
    await showDialog<void>(context:context,barrierDismissible:false,builder:(ctx)=>StatefulBuilder(builder:(ctx,update)=>PopScope(
      canPop:!busy,child:AlertDialog(title:const Text('Send developer notification'),
        content:SizedBox(width:520,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
          Text('Recipient: $recipient'),
          TextField(controller:title,maxLength:160,enabled:!busy,decoration:const InputDecoration(labelText:'Title')),
          TextField(controller:message,maxLength:5000,minLines:4,maxLines:10,enabled:!busy,decoration:const InputDecoration(labelText:'Message')),
          if(error!=null)Text(error!,style:const TextStyle(color:Colors.orangeAccent)),
        ]))),actions:[TextButton(onPressed:busy?null:()=>Navigator.pop(ctx),child:const Text('Cancel')),
          FilledButton(onPressed:busy?null:()async{
            final heading=title.text.trim(),body=message.text.trim();
            if(heading.isEmpty||body.isEmpty){update(()=>error='Enter a title and message.');return;}
            if(heading.length>160||body.length>5000){update(()=>error='Use a title up to 160 characters and a message up to 5000 characters.');return;}
            update((){busy=true;error=null;});
            try{
              final user=FirebaseAuth.instance.currentUser;
              if(user==null)throw StateError('Developer login required.');
              final ref=FirebaseFirestore.instance.collection('platform_developer_notifications').doc(audience).collection('messages').doc(id);
              await FirebaseFirestore.instance.runTransaction((tx)async{
                final old=await tx.get(ref);
                if(old.exists){
                  final data=old.data()!;
                  if(data['title']!=heading||data['message']!=body||data['createdBy']!=user.uid)throw StateError('This notification was already sent. Start a new message.');
                  return;
                }
                tx.set(ref,{'audience':audience,'title':heading,'message':body,'createdBy':user.uid,'createdAt':FieldValue.serverTimestamp()});
              });
              if(ctx.mounted)Navigator.pop(ctx);
              if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Developer notification published.')));
            }catch(e){if(ctx.mounted)update(()=>error=e.toString().replaceFirst('Bad state: ',''));}
            finally{if(ctx.mounted)update(()=>busy=false);}
          },child:Text(busy?'Publishing…':'Publish notification'))]))));
    // Dialog route animations may still reference the controllers.
    await Future<void>.delayed(const Duration(milliseconds:300));
    title.dispose();message.dispose();
  }
  @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    const Text('Developer notifications',style:TextStyle(fontSize:18,fontWeight:FontWeight.w700)),
    const SizedBox(height:12),
    DropdownButtonFormField<String>(value:_audience,isExpanded:true,
      decoration:const InputDecoration(labelText:'Send to'),
      items:[const DropdownMenuItem(value:'all',child:Text('All schools')),
        for(final s in widget.schools)DropdownMenuItem(value:s['id'] as String,child:Text('${s['name'] ?? s['id']} (${s['id']})'))],
      onChanged:(v){if(v!=null)setState(()=>_audience=v);}),
    const SizedBox(height:12),
    FilledButton.icon(onPressed:_compose,icon:const Icon(Icons.notifications_outlined),label:const Text('Send notification')),
    const SizedBox(height:16),
    StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
      stream:FirebaseFirestore.instance.collection('platform_developer_notifications').doc(_audience).collection('messages').orderBy('createdAt',descending:true).limit(50).snapshots(),
      builder:(context,s){
        if(s.hasError)return const Text('Published notifications could not be loaded.');
        if(!s.hasData)return const LinearProgressIndicator();
        if(s.data!.docs.isEmpty)return const Text('No notifications published for this audience yet.');
        return Column(children:[for(final d in s.data!.docs)ListTile(
          leading:const Icon(Icons.notifications),title:Text(d.data()['title']?.toString()??''),
          subtitle:Text(d.data()['message']?.toString()??'',maxLines:2,overflow:TextOverflow.ellipsis))]);
      }),
    const Divider(height:40),
  ]);
}
