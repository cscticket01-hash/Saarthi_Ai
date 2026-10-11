import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:printing/printing.dart';
import 'id_card_local_cipher.dart';
import 'id_card_manifest.dart';
import 'id_card_engine.dart';
import 'id_card_bulk_screen.dart';
import 'id_card_bulk_job_store.dart';
import 'id_card_school_source.dart';
import 'windows_connect/school_drive_images.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'id_card_catalog.dart';
import 'id_card_designer.dart';
import 'id_card_designer_screen.dart';
import 'id_card_draft_storage_io.dart';
import 'windows_local_firestore.dart';

/// The actual Windows document-template route into the local-first ID
/// designer. This deliberately saves DRAFTS only; it does not silently change
/// school-wide print layouts, issue QR credentials or sync school data.
class WindowsIdCardDesignerEntry {
  static const enabled = bool.fromEnvironment('SAARTHI_ID_ENGINE_2_ENABLED', defaultValue: false);
  static Future<bool> confirm(BuildContext context, String title, String message) async =>
    await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:Text(title),content:Text(message),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Confirm'))])) ?? false;
  static Future<void> pdfPreview(BuildContext context, Uint8List bytes) async {
    if(!context.mounted)return;
    await Navigator.of(context).push<void>(MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Review exact front/back PDF')),body:PdfPreview(build:(_)=>bytes,canChangePageFormat:false,canChangeOrientation:false))));
  }
  static Future<IdCardDraftStorageIo> storage(String templateId, String school) async {
    if(!RegExp(r'^[a-z][a-z0-9-]{1,80}$').hasMatch(templateId))throw const FormatException('Invalid template identity');
    final root=await getApplicationSupportDirectory();
    return IdCardDraftStorageIo(rootPath:'${root.path}${Platform.pathSeparator}id_card_drafts${Platform.pathSeparator}$templateId',schoolId:school);
  }
  static Future<IdCardManifest> reviewed(String selection, String school) async {
    if(!enabled)throw StateError('Reviewed ID rollout is disabled');
    final parts=selection.split(':');
    if(parts.length!=3||parts.first!='reviewed')throw const FormatException('Invalid reviewed template selection');
    final draft=await (await storage(parts[1],school)).loadAppliedTemplate();
    if(draft==null||IdCardDraftStorageIo.manifestHash(draft)!=parts[2])throw StateError('Reviewed template revision unavailable; explicit review required');
    return IdCardManifest.fromJson(Map<String,dynamic>.from(draft['manifest'] as Map));
  }
  static Future<void> openBulk(BuildContext context, {required IdCardCatalogEntry entry, String? selection}) async {
    if(!enabled)throw StateError('Class bulk rollout is disabled');
    final source=await IdCardSchoolSource.capture();
    final template=selection?.startsWith('reviewed:')==true?await reviewed(selection!,source.schoolId):await entry.manifest();
    final root=await getApplicationSupportDirectory();
    final backgrounds=await entry.backgrounds();source.ensureActive();
    if(!context.mounted)return;
    await Navigator.of(context).push<void>(MaterialPageRoute(builder:(_)=>IdCardBulkScreen(source:source,template:template,backgrounds:backgrounds,store:IdCardBulkJobStore(rootPath:'${root.path}${Platform.pathSeparator}id_card_bulk_jobs${Platform.pathSeparator}${sha256.convert(utf8.encode(source.schoolId))}',schoolId:source.schoolId))));
  }

  static Future<void> open(
    BuildContext context, {
    required IdCardCatalogEntry entry,
  }) async {
    final db = FirebaseFirestore.instance;
    final originalProfile = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId']?.toString().trim();
    if (originalProfile.isEmpty || originalProfile == 'unbound') {
      throw StateError('Select a local school before editing ID cards.');
    }
    final schoolScope = school == null || school.isEmpty
        ? 'local:$originalProfile'
        : school;

    void checkSchool() {
      if (db.activeProfileId != originalProfile ||
          (db.activeProfileIdentity['schoolSyncId']?.toString().trim() ?? '') !=
              (school ?? '')) {
        throw StateError('School changed. Reopen the ID card designer.');
      }
    }

    if (!entry.kinds.contains('studentId')) {
      throw StateError('This designer route requires a student ID template.');
    }

    // Paths come from a validated bundled catalog ID, never user input.
    final root = await getApplicationSupportDirectory();
    checkSchool();
    final safeTemplate = entry.id;
    if (!RegExp(r'^[a-z][a-z0-9-]{1,80}$').hasMatch(safeTemplate)) {
      throw const FormatException('Invalid ID template storage key.');
    }
    final store = IdCardDraftStorageIo(
      rootPath: '${root.path}${Platform.pathSeparator}id_card_drafts'
          '${Platform.pathSeparator}$safeTemplate',
      schoolId: schoolScope,
    );
    final asset = jsonDecode(await rootBundle.loadString(entry.manifestAsset));
    if (asset is! Map) throw const FormatException('Invalid ID template.');
    final editor = IdCardDesigner(
      schoolId: schoolScope,
      manifest: Map<String, dynamic>.from(asset),
    );
    Map<String,dynamic>? current;
    try { current=await store.loadDraft(); }
    on IdCardLegacyPlaintextException {
      if(!context.mounted||!await confirm(context,'Protect existing draft','Validate and encrypt all retained draft revisions for this school. No layout is applied.'))return;
      checkSchool();await store.migrateLegacy(confirmed:true);current=await store.loadDraft();
    }
    checkSchool();
    if (current != null) {
      final savedManifest = current['manifest'];
      if (savedManifest is! Map || savedManifest['id'] != entry.id) {
        throw StateError('Saved template identity changed. Review the local draft.');
      }
      editor.restore(current);
    }
    final profile=(await db.collection('school_config').doc('school_profile_cache').get()).data()??{};
    final people=await db.collection('students_directory').get();checkSchool();
    final first=IdCardSchoolSource.previewSample(
      people.docs.map((doc)=><String,dynamic>{...doc.data(),'_recordId':doc.id}),
      school,
    )??<String,dynamic>{};
    final data=<String,dynamic>{...profile,...first,'schoolName':profile['schoolName']??profile['name']??'','schoolAddress':profile['address']??'','class':first['studentClass']??first['class']??'','parentName':first['parentName']??first['fatherName']??''};
    final backgrounds=await entry.backgrounds();checkSchool();
    final images=<String,Uint8List>{};
    final sources={'photo':first['photoUrl']??(first['photoBase64']==null?null:first['photoBase64'].toString().startsWith('data:image/')?first['photoBase64']:'data:image/png;base64,${first['photoBase64']}'),'logo':profile['logoUrl'],'signature':profile['principalSignatureUrl'],'seal':profile['sealUrl']};
    for(final item in sources.entries){
      if(item.value==null)continue;
      final bytes=await schoolImageBytes(item.value.toString()).timeout(const Duration(seconds:8),onTimeout:()=>null);checkSchool();
      if(bytes!=null)images[item.key]=bytes;
    }
    String qr='';
    if(first.isNotEmpty && school!=null && school.isNotEmpty){
      try{final source=await IdCardSchoolSource.capture();checkSchool();final record=source.records.where((r)=>r['_recordId']==first['_recordId']).toList();if(record.isNotEmpty)qr=source.existingQr(record.first);}catch(_){checkSchool();/* Missing existing QR remains visibly absent; never mint credentials. */}
    }
    Future<void> preview(Map<String,dynamic> draft) async {
      checkSchool();final bytes=await IdCardEngine.render(IdCardManifest.fromJson(Map<String,dynamic>.from(draft['manifest'] as Map)),data,backgrounds:backgrounds,images:images,qr:qr);checkSchool();await pdfPreview(context,bytes);
    }
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => IdCardDesignerScreen(
          designer: editor,
          templateVersion: 'manifest-v1:${entry.id}',
          data:data, images:images, qr:qr,
          onPreview:preview,
          onRecover:() async {
            if(!await confirm(context,'Recover previous draft','Load the retained previous revision into the editor. Current saved revision remains unchanged until Save draft.'))return null;
            checkSchool();final previous=await store.readPreviousRevision();checkSchool();return previous;
          },
          onApply: enabled ? (draft) async {
            checkSchool();await store.saveDraft(draft);await preview(draft);
            if(!context.mounted||!await confirm(context,'Apply reviewed student layout','Apply this exact saved manifest to student IDs for this school. Teacher layouts and QR credentials remain unchanged.'))return;
            checkSchool();final hash=IdCardDraftStorageIo.manifestHash(draft);
            await store.applyReviewedDraft(draft,reviewedManifestHash:hash,confirmed:true);checkSchool();
            await db.collection('school_settings').doc('document_templates').set({'studentId':'reviewed:${entry.id}:$hash'},SetOptions(merge:true));checkSchool();
          } : null,
          onSave: (draft) async {
            checkSchool();
            await store.saveDraft(draft);
            checkSchool();
          },
        ),
      ),
    );
  }
}
