import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'windows_connect/central_school_cloud.dart';
import 'windows_local_firestore.dart';
import 'windows_school_image_cache.dart';

bool googleProfileImageUrl(String source) {
  final uri=Uri.tryParse(source);
  return uri!=null && uri.scheme=='https' && uri.userInfo.isEmpty &&
      (uri.host=='googleusercontent.com'||uri.host.endsWith('.googleusercontent.com'));
}
class WindowsAdminAvatar extends StatefulWidget {
  const WindowsAdminAvatar({super.key,required this.initial});
  final String initial;
  @override State<WindowsAdminAvatar> createState()=>_WindowsAdminAvatarState();
}
class _WindowsAdminAvatarState extends State<WindowsAdminAvatar> {
  Uint8List? bytes;
  @override void initState(){super.initState();_load();}
  Future<void> _load() async {
    final profile=FirebaseFirestore.instance.activeProfileId;
    final saved=await CentralSchoolCloud.saved();
    final school=saved['schoolId']?.toString()??'',uid=saved['uid']?.toString()??'';
    final source=saved['photoUrl']?.toString()??'';
    if(uid.isEmpty||!googleProfileImageUrl(source))return;
    final key='admin-profile-$uid';
    bool own()=>FirebaseFirestore.instance.activeProfileId==profile && FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']==school;
    try {
      final cached=await WindowsSchoolImageCache.read(school,key);
      if(!own())return;
      if(cached!=null){if(mounted)setState(()=>bytes=cached);return;}
      final response=await http.get(Uri.parse(source)).timeout(const Duration(seconds:5));
      if(!own() || (await CentralSchoolCloud.saved())['uid']!=uid)return;
      if(response.statusCode!=200 || response.bodyBytes.length>2*1024*1024 || !(response.headers['content-type']??'').startsWith('image/'))return;
      await WindowsSchoolImageCache.store(school,key,WindowsSchoolImageCache.dataUrl(response.bodyBytes),profileId:profile);
      if(mounted&&own())setState(()=>bytes=response.bodyBytes);
    }catch(_){/* Keep the letter fallback when Google supplies no usable image. */}
  }
  @override Widget build(BuildContext context)=>bytes==null?Text(widget.initial,style:const TextStyle(color:Colors.white,fontSize:25,fontWeight:FontWeight.w800)):
    ClipOval(child:Image.memory(bytes!,width:64,height:64,fit:BoxFit.cover,errorBuilder:(_,__,___)=>Text(widget.initial)));
}
