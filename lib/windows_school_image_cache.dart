import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:image/image.dart' as image;
import 'windows_local_firestore.dart';
import 'windows_binary_downloads.dart';
import 'windows_local_storage.dart';

/// Private Drive media is cached only inside its immutable school database.
class WindowsSchoolImageCache {
  static String dataUrl(List<int> bytes) {
    final png=bytes.length>=4&&bytes[0]==137&&bytes[1]==80&&bytes[2]==78&&bytes[3]==71;
    final webp=bytes.length>=12&&String.fromCharCodes(bytes.sublist(0,4))=='RIFF'&&String.fromCharCodes(bytes.sublist(8,12))=='WEBP';
    final mime=png?'image/png':webp?'image/webp':'image/jpeg';
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }
  static Future<void> store(String school, String fileId, String dataUrl, {String? profileId}) async {
    final db=FirebaseFirestore.instance;
    final origin=profileId??db.activeProfileId;
    void verify() {
      if(db.activeProfileId!=origin||db.activeProfileIdentity['schoolSyncId']!=school) throw StateError('School changed while caching image.');
    }
    verify();
    if(!dataUrl.startsWith('data:image/')) throw StateError('Invalid school image.');
    final ref=db.collection('_windows_school_image_cache').doc(base64UrlEncode(utf8.encode(fileId)).replaceAll('=',''));
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>ref.set({'schoolId':school,'fileId':fileId,'dataUrl':dataUrl}));
    verify();
  }
  static Future<Uint8List?> read(String school, String fileId) async {
    final db=FirebaseFirestore.instance,origin=FirebaseFirestore.instance.activeProfileId;
    if(db.activeProfileIdentity['schoolSyncId']!=school)return null;
    final ref=db.collection('_windows_school_image_cache').doc(base64UrlEncode(utf8.encode(fileId)).replaceAll('=',''));
    final cached=(await ref.get()).data();
    if(db.activeProfileId!=origin||db.activeProfileIdentity['schoolSyncId']!=school)return null;
    final raw=cached?['dataUrl'];
    if(cached?['schoolId']==school && cached?['fileId']==fileId && raw is String && raw.startsWith('data:image/')) {
      try {
        final bytes=UriData.parse(raw).contentAsBytes();
        if(image.decodeImage(bytes)!=null)return bytes;
      } catch (_) {/* A damaged original cache must not prevent verified repair. */}
    }
    final downloads=WindowsBinaryDownloads(schoolId:school,
      storageDirectory:Directory('${(await WindowsLocalStorage.localFilesDirectory()).path}/Verified_Cloud_Cache'),
      currentSchool:()=>db.activeProfileId==origin?db.activeProfileIdentity['schoolSyncId']?.toString()??'':'',
      request:(_)async=>throw StateError('Offline cache read does not start a cloud request.'));
    try {
      final path=await downloads.verifiedPath(fileId);
      if(path==null)return null;
      final bytes=await File(path).readAsBytes();
      if(db.activeProfileId!=origin || db.activeProfileIdentity['schoolSyncId']!=school || image.decodeImage(bytes)==null)return null;
      return bytes;
    } catch (_) {return null;}
  }
}
