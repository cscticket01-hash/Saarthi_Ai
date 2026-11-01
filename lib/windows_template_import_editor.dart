import 'dart:async';
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
    final progress=ValueNotifier<String>('Reading selected file…');
    DialogRoute<void>? progressRoute;
    NavigatorState? progressNavigator;
    void closeProgress(){
      final route=progressRoute;
      progressRoute=null;
      if(route!=null && route.isActive)progressNavigator?.removeRoute(route);
    }
    void stage(String message){progress.value=message;}
    try {
      SchoolTemplateImportEngine.verifySchool(school);
      const types=XTypeGroup(label:'A4 PDF, image, Word or Excel',
        extensions:['pdf','png','jpg','jpeg','doc','docx','xls','xlsx']);
      final file=await openFile(acceptedTypeGroups:[types]);
      if(file==null||!context.mounted)return;
      if(!sameSchool())throw StateError('School changed.');
      progressNavigator=Navigator.of(context,rootNavigator:true);
      progressRoute=DialogRoute<void>(context:context,barrierDismissible:false,
        builder:(_)=>PopScope(canPop:false,child:AlertDialog(
          title:const Text('Preparing school template'),
          content:ValueListenableBuilder<String>(valueListenable:progress,
            builder:(_,message,__)=>Column(mainAxisSize:MainAxisSize.min,
              crossAxisAlignment:CrossAxisAlignment.start,children:[
                const LinearProgressIndicator(),const SizedBox(height:16),
                Text(message),const SizedBox(height:10),
                const Text('Please wait. The template is saved only after verification.'),
              ])),
        )));
      unawaited(progressNavigator!.push(progressRoute!));
      // Paint feedback before starting raster analysis on the UI isolate.
      await WidgetsBinding.instance.endOfFrame;
      final raw=await file.readAsBytes();
      stage('Converting document to a printable page… Word/Excel requires installed Microsoft Office or LibreOffice.');
      final draft=await SchoolTemplateImportEngine.importBytes(
        kind:kind,schoolId:school,filename:file.name,
        bytes:Uint8List.fromList(raw));
      if(!sameSchool())throw StateError('School changed while uploading.');
      stage('Checking page orientation…');
      final oriented=await TemplateForgeOfflineOcr.normalizeOrientation(draft);
      if(!sameSchool())throw StateError('School changed during orientation detection.');
      stage('Recognizing text and template fields…');
      var tsv=await TemplateForgeOfflineOcr.recognize(oriented);
      if(!sameSchool())throw StateError('School changed during recognition.');
      var textRecognition=TemplateForgeAutoMapper.detect(oriented,tsv);
      // Retry faint, low-contrast OCR once, on a TEMPORARY enhanced raster.
      // A source warning for an old photo, duplicated field, wrong document
      // kind or unsafe overlapping boxes must never be erased by this retry.
      final unsafe=textRecognition.warnings.any((w)=>
        w.contains('Image/QR/signature') ||
        w.contains('ambiguous') || w.contains('Overlapping') ||
        w.contains('appears to be'));
      if(!textRecognition.safeToActivate && !unsafe){
        stage('Checking faint text with enhanced recognition…');
        final enhanced=await TemplateForgeOfflineOcr.recognize(
          oriented,enhanced:true);
        if(!sameSchool())throw StateError('School changed during OCR retry.');
        final second=TemplateForgeAutoMapper.detect(oriented,enhanced);
        final consistent=textRecognition.draft.fields.every((first){
          final matches=second.draft.fields.where((f)=>f.key==first.key);
          return matches.length==1 &&
            (matches.single.x-first.x).abs()<=.028 &&
            (matches.single.y-first.y).abs()<=.028;
        });
        if(consistent && second.missing.length<textRecognition.missing.length &&
            second.warnings.where((w)=>w.contains('ambiguous') ||
              w.contains('Overlapping')||w.contains('Image/QR/signature'))
              .isEmpty){
          tsv=enhanced;
          textRecognition=second;
        }
      }
      stage('Checking photo, signature and QR positions…');
      await Future<void>.delayed(Duration.zero);
      final labels=TemplateForgeVisualSlots.labelCounts(
        tsv,oriented.width,oriented.height);
      final slots=labels.isEmpty?const <ForgeVisualSlot>[]:
        TemplateForgeVisualSlots.detect(oriented,tsv);
      final allVerified=labels.isNotEmpty &&
        labels.values.every((count)=>count==1) &&
        slots.length==labels.length;
      final warnings=[...textRecognition.warnings];
      if(TemplateForgeVisualSlots.hasUnverifiedColorPhoto(
        oriented,allVerified?slots:const <ForgeVisualSlot>[])){
        warnings.add('Unlabelled colour image may contain an old student '
          'photo. Upload a blank form or a source with a verifiable photo slot.');
      }
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
      stage('Loading verified school images and preparing preview…');
      final imageAssets=await WindowsTemplateCloudStore.previewVisualAssets(
        result.draft,record);
      if(!sameSchool())throw StateError('School changed during image preview.');
      // Render the complete source+live-record preview before any Drive write.
      final output=await SchoolTemplateImportEngine.previewPdf(
        result.draft,record,visualAssets:imageAssets);
      if(!sameSchool())throw StateError('School changed before publication.');
      // Keep one immutable, verified local draft even if the school Drive
      // becomes unavailable after recognition; repeat uploads are idempotent.
      await SchoolTemplateImportEngine.saveLocalDraft(result.draft,
        currentSchoolId:()=>db.activeProfileIdentity['schoolSyncId']
          ?.toString()??'');
      if(!sameSchool())throw StateError('School changed before publication.');
      // Publish verifies the Drive image hash and reads back the manifest.
      // Reuse the already validated PDF instead of downloading all assets
      // and rendering the identical preview a second time.
      stage('Saving to school Drive and verifying upload…');
      await WindowsDocumentTemplates.publishImportedTemplate(result.draft);
      if(!sameSchool()||!context.mounted)return;
      closeProgress();
      await WindowsDocumentTemplates.preview(context,output,
        title:kind.title+' • School template preview',
        notice:'Drive image read-back and content hash verified. This template is saved to this PC’s school catalog; other PCs receive its manifest through school sync. Select “Use for school” after preview to apply it to future prints.');
    } catch(error) {
      closeProgress();
      if(context.mounted) {
        await showDialog<void>(context:context,builder:(dialogContext)=>AlertDialog(
          title:const Text('Template import did not finish'),
          content:SingleChildScrollView(child:SelectableText(
            'Stage: '+progress.value+'\n\n'+error.toString()+
            '\n\nNo successful upload was confirmed. Existing templates remain available.')),
          actions:[TextButton(onPressed:()=>Navigator.of(dialogContext).pop(),
            child:const Text('Close'))],
        ));
      }
    } finally {
      closeProgress();
      progress.dispose();
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
      final schoolProfile=(await db.collection('school_config')
        .doc('school_profile_cache').get()).data()??{};
      if(db.activeProfileId!=profile ||
        db.activeProfileIdentity['schoolSyncId']!=school){
        throw StateError('School changed during draft preview.');
      }
      final record={...schoolProfile,...example};
      final images=await WindowsTemplateCloudStore.previewVisualAssets(
        draft,record);
      final pdf=await SchoolTemplateImportEngine.previewPdf(
        draft,record,visualAssets:images);
      if(db.activeProfileId!=profile ||
        db.activeProfileIdentity['schoolSyncId']!=school){
        throw StateError('School changed before draft preview.');
      }
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
