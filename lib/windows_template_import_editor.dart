import 'dart:async';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'windows_document_templates.dart';
import 'windows_local_firestore.dart';
import 'windows_template_import_engine.dart';
import 'windows_template_office_layout.dart';
import 'windows_template_office_converter.dart';
import 'fitted_document_preview.dart';
import 'windows_template_cloud_store.dart';

/// Structured, Office-independent TemplateForge upload for the three supported tabs.
/// Approved pages are hash-verified in the school's Drive and listed as selectable versions.
class SchoolTemplateImportEditor {
  /// Structured import, strict record preflight, explicit approval, verified Drive
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
      const types=XTypeGroup(label:'Word or Excel template',extensions:['docx','xlsx']);
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
      if(!SchoolTemplateOfficeConverter.supportsNative(file.name))
        throw const FormatException('Only Word DOCX and Excel XLSX templates are supported.');
      if(await file.length()>SchoolTemplateOfficeConverter.maxSourceBytes)
        throw const FormatException('Office template exceeds 16 MB.');
      stage('Reading and validating Word / Excel layout…');
      final approved=await SchoolTemplateOfficeLayout.importSource(
        kind:kind,schoolId:school,filename:file.name,bytes:Uint8List.fromList(await file.readAsBytes()));
      if(!sameSchool())throw StateError('School changed during import.');
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
      SchoolTemplateImportEngine.validatePreviewRecord(approved,record);
      stage('Loading verified school images and preparing preview…');
      final imageAssets=await WindowsTemplateCloudStore.previewVisualAssets(
        approved,record);
      if(!sameSchool())throw StateError('School changed during image preview.');
      // Render the complete source+live-record preview before any Drive write.
      final output=await SchoolTemplateImportEngine.previewPdf(
        approved,record,visualAssets:imageAssets);
      if(!sameSchool())throw StateError('School changed before publication.');
      closeProgress();
      if(!context.mounted)return;
      final confirmed=await showDialog<bool>(context:context,barrierDismissible:false,
        builder:(ctx)=>Dialog(child:SizedBox(width:900,height:680,child:Column(children:[
          const ListTile(title:Text('Review generated template'),subtitle:Text('Check the design and data fields. Confirm that no old student or staff data remains.')),
          Expanded(child:FittedDocumentPreview(bytes:output)),
          Padding(padding:const EdgeInsets.all(12),child:Row(mainAxisAlignment:MainAxisAlignment.end,children:[
            TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
            const SizedBox(width:12),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Approve and save')),
          ])),
        ]))));
      if(confirmed!=true || !context.mounted)return;
      if(!sameSchool())throw StateError('School changed before approval.');
      // Keep one immutable, verified local draft even if the school Drive
      // becomes unavailable after recognition; repeat uploads are idempotent.
      await SchoolTemplateImportEngine.markPublicationPending(approved,
        currentSchoolId:()=>db.activeProfileIdentity['schoolSyncId']
          ?.toString()??'');
      if(!sameSchool())throw StateError('School changed before publication.');
      // Publish verifies the Drive image hash and reads back the manifest.
      // Reuse the already validated PDF instead of downloading all assets
      // and rendering the identical preview a second time.
      stage('Saving to school Drive and verifying upload…');
      progressRoute=DialogRoute<void>(context:context,barrierDismissible:false,
        builder:(_)=>const PopScope(canPop:false,child:AlertDialog(
          title:Text('Saving verified template'),content:Column(mainAxisSize:MainAxisSize.min,
            children:[LinearProgressIndicator(),SizedBox(height:12),Text('Local draft saved. Verifying school Drive publication…')]))));
      unawaited(progressNavigator!.push(progressRoute!));
      await WindowsTemplateCloudStore.publishApprovedLocalDraft(approved);
      if(!sameSchool()||!context.mounted)return;
      closeProgress();
      await WindowsDocumentTemplates.preview(context,output,
        title:kind.title+' • '+approved.pageDrafts.length.toString()+' source page(s) • School template preview',
        notice:'Use matching A4 or Legal paper at Actual Size (100%) when printing. Drive image read-back and content hash verified. This template is saved to this PC’s school catalog; other PCs receive its manifest through school sync. Select “Use for school” after preview to apply it to future prints.');
    } catch(error) {
      closeProgress();
      if(context.mounted) {
        await showDialog<void>(context:context,builder:(dialogContext)=>AlertDialog(
          title:const Text('Template import did not finish'),
          content:SingleChildScrollView(child:SelectableText(
            'Stage: '+progress.value+'\n\n'+error.toString()+
            '\n\nNo successful publication was confirmed. Approved local drafts may be retried. Existing selected templates remain available.')),
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
            child:Text(d.filename+' • '+SchoolTemplateImportEngine.pageSizeLabel(
              d.width,d.height)+' • '+d.fields.length.toString()+
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
      final record={...schoolProfile,...example,'schoolName':schoolProfile['schoolName']??schoolProfile['name']??example['schoolName']??''};
      final images=await WindowsTemplateCloudStore.previewVisualAssets(
        draft,record);
      final pdf=await SchoolTemplateImportEngine.previewPdf(
        draft,record,visualAssets:images);
      if(db.activeProfileId!=profile ||
        db.activeProfileIdentity['schoolSyncId']!=school){
        throw StateError('School changed before draft preview.');
      }
      if(!context.mounted)return;
      await WindowsDocumentTemplates.preview(context,pdf,
        title:kind.title+' • '+SchoolTemplateImportEngine.pageSizeLabel(
          draft.width,draft.height)+' • Saved auto draft',
        notice:'A local draft, not an approved/published school template. '
          'Original school document selections remain in effect.');
      if(!context.mounted||db.activeProfileId!=profile||db.activeProfileIdentity['schoolSyncId']!=school)return;
      if(!SchoolTemplateOfficeConverter.supportsNative(draft.filename))return;
      final retry=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Publish approved local draft?'),
        content:const Text('Confirm this is the correct blank school template. Existing selected layouts are retained.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Retry publication'))]));
      if(retry!=true||!context.mounted)return;
      if(db.activeProfileId!=profile||db.activeProfileIdentity['schoolSyncId']!=school)throw StateError('School changed.');
      await SchoolTemplateImportEngine.markPublicationPending(draft,
        currentSchoolId:()=>db.activeProfileId==profile?db.activeProfileIdentity['schoolSyncId']?.toString()??'':'');
      await WindowsTemplateCloudStore.publishApprovedLocalDraft(draft);
      if(context.mounted&&db.activeProfileId==profile&&db.activeProfileIdentity['schoolSyncId']==school)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Template publication verified. Choose Use for school to select it.')));
    }catch(e){
      if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text('Draft preview unavailable: '+e.toString())));
    }
  }

}
