import 'dart:convert';
import 'dart:typed_data';
import 'windows_local_firestore.dart';

/// Private Drive media is cached only inside its immutable school database.
class WindowsSchoolImageCache {
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
    if(db.activeProfileId!=origin||db.activeProfileIdentity['schoolSyncId']!=school||cached?['schoolId']!=school||cached?['fileId']!=fileId)return null;
    final raw=cached?['dataUrl'];
    return raw is String&&raw.startsWith('data:image/')?UriData.parse(raw).contentAsBytes():null;
  }
}
