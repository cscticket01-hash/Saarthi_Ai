import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'platform/managed_developer_service.dart';
class ManagedDeveloperPanel extends StatefulWidget {
  const ManagedDeveloperPanel({super.key,required this.schools,required this.refresh});
  final List<Map<String,dynamic>> schools;
  final Future<void> Function() refresh;
  @override State<ManagedDeveloperPanel> createState()=>_ManagedDeveloperPanelState();
}
class _ManagedDeveloperPanelState extends State<ManagedDeveloperPanel> {
  bool busy=false;String? message;Map<String,dynamic>? monitoring;
  Future<void> run(String action,Map<String,dynamic> body) async {
    if(busy)return;setState(()=>busy=true);
    try {final result=await ManagedDeveloperService.call(action,body);if(!mounted)return;
      if(action=='monitor'){setState(()=>monitoring=result);}
      else {await widget.refresh();if(!mounted)return;final output=result['passwordSetupLink']??result['key'];
        if(output!=null)await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(title:Text(result['key']!=null?'School licence':'Secure password setup link'),content:SelectableText('$output'),actions:[TextButton(onPressed:()=>Clipboard.setData(ClipboardData(text:'$output')),child:const Text('Copy')),TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))]));
        if(mounted)setState(()=>message='Completed');}
    }catch(e){if(mounted)setState(()=>message='$e');}finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> form(String action,Map<String,dynamic>? school) async {
    final name=TextEditingController(),email=TextEditingController(),url=TextEditingController(),secret=TextEditingController(),days=TextEditingController(text:'365');bool paid=true;
    final body=await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,update)=>AlertDialog(title:Text(action=='create'?'Create school account':action=='storage'?'Connect school GS / Drive':'Issue / renew licence'),content:SizedBox(width:440,child:Column(mainAxisSize:MainAxisSize.min,children:[
      if(action=='create')... [TextField(controller:name,decoration:const InputDecoration(labelText:'School name')),TextField(controller:email,decoration:const InputDecoration(labelText:'School login email')),const Text('School sets its password using a Firebase setup link. Initial trial: five days.')],
      if(action=='storage')...[SelectableText('School ID: ${school!['id']}'),TextField(controller:url,decoration:const InputDecoration(labelText:'Existing Advanced Settings GS /exec URL')),TextField(controller:secret,obscureText:true,decoration:const InputDecoration(labelText:'Connection secret from VS_setupManagedSchool')),const Text('Deploy the managed GS adapter as this school’s Google account. Existing storage replacement requires separate review.')],
      if(action=='licence')...[TextField(controller:days,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Licence days (1–3650)')),CheckboxListTile(value:paid,onChanged:(v)=>update(()=>paid=v??true),title:const Text('Paid licence'))],
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,{'schoolId':school?['id'],if(action=='create')...{'schoolName':name.text.trim(),'email':email.text.trim()},if(action=='storage')...{'scriptUrl':url.text.trim(),'secret':secret.text.trim()},if(action=='licence')...{'days':int.tryParse(days.text),'paid':paid}}),child:const Text('Save'))])));
    if(body!=null)await run(action,body);for(final c in [name,email,url,secret,days]){c.dispose();}
  }
  @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Wrap(spacing:12,children:[FilledButton(onPressed:busy?null:()=>form('create',null),child:const Text('Create central school account')),OutlinedButton(onPressed:busy?null:()=>run('monitor',{}),child:const Text('Developer-only Firebase monitor'))]),
    if(busy)const LinearProgressIndicator(),if(message!=null)Text(message!),
    if(monitoring!=null)...[Text('Server response: ${monitoring!['responseMs']} ms • ${monitoring!['projectId']}'),SelectableText(const JsonEncoder.withIndent('  ').convert(monitoring!['metrics']))],
    for(final school in widget.schools.where((s)=>s['managed']==true))Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${school['name']} • ${school['id']}'),Text('Login: ${school['loginEmail']} • Storage: ${school['storageReady']==true?'Ready':'Not connected'} • Last activity: ${school['lastSeenAt']??'Not available'}'),Wrap(spacing:8,children:[
      TextButton(onPressed:busy?null:()=>run('reset',{'schoolId':school['id']}),child:const Text('Password setup / reset')),
      TextButton(onPressed:busy?null:()=>form('licence',school),child:const Text('Issue / renew licence')),
      TextButton(onPressed:busy?null:()=>form('storage',school),child:const Text('Connect school GS')),
      TextButton(onPressed:busy?null:()=>run('block',{'schoolId':school['id'],'blocked':school['blocked']!=true}),child:Text(school['blocked']==true?'Unblock':'Block')),
      TextButton(onPressed:busy?null:()=>run('disable',{'schoolId':school['id'],'blocked':school['loginDisabled']!=true}),child:Text(school['loginDisabled']==true?'Enable login':'Disable login')),
      TextButton(onPressed:busy?null:()=>run('revoke',{'schoolId':school['id']}),child:const Text('Revoke licence')),
      TextButton(onPressed:busy?null:()=>run('delete-licence',{'schoolId':school['id']}),child:const Text('Delete licence metadata')),
    ])]))),
  ]);
}
