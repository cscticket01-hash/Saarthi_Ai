import 'package:flutter/material.dart';
class SchoolPasswordPanel extends StatefulWidget {
  const SchoolPasswordPanel({super.key,required this.change});
  final Future<void> Function(String,String) change;
  @override State<SchoolPasswordPanel> createState()=>_SchoolPasswordPanelState();
}
class _SchoolPasswordPanelState extends State<SchoolPasswordPanel>{
  final current=TextEditingController(),next=TextEditingController(),confirm=TextEditingController();
  bool busy=false;String? message;
  @override void dispose(){current.dispose();next.dispose();confirm.dispose();super.dispose();}
  Future<void> save()async{
    if(busy)return;
    if(next.text.length<12||next.text.length>128||next.text!=confirm.text){setState(()=>message='Use 12–128 characters and matching passwords.');return;}
    setState(()=>busy=true);
    try{await widget.change(current.text,next.text);if(!mounted)return;current.clear();next.clear();confirm.clear();if(mounted)setState(()=>message='Password changed. Sign in with your new password.');}
    catch(_){if(mounted)setState(()=>message='Password change failed. Check your current password and connection.');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context)=>Card(child:Padding(padding:const EdgeInsets.all(20),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Change account password',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),const SizedBox(height:16),for(final entry in [(current,'Current Password'),(next,'New Password'),(confirm,'Confirm Password')])Padding(padding:const EdgeInsets.only(bottom:12),child:TextField(controller:entry.$1,obscureText:true,enableSuggestions:false,autocorrect:false,decoration:InputDecoration(labelText:entry.$2))),if(message!=null)Text(message!),FilledButton(onPressed:busy?null:save,child:Text(busy?'Saving…':'Change Password'))])));
}
