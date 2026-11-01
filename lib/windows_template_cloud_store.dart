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
  static const _maxVersions=3;

  static Future<Map<String,dynamic>> _settings() async =>
    (await FirebaseFirestore.instance.collection('school_settings')
      .doc('document_templates').get()).data()??{};

  static String _idFor(SchoolTemplateDraft draft,String contentHash) {
    final fields=jsonEncode(draft.fields.map((f)=>f.toJson()).toList());
    return sha256.convert(utf8.encode(
      '${draft.sourceHash}:$contentHash:$fields:$_engineVersion')).toString();
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
    if(existing!=null && existing['contentHash']==contentHash &&
      existing['fileUrl'] is String){
      final bytes=await schoolImageBytes(existing['fileUrl'].toString());
      ensureSchool();
      if(bytes!=null && sha256.convert(bytes).toString()==contentHash){
        return existing;
      }
    }

    Map<String,dynamic>? reusable;
    for(final item in importedTemplates(settings,draft.kind.name)){
      if(item['sourceHash']==draft.sourceHash && item['contentHash']==contentHash &&
        item['fileUrl'] is String){
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
      'engine':_engineVersion,
    };
    ensureSchool();
    final allAssets=settings['templateAssets'] is Map
      ?Map<String,dynamic>.from(settings['templateAssets'] as Map)
      :<String,dynamic>{};
    final rawVersions=allAssets[draft.kind.name];
    final versions=<String,dynamic>{};
    if(rawVersions is Map){
      if(rawVersions['version']==1 && rawVersions['sourceHash'] is String){
        final old=Map<String,dynamic>.from(rawVersions);
        final oldId=old['templateId']?.toString()??old['sourceHash'].toString();
        versions[oldId]=old;
      }else{
        for(final entry in rawVersions.entries){
          if(entry.value is Map){
            versions[entry.key.toString()]=Map<String,dynamic>.from(entry.value as Map);
          }
        }
      }
    }
    versions[templateId]=manifest;
    final selected=(settings[draft.kind.name]?.toString()??'');
    final selectedId=selected.startsWith('imported:')?selected.substring(9):'';
    while(versions.length>_maxVersions){
      final removable=versions.keys.firstWhere(
        (key)=>key!=selectedId && key!=templateId,
        orElse:()=>templateId,
      );
      if(removable==templateId)break;
      versions.remove(removable);
    }
    allAssets[draft.kind.name]=versions;
    final latest=settings['templateAssetLatest'] is Map
      ?Map<String,dynamic>.from(settings['templateAssetLatest'] as Map)
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
    return verified;
  }

  static Future<Uint8List> render(
    String kind,Map<String,dynamic> manifest,Map<String,dynamic> record,
  ) async {
    final parsed=SchoolTemplateKind.values.where((v)=>v.name==kind).toList();
    if(parsed.length!=1)throw StateError('Unsupported imported template type.');
    final db=FirebaseFirestore.instance;
    final school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
    SchoolTemplateImportEngine.verifySchool(school);
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
    final output=await SchoolTemplateImportEngine.previewPdf(draft,record);
    if(db.activeProfileId!=origin ||
      db.activeProfileIdentity['schoolSyncId']!=school){
      throw StateError('School changed while rendering the imported template.');
    }
    return output;
  }
}
