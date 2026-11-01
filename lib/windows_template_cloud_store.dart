import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/school_drive_images.dart';
import 'windows_local_firestore.dart';
import 'windows_template_import_engine.dart';

/// Owns only the Drive asset and small school-scoped manifest for TemplateForge.
/// Existing templates stay selected until the school explicitly chooses a new version.
class WindowsTemplateCloudStore {
  static const _engineVersion='TemplateForge-3';
  // Keep rollback history across up to five devices; do not silently remove
  // verified Drive versions during another PC's concurrent upload.
  static const maxStoredVersions=32;

  static Future<Map<String,dynamic>> _settings() async =>
    (await FirebaseFirestore.instance.collection('school_settings')
      .doc('document_templates').get()).data()??{};

  static String _idFor(SchoolTemplateDraft draft,String contentHash) {
    final fields=jsonEncode(draft.fields.map((f)=>f.toJson()).toList());
    final visuals=draft.visualSlots.isEmpty?'':':'+jsonEncode(
      draft.visualSlots.map((s)=>s.toJson()).toList());
    return sha256.convert(utf8.encode(
      '${draft.sourceHash}:$contentHash:$fields$visuals:$_engineVersion')).toString();
  }

  static List<Map<String,dynamic>> importedTemplates(
    Map<String,dynamic> settings,String kind,
  ) {
    final all=settings['templateAssets'];
    if(all is! Map)return const [];
    final raw=all[kind];
    if(raw is! Map)return const [];
    if(raw['version']==1)return [Map<String,dynamic>.from(raw)];
    final versions=raw.values.whereType<Map>()
      .map((v)=>Map<String,dynamic>.from(v)).toList();
    final latest=(settings['templateAssetLatest'] is Map)
      ?(settings['templateAssetLatest'] as Map)[kind]?.toString():null;
    if(latest!=null){
      versions.sort((a,b){
        final aid=(a['templateId']??a['sourceHash']).toString();
        final bid=(b['templateId']??b['sourceHash']).toString();
        if(aid==latest)return -1;
        if(bid==latest)return 1;
        return (a['filename']??'').toString().compareTo((b['filename']??'').toString());
      });
    }
    return versions;
  }

  /// Keep the visible/selected/printed catalog identical and school-scoped.
  static List<Map<String,dynamic>> availableSchoolTemplates(
    Map<String,dynamic> settings,String kind,String schoolId,
  ) {
    if(!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(schoolId))return const [];
    return importedTemplates(settings,kind).where((item)=>
      item['approved']==true &&
      item['schoolId']==schoolId &&
      item['kind']==kind &&
      (item['templateId']??item['sourceHash']) is String
    ).toList(growable:false);
  }

  static Map<String,dynamic>? importedAsset(
    Map<String,dynamic> settings,String kind,{String? templateId}
  ) {
    final versions=importedTemplates(settings,kind);
    if(versions.isEmpty)return null;
    if(templateId!=null){
      for(final item in versions){
        if(item['templateId']==templateId ||
          (item['templateId']==null && item['sourceHash']==templateId)){
          return item;
        }
      }
      return null;
    }
    final selected=settings[kind]?.toString()??'';
    if(selected.startsWith('imported:')){
      return importedAsset(settings,kind,templateId:selected.substring(9));
    }
    return versions.first;
  }

  /// Pure, non-destructive manifest merge used by the real publisher and
  /// by 1/2/5-device regression tests. An existing version is immutable.
  /// Reaching the bounded catalog limit refuses a new upload: it never
  /// silently evicts the active template or the rollback target.
  static Map<String,dynamic> appendedVersionHistory(
    dynamic rawVersions,String templateId,Map<String,dynamic> manifest,
  ){
    final versions=<String,dynamic>{};
    if(rawVersions is Map){
      if(rawVersions['version']==1 && rawVersions['sourceHash'] is String){
        final old=Map<String,dynamic>.from(rawVersions);
        final id=old['templateId']?.toString()??
          old['sourceHash'].toString();
        versions[id]=old;
      }else{
        for(final entry in rawVersions.entries){
          if(entry.value is Map){
            versions[entry.key.toString()]=
              Map<String,dynamic>.from(entry.value as Map);
          }
        }
      }
    }
    final prior=versions[templateId];
    if(prior is Map && (prior['sourceHash']!=manifest['sourceHash'] ||
      prior['contentHash']!=manifest['contentHash'] ||
      prior['schoolId']!=manifest['schoolId'] ||
      prior['kind']!=manifest['kind'])){
      throw StateError('Template version identity collision; existing'
        ' Drive version must not be overwritten.');
    }
    versions[templateId]=manifest;
    if(versions.length>maxStoredVersions){
      throw StateError('School template history is full.'
        ' Archive older versions safely before publishing another template.');
    }
    return versions;
  }

  /// A matching PNG hash is not sufficient to borrow another school's
  /// Drive asset. Reuse is permitted only within the verified tenant/kind
  /// and when the recorded file URL resolves to its declared Drive file.
  static bool canReuseVerifiedAsset(Map<String,dynamic> asset,{
    required String schoolId,required String kind,
    required String contentHash,
  }){
    final url=asset['fileUrl']?.toString()??'';
    final id=asset['fileId']?.toString()??'';
    return asset['schoolId']==schoolId && asset['kind']==kind &&
      asset['approved']==true && asset['contentHash']==contentHash &&
      id.isNotEmpty && schoolDriveFileId(url)==id;
  }

  /// A completed upload must not report success if the last save dropped
  /// an already observed school version. This detects a concurrent writer
  /// whose manifest overtook our read-modify-write; it is not a cloud CAS.
  static bool containsExpectedVersions(
    Map<String,dynamic> settings,String kind,Iterable<String> expected,
  ){
    return expected.every((id)=>importedAsset(
      settings,kind,templateId:id)!=null);
  }

  static Future<Map<String,dynamic>> publish(SchoolTemplateDraft draft) async {
    final db=FirebaseFirestore.instance;
    final origin=db.activeProfileId;
    final school=SchoolTemplateImportEngine.verifySchool(draft.schoolId);
    void ensureSchool(){
      if(db.activeProfileId!=origin ||
        db.activeProfileIdentity['schoolSyncId']!=school){
        throw StateError('School changed during template publication.');
      }
    }
    ensureSchool();
    SchoolTemplateImportEngine.validateDraft(draft);
    if(draft.png.length>20*1024*1024){
      throw StateError('Template image is too large for verified Drive upload.');
    }
    final contentHash=sha256.convert(draft.png).toString();
    final templateId=_idFor(draft,contentHash);
    final settings=await _settings();
    ensureSchool();
    final existing=importedAsset(settings,draft.kind.name,templateId:templateId);
    if(existing!=null && canReuseVerifiedAsset(existing,
      schoolId:school,kind:draft.kind.name,contentHash:contentHash)){
      final bytes=await schoolImageBytes(existing['fileUrl'].toString());
      ensureSchool();
      if(bytes!=null && sha256.convert(bytes).toString()==contentHash){
        return existing;
      }
    }

    Map<String,dynamic>? reusable;
    for(final item in importedTemplates(settings,draft.kind.name)){
      if(item['sourceHash']==draft.sourceHash && canReuseVerifiedAsset(item,
        schoolId:school,kind:draft.kind.name,contentHash:contentHash)){
        final bytes=await schoolImageBytes(item['fileUrl'].toString());
        ensureSchool();
        if(bytes!=null && sha256.convert(bytes).toString()==contentHash){
          reusable=item;
          break;
        }
      }
    }

    String fileId;
    String fileUrl;
    if(reusable!=null){
      fileId=reusable['fileId'].toString();
      fileUrl=reusable['fileUrl'].toString();
    }else{
      final connection=await CentralSchoolCloud.saved();
      ensureSchool();
      if(connection['schoolId']!=school ||
        (connection['endpoint']?.toString()??'').isEmpty){
        throw StateError('Connect this school to its own Drive before publishing a template.');
      }
      final uploadKey=sha256.convert(utf8.encode(
        '$school:document-template:${draft.kind.name}:$contentHash')).toString();
      final cloud=CentralSchoolCloud(
        endpoint:connection['endpoint'],expectedSchoolId:school);
      late final Map<String,dynamic> uploaded;
      try{
        uploaded=await cloud.upload(
          'school_template_${draft.kind.name}_$contentHash.png',
          'image/png',
          'data:image/png;base64,${base64Encode(draft.png)}',
          uploadKey:uploadKey,
        );
      }finally{cloud.close();}
      ensureSchool();
      fileId=uploaded['fileId']?.toString()??'';
      fileUrl=uploaded['fileUrl']?.toString()??'';
      if(!RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(fileId) ||
        schoolDriveFileId(fileUrl)!=fileId){
        throw StateError('Drive upload returned an invalid file identity.');
      }
      final readback=await schoolImageBytes(fileUrl);
      ensureSchool();
      if(readback==null || sha256.convert(readback).toString()!=contentHash){
        throw StateError('Drive template read-back hash failed. Existing template remains selected.');
      }
    }

    final manifest=<String,dynamic>{
      'version':1,'approved':true,'schoolId':school,
      'kind':draft.kind.name,'filename':draft.filename,
      'sourceHash':draft.sourceHash,'contentHash':contentHash,
      'templateId':templateId,'fileId':fileId,'fileUrl':fileUrl,
      'width':draft.width,'height':draft.height,
      'fields':draft.fields.map((f)=>f.toJson()).toList(),
      if(draft.visualSlots.isNotEmpty)
        'visualSlots':draft.visualSlots.map((s)=>s.toJson()).toList(),
      'engine':_engineVersion,
    };
    ensureSchool();
    // The Drive upload can take time. Merge from the latest local/cloud
    // settings snapshot, not the stale state loaded before upload, to avoid
    // erasing a version added by another device during that wait.
    final latestSettings=await _settings();
    ensureSchool();
    final allAssets=latestSettings['templateAssets'] is Map
      ?Map<String,dynamic>.from(latestSettings['templateAssets'] as Map)
      :<String,dynamic>{};
    final rawVersions=allAssets[draft.kind.name];
    final versions=appendedVersionHistory(
      rawVersions,templateId,manifest);
    allAssets[draft.kind.name]=versions;
    final latest=latestSettings['templateAssetLatest'] is Map
      ?Map<String,dynamic>.from(latestSettings['templateAssetLatest'] as Map)
      :<String,dynamic>{};
    latest[draft.kind.name]=templateId;
    await db.collection('school_settings').doc('document_templates').set({
      'templateAssets':allAssets,'templateAssetLatest':latest,
      'updatedAt':FieldValue.serverTimestamp(),
    },SetOptions(merge:true));
    ensureSchool();
    final savedSettings=await _settings();
    ensureSchool();
    final verified=importedAsset(savedSettings,draft.kind.name,templateId:templateId);
    if(verified==null || verified['contentHash']!=contentHash ||
      verified['fileId']!=fileId || verified['schoolId']!=school){
      throw StateError('School template manifest read-back failed.');
    }
    if(!containsExpectedVersions(
      savedSettings,draft.kind.name,versions.keys)){
      throw StateError('Concurrent template update detected;'
        ' published version history is incomplete. Recheck before selection.');
    }
    // Selecting an imported version remains an explicit separate action.
    if(savedSettings[draft.kind.name]!=latestSettings[draft.kind.name]){
      throw StateError('Selected school template changed during upload.');
    }
    return verified;
  }

  static void verifyRecordSchool(Map<String,dynamic> record,String schoolId){
    SchoolTemplateImportEngine.verifySchool(schoolId);
    final recordSchool=record['schoolId'];
    if(recordSchool!=null && recordSchool!=schoolId){
      throw StateError('A document record from another school cannot be printed.');
    }
  }

  /// Only fetch the image roles actually printed by this template.
  /// The existing private school image loader handles authenticated Drive
  /// access; never copy OCR sample images into another student's document.
  static Future<Map<String,Uint8List>> _visualAssets(
    SchoolTemplateDraft draft,Map<String,dynamic> record,
    void Function() ensureSchool,
  ) async {
    final result=<String,Uint8List>{};
    for(final slot in draft.visualSlots){
      if(slot.role=='qrCode')continue;
      final values=switch(slot.role){
        'studentPhoto'=>[record['photoUrl'],record['photoBase64']],
        'schoolLogo'=>[record['schoolLogoUrl'],record['logoUrl'],
          record['logoBase64']],
        'signature'=>[record['principalSignatureUrl'],
          record['principalSignatureBase64']],
        'seal'=>[record['sealUrl'],record['sealBase64']],
        _=>const <dynamic>[],
      };
      Uint8List? bytes;
      for(final candidate in values){
        final source=candidate?.toString().trim()??'';
        if(source.isEmpty)continue;
        try{
          if(source.startsWith('data:image/')){
            if(source.length>6*1024*1024)continue;
            bytes=Uint8List.fromList(UriData.parse(source).contentAsBytes());
          }else if(source.startsWith('https://')){
            bytes=await schoolImageBytes(source);
          }else if(!source.contains('://') && source.length<6*1024*1024 &&
              RegExp(r'^[A-Za-z0-9+/=\\s]+$').hasMatch(source)){
            bytes=Uint8List.fromList(base64Decode(source));
          }
        }catch(_){
          bytes=null;
        }
        ensureSchool();
        if(bytes!=null)break;
      }
      if(bytes!=null)result[slot.role]=bytes;
    }
    return result;
  }

  /// Preview the current school's live image assets before publishing any
  /// manifest. A broken photo/signature URL must never create a usable design.
  static Future<Map<String,Uint8List>> previewVisualAssets(
    SchoolTemplateDraft draft,Map<String,dynamic> record,
  ) async {
    final db=FirebaseFirestore.instance;
    final origin=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
    if(school!=draft.schoolId)throw StateError('School changed before image preview.');
    verifyRecordSchool(record,school);
    void ensureSchool(){
      if(db.activeProfileId!=origin ||
        db.activeProfileIdentity['schoolSyncId']!=school){
        throw StateError('School changed during image preview.');
      }
    }
    final assets=await _visualAssets(draft,record,ensureSchool);
    ensureSchool();
    SchoolTemplateImportEngine.validateVisualAssets(draft,record,assets);
    return assets;
  }

  static Future<Uint8List> render(
    String kind,Map<String,dynamic> manifest,Map<String,dynamic> record,
  ) async {
    final parsed=SchoolTemplateKind.values.where((v)=>v.name==kind).toList();
    if(parsed.length!=1)throw StateError('Unsupported imported template type.');
    final db=FirebaseFirestore.instance;
    final school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
    SchoolTemplateImportEngine.verifySchool(school);
    verifyRecordSchool(record,school);
    if(manifest['schoolId']!=school || manifest['kind']!=kind){
      throw StateError('Imported template belongs to another school.');
    }
    final url=manifest['fileUrl']?.toString()??'';
    if(schoolDriveFileId(url)!=(manifest['fileId']?.toString()??'')){
      throw StateError('Imported template Drive identity is invalid.');
    }
    final origin=db.activeProfileId;
    final bytes=await schoolImageBytes(url);
    if(bytes==null)throw StateError('School template is not available from its private Drive.');
    if(db.activeProfileId!=origin ||
      db.activeProfileIdentity['schoolSyncId']!=school){
      throw StateError('School changed during template download.');
    }
    final draft=SchoolTemplateImportEngine.fromPublishedManifest(
      kind:parsed.single,schoolId:school,manifest:manifest,png:bytes);
    void ensureSchool(){
      if(db.activeProfileId!=origin ||
        db.activeProfileIdentity['schoolSyncId']!=school){
        throw StateError('School changed during template image retrieval.');
      }
    }
    final imageAssets=await _visualAssets(draft,record,ensureSchool);
    ensureSchool();
    final output=await SchoolTemplateImportEngine.previewPdf(
      draft,record,visualAssets:imageAssets);
    if(db.activeProfileId!=origin ||
      db.activeProfileIdentity['schoolSyncId']!=school){
      throw StateError('School changed while rendering the imported template.');
    }
    return output;
  }
}
