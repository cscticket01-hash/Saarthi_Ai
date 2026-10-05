import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'windows_local_firestore.dart';
import 'windows_school_image_cache.dart';
import 'windows_connect/school_drive_images.dart';

/// The existing payroll directory remains the single non-teacher staff source.
class OtherStaffDirectory {
  static const roles = ['Office staff', 'Driver', 'Guard', 'Support staff', 'Other'];
  static Future<void> _tail = Future<void>.value();
  static void requireSchool(String profile) {
    if (FirebaseFirestore.instance.activeProfileId != profile) throw StateError('School changed. Reopen Staff Directory.');
  }
  static Future<List<Map<String,dynamic>>> load(String profile) async {
    requireSchool(profile);
    final data=(await FirebaseFirestore.instance.collection('school_settings').doc('staff_payroll_directory').get()).data();
    requireSchool(profile);
    return (data?['staff'] as List? ?? []).whereType<Map>().map((s)=>Map<String,dynamic>.from(s)).toList();
  }
  static Future<void> save(String profile, Map<String,dynamic> person) {
    final next=_tail.then((_) async {
      requireSchool(profile);
      final name=person['name']?.toString().trim()??'', employee=person['employeeId']?.toString().trim()??'';
      if(name.isEmpty || name.length>120 || employee.isEmpty || employee.length>60 || !roles.contains(person['role'])) throw ArgumentError('Name, unique Employee ID and staff category are required.');
      final people=await load(profile);
      final teachers=await FirebaseFirestore.instance.collection('teachers_directory').get();
      requireSchool(profile);
      if(people.any((p)=>p['id']!=person['id'] && p['employeeId']?.toString().toLowerCase()==employee.toLowerCase()) ||
          teachers.docs.any((d)=>(d.data()['teacherId']??d.id).toString().toLowerCase()==employee.toLowerCase())) throw StateError('This Employee ID is already assigned.');
      final id=person['id']?.toString()??'staff:${DateTime.now().microsecondsSinceEpoch}';
      final index=people.indexWhere((p)=>p['id']==id);
      final record={...person,'id':id,'name':name,'employeeId':employee,'active':person['active']!=false,'updatedAt':DateTime.now().millisecondsSinceEpoch};
      if(index<0) people.add(record); else people[index]=record;
      await FirebaseFirestore.instance.collection('school_settings').doc('staff_payroll_directory').set({'staff':people},SetOptions(merge:true));
    });
    _tail=next.then<void>((_) {},onError:(Object _,StackTrace __){});
    return next;
  }
}

class SchoolStaffDirectory extends StatefulWidget {
  const SchoolStaffDirectory({super.key,required this.teachers});
  final Widget teachers;
  @override State<SchoolStaffDirectory> createState()=>_SchoolStaffDirectoryState();
}
class _SchoolStaffDirectoryState extends State<SchoolStaffDirectory> {
  late final String profile;
  String category='Teachers',search='';
  List<Map<String,dynamic>> staff=[];
  String? error;
  @override void initState(){super.initState();profile=FirebaseFirestore.instance.activeProfileId;_load();}
  Future<void> _load() async {
    try {final value=await OtherStaffDirectory.load(profile);if(mounted)setState((){staff=value;error=null;});}
    catch(e){if(mounted)setState(()=>error='$e');}
  }
  Future<void> _edit([Map<String,dynamic>? existing]) async {
    final name=TextEditingController(text:existing?['name']?.toString()??''), employee=TextEditingController(text:existing?['employeeId']?.toString()??''),
      department=TextEditingController(text:existing?['designation']?.toString()??''), mobile=TextEditingController(text:existing?['mobile']?.toString()??''),
      joining=TextEditingController(text:existing?['joiningDate']?.toString()??'');
    var role=existing?['role']?.toString()??category, active=existing?['active']!=false;
    if(!OtherStaffDirectory.roles.contains(role))role=OtherStaffDirectory.roles.first;
    var photo=existing?['photoUrl']?.toString()??'', saving=false;
    String? problem;
    final changed=await showDialog<bool>(context:context,barrierDismissible:false,builder:(ctx)=>StatefulBuilder(builder:(ctx,setD)=>PopScope(canPop:!saving,child:AlertDialog(
      title:Text(existing==null?'Add Other Staff':'Edit Other Staff'),
      content:SizedBox(width:460,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:name,decoration:const InputDecoration(labelText:'Name')),
        TextField(controller:employee,decoration:const InputDecoration(labelText:'Employee ID')),
        DropdownButtonFormField<String>(initialValue:role,items:OtherStaffDirectory.roles.map((r)=>DropdownMenuItem(value:r,child:Text(r))).toList(),onChanged:saving?null:(v)=>setD(()=>role=v!),decoration:const InputDecoration(labelText:'Category')),
        TextField(controller:department,decoration:const InputDecoration(labelText:'Department / designation')),
        TextField(controller:mobile,decoration:const InputDecoration(labelText:'Mobile')),
        TextField(controller:joining,decoration:const InputDecoration(labelText:'Joining date / details')),
        SwitchListTile(value:active,onChanged:saving?null:(v)=>setD(()=>active=v),title:const Text('Active')),
        if(photo.isNotEmpty) schoolNetworkImage(photo,width:70,height:70,fit:BoxFit.cover),
        TextButton.icon(onPressed:saving?null:() async {try {final file=await ImagePicker().pickImage(source:ImageSource.gallery,maxWidth:600,imageQuality:80);if(file==null)return;final bytes=await file.readAsBytes();OtherStaffDirectory.requireSchool(profile);if(bytes.length>5*1024*1024)throw StateError('Select a photo smaller than 5 MB.');if(ctx.mounted)setD(()=>photo=WindowsSchoolImageCache.dataUrl(bytes));}catch(e){if(ctx.mounted)setD(()=>problem='$e');}},icon:const Icon(Icons.photo),label:const Text('Select photo')),
        if(problem!=null)Text(problem!,style:const TextStyle(color:Colors.orangeAccent)),
      ]))),
      actions:[TextButton(onPressed:saving?null:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:saving?null:() async {setD(()=>saving=true);try{await OtherStaffDirectory.save(profile,{...?existing,'name':name.text,'employeeId':employee.text,'role':role,'designation':department.text,'mobile':mobile.text,'joiningDate':joining.text,'active':active,'photoUrl':photo});if(ctx.mounted)Navigator.pop(ctx,true);}catch(e){if(ctx.mounted)setD((){saving=false;problem='$e';});}},child:Text(saving?'Saving…':'Save locally'))],
    ))));
    await Future<void>.delayed(const Duration(milliseconds:250));
    for(final c in [name,employee,department,mobile,joining])c.dispose();
    if(changed==true&&mounted)await _load();
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Teachers & Other Staff')),body:Column(children:[
    SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:[for(final r in ['Teachers',...OtherStaffDirectory.roles])Padding(padding:const EdgeInsets.all(6),child:ChoiceChip(label:Text(r),selected:category==r,onSelected:(_)=>setState(()=>category=r)))])),
    Expanded(child:category=='Teachers'?widget.teachers:Column(children:[
      Padding(padding:const EdgeInsets.all(12),child:Row(children:[Expanded(child:TextField(onChanged:(v)=>setState(()=>search=v.toLowerCase()),decoration:const InputDecoration(labelText:'Search staff name / Employee ID'))),const SizedBox(width:12),FilledButton.icon(onPressed:()=>_edit(),icon:const Icon(Icons.person_add),label:const Text('Add Other Staff'))])),
      if(error!=null)Text(error!),
      Expanded(child:ListView(children:[for(final person in staff.where((p)=>p['role']==category && '${p['name']} ${p['employeeId']}'.toLowerCase().contains(search)))ListTile(
        leading:(person['photoUrl']?.toString().isNotEmpty??false)?schoolNetworkImage(person['photoUrl'],width:48,height:48,fit:BoxFit.cover):const Icon(Icons.person),
        title:Text(person['name']?.toString()??''),subtitle:Text('${person['employeeId']??person['id']} • ${person['designation']??''} • ${person['active']==false?'Inactive':'Active'}'),
        trailing:IconButton(onPressed:()=>_edit(person),icon:const Icon(Icons.edit)),
      )])),
    ])),
  ]));
}
