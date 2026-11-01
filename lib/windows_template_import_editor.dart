import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'windows_document_templates.dart';
import 'windows_local_firestore.dart';
import 'windows_template_import_engine.dart';
import 'windows_template_forge_ocr.dart';
import 'windows_template_forge_auto.dart';
import 'windows_template_forge_visual_slots.dart';
import 'windows_template_cloud_store.dart';

/// Zero-edit TemplateForge upload and preview for the three supported tabs.
/// Approved pages are hash-verified in the school's Drive and listed as selectable versions.
class SchoolTemplateImportEditor {
  /// One-click conversion: offline OCR, strict record preflight, verified Drive
  /// publication and a real print preview. The school explicitly selects the version.
  static Future<void> pickAutomatic(
    BuildContext context,SchoolTemplateKind kind,Map<String,dynamic> example,
  ) async {
    final db=FirebaseFirestore.instance;
    final origin=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
    bool sameSchool()=>db.activeProfileId==origin &&
      db.activeProfileIdentity['schoolSyncId']==school;
    try {
      SchoolTemplateImportEngine.verifySchool(school);
      const types=XTypeGroup(label:'A4 image or PDF',
        extensions:['pdf','png','jpg','jpeg']);
      final file=await openFile(acceptedTypeGroups:[types]);
      if(file==null||!context.mounted)return;
      if(!sameSchool())throw StateError('School changed.');
      final raw=await file.readAsBytes();
      final draft=await SchoolTemplateImportEngine.importBytes(
        kind:kind,schoolId:school,filename:file.name,
        bytes:Uint8List.fromList(raw));
      if(!sameSchool())throw StateError('School changed while uploading.');
      final oriented=await TemplateForgeOfflineOcr.normalizeOrientation(draft);
      if(!sameSchool())throw StateError('School changed during orientation detection.');
      final tsv=await TemplateForgeOfflineOcr.recognize(oriented);
      if(!sameSchool())throw StateError('School changed during recognition.');
      final textRecognition=TemplateForgeAutoMapper.detect(oriented,tsv);
      final labels=TemplateForgeVisualSlots.labelCounts(
        tsv,oriented.width,oriented.height);
      final slots=labels.isEmpty?const <ForgeVisualSlot>[]:
        TemplateForgeVisualSlots.detect(oriented,tsv);
      final allVerified=labels.isNotEmpty &&
        labels.values.every((count)=>count==1) &&
        slots.length==labels.length;
      final warnings=[...textRecognition.warnings];
      if(allVerified){
        warnings.remove('Image/QR/signature slot needs verified automatic replacement.');
      }
      final result=ForgeRecognition(
        textRecognition.draft.copyWith(
          visualSlots:allVerified?slots:const <ForgeVisualSlot>[]),
        textRecognition.detected,textRecognition.missing,warnings);
      if(!context.mounted)return;
      if(!result.safeToActivate){
        final missing=result.missing.isEmpty?'none':result.missing.join(', ');
        final warnings=result.warnings.isEmpty?'none':result.warnings.join('; ');
        throw StateError('This scan is not safe to publish. Missing fields: '
          +missing+'. Recognition warnings: '+warnings+
          '. Use a clearer A4 source; existing school templates remain unchanged.');
      }
      final profile=(await db.collection('school_config')
        .doc('school_profile_cache').get()).data()??{};
      if(!sameSchool())throw StateError('School changed before preview.');
      final schoolName=[profile['schoolName'],profile['name'],example['schoolName']]
        .map((v)=>v?.toString().trim()??'')
        .firstWhere((v)=>v.isNotEmpty,orElse:()=> '');
      final record={
        ...profile,...example,
        'schoolName':schoolName,
        'schoolAddress':profile['address']??example['schoolAddress']??'',
        'schoolEmail':profile['schoolEmail']??profile['email']??example['schoolEmail']??'',
      };
      SchoolTemplateImportEngine.validatePreviewRecord(result.draft,record);
      final imageAssets=await WindowsTemplateCloudStore.previewVisualAssets(
        result.draft,record);
      if(!sameSchool())throw StateError('School changed during image preview.');
      // Render the complete source+live-record preview before any Drive write.
      await SchoolTemplateImportEngine.previewPdf(
        result.draft,record,visualAssets:imageAssets);
      if(!sameSchool())throw StateError('School changed before publication.');
      final manifest=await WindowsDocumentTemplates.publishImportedTemplate(result.draft);
      if(!sameSchool()||!context.mounted)return;
      final output=await WindowsDocumentTemplates.renderImportedTemplate(
        kind.name,manifest,record);
      if(!sameSchool()||!context.mounted)return;
      await WindowsDocumentTemplates.preview(context,output,
        title:kind.title+' • School template preview',
        notice:'Drive image read-back and content hash verified. This template is saved to this PC’s school catalog; other PCs receive its manifest through school sync. Select “Use for school” after preview to apply it to future prints.');
    } catch(error) {
      if(context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration:const Duration(seconds:9),
            content:Text('TemplateForge: '+error.toString())));
      }
    }
  }

  /// One-click preview of a previously generated draft. No drag editor.
  static Future<void> previewSavedAutomatic(
    BuildContext context,SchoolTemplateKind kind,Map<String,dynamic> example,
  ) async {
    final db=FirebaseFirestore.instance;
    final profile=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
    try {
      final drafts=await SchoolTemplateImportEngine.loadLocalDrafts(
        kind:kind,schoolId:school);
      if(!context.mounted||db.activeProfileId!=profile||
        db.activeProfileIdentity['schoolSyncId']!=school) {
        throw StateError('School changed.');
      }
      if(drafts.isEmpty){
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:Text('No automatically generated local drafts yet.')));
        return;
      }
      final draft=await showDialog<SchoolTemplateDraft>(
        context:context,
        builder:(ctx)=>SimpleDialog(
          title:Text(kind.title+' • Auto generated drafts'),
          children:drafts.map((d)=>SimpleDialogOption(
            child:Text(d.filename+' • '+d.fields.length.toString()+
              ' auto-detected fields'),
            onPressed:()=>Navigator.pop(ctx,d),
          )).toList(),
        ));
      if(draft==null||!context.mounted)return;
      if(db.activeProfileId!=profile||
         db.activeProfileIdentity['schoolSyncId']!=school) {
        throw StateError('School changed.');
      }
      final pdf=await SchoolTemplateImportEngine.previewPdf(draft,example);
      if(context.mounted)await WindowsDocumentTemplates.preview(context,pdf,
        title:kind.title+' • Saved auto draft',
        notice:'A local draft, not an approved/published school template. '
          'Original school document selections remain in effect.');
    }catch(e){
      if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text('Draft preview unavailable: '+e.toString())));
    }
  }

}
