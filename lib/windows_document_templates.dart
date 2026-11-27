import 'windows_sync_dependencies.dart';
import 'windows_id_card_inputs.dart';
import 'windows_firebase_sync.dart';
import 'windows_payslip_template.dart';
import 'windows_id_card_reviews.dart';
import 'windows_appearance.dart';
import 'dart:convert';
import 'dart:async';
import 'windows_sync_projection.dart';
import 'windows_sync_comparison.dart';

import 'package:crypto/crypto.dart';

import 'school_qr_link.dart';
import 'windows_school_identity.dart';
import 'windows_backend_bridge.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/atomic_person_portrait_delivery.dart';
import 'windows_connect/managed_school_session.dart';
import 'id_card_catalog.dart';
import 'green_blue_student_uid.dart';
import 'id_card_school_branding.dart';
import 'teacher_reference_native_preview.dart';
import 'school_media_budgets.dart';
import 'id_card_engine.dart';
import 'id_card_manifest.dart';
import 'id_card_native_preview.dart';
import 'windows_browser_print.dart';
import 'windows_report_card_preview.dart';
import 'windows_save_pdf.dart';
import 'windows_id_card_designer_entry.dart';
import 'fitted_document_preview.dart';
import 'windows_connect/school_drive_images.dart';
// Template catalog, preview and document text intentionally retain their own
// language; device UI translation must not wrap these widgets.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'windows_local_firestore.dart';
import 'windows_reference_documents.dart';
import 'windows_template_import_engine.dart';
import 'windows_template_import_editor.dart';
import 'windows_template_cloud_store.dart';
import 'windows_template_feature_access.dart';
import 'windows_template_thumbnail_queue.dart';
import 'windows_student_id_cards.dart';
import 'windows_sync_recovery.dart';

// Preserve the existing import surface for document owners and callers.
export 'windows_sync_recovery.dart' show IdCardPreparationFailure;

class WindowsDocumentTemplates {
  static const manifestName = 'School ID • Manifest Front + Back';
  static const plainSelection = 'plain';
  static bool financialKind(String kind) =>
      const {'receipt', 'reportCard', 'payslip'}.contains(kind);
  static bool personKind(String kind) =>
      const {'studentId', 'teacherId', 'otherStaffId'}.contains(kind);
  static bool supportsPlain(String kind) => financialKind(kind) || personKind(kind);
  // Presentation-only filtering: never renumber existing renderer indices,
  // modify saved school selections, or remove historical template assets.
  static List<int> visibleCatalogIndices(String kind,List<String> names)=>[
    if(kind=='otherStaffId'||kind=='payslip') -1,
    for(var i=0;i<names.length;i++)
      if(!(kind=='payslip'&&i==0)&&
         !((kind=='teacherId'||kind=='otherStaffId')&&names[i]==manifestName)) i,
  ];
  static bool plainPrintSelection(String kind, Object? value) =>
      supportsPlain(kind) && (value == null || value == plainSelection);

  /// Missing selection is not a selected decorative layout. Existing explicit
  /// numeric and imported choices remain unchanged.
  static Object? financialSelection(String kind, Object? value) {
    if (!financialKind(kind)) return value;
    if (value == null || value == plainSelection) return plainSelection;
    if (value is num && value.isFinite && value == value.toInt() && value >= 0)
      return kind == 'payslip' ? 0 : windowsReferenceDocumentIndex(kind,value);
    return value;
  }
  static String studentCardSelection(Object? selection) {
    if (selection is String &&
        (selection.startsWith('manifest:') ||
         (WindowsIdCardDesignerEntry.enabled && selection.startsWith('reviewed:')))) {
      return selection;
    }
    return 'manifest:$studentIdTemplateId';
  }

  static String _studentRevisionSelection(Object? value) {
    final selected = studentCardSelection(value);
    return selected == 'manifest:$studentIdTemplateId' ? studentIdTemplateId : selected;
  }

  static Future<Uint8List> manifestId(
    Map<String, dynamic> data, {
    String qr = '',
    String templateId = 'school-id-v1',
    IdCardManifest? reviewedManifest,
    Uint8List? photo,
    Uint8List? logo,
    Uint8List? signature,
    Uint8List? seal,
    bool printOnly=false,
  }) async {
    final entry = await IdCardCatalog.find(templateId);
    final manifest = reviewedManifest ?? await entry.manifest();
    final cardData = manifest.id == greenBlueStudentTemplateId
        ? await greenBlueStudentData(data) : data;
    return IdCardEngine.render(
      manifest,
      cardData,
      qr: qr,
      printOnly:printOnly,
      backgrounds: await entry.backgrounds(),
      images: {
        if (photo != null) 'photo': photo,
        if (logo != null) 'logo': logo,
        if (signature != null) 'signature': signature,
        if (seal != null) 'seal': seal,
      },
    );
  }

  /// A native card can be prepared entirely without the PDF or print engine.
  /// Legacy teacher layouts remain selected as before: never substitute a
  /// different school design silently. Return false for those legacy layouts.
  static Future<({IdCardManifest template, Map<String,dynamic> data,
      Map<String,Uint8List> images, Map<String,Uint8List> backgrounds})?>
      nativePersonCard(String kind, Map<String,dynamic> data, {String? selection}) async {
    if (!{'studentId','teacherId','otherStaffId'}.contains(kind)) {
      throw ArgumentError('Person card kind required.');
    }
    final db = FirebaseFirestore.instance;
    final origin = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId'];
    void checkSchool() {
      if (db.activeProfileId != origin ||
          db.activeProfileIdentity['schoolSyncId'] != school ||
          (data['schoolId'] != null && data['schoolId'] != school)) {
        throw StateError('School changed during native ID card preview.');
      }
    }
    checkSchool();
    final settings = await selections();
    final rawSelection = selection ?? settings[kind];
    final plain = plainPrintSelection(kind,rawSelection);
    // Use the already bundled undecorated manifest only for user-initiated
    // preview/print. Do not rewrite an issued ID or its sync identity.
    final v = plain ? 'manifest:school-id-v1' : kind == 'studentId'
        ? studentCardSelection(rawSelection) : rawSelection ?? 0;
    if (!(v is String && (v.startsWith('manifest:') || v.startsWith('reviewed:'))) &&
        kind != 'otherStaffId') return null;
    final profile = (await db.collection('school_config').doc('school_profile_cache').get()).data() ?? {};
    checkSchool();
    if (profile['schoolId'] != null && profile['schoolId'] != school) {
      throw StateError('Foreign school branding cannot be used.');
    }
    final schoolName = [profile['schoolName'],profile['name'],data['schoolName']]
      .map((value) => value?.toString().trim() ?? '')
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final reviewed = kind == 'studentId' && v is String && v.startsWith('reviewed:')
        ? await WindowsIdCardDesignerEntry.reviewed(v,school?.toString() ?? 'local:$origin')
        : null;
    final templateId = reviewed?.id ?? (v is String && v.startsWith('manifest:')
        ? v.substring(9) : (await IdCardCatalog.load()).firstWhere((e) => e.kinds.contains(kind)).id);
    final entry = await IdCardCatalog.find(templateId);
    if (!entry.kinds.contains(kind) && !(plain && entry.id=='school-id-v1'))
      throw StateError('Selected template is not for this person category.');
    final manifest = reviewed ?? await entry.manifest();
    final backgrounds = await entry.backgrounds();
    final cardData = manifest.id == greenBlueStudentTemplateId
        ? await greenBlueStudentData(data) : data;
    checkSchool();
    // School Data is authoritative; load only branding used by this manifest.
    String? source(String slot, String prefix) =>
        manifest.regions.any((r) => r.kind == 'image' && r.key == slot)
            ? idCardBrandingSource(profile, prefix) : null;
    final brandingSources = [
      source('logo', 'logo'),
      source('signature', 'principalSignature'),
      source('seal', 'seal'),
    ];
    final assets = await Future.wait<Uint8List?>([
      _personPhoto(data),
      for (final branding in brandingSources) _image(branding),
    ]);
    checkSchool();
    for (var i = 0; i < brandingSources.length; i++) {
      if ((brandingSources[i]?.toString().trim() ?? '').isNotEmpty &&
          (assets[i + 1] == null || assets[i + 1]!.isEmpty)) {
        throw StateError('Configured school logo, signature or seal is unavailable. Existing ID retained.');
      }
    }
    return (
      template: manifest,
      data: <String,dynamic>{...profile,...cardData,'schoolName':schoolName,
        'schoolAddress':profile['address'] ?? profile['schoolAddress'] ?? '',
        'schoolLocation':profile['address'] ?? profile['schoolAddress'] ?? '',
        'designation':data['designation'] ?? data['role'] ?? (kind == 'studentId' ? 'Student' : 'Teacher'),
        'rollNo':data['rollNo'] ?? data['roll'] ?? data['employeeId'] ?? data['teacherId'] ?? '',
        'parentName':data['parentName'] ?? data['fatherName'] ?? '',
      },
      images: <String,Uint8List>{
        if (assets[0] != null) 'photo':assets[0]!,
        if (assets[1] != null) 'logo':assets[1]!,
        if (assets[2] != null) 'signature':assets[2]!,
        if (assets[3] != null) 'seal':assets[3]!,
      },
      backgrounds: backgrounds,
    );
  }

  static Future<bool> previewNativePerson(BuildContext context, String kind,
      Map<String,dynamic> data, {String qr = '', required String filename}) async {
    final db=FirebaseFirestore.instance, origin=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId'];
    void checkSchool() {
      if (db.activeProfileId != origin || db.activeProfileIdentity['schoolSyncId'] != school) {
        throw StateError('School changed. Reopen the ID card.');
      }
    }
    final card=await nativePersonCard(kind,data);
    checkSchool();
    if (card == null) {
      if (kind == 'teacherId' && context.mounted) {
        await previewLegacyTeacher(context,data,qr:qr,filename:filename);
        return true;
      }
      return false;
    }
    if (!context.mounted) return true;
    final hasPhoto = card.images['photo']?.isNotEmpty == true;
    final compact=IdCardEngine.compactQr(qr);
    await NativeIdCardPreview.open(context, (previewContext) =>
      NativeIdCardPreview(template:card.template,data:card.data,images:card.images,
        backgrounds:card.backgrounds,qr:compact,
        actionsEnabled:hasPhoto || card.template.id == greenBlueStudentTemplateId,
        onPrintDocument:(frontOnly) async {
          checkSchool();
          final bytes = await IdCardEngine.render(card.template,card.data,
            images:card.images,backgrounds:card.backgrounds,qr:compact,frontOnly:frontOnly,printOnly:true);
          checkSchool();
          if(compact.isNotEmpty && card.template.regions.any((r)=>r.kind=='qr' &&
              (!frontOnly || r.side=='front'))) await IdCardEngine.verifyExport(bytes,compact);
          checkSchool();
          if (!previewContext.mounted) return;
          await WindowsBrowserPrint.open(previewContext,bytes,title:'ID card',
            preserveActualSize:true,isCurrent:(){try{checkSchool();return true;}catch(_){return false;}});
        },
        onDownload:() async {
          checkSchool();
          final bytes = await IdCardEngine.renderLocalDownload(card.template, card.data,
            images: card.images, backgrounds: card.backgrounds, qr: compact);
          checkSchool();
          if (compact.isNotEmpty) await IdCardEngine.verifyExport(bytes,compact);
          checkSchool();
          await WindowsSavePdf.save(bytes,filename);
        }));
    return true;
  }

  /// Legacy numeric layouts keep their existing PDF renderer, but now share
  /// the same vector layout with the native modal. No PDF before an action.
  static Future<void> previewLegacyTeacher(BuildContext context, Map<String,dynamic> data,
      {String qr='',String filename='teacher-id.pdf',int? selection,bool gallery=false}) async {
    final db=FirebaseFirestore.instance,origin=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId'];
    void checkSchool() {
      if(db.activeProfileId!=origin || db.activeProfileIdentity['schoolSyncId']!=school ||
        (data['schoolId']!=null && data['schoolId']!=school)) {
        throw StateError('School changed. Reopen teacher ID.');
      }
    }
    checkSchool();
    final selected=selection??(await selections())['teacherId'];
    checkSchool();
    if(selected is! num || selected!=selected.toInt() ||
      selected<0 || selected>=windowsReferenceDocumentNames['teacherId']!.length) {
      throw StateError('Teacher template changed. Reopen the ID card.');
    }
    final i=selected.toInt();
    final profile=(await db.collection('school_config').doc('school_profile_cache').get()).data()??{};
    checkSchool();
    if(profile['schoolId']!=null&&profile['schoolId']!=school) throw StateError('Foreign school branding');
    final sources=[idCardBrandingSource(profile,'logo'),idCardBrandingSource(profile,'principalSignature')];
    final assets=await Future.wait<Uint8List?>([
      _personPhoto(data),for(final source in sources)_image(source),
    ]);
    checkSchool();
    for(var n=0;n<sources.length;n++) {
      if(sources[n]!=null&&(assets[n+1]==null||assets[n+1]!.isEmpty)) {
        throw StateError('Configured teacher ID branding unavailable. Retry.');
      }
    }
    final effective=<String,dynamic>{...profile,...data,
      'schoolName':[profile['schoolName'],profile['name'],data['schoolName']]
        .map((v)=>v?.toString().trim()??'').firstWhere((v)=>v.isNotEmpty,orElse:()=> ''),
      'schoolAddress':profile['address']??profile['schoolAddress']??'',
      'schoolEmail':profile['schoolEmail']??profile['email']??'',
      'schoolContactNo':profile['schoolContactNo']??'',
    };
    final compact=IdCardEngine.compactQr(qr);
    final images=<String,Uint8List>{
      if(assets[0]!=null)'photo':assets[0]!,
      if(assets[1]!=null)'logo':assets[1]!,
      if(assets[2]!=null)'signature':assets[2]!,
    };
    final geometry=teacherReferencePreviewGeometry(i);
    final sides=teacherReferenceNativeSides(i,effective,images,compact);
    Future<Uint8List> render() async {
      checkSchool();
      final bytes=SchoolMediaBudgets.verifyPrintPdf(await renderWindowsReferenceDocument(
        kind:'teacherId',template:i,data:effective,qr:compact,photo:assets[0],
        logo:assets[1],signature:assets[2],printOnly:true));
      checkSchool();
      if(compact.isNotEmpty)await IdCardEngine.verifyExport(bytes,compact);
      checkSchool();
      return bytes;
    }
    if(!context.mounted)return;
    await NativeIdCardPreview.open(context,(previewContext)=>NativeIdCardPreview(
      template:geometry,data:effective,qr:compact,sideBuilder:(side)=>side=='front'?sides.front:sides.back,
      actionsEnabled:assets[0]?.isNotEmpty==true,
      onPrintDocument:gallery?null:(_) async {
        final bytes=await render();
        if(!previewContext.mounted)return;
        await WindowsBrowserPrint.open(previewContext,bytes,title:'Teacher ID card',
          preserveActualSize:true,isCurrent:(){try{checkSchool();return true;}catch(_){return false;}});
      },
      onDownload:gallery?null:() async {
        final bytes=await render();
        await WindowsSavePdf.save(bytes,filename);
      },
    ));
  }

  /// Student dashboard download action. Native record preview never calls this.
  static Future<Uint8List> downloadStudentIdPdf(Map<String,dynamic> data, {required String qr}) async {
    final db = FirebaseFirestore.instance;
    final origin = db.activeProfileId, school = db.activeProfileIdentity['schoolSyncId'];
    void guard() {
      if (db.activeProfileId != origin || db.activeProfileIdentity['schoolSyncId'] != school) {
        throw StateError('School changed; reopen the ID card.');
      }
    }
    final card = await nativePersonCard('studentId', data);
    guard();
    if (card == null || (card.template.id != greenBlueStudentTemplateId && card.images['photo']?.isNotEmpty != true)) {
      throw StateError('ID card unavailable. Verify the student photo.');
    }
    final compact = IdCardEngine.compactQr(qr);
    final bytes = await IdCardEngine.renderLocalDownload(card.template, card.data,
      images: card.images, backgrounds: card.backgrounds, qr: compact);
    guard();
    if (compact.isNotEmpty) await IdCardEngine.verifyExport(bytes, compact);
    guard();
    return bytes;
  }

  static Future<Map<String, dynamic>> selections() async =>
      (await FirebaseFirestore.instance
              .collection('school_settings')
              .doc('document_templates')
              .get())
          .data() ??
      {};

  static List<Map<String,dynamic>> importedTemplates(
    Map<String,dynamic> settings,String kind,
  ) => WindowsTemplateCloudStore.importedTemplates(settings,kind);

  static List<Map<String,dynamic>> availableImportedTemplates(
    Map<String,dynamic> settings,String kind,String schoolId,
  ) => WindowsTemplateCloudStore.availableSchoolTemplates(settings,kind,schoolId);

  static Map<String,dynamic>? importedAsset(
    Map<String,dynamic> settings,String kind,{String? templateId}
  ) => WindowsTemplateCloudStore.importedAsset(settings,kind,templateId:templateId);

  static int importedTemplateIndex(String kind) =>
    windowsReferenceDocumentNames[kind]?.length ?? (kind=='payslip'?1:0);

  static Future<Map<String,dynamic>> publishImportedTemplate(
    SchoolTemplateDraft draft,
  ) => WindowsTemplateCloudStore.publish(draft);

  static Future<Uint8List> renderImportedTemplate(
    String kind,Map<String,dynamic> manifest,Map<String,dynamic> record,
    {bool printOnly=false}
  ) async {
    final bytes=await WindowsTemplateCloudStore.render(kind,manifest,record);
    return printOnly ? SchoolMediaBudgets.verifyPrintPdf(bytes)
        : SchoolMediaBudgets.verifyGeneratedPdf(kind,bytes);
  }

  static Future<Uint8List?> _image(dynamic raw) async {
    final source = raw?.toString().trim() ?? '';
    if (source.startsWith('data:image/')) {
      try {
        return Uint8List.fromList(UriData.parse(source).contentAsBytes());
      } catch (_) {
        return null;
      }
    }
    final u = Uri.tryParse(raw?.toString() ?? '');
    if (u == null || u.scheme != 'https') return null;
    try {
      return await schoolImageBytes(
        u.toString(),
      ).timeout(const Duration(seconds: 30), onTimeout: () => null);
    } catch (_) {}
    return null;
  }

  static String _documentDate(dynamic timestamp) {
    final date = timestamp is Timestamp
        ? timestamp.toDate()
        : timestamp is num
        ? DateTime.fromMillisecondsSinceEpoch(timestamp.toInt())
        : null;
    return date == null
        ? '-'
        : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  static Future<Uint8List?> _personPhoto(Map<String, dynamic> data) async {
    final url = data['photoUrl']?.toString().trim() ?? '';
    if (url.isNotEmpty) {
      final found=await _image(url);
      if(found!=null)return found;
    }
    final raw = data['photoBase64']?.toString().trim() ?? '';
    if (raw.isNotEmpty) {
      final found=await _image(
        raw.startsWith('data:image/') ? raw : 'data:image/jpeg;base64,$raw',
      );
      if(found!=null)return found;
    }
    if(data['atomicPortrait'] is Map)
      return AtomicPersonPortraitDelivery.cachedBytes(data);
    return null;
  }

  static Future<Uint8List?> selected(
    String kind,
    Map<String, dynamic> data, {
    String qr = '',
    // Preview/print/export never changes the durable publication queue.
    // Sync Engine 3.0 publishes changed cards through publishChangedIdCards.
    bool publish = false,
    bool previewOnly = false,
    bool printOnly = false,
  }) async {
    if (publish && printOnly) throw ArgumentError('Print-only bytes cannot be published.');
    if (previewOnly && {'studentId', 'teacherId', 'otherStaffId'}.contains(kind)) {
      final origin = FirebaseFirestore.instance.activeProfileId;
      if (data['schoolId'] != null && data['schoolId'] !=
          FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']) {
        throw StateError('Another school document is not accessible.');
      }
      final photo = await _personPhoto(data);
      if (FirebaseFirestore.instance.activeProfileId != origin) {
        throw StateError('School changed during ID card preview.');
      }
      // A no-photo card must still be generated by the normal publication
      // owner. Only the interactive preview is withheld.
      if (photo == null || photo.isEmpty) return null;
      final card = await nativePersonCard(kind,data);
      if (card != null) {
        if (card.template.id == greenBlueStudentTemplateId) {
          throw StateError('Use Download ID Card for the full-resolution local PDF.');
        }
        qr = IdCardEngine.compactQr(qr);
        final bytes=await IdCardEngine.render(card.template,card.data,
          images:card.images,backgrounds:card.backgrounds,qr:qr,printOnly:printOnly);
        if(qr.isNotEmpty) await IdCardEngine.verifyExport(bytes,qr);
        if(FirebaseFirestore.instance.activeProfileId!=origin)
          throw StateError('School changed during ID card export.');
        return bytes;
      }
    }
    qr = IdCardEngine.compactQr(qr);
    final rendered = await _selected(kind, data, qr: qr,printOnly:printOnly,
        personPreview: previewOnly || printOnly);
    final bytes = rendered == null ? null : printOnly
        ? SchoolMediaBudgets.verifyPrintPdf(rendered)
        : SchoolMediaBudgets.verifyGeneratedPdf(kind, rendered);
    if (bytes != null &&
        {'studentId', 'teacherId', 'otherStaffId'}.contains(kind) &&
        qr.isNotEmpty)
      await IdCardEngine.verifyExport(bytes, qr);
    if (bytes != null &&
        publish && !previewOnly &&
        {'studentId', 'teacherId'}.contains(kind) &&
        qr.isNotEmpty) {
      final identity = await CentralSchoolCloud.saved();
      if (identity['managed'] == true) await _publish(kind, data, qr, bytes);
    }
    return bytes;
  }

  static bool _repairingQueuedIds=false;
  static final Map<String,DateTime> _queuedIdChecks={};
  /// Rebuild only derived IDs whose currently printed source inputs agree with
  /// fresh authenticated school records. Originals and rejected queue revisions
  /// are archived; a new operation uses the actual document CAS baseline.
  static Future<int> repairQueuedIdCards(String school,{bool Function()? canAdmit,
    Future<Map<String,dynamic>> Function(String,String)? readRecord,
  }) async {
    if(_repairingQueuedIds)return 0;
    _repairingQueuedIds=true;
    final db=FirebaseFirestore.instance,origin=db.activeProfileId;
    var repaired=0,probed=0;
    try {
      final connection=await CentralSchoolCloud.saved();
      if(connection['managed']!=true || connection['schoolId']!=school ||
        db.activeProfileIdentity['schoolSyncId']!=school)return 0;
      final queue=await db.collection('_windows_document_outbox').get();
      for(final item in queue.docs){
        if(probed>=1 || canAdmit?.call()==false || db.activeProfileId!=origin)break;
        final expected=item.data();
        if(expected['schoolId']!=school || expected['syncState']!='conflict' ||
          expected['documentKind']!='idCard' || expected['inventoryCategory']!='generatedIdCard' ||
          expected['deleted']==true || !{'student','teacher'}.contains(expected['ownerRole']))continue;
        final key='$origin:${item.id}:${expected['documentRevision']}';
        final last=_queuedIdChecks[key],now=DateTime.now();
        if(last!=null && now.difference(last)<const Duration(minutes:5))continue;
        if(_queuedIdChecks.length>=128)_queuedIdChecks.remove(_queuedIdChecks.keys.first);
        _queuedIdChecks[key]=now;probed++;
        try {
          final role=expected['ownerRole'] as String,personId=expected['studentId']?.toString()??'';
          final kind=role=='student'?'studentId':'teacherId';
          final collection=role=='student'?'students_directory':'teachers_directory';
          final personSnap=await db.collection(collection).doc(personId).get();
          final profileSnap=await db.collection('school_config').doc('school_profile_cache').get();
          final templateSnap=await db.collection('school_settings').doc('document_templates').get();
          final person=personSnap.data(),profile=profileSnap.data(),templates=templateSnap.data()??{};
          if(person==null || profile==null || person['_syncDeleted']==true ||
            person['mobileLinkToken'] is! String ||
            WindowsBackendBridge.publishedIdCardOwnerIdForPerson(role,personId,person)!=item.id)continue;
          final qr=SchoolLink.encodeCompact({'app':'VIDYA_SAARTHI','v':2,'managed':true,
            'schoolId':school,'centralEndpoint':connection['endpoint'],'firebaseProjectId':connection['projectId'],
            'type':role,'personId':personId,'linkToken':person['mobileLinkToken']});
          final localInputs=await inputRevisions(person,profile,kind=='studentId'?_studentRevisionSelection(templates[kind]):templates[kind],qr);
          Future<Map<String,dynamic>?> read(String c,String id) async {
            final reply=await (readRecord?.call(c,id) ?? ManagedSchoolSession.callForSchool(school,'managed/records',{
              'operation':'read','collection':c,'id':id,'syncProtocol':2}));
            if(db.activeProfileId!=origin || canAdmit?.call()==false || reply['schoolId']!=school ||
              reply['syncProtocol']!=2 || reply['records'] is! Map || reply['unchanged']==true)
              throw StateError('Current ID sources could not be verified.');
            final row=(reply['records'] as Map)[id];
            if(row==null)return null;
            if(row is! Map || row['schoolId']!=school || row['_syncDeleted']==true ||
              row['_syncRevision'] is! String || row['_syncRevision'].isEmpty)
              throw StateError('Current ID source identity changed.');
            return Map<String,dynamic>.from(row);
          }
          Future<List<Map<String,dynamic>?>> evidence() => Future.wait([
            read(collection,personId),read('school_config','school_profile_cache'),
            read('school_settings','document_templates'),read('documents',item.id)]);
          final before=await evidence();
          final remotePerson=before[0],remoteProfile=before[1],remoteTemplates=before[2]??{},cloud=before[3];
          if(remotePerson==null || remoteProfile==null || cloud==null ||
            remotePerson['mobileLinkToken']!=person['mobileLinkToken'] ||
            (remotePerson['mobileStableId']??personId)!=expected['personId'])continue;
          final remoteInputs=await inputRevisions(remotePerson,remoteProfile,
            kind=='studentId'?_studentRevisionSelection(remoteTemplates[kind]):remoteTemplates[kind],qr);
          if(remoteInputs.visual!=localInputs.visual)continue;
          final bytes=await selected(kind,personCardData(person,profile),qr:qr,publish:false);
          if(bytes==null)continue;
          final after=await evidence();
          if(syncPayloadHash({'sources':before})!=syncPayloadHash({'sources':after}))continue;
          await WindowsBackendBridge.regenerateVerifiedIdConflict(id:item.id,expected:expected,
            cloud:cloud,person:person,qr:qr,inputRevision:localInputs.visual,bytes:bytes,
            dependencies:[personSnap,profileSnap,templateSnap]);
          repaired++;
        } catch (_) { /* Unproven source, race or unavailable photo: retain all originals. */ }
        break; // One bounded derived repair per pass; unrelated sync continues.
      }
      return repaired;
    } finally {_repairingQueuedIds=false;}
  }

  static Future<String> _fingerprint(Map<String,dynamic> data,Map<String,dynamic> profile,dynamic template,String qr) async =>
    (await inputRevisions(data,profile,template,qr)).visual;

  /// Includes the old identity only to verify existing published cards during
  /// migration. The new identity contains rendered text and active image slots.
  static Future<({String visual,String legacy})> inputRevisions(
    Map<String, dynamic> data,
    Map<String, dynamic> profile,
    dynamic template,
    String qr,
  ) async {
    final origin = FirebaseFirestore.instance.activeProfileId;
    final refs = [data['photoUrl'] ?? data['photoBase64'],
      data['schoolLogoUrl'] ?? profile['logoUrl'],
      data['principalSignatureUrl'] ?? profile['principalSignatureUrl'], profile['sealUrl']];
    final sourceHashes = [data['photoSourceHash'],
      data['schoolLogoUrl'] != null ? null : profile['logoSourceHash'],
      data['principalSignatureUrl'] != null ? data['principalSignatureSourceHash'] : profile['principalSignatureSourceHash'],
      profile['sealSourceHash']];
    final sourceFileIds=[data['photoFileId'],
      data['schoolLogoUrl'] != null ? null : profile['logoFileId'],
      data['principalSignatureUrl'] != null ? data['principalSignatureFileId'] : profile['principalSignatureFileId'],
      profile['sealFileId']];
    bool hasSource(int i) {
      final source=sourceHashes[i];
      final ref=refs[i]?.toString()??'';
      final inline=ref.startsWith('data:image/') ||
        (i==0 && (data['photoUrl']?.toString()??'').isEmpty &&
          (data['photoBase64']?.toString()??'').isNotEmpty);
      return ref.isNotEmpty && !inline && source is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(source) &&
        sourceFileIds[i] is String && schoolDriveFileId(ref)==sourceFileIds[i];
    }
    // Verified source identity lets a receiving PC reuse a card without first
    // downloading every image. Inline edits always hash their current bytes.
    final images = await Future.wait<Uint8List?>([
      hasSource(0) ? Future.value(null) : _personPhoto(data),
      for(var i=1;i<refs.length;i++) hasSource(i) ? Future.value(null) : _image(refs[i]),
    ]);
    if (FirebaseFirestore.instance.activeProfileId != origin)
      throw StateError('School changed while checking ID inputs.');
    for (var i = 0; i < refs.length; i++) {
      if ((refs[i]?.toString().trim() ?? '').isNotEmpty && images[i] == null && !hasSource(i))
        throw StateError('ID image is not available locally. Existing card and pending work retained.');
    }
    Map<String, dynamic> inputs(Map<String, dynamic> value) => {
      for (final entry in value.entries)
        if (!{'schoolId', 'photoUrl', 'photoBase64', 'photoFileId',
          'logoUrl', 'logoBase64', 'logoFileId', 'schoolLogoUrl',
          'principalSignatureUrl', 'principalSignatureBase64', 'principalSignatureFileId',
          'sealUrl', 'sealBase64', 'sealFileId',
          'photoSourceHash', 'logoSourceHash', 'principalSignatureSourceHash', 'sealSourceHash'}.contains(entry.key)) entry.key: entry.value,
    };
    dynamic clean(dynamic v) {
      if (v is Timestamp) return v.millisecondsSinceEpoch;
      if (v is DateTime) return v.millisecondsSinceEpoch;
      if (v is Map) {
        final keys =
            v.keys
                .map((k) => k.toString())
                .where(
                  (k) =>
                      !k.startsWith('_sync') &&
                      !{
                        'updatedAt',
                        'lastEdited',
                        'mobileLinkUpdatedAt',
                      }.contains(k),
                )
                .toList()
              ..sort();
        return {for (final k in keys) k: clean(v[k])};
      }
      if (v is List) return v.map(clean).toList();
      return v;
    }

    String? imageIdentity(int i) => hasSource(i) ? sourceHashes[i] as String :
      images[i]==null?null:sha256.convert(images[i]!).toString();
    final legacy=sha256.convert(utf8.encode(jsonEncode(clean([inputs(data),inputs(profile),template,qr,
      if(SchoolLink.parse(qr).role=='teacher') 'teacher-personal-details-v2',
      for(var i=0;i<images.length;i++)imageIdentity(i)])))).toString();
    final student=SchoolLink.parse(qr).role=='student';
    final kind=student?'studentId':'teacherId';
    final effective={...profile,...personCardData(data,profile),
      'schoolName':profile['schoolName']??profile['name']??'',
      'schoolAddress':profile['address']??'',
      'schoolEmail':profile['schoolEmail']??profile['email']??'',
      'designation':data['designation']??data['role']??(student?'Student':'Teacher'),
      'rollNo':data['rollNo']??data['employeeId']??data['teacherId']??'',
      'parentName':data['parentName']??data['fatherName']??'',
    };
    Map<String,dynamic> text;
    Set<String> slots;
    if(student||template is String&&(template.startsWith('manifest:')||template.startsWith('reviewed:'))) {
      final manifest=template is String&&template.startsWith('reviewed:')
        ?await WindowsIdCardDesignerEntry.reviewed(template,FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']?.toString()??'local:$origin')
        :await (await IdCardCatalog.find(template is String?template.replaceFirst('manifest:',''):studentIdTemplateId)).manifest();
      if(manifest==null)throw StateError('Verified ID design is required.');
      final cardData = manifest.id == greenBlueStudentTemplateId
          ? await greenBlueStudentData(effective) : effective;
      final normalized=IdCardEngine.normalizedInput(manifest,Map<String,dynamic>.from(cardData));
      text={for(final region in manifest.regions.where((r)=>r.kind=='text'))region.key:normalized[region.key]?.toString()??''};
      slots=manifest.regions.where((r)=>r.kind=='image').map((r)=>r.key).toSet();
    } else {
      text=teacherCardText(effective,windowsReferenceDocumentIndex(kind,template));
      slots={'photo','logo','signature'};
    }
    final visual=sha256.convert(utf8.encode(jsonEncode(clean(['id-visible-v1',student?_studentRevisionSelection(template):template is String&&(template.startsWith('manifest:')||template.startsWith('reviewed:'))?template:windowsReferenceDocumentIndex(kind,template),qr,text,
      for(var i=0;i<images.length;i++)if(slots.contains(['photo','logo','signature','seal'][i]))imageIdentity(i)])))).toString();
    if(FirebaseFirestore.instance.activeProfileId!=origin)throw StateError('School changed while checking ID inputs.');
    return (visual:visual,legacy:legacy);
  }

  static Future<void> _publish(
    String kind,
    Map<String, dynamic> data,
    String qr,
    Uint8List bytes,
  ) async {
    final link = SchoolLink.parse(qr), db = FirebaseFirestore.instance;
    final collection = kind == 'teacherId'
        ? 'teachers_directory'
        : 'students_directory';
    final person = (await db.collection(collection).doc(link.personId).get())
        .data();
    if (person == null ||
        person['mobileLinkToken'] != link.linkToken ||
        link.schoolId != db.activeProfileIdentity['schoolSyncId'])
      throw StateError('Verified ID owner changed. Reopen ID card.');
    final profile =
        (await db.collection('school_config').doc('school_profile_cache').get())
            .data() ??
        {};
    final revision = await _fingerprint(
      person,
      profile,
      kind == 'studentId' ? _studentRevisionSelection((await selections())[kind]) : (await selections())[kind],
      qr,
    );
    await WindowsBackendBridge.publishIdCard(
      bytes: bytes,
      qr: qr,
      kind: kind,
      person: person,
      inputRevision: revision,
    );
  }

  /// One-time discovery for installations predating automatic card publication.
  /// Does not regenerate existing packages, retained deletions or conflicts.
  static Future<Map<String, Set<String>>> missingIdCardTargets() async {
    final db = FirebaseFirestore.instance, origin = FirebaseFirestore.instance.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId'];
    final result = <String, Set<String>>{};
    for (final kind in ['studentId', 'teacherId']) {
      final role = kind == 'studentId' ? 'student' : 'teacher';
      final people = (await db.collection(kind == 'studentId' ? 'students_directory' : 'teachers_directory').get()).docs;
      for (final person in people) {
        if (person.data()['deleted'] == true || person.data()['_syncDeleted'] == true ||
            person.data()['schoolId'] != null && person.data()['schoolId'] != school) continue;
        final id = WindowsBackendBridge.publishedIdCardOwnerIdForPerson(role, person.id, person.data());
        final local = (await db.collection('_local_student_documents').doc(id).get()).data();
        final pending = (await db.collection('_windows_document_outbox').doc(id).get()).data();
        final cloud = (await db.collection('documents').doc(id).get()).data();
        if (db.activeProfileId != origin || db.activeProfileIdentity['schoolSyncId'] != school)
          throw StateError('School changed during missing ID discovery.');
        if (holdAutomaticIdCard(local, pending, cloud, school as String) || pending != null || cloud != null) continue;
        (result[kind] ??= <String>{}).add(person.id);
      }
    }
    return result;
  }

  /// Uses the same selected renderer and the existing durable document outbox.
  /// Only changed person/profile/template inputs create a new immutable package.
  static Future<void> publishChangedIdCards({
    Future<Map<String, dynamic>> Function()? readInventory,
    Map<String, Set<String>>? affectedPeople,
    Future<Map<String, dynamic>> Function(String)? readDocument,
    void Function(Map<String, dynamic>)? onCardRepair,
  }) async {
    if (affectedPeople != null && affectedPeople.values.every((ids) => ids.isEmpty)) return;
    final db = FirebaseFirestore.instance, origin = db.activeProfileId;
    final identity = await CentralSchoolCloud.saved();
    if (identity['managed'] != true) return;
    final profile =
        (await db.collection('school_config').doc('school_profile_cache').get())
            .data() ??
        {};
    final templates = await selections();
    Future<Map<String, dynamic>>? publishedInventory;
    Future<Map<String, dynamic>> readPublished() =>
        publishedInventory ??= readInventory?.call() ?? ManagedSchoolSession.callForSchool(
          identity['schoolId'] as String,
          'managed/records',
          {'operation': 'read', 'collection': 'documents', 'syncProtocol': 2},
        );
    final pointReads = <String, Future<Map<String, dynamic>>>{};
    Future<Map<String, dynamic>> readTarget(String id) {
      if (readInventory != null) return readPublished();
      if (readDocument != null) return pointReads.putIfAbsent(id, () => readDocument(id));
      if (!WindowsFirebaseRemote.recordPointReadSupported) return readPublished();
      return pointReads.putIfAbsent(id, () => WindowsBackendBridge.readManagedDocument(
        identity['schoolId'] as String, id));
    }
    final fileQueue =
        (await db.collection('_windows_document_outbox').get()).docs;
    final recordQueue =
        (await db.collection('_windows_firebase_outbox').get()).docs;
    final conflictedIds = {
      for (final q in fileQueue)
        if ({'conflict', 'needsAttention'}.contains(q.data()['syncState']))
          q.id,
      for (final q in recordQueue)
        if (q.data()['collection'] == 'documents' &&
            {'conflict', 'needsAttention'}.contains(q.data()['syncState']))
          q.data()['documentId'],
    };
    Object? firstFailure;
    StackTrace? firstFailureStack;
    for (final kind in ['studentId', 'teacherId']) {
      final collection = kind == 'studentId'
          ? 'students_directory'
          : 'teachers_directory';
      final targets = affectedPeople?[kind];
      if (affectedPeople != null && (targets == null || targets.isEmpty)) continue;
      final people = targets == null
          ? (await db.collection(collection).get()).docs
          : await Future.wait(targets.map((id) => db.collection(collection).doc(id).get()));
      for (final doc in people) {
        if (!doc.exists) continue;
        if (db.activeProfileId != origin)
          throw StateError('School changed during ID publication.');
        try {
        // Retained file/metadata conflicts must be explicitly reviewed before
        // automatic ID regeneration can change their queue or local originals.
        final ownerId = WindowsBackendBridge.publishedIdCardOwnerIdForPerson(
          kind == 'studentId' ? 'student' : 'teacher',
          doc.id, doc.data()!,
        );
        if (conflictedIds.contains(ownerId)) continue;
        final person = await SchoolPersonIdentity.ensure(collection, doc.id);
        final qr = SchoolLink.encodeCompact({
          'app': 'VIDYA_SAARTHI',
          'v': 2,
          'managed': true,
          'schoolId': identity['schoolId'],
          'centralEndpoint': identity['endpoint'],
          'firebaseProjectId': identity['projectId'],
          'type': kind == 'studentId' ? 'student' : 'teacher',
          'personId': doc.id,
          'linkToken': person['mobileLinkToken'],
        });
        final revisions = await inputRevisions(person, profile, kind == 'studentId' ? _studentRevisionSelection(templates[kind]) : templates[kind], qr);
        final revision = revisions.visual;
        final id = WindowsBackendBridge.publishedIdCardOwnerIdForPerson(kind == 'studentId' ? 'student' : 'teacher',doc.id,person);
        final existing =
            (await db.collection('_local_student_documents').doc(id).get())
                .data();
        final pending=(await db.collection('_windows_document_outbox').doc(id).get()).data();
        final cached=(await db.collection('documents').doc(id).get()).data();
        if(db.activeProfileId!=origin)throw StateError('School changed during ID publication.');
        if(holdAutomaticIdCard(existing,pending,cached,identity['schoolId'] as String))continue;
        if (await WindowsIdCardReviews.held(identity['schoolId'] as String, id, revision, cached?['_syncRevision'])) continue;
        final localVisualMatch=existing?['visualInputRevision']==revision&&
          existing?['visualInputSourceRevision']==existing?['inputRevision'];
        var verifiedLegacyMatch=existing?['inputRevision']==revisions.legacy;
        if(!verifiedLegacyMatch&&!localVisualMatch&&existing!=null&&pending==null) {
          final dependencies=await WindowsSyncDependencies.read(identity['schoolId'] as String);
          for(final job in dependencies) {
            final evidence=job.data();
            if(evidence['collection']!=collection||evidence['documentId']!=doc.id||evidence['revision']!=person['_syncRevision']||evidence['previousRecord'] is! Map)continue;
            final before=await inputRevisions(Map<String,dynamic>.from(evidence['previousRecord']),profile,
              kind=='studentId'?_studentRevisionSelection(templates[kind]):templates[kind],qr);
            if(before.visual==revision&&before.legacy==existing['inputRevision'])verifiedLegacyMatch=true;
          }
        }
        if(pending==null&&existing?['syncState']=='Synced'&&existing?['deleted']!=true&&
            (localVisualMatch||verifiedLegacyMatch)) {
          await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>db.collection('_local_student_documents').doc(id).set({
            'visualInputRevision':revision,'visualInputSourceRevision':existing!['inputRevision']},const SetOptions(merge:true)));
          continue;
        }
        if ((existing?['inputRevision'] == revision ||
                existing?['ownerCloudChoiceInputRevision'] == revision) &&
            existing?['deleted'] != true) {
          if (pending == null && cached == null && existing?['syncState'] != 'Synced') {
            await WindowsBackendBridge.requeueUnpublishedIdCard(id, readPublished: () => readTarget(id));
          }
          continue;
        }
        if (existing == null) {
          final cached = (await db.collection('documents').doc(id).get())
              .data();
          if (db.activeProfileId != origin)
            throw StateError('School changed during ID publication.');
          if (cached?['schoolId'] == identity['schoolId'] &&
              cached?['studentId']==doc.id && cached?['personId']==(person['mobileStableId']??doc.id) &&
              cached?['ownerRole']==(kind=='studentId'?'student':'teacher') && cached?['documentKind']=='idCard' &&
              (cached?['inputRevision'] == revision || cached?['inputRevision'] == revisions.legacy) &&
              cached?['_syncDeleted'] != true)
            continue;
        }
        final data = personCardData(person,profile);
        await WindowsBackendBridge.publishIdCard(
          prepareBytes: () => selected(kind, data, qr: qr, publish: false),
          qr: qr,
          kind: kind,
          person: person,
          inputRevision: revision,
          readPublished: () => readTarget(id),
          automatic:true,
        );
        await WindowsIdCardReviews.supersede(identity['schoolId'] as String, id);
        } catch (error, stack) {
          if (error is PublishedIdInputConflict && db.activeProfileId == origin) {
            await WindowsIdCardReviews.retain(error, doc.data()?['name']?.toString() ?? doc.id);
            // Reuse this operation's already verified point-read response.
            // Do not scan all reviews or fetch the entire documents inventory
            // once per conflicting person. keepPublished retains its full CAS,
            // school/owner/revision/hash checks and never acknowledges bytes.
            try {
            await WindowsIdCardReviews.keepPublished(origin, {
              'schoolId': error.schoolId, 'documentId': error.documentId,
              'inputRevision': error.inputRevision, 'cloudRevision': error.cloudRevision,
              'ownerRole': error.ownerRole, 'personId': error.personId,
              'personDocId': error.personDocId,
            }, read: () => readTarget(error.documentId!));
            onCardRepair?.call({'schoolId': error.schoolId, 'stage': 'repairDiagnosed',
              'failureCategory': 'idCardInputs', 'outcome': 'verified_published_card_retained',
              'collection': 'documents', 'documentId': error.documentId,
              'inputRevision': error.inputRevision});
            } catch (repairError, repairStack) {
              if (db.activeProfileId != origin || repairError is CentralCloudException) rethrow;
              firstFailure ??= repairError;
              firstFailureStack ??= repairStack;
            }
            continue;
          }
          // One unavailable photo, renderer or owner conflict must not starve
          // every later student/teacher. The caller retains dependencies and
          // retries failures after uploading the packages already prepared.
          if (db.activeProfileId != origin ||
              error is CentralCloudException) rethrow;
          firstFailure ??= error;
          firstFailureStack ??= stack;
        }
      }
    }
    if (firstFailure != null) {
      Error.throwWithStackTrace(IdCardPreparationFailure(firstFailure), firstFailureStack!);
    }
  }

  static Future<Uint8List?> _selected(
    String kind,
    Map<String, dynamic> data, {
    String qr = '',
    Object? selectionOverride,
    bool printOnly=false,
    bool personPreview=false,
  }) async {
    final origin = FirebaseFirestore.instance.activeProfileId;
    if (data['schoolId'] != null &&
        data['schoolId'] !=
            FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'])
      throw StateError('Another school document is not accessible.');
    if (kind == 'reportCard' && data['studentId'] is String) {
      final student = (await FirebaseFirestore.instance.collection('students_directory').doc(data['studentId'] as String).get()).data();
      if (FirebaseFirestore.instance.activeProfileId != origin)
        throw StateError('School changed during marksheet preview.');
      final school = FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'];
      if (student != null && student['deleted'] != true && student['_syncDeleted'] != true &&
          (student['schoolId'] == null || student['schoolId'] == school) &&
          (data['personId'] != null && data['personId'] == student['mobileStableId'])) {
        data = {...student, ...data};
      }
    }
    final templateSettings=await selections();
    final rawSelection = selectionOverride ?? (kind == 'receipt'
        ? data['receiptTemplateSelection'] ?? templateSettings[kind]
        : templateSettings[kind]);
    final v = kind == 'studentId'
        ? studentCardSelection(rawSelection)
        : financialSelection(kind, rawSelection) ?? 0;
    final plain = v == plainSelection;
    if (financialKind(kind) && !plain &&
        !(v is num && v.isFinite && v == v.toInt() && v >= 0 &&
          v < (kind == 'payslip' ? 1 : windowsReferenceDocumentNames[kind]!.length)) &&
        !(v is String && v.startsWith('imported:'))) {
      throw StateError('Selected school template is invalid. Choose a template or Plain White.');
    }
    final profile =
        (await FirebaseFirestore.instance
                .collection('school_config')
                .doc('school_profile_cache')
                .get())
            .data() ??
        {};
    if (FirebaseFirestore.instance.activeProfileId != origin)
      throw StateError('School changed during document preview.');
    final schoolName=[
      if (kind == 'receipt') data['schoolName'],
      profile['schoolName'], profile['name'], data['schoolName'],
    ].map((v)=>v?.toString().trim()??'')
      .firstWhere((v)=>v.isNotEmpty,orElse:()=> '');
    if(v is String && v.startsWith('imported:')){
      final manifest=importedAsset(templateSettings,kind,templateId:v.substring(9));
      if(manifest==null){
        throw StateError('Selected school template manifest is missing or mismatched.');
      }
      final record={
        ...profile,...data,
        'schoolName':schoolName,
        'schoolAddress': kind == 'receipt'
            ? (data['schoolAddress'] ?? profile['address'] ?? '')
            : (profile['address'] ?? data['schoolAddress'] ?? ''),
        'schoolEmail':profile['schoolEmail']??profile['email']??data['schoolEmail']??'',
        if(qr.isNotEmpty)'qr':qr,
        if(kind=='reportCard' && (data['dateText']?.toString().trim().isEmpty??true))
          'dateText':_documentDate(data['timestamp']),
      };
      return renderImportedTemplate(kind,manifest,record,printOnly:printOnly);
    }
    if(kind=='payslip'){
      return renderWindowsPayslip({
        ...profile,...data,
        'netPaise':data['netPaise']??data['salaryNetPaise']??0,
        'paidPaise':data['paidPaise']??0,
      },schoolName:schoolName,plain:plain);
    }
    final useSchoolBranding = personPreview && personKind(kind);
    if (useSchoolBranding && profile['schoolId'] != null &&
        profile['schoolId'] != FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']) {
      throw StateError('Foreign school branding cannot be used.');
    }
    // Legacy teacher layouts have logo/signature slots but no seal slot.
    final legacyTeacher = useSchoolBranding && kind == 'teacherId' && v is num;
    final brandingSources = [
      useSchoolBranding ? profile['logoUrl'] : data['schoolLogoUrl'] ?? profile['logoUrl'],
      useSchoolBranding ? profile['principalSignatureUrl'] : data['principalSignatureUrl'] ?? profile['principalSignatureUrl'],
      legacyTeacher ? null : profile['sealUrl'],
    ];
    final assets = await Future.wait<Uint8List?>([
      _personPhoto(data),
      _image(brandingSources[0]),
      _image(brandingSources[1]),
      _image(kind == 'receipt' ? (data['schoolSealUrl'] ?? profile['sealUrl']) : brandingSources[2]),
    ]);
    if (FirebaseFirestore.instance.activeProfileId != origin)
      throw StateError('School changed during document preview.');
    for(var i=0;i<brandingSources.length;i++) {
      if((brandingSources[i]?.toString().trim()??'').isNotEmpty &&
          (assets[i+1]==null || assets[i+1]!.isEmpty)) {
        throw StateError('Configured school logo, signature or seal is unavailable. Existing ID and pending work retained.');
      }
    }
    if ((v is String &&
            (v.startsWith('manifest:') || v.startsWith('reviewed:'))) ||
        kind == 'otherStaffId') {
      final reviewed =
          kind == 'studentId' && v is String && v.startsWith('reviewed:')
          ? await WindowsIdCardDesignerEntry.reviewed(
              v,
              FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']
                      ?.toString() ??
                  'local:$origin',
            )
          : null;
      if (FirebaseFirestore.instance.activeProfileId != origin)
        throw StateError('School changed during reviewed preview');
      final templateId = reviewed?.id ?? (v is String && v.startsWith('manifest:')
          ? v.substring(9)
          : (await IdCardCatalog.load()).firstWhere((entry) => entry.kinds.contains(kind)).id);
      if (!(await IdCardCatalog.find(templateId)).kinds.contains(kind)) {
        throw StateError('Selected template is not for this person category.');
      }
      if (FirebaseFirestore.instance.activeProfileId != origin)
        throw StateError('School changed during document preview.');
      return manifestId(
        {
          ...profile,
          ...data,
          'schoolName': schoolName,
          'schoolAddress': profile['address'] ?? '',
          'designation':
              data['designation'] ??
              data['role'] ??
              (kind == 'studentId' ? 'Student' : 'Teacher'),
          'rollNo':
              data['rollNo'] ?? data['employeeId'] ?? data['teacherId'] ?? '',
          'parentName': data['parentName'] ?? data['fatherName'] ?? '',
        },
        qr: qr,
        reviewedManifest: reviewed,
        templateId: templateId,
        printOnly:printOnly,
        photo: assets[0],
        logo: assets[1],
        signature: assets[2],
        seal: assets[3],
      );
    }
    if (kind == 'studentId') {
      return renderWindowsStudentId(
        template: windowsStudentIdIndex(v),
        data: {
          'schoolName': profile['schoolName'] ?? profile['name'] ?? '',
          ...data,
          if ((profile['schoolName']?.toString().trim() ?? '').isNotEmpty)
            'schoolName': profile['schoolName'],
          'schoolAddress': profile['address'] ?? '',
        },
        qr: qr,
        photo: assets[0],
        logo: assets[1],
        signature: assets[2],
      );
    }
    return renderWindowsReferenceDocument(
      kind: kind,
      template: windowsReferenceDocumentIndex(kind, v),
      plain: plain, printOnly:printOnly,
      data: {
        ...profile,
        'schoolName': profile['schoolName'] ?? profile['name'] ?? '',
        ...data,
        if ((profile['schoolName']?.toString().trim() ?? '').isNotEmpty)
          'schoolName': profile['schoolName'],
        'schoolAddress': kind == 'receipt'
            ? (data['schoolAddress'] ?? profile['address'] ?? '')
            : (profile['address'] ?? ''),
        'schoolEmail': profile['schoolEmail'] ?? profile['email'] ?? '',
        if (kind == 'reportCard' &&
            (data['dateText']?.toString().trim().isEmpty ?? true))
          'dateText': _documentDate(data['timestamp']),
      },
      qr: qr,
      photo: assets[0],
      logo: assets[1],
      signature: assets[2],
      seal: assets[3],
    );
  }

  static Future<Uint8List?> renderTemplate(
    String kind,
    int index,
    Map<String, dynamic> data,
  ) async {
    final origin = FirebaseFirestore.instance.activeProfileId;
    if (personKind(kind) && index == -1) {
      final sample={...data,if ((data['schoolName']?.toString().trim()??'').isEmpty)
        'schoolName':'Sample School'};
      final card=await nativePersonCard(kind,sample,selection:plainSelection);
      if(card==null)throw StateError('Plain ID preview unavailable.');
      return IdCardEngine.render(card.template,card.data,images:card.images,
        backgrounds:card.backgrounds,printOnly:true);
    }
    if (financialKind(kind)) {
      final sample = kind == 'payslip' ? <String, dynamic>{
        'name': 'Sample staff', 'employeeId': 'EMP-001',
        'netPaise': 2850000, 'paidPaise': 2000000, 'basicPaise': 2500000,
        'allowancePaise': 400000, 'deductionPaise': 50000,
        'role': 'Teacher', 'month': '2026-10', 'status': 'Part paid', ...data,
      } : Map<String, dynamic>.of(data);
      Object choice = index == -1 ? plainSelection : index;
      final base = importedTemplateIndex(kind);
      if (index >= base) {
        final settings = await selections();
        final assets = availableImportedTemplates(settings, kind,
          FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']?.toString() ?? '');
        final position = index - base;
        if (position >= assets.length) throw StateError('Template list changed. Reopen preview.');
        choice = 'imported:${assets[position]['templateId'] ?? assets[position]['sourceHash']}';
      }
      if (FirebaseFirestore.instance.activeProfileId != origin)
        throw StateError('School changed during template preview.');
      return _selected(kind, sample, selectionOverride: choice,printOnly:true);
    }
    final profile =
        (await FirebaseFirestore.instance
                .collection('school_config')
                .doc('school_profile_cache')
                .get())
            .data() ??
        {};
    final schoolName=[profile['schoolName'],profile['name'],data['schoolName']]
      .map((v)=>v?.toString().trim()??'')
      .firstWhere((v)=>v.isNotEmpty,orElse:()=> '');
    final branding = {
      ...data,
      ...profile,
      'schoolName': schoolName,
      'schoolAddress': profile['address'] ?? '',
      'schoolEmail': profile['schoolEmail'] ?? profile['email'] ?? '',
    };
    final customIndex=index-importedTemplateIndex(kind);
    if(['receipt','reportCard','payslip'].contains(kind) && customIndex>=0){
      final customTemplates=availableImportedTemplates(
        await selections(),kind,
        FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']?.toString()??'');
      if(customIndex<customTemplates.length){
        return renderImportedTemplate(kind,customTemplates[customIndex],{
          ...profile,...data,
          'schoolName':schoolName,
          'schoolAddress':profile['address']??data['schoolAddress']??'',
          'schoolEmail':profile['schoolEmail']??profile['email']??data['schoolEmail']??'',
        });
      }
    }
    if (kind == 'payslip') return renderWindowsPayslip({...data, ...{'netPaise':2850000,'paidPaise':2000000,'basicPaise':2500000,'allowancePaise':400000,'deductionPaise':50000,'role':'Teacher','month':'2026-10','status':'Part paid'}},schoolName:branding['schoolName']?.toString()??'');
    final school = FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'];
    if (personKind(kind) && profile['schoolId'] != null &&
        profile['schoolId'] != school) {
      throw StateError('Foreign school branding cannot be used.');
    }
    final legacyTeacher = kind == 'teacherId' && index >= 0 &&
        index < windowsReferenceDocumentNames['teacherId']!.length;
    final brandingSources = [profile['logoUrl'], profile['principalSignatureUrl'],
      legacyTeacher ? null : profile['sealUrl']];
    final images = await Future.wait<Uint8List?>([
      for (final source in brandingSources) _image(source),
    ]);
    if (FirebaseFirestore.instance.activeProfileId != origin ||
        FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] != school)
      throw StateError('School changed during template preview.');
    if (personKind(kind)) {
      for (var i = 0; i < brandingSources.length; i++) {
        if ((brandingSources[i]?.toString().trim() ?? '').isNotEmpty &&
            (images[i] == null || images[i]!.isEmpty)) {
          throw StateError('Configured school branding is unavailable. Retry preview.');
        }
      }
    }
    final legacyCount = kind == 'studentId'
        ? windowsStudentIdNames.length
        : kind == 'teacherId'
        ? windowsReferenceDocumentNames['teacherId']!.length
        : kind == 'otherStaffId'
        ? 0
        : -1;
    if (legacyCount >= 0 && index >= legacyCount) {
      final choices = (await IdCardCatalog.load())
          .where((e) => e.kinds.contains(kind))
          .toList();
      final entry = choices[index - legacyCount];
      if (entry.id == greenBlueStudentTemplateId) {
        // Gallery and selection must use native preview, not the PDF renderer.
        return null;
      }
      return manifestId(
        branding,
        templateId: entry.id,
        printOnly:true,
        logo: images[0],
        signature: images[1],
        seal: images[2],
      );
    }
    if (kind == 'studentId')
      return renderWindowsStudentId(
        template: index,
        data: branding,
        logo: images[0],
        signature: images[1],
      );
    return renderWindowsReferenceDocument(
      kind: kind,
      template: index,
      data: branding,
      printOnly:true,
      logo: images[0],
      signature: images[1],
      seal: images[2],
    );
  }

  static Future<void> preview(
    BuildContext context,
    Uint8List bytes, {
    String title = 'Document preview',
    String? notice,
    VoidCallback? onDownload,
    VoidCallback? onPrint,
    String printLabel = 'Print ID Card',
  }) => showDialog<void>(
    context: context,
    builder: (ctx) { WindowsAppearance.watch(ctx); return  Dialog(
      child: SizedBox(
        width: 900,
        height: 680,
        child: Column(
          children: [
            ListTile(
              title: Text(title),
              trailing: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close),
              ),
            ),
            if (notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(notice, textAlign: TextAlign.center),
              ),
            Expanded(child: FittedDocumentPreview(bytes: bytes)),
            if (onDownload != null || onPrint != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  children: [
                    if (onPrint != null)
                      OutlinedButton.icon(
                        onPressed: onPrint,
                        icon: const Icon(Icons.print),
                        label: Text(printLabel),
                      ),
                    if (onDownload != null)
                      FilledButton.icon(
                        onPressed: onDownload,
                        icon: const Icon(Icons.download),
                        label: const Text('Download PDF'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ); },
  );
  static Future<bool> previewReport(
    BuildContext context,
    Map<String, dynamic> data,
  ) =>
      WindowsReportCardPreview.open(
        context,
        data,
        // Explicit print preview: transient bytes only, never published.
        createPdf: (record) => selected('reportCard', record, publish: false,printOnly:true),
      );
}

class SchoolDocumentTemplatesScreen extends StatefulWidget {
  const SchoolDocumentTemplatesScreen({super.key, this.thumbnail});
  /// Optional native-raster boundary for UI tests; production renders the PDF.
  final Future<Uint8List> Function(String kind, int index)? thumbnail;
  @override
  State<SchoolDocumentTemplatesScreen> createState() =>
      _SchoolDocumentTemplatesScreenState();
}

class _SchoolDocumentTemplatesScreenState
    extends State<SchoolDocumentTemplatesScreen> {
  final _names = <String, List<String>>{
    ...windowsReferenceDocumentNames,
    'studentId': ['Maroon & Gold • Front + Back'],
    'teacherId': [
      ...windowsReferenceDocumentNames['teacherId']!,
      WindowsDocumentTemplates.manifestName,
    ],
    'otherStaffId': [WindowsDocumentTemplates.manifestName],
    'payslip': ['Classic • Staff payslip'],
  };
  List<IdCardCatalogEntry> _catalog = [];
  String? _catalogError;
  int _legacyCount(String kind) => kind == 'studentId'
      ? windowsStudentIdNames.length
      : kind == 'teacherId'
      ? windowsReferenceDocumentNames['teacherId']!.length
      : 0;
  List<IdCardCatalogEntry> _choices(String kind) =>
      _catalog.where((e) => e.kinds.contains(kind)).toList();
  int _baseTemplateCount(String kind) =>
      kind=='payslip' ? 1 : (windowsReferenceDocumentNames[kind]?.length ?? 0);
  List<String> _baseTemplateNames(String kind) =>
      kind=='payslip' ? const ['Classic • Staff payslip']
        : List<String>.from(windowsReferenceDocumentNames[kind]??const <String>[]);

  int _chosen() {
    if (WindowsDocumentTemplates.plainPrintSelection(_kind,_selected[_kind])) return -1;
    if (_kind == 'studentId') {
      final selection = WindowsDocumentTemplates.studentCardSelection(_selected[_kind]);
      final id = selection.split(':')[1];
      final position=_choices(_kind).indexWhere((entry) => entry.id == id);
      return position<0?-2:position;
    }
    final value = WindowsDocumentTemplates.financialSelection(_kind, _selected[_kind]);
    if (value == WindowsDocumentTemplates.plainSelection) return -1;
    if(value is String && value.startsWith('imported:')){
      final templates=WindowsDocumentTemplates.availableImportedTemplates(
        _selected,_kind,
        FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']?.toString()??'');
      final index=templates.indexWhere((asset)=>
        asset['approved']==true &&
        (asset['templateId']??asset['sourceHash'])==value.substring(9));
      return index<0?-2:_baseTemplateCount(_kind)+index;
    }
    if (value is String && value.startsWith('manifest:')) {
      final i = _choices(_kind).indexWhere((e) => e.id == value.substring(9));
      return i < 0 ? -2 : _legacyCount(_kind) + i;
    }
    return _kind == 'studentId'
        ? windowsStudentIdIndex(value)
        : _kind == 'otherStaffId'
        ? 0
        : windowsReferenceDocumentIndex(_kind, value);
  }

  String _activeKind = 'studentId';
  String get _kind=>_activeKind;
  set _kind(String value){
    if(value==_activeKind)return;
    _thumbnails.clear();
    _activeKind=value;
  }
  Map<String, dynamic> _selected = {};
  bool _loading = true;
  final _thumbnails=WindowsTemplateThumbnailQueue();
  String? _thumbnailCatalogSignature;
  StreamSubscription? _templateChanges;
  bool _deletingTemplate=false;
  bool _selectingTemplate=false;
  TemplateFeatureAccess _feature=const TemplateFeatureAccess.unverified();
  Timer? _featureTimer;
  bool _refreshingFeature=false;
  String _featureSchoolLabel='';
  List<int> get _visibleIndices=>WindowsDocumentTemplates.visibleCatalogIndices(_kind,_names[_kind]!);
  Future<void> _refreshFeature() async {
    if(_refreshingFeature)return;
    _refreshingFeature=true;
    final db=FirebaseFirestore.instance,origin=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId'];
    bool current()=>mounted&&db.activeProfileId==origin&&db.activeProfileIdentity['schoolSyncId']==school;
    try{
      final next=await WindowsTemplateFeatureAccess.read(force:true);
      var label='';
      try{
        final saved=await CentralSchoolCloud.saved();
        if(saved['schoolId']==school)label=saved['schoolName']?.toString()??'';
      }catch(_){}
      if(current()){
        final resumed=next.canUpload&&!_feature.canUpload;
        if(next.canUse!=_feature.canUse)_thumbnails.clear();
        setState((){_feature=next;_featureSchoolLabel=label;});
        if(resumed)unawaited(_resumeApprovedTemplates());
      }
    }catch(_){
      if(current())setState(()=>_feature=const TemplateFeatureAccess.unverified());
    }finally{_refreshingFeature=false;}
  }

  Future<Uint8List?> _thumbnail(int index) {
    final kind=_kind,sample=_sample;
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId'];
    return _thumbnails.request('$profile:$school:$kind:$index',(current)async{
      if(widget.thumbnail!=null)return widget.thumbnail!(kind,index);
      final bytes=await WindowsDocumentTemplates.renderTemplate(kind,index,sample);
      if(bytes==null||!current())return null;
      // Thumbnails only: use a smaller raster and drain the native stream
      // completely before allowing the next PDF job. Actual printing is unchanged.
      Uint8List? png;
      await for(final page in Printing.raster(bytes,pages:[0],dpi:72)){
        if(current()&&png==null)png=await page.toPng();
      }
      return current()?png:null;
    },current:()=>mounted&&_kind==kind&&db.activeProfileId==profile&&
      db.activeProfileIdentity['schoolSyncId']==school);
  }

  @override
  void initState() {
    super.initState();
    _initializeCatalog();
    unawaited(_refreshFeature());
    _featureTimer=Timer.periodic(const Duration(seconds:15),(_){
      if(WindowsDocumentTemplates.financialKind(_kind))unawaited(_refreshFeature());
    });
    final db=FirebaseFirestore.instance,origin=db.activeProfileId;
    _templateChanges=db.collection('school_settings').doc('document_templates')
      .snapshots().listen((_){
        if(mounted && db.activeProfileId==origin) unawaited(_initializeCatalog());
      });
  }

  @override
  void dispose(){_thumbnails.clear();_featureTimer?.cancel();_templateChanges?.cancel();super.dispose();}

  Future<void> _deleteUploaded(int index) async {
    final kind=_kind;
    final school=FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']?.toString()??'';
    final assets=WindowsDocumentTemplates.availableImportedTemplates(_selected,kind,school);
    final position=index-_baseTemplateCount(kind);
    if(position<0 || position>=assets.length || _deletingTemplate)return;
    final asset=assets[position],id=(assets[position]['templateId']??assets[position]['sourceHash']).toString();
    final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Delete uploaded template?'),
      content:Text('Remove ${asset['filename']??'this design'} from this school’s template list on all devices? Existing printed documents are retained.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
        TextButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Delete'))]));
    if(confirmed!=true || !mounted)return;
    setState(()=>_deletingTemplate=true);
    try {
      if(FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']!=school)
        throw StateError('School changed. Reopen templates.');
      await WindowsTemplateCloudStore.deleteTemplate(kind,id);
      if(mounted)await _initializeCatalog();
    } catch(error) {
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Template deletion failed: $error')));
    } finally {if(mounted)setState(()=>_deletingTemplate=false);}
  }

  Future<void> _resumeApprovedTemplates() async {
    final origin=FirebaseFirestore.instance.activeProfileId;
    try{
      final count=await WindowsTemplateCloudStore.resumeApprovedPublications();
      if(count>0&&mounted&&FirebaseFirestore.instance.activeProfileId==origin)await _initializeCatalog();
    }catch(_){ /* Local approved drafts remain available for explicit retry. */ }
  }

  int _catalogLoadGeneration=0;
  Future<void> _initializeCatalog() async {
    final generation=++_catalogLoadGeneration;
    final origin=FirebaseFirestore.instance.activeProfileId;
    try {
      final entries = await IdCardCatalog.load(),
          v = await WindowsDocumentTemplates.selections();
      // Identical sync notifications must not restart every thumbnail.
      // Include the school/profile, actual catalog, and all template data,
      // except bookkeeping-only timestamps and sync revisions.
      final signature=syncPayloadHash({
        'profile':origin,
        'school':FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'],
        'entries':entries.map((e)=>e.id).toList(),
        'settings':{for(final e in v.entries)if(e.key!='updatedAt')e.key:e.value},
      });
      if (mounted && generation==_catalogLoadGeneration &&
          FirebaseFirestore.instance.activeProfileId==origin)
        setState(() {
          if(signature!=_thumbnailCatalogSignature){
            _thumbnailCatalogSignature=signature;
            _thumbnails.clear();
          }
          _catalog = entries;
          _selected = v;
          _catalogError = null;
          for (final kind in ['studentId', 'teacherId', 'otherStaffId'])
            _names[kind] = [
              if (kind == 'studentId') ...windowsStudentIdNames,
              if (kind == 'teacherId')
                ...windowsReferenceDocumentNames['teacherId']!,
              ..._choices(kind).map((e) => e.name),
            ];
          for(final kind in ['receipt','reportCard','payslip']){
            final assets=WindowsDocumentTemplates.availableImportedTemplates(
              v,kind,
              FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']?.toString()??'');
            _names[kind]=[
              ..._baseTemplateNames(kind),
              ...assets.map((asset)=>'School upload • ${asset['filename']??'School template'}'),
            ];
          }
          _loading = false;
        });
    } catch (e) {
      if (mounted && generation==_catalogLoadGeneration && FirebaseFirestore.instance.activeProfileId==origin)
        setState(() {
          _loading = false;
          _catalogError = 'Invalid template catalog: $e';
        });
    }
  }

  Map<String, dynamic> get _sample => {
    'schoolName': '',
    'name': _kind == 'teacherId' ? 'Ananya Sharma' : 'Arup Das',
    'teacherId': 'T-0001',
    'designation': 'Senior Teacher',
    'subject': 'Mathematics',
    'class': 'Class 5',
    'studentClass': 'Class 5',
    'rollNo': '12',
    'parentName': 'Bikash Das',
    'contact': '9876543210',
    'address': '',
    'district': 'Cachar',
    'state': 'Assam',
    'pinCode': '788001',
    'dob': '15/03/2015',
    'examName': 'Final Examination',
    'academicSession': '2026-27',
    'marks': {'English': 84, 'Mathematics': 91, 'Science': 87},
    'fullMarks': 100,
    'totalMarks': 262,
    'percentage': '87.3',
    'result': 'PASS',
    'receiptNo': 'VS-000124',
    'employeeId': 'EMP-001',
    'role': 'Teacher',
    'month': '2026-10',
    'basicPaise': 2500000,
    'allowancePaise': 400000,
    'deductionPaise': 50000,
    'netPaise': 2850000,
    'paidPaise': 2000000,
    'status': 'Part paid',
    'dateText': '01/10/2026',
    'feeItems': {'Tuition fee': 1000, 'Exam fee': 200},
    'totalAmount': 1200,
    'paymentMode': 'Cash',
  };
  bool _openingDesigner = false;
  Future<void> _openBulk() async {
    if(_openingDesigner)return;
    setState(()=>_openingDesigner=true);
    try {
      final origin = FirebaseFirestore.instance.activeProfileId;
      final settings = await WindowsDocumentTemplates.selections();
      final value = WindowsDocumentTemplates.plainPrintSelection('studentId',settings['studentId'])
        ? 'manifest:school-id-v1' : WindowsDocumentTemplates.studentCardSelection(settings['studentId']);
      final id = value.split(':')[1];
      final entry = await IdCardCatalog.find(id);
      if (mounted && FirebaseFirestore.instance.activeProfileId == origin)
        await WindowsIdCardDesignerEntry.openBulk(
          context,
          entry: entry,
          selection: value,
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Bulk ID unavailable: $e')));
    } finally {
      if (mounted) setState(() => _openingDesigner = false);
    }
  }

  Map<String,dynamic>? _uploadedTemplate(int index) {
    if(!const ['receipt','reportCard','payslip'].contains(_kind))return null;
    final position=index-_baseTemplateCount(_kind);
    if(position<0)return null;
    final school=FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']?.toString()??'';
    final assets=WindowsDocumentTemplates.availableImportedTemplates(
      _selected,_kind,school);
    return position<assets.length?assets[position]:null;
  }

  String? _uploadedPaperLabel(int index) {
    final asset=_uploadedTemplate(index);
    if(asset==null)return null;
    if(asset['version']==2 && asset['pages'] is List){
      return '${(asset['pages'] as List).length} verified source pages • A4 / Legal';
    }
    final width=asset['width'],height=asset['height'];
    if(width is! num || height is! num)return 'Paper size unavailable';
    try {
      return SchoolTemplateImportEngine.pageSizeLabel(width.toInt(),height.toInt());
    }on FormatException {
      return 'Paper size unavailable';
    }
  }

  Future<void> _preview(int index) async {
    final kind=_kind;
    final title=index<0?'Plain White preview':_names[kind]![index];
    final entry = _manifestEntry(kind, index);
    if (entry != null || (WindowsDocumentTemplates.personKind(kind) && index == -1)) {
      try {
        final db = FirebaseFirestore.instance;
        final profile = db.activeProfileId;
        final card = await WindowsDocumentTemplates.nativePersonCard(
          kind, _sample, selection: entry == null
              ? WindowsDocumentTemplates.plainSelection : 'manifest:${entry.id}',
        );
        if (!mounted || db.activeProfileId != profile || card == null) return;
        await NativeIdCardPreview.open(context, (_) =>
          NativeIdCardPreview(template: card.template, data: card.data,
            images: card.images, backgrounds: card.backgrounds));
      } catch (error) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Template preview unavailable: $error')));
      }
      return;
    }
    try {
      if(kind=='teacherId' && index>=0 && index<windowsReferenceDocumentNames['teacherId']!.length) {
        await WindowsDocumentTemplates.previewLegacyTeacher(context,_sample,selection:index,gallery:true);
        return;
      }
      final paper=_uploadedPaperLabel(index);
      final bytes = await WindowsDocumentTemplates.renderTemplate(kind,index,_sample);
      if (bytes == null) throw StateError('Template renderer returned no document.');
      if (mounted) await WindowsDocumentTemplates.preview(
        context, bytes, title:title,
        notice:paper==null?null:'$paper. Print using matching paper at Actual size (100%).',
      );
    } catch(error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Template preview unavailable. Retry Preview.')));
    }
  }

  IdCardCatalogEntry? _manifestEntry(String kind, int index) {
    final position = index - _legacyCount(kind);
    final choices = _choices(kind);
    return position >= 0 && position < choices.length ? choices[position] : null;
  }

  Future<void> _select(int index) async {
    final kind = _kind, count = _legacyCount(_kind);
    final db=FirebaseFirestore.instance;
    final origin=db.activeProfileId;
    final boundSchool=db.activeProfileIdentity['schoolSyncId'];
    final school=boundSchool?.toString()??'';
    final settings=Map<String,dynamic>.of(_selected);
    final sample=Map<String,dynamic>.of(_sample);
    if(db.activeProfileId!=origin ||
      db.activeProfileIdentity['schoolSyncId']!=boundSchool){
      throw StateError('School changed before template selection.');
    }
    final templates=WindowsDocumentTemplates.availableImportedTemplates(
      settings,kind,school);
    final customIndex=index-_baseTemplateCount(kind);
    final asset=customIndex>=0 && customIndex<templates.length
      ?templates[customIndex]:null;
    final isImported=['receipt','reportCard','payslip'].contains(kind) &&
      asset!=null && asset['approved']==true &&
      asset['schoolId']==school;
    if(isImported)await WindowsTemplateFeatureAccess.requireUse(force:true);
    final value = index == -1 && WindowsDocumentTemplates.supportsPlain(kind)
        ? WindowsDocumentTemplates.plainSelection
        : isImported
        ? 'imported:${asset['templateId']??asset['sourceHash']}'
        : {'studentId', 'teacherId', 'otherStaffId'}.contains(kind) &&
            index >= count
          ? 'manifest:${_choices(kind)[index - count].id}'
          : index;
    if(db.activeProfileId!=origin ||
      db.activeProfileIdentity['schoolSyncId']!=boundSchool){
      throw StateError('School changed before template selection was saved.');
    }
    if (isImported && (asset['version']==2 || ((asset['fields'] as List?)??const []).any((f)=>f is Map&&(f.containsKey('ink')||f.containsKey('bold')||f.containsKey('alignment'))))) {
      if(!mounted)return;
      final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Select updated template format?'),
        content:const Text('All school PCs must use the current Windows app with support for this template format. Older apps cannot render this design. Update every PC before applying.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('All PCs updated'))]));
      if(confirmed!=true || !mounted)return;
      if(db.activeProfileId!=origin || db.activeProfileIdentity['schoolSyncId']!=boundSchool)
        throw StateError('School changed before template selection.');
    }
    final ref = db.collection('school_settings').doc('document_templates');
    // Validate the exact selected financial renderer before changing selection.
    // The approved manifest cannot silently become a different version.
    if (kind == 'studentId' && value == 'manifest:$greenBlueStudentTemplateId') {
      // Selecting the bundled approved layout must not generate a PDF.
      final entry = await IdCardCatalog.find(greenBlueStudentTemplateId);
      if (!await entry.hasApprovedGreenBlueArtwork()) {
        throw StateError('Approved original artwork is missing.');
      }
      await entry.manifest();
      if (!mounted) return;
      final confirmed = await showDialog<bool>(context: context, builder: (ctx) =>
        AlertDialog(title: const Text('Use Green Blue Modern for this school?'),
          content: const Text('Update all school PCs to a version that includes this template before selecting it.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('All PCs updated')),
          ]));
      if (confirmed != true || !mounted) return;
    } else if (WindowsDocumentTemplates.supportsPlain(kind)) {
      final preview = WindowsDocumentTemplates.financialKind(kind)
        ? await WindowsDocumentTemplates._selected(kind,sample,selectionOverride:value,printOnly:true)
        : await WindowsDocumentTemplates.renderTemplate(kind,index,sample);
      if (preview == null || preview.isEmpty) throw StateError('Template is not printable.');
    }
    if(db.activeProfileId!=origin ||
       db.activeProfileIdentity['schoolSyncId']!=boundSchool) {
      throw StateError('School changed during template verification.');
    }
    final currentSnapshot = (await ref.get()).data();
    final current = currentSnapshot ?? <String,dynamic>{};
    if (current[kind] != settings[kind])
      throw StateError('Template selection changed on another device. Refresh and retry.');
    if (isImported && !WindowsDocumentTemplates.availableImportedTemplates(current,kind,school)
        .any((asset)=>'imported:${WindowsTemplateCloudStore.versionId(asset)}'==value)) {
      throw StateError('Uploaded template was removed. Reopen templates.');
    }
    if(db.activeProfileId!=origin || db.activeProfileIdentity['schoolSyncId']!=boundSchool)
      throw StateError('School changed before template save.');
    final batch = db.batch();
    batch.requireUnchanged(ref,currentSnapshot);
    batch.set(ref,{kind:value,'updatedAt':FieldValue.serverTimestamp()},const SetOptions(merge:true));
    await batch.commit();
    if(db.activeProfileId!=origin ||
      db.activeProfileIdentity['schoolSyncId']!=boundSchool){
      throw StateError('School changed while template selection was saving.');
    }
    if (mounted) setState(() => _selected[kind] = value);
  }

  @override
  Widget build(BuildContext context) { WindowsAppearance.watch(context); return  Scaffold(
    appBar: AppBar(title: const Text('School document templates')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_loading && _chosen()==-2) const Text('Selected template unavailable. Retry or explicitly choose another design.'),
          if(!_loading&&_chosen()!=-2&&!_visibleIndices.contains(_chosen()))
            const Text('Current saved layout is retained. Choose a displayed design to change it.',style:TextStyle(fontSize:12)),
          if (_catalogError != null) ...[Text(_catalogError!),
            TextButton(onPressed:_initializeCatalog,child:const Text('Retry templates'))],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _names.keys
                .map(
                  (k) => ChoiceChip(
                    label: Text(
                      {
                        'studentId': 'Student ID',
                        'teacherId': 'Teacher ID',
                        'otherStaffId': 'Other Staff ID',
                        'reportCard': 'Report card',
                        'receipt': 'Fee receipt',
                        'payslip': 'Staff payslip',
                      }[k]!,
                    ),
                    selected: _kind == k,
                    onSelected: (_) {
                      setState(()=>_kind=k);
                      if(WindowsDocumentTemplates.financialKind(k))unawaited(_refreshFeature());
                    },
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 14),
           Text(
            'Preview first, then select one layout for the whole school. Student and teacher ID layouts are stored separately.',
            style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.white54)),
          ),
          const SizedBox(height: 20),
          if (_kind == 'studentId') ...[
            if (WindowsIdCardDesignerEntry.enabled)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _loading || _openingDesigner ? null : _openBulk,
                  icon: const Icon(Icons.print),
                  label: const Text('Class bulk ID Cards'),
                ),
              ),
            const SizedBox(height: 10),
          ],
          if (const ['receipt','reportCard','payslip'].contains(_kind)) ...[
            Align(
              alignment:Alignment.centerLeft,
              child:Row(mainAxisSize:MainAxisSize.min,
                crossAxisAlignment:CrossAxisAlignment.center,children:[
                  SizedBox(height:36,child:OutlinedButton(
                    key:ValueKey('upload-template-'+_kind),
                    style:OutlinedButton.styleFrom(
                      foregroundColor:const Color(0xFFFBAE17),
                      disabledForegroundColor:const Color(0xFFFBAE17),
                      side:const BorderSide(color:Color(0xFFFBAE17)),
                      shape:const StadiumBorder(),
                      padding:const EdgeInsets.symmetric(horizontal:14),
                      minimumSize:Size.zero,
                      tapTargetSize:MaterialTapTargetSize.shrinkWrap,
                      visualDensity:VisualDensity.standard,
                    ),
                    onPressed:_loading||!_feature.canUpload?null:() async {
                      await SchoolTemplateImportEditor.pickAutomatic(
                        context,
                        switch (_kind) {
                          'receipt'=>SchoolTemplateKind.receipt,
                          'reportCard'=>SchoolTemplateKind.reportCard,
                          _=>SchoolTemplateKind.payslip,
                        },
                        _sample,
                      );
                      if(mounted){await _initializeCatalog();await _refreshFeature();}
                    },
                    child:Row(mainAxisSize:MainAxisSize.min,
                      mainAxisAlignment:MainAxisAlignment.center,
                      crossAxisAlignment:CrossAxisAlignment.center,children:[
                        Icon(_feature.canUpload?Icons.upload_file_outlined:Icons.lock_outline,
                          size:18,color:const Color(0xFFFBAE17)),
                        const SizedBox(width:8),
                        const Text('Upload Word / Excel template'),
                      ]),
                  )),
                  const SizedBox(width:8),
                  Tooltip(message:[if(_featureSchoolLabel.isNotEmpty)'School: $_featureSchoolLabel',_feature.uploadExplanation,'Click to refresh access.'].join('\n'),waitDuration:const Duration(milliseconds:250),
                    child:IconButton(
                      constraints:const BoxConstraints.tightFor(width:36,height:36),
                      padding:EdgeInsets.zero,
                      alignment:Alignment.center,
                      onPressed:()=>_refreshFeature(),
                      icon:const Icon(Icons.info_outline,size:19,color:Color(0xFFFBAE17)))),
                ])
            ),
            const Padding(
              padding:EdgeInsets.symmetric(vertical:9),
              child:Text('Upload a blank Word (.docx) or Excel (.xlsx) school form with supported A4 / Legal layout. Review the generated design before saving. No Office installation is required.',
                style:TextStyle(fontSize:12)),
            ),
          ],
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 350,
                mainAxisExtent: 360,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: _visibleIndices.length,
              itemBuilder: (ctx, n) {
                final i = _visibleIndices[n];
                final chosen = _chosen();
                final active = i == chosen;
                final entry = _manifestEntry(_kind, i);
                final portrait =
                    (_kind == 'studentId' || _kind == 'teacherId') &&
                    entry == null &&
                    (_kind == 'studentId' ? i < 2 : i != 2);
                return Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: active ? const Color(0xFF00D9A5) : WindowsAppearance.outline(Colors.white12),
                      width: active ? 2 : 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _kind == 'teacherId'
                                  ? Icons.school_outlined
                                  : _kind == 'studentId'
                                  ? Icons.badge_outlined
                                  : Icons.description_outlined,
                              color: WindowsAppearance.foreground(Colors.tealAccent),
                            ),
                            const Spacer(),
                            if(const ['receipt','reportCard','payslip'].contains(_kind) &&
                                i>=_baseTemplateCount(_kind))
                              IconButton(tooltip:'Delete uploaded template',
                                onPressed:_deletingTemplate?null:()=>_deleteUploaded(i),
                                icon:const Icon(Icons.delete_outline)),
                            if (active)
                              Icon(
                                Icons.check_circle,
                                color: WindowsAppearance.foreground(Colors.tealAccent),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        ...[
                          Expanded(
                            child: Center(
                              child: entry?.frontAsset != null
                                  ? Image.asset(entry!.frontAsset!, fit: BoxFit.contain)
                                  : entry != null
                                  ? const Icon(Icons.badge_outlined, size: 54)
                                  : FutureBuilder<Uint8List?>(
                                key:ValueKey('$_kind:$i:${_thumbnails.generation}'),
                                future: _thumbnail(i),
                                builder: (context, snapshot) { WindowsAppearance.watch(context); return  snapshot.hasData
                                    ? DecoratedBox(
                                        decoration: const BoxDecoration(color: Colors.white),
                                        child: Image.memory(snapshot.data!,fit:BoxFit.contain,cacheWidth:320,
                                          errorBuilder:(_,__,___)=>const Text('Use Preview to view this design')),
                                      )
                                    : snapshot.hasError||snapshot.connectionState==ConnectionState.done
                                    ? const Text(
                                        'Use Preview to view this design',
                                      )
                                    : const CircularProgressIndicator(); },
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Text(
                          i < 0 ? 'Plain White' : _names[_kind]![i],
                          style: const TextStyle(fontFamily: 'Segoe UI', fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          i < 0
                              ? 'No decorative template'
                              : entry?.id == greenBlueStudentTemplateId
                              ? 'Front only • 85.6 × 54.1 mm'
                              : portrait
                              ? 'Front | Back • each 54 × 85.6 mm'
                              : _kind.endsWith('Id')
                              ? 'Front | Back • each 85.6 × 54 mm'
                              : _uploadedPaperLabel(i) ?? 'Printable school document',
                          style:  TextStyle(fontFamily: 'Segoe UI', 
                            color: WindowsAppearance.foreground(Colors.white54),
                            fontSize: 12,
                          ),
                        ),

                        Row(
                          children: [
                            OutlinedButton(
                              onPressed: () => _preview(i),
                              child: const Text('Preview'),
                            ),
                            const SizedBox(width: 10),
                            FilledButton(
                              onPressed: active || _loading || _selectingTemplate || _catalogError != null ||
                                  (_uploadedTemplate(i)!=null&&!_feature.canUse)
                                  ? null
                                  : () async {
                                      setState(() => _selectingTemplate = true);
                                      try { await _select(i); }
                                      catch (_) {
                                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Template selection failed. Existing selection retained. Retry.')));
                                      } finally {
                                        if (mounted) setState(() => _selectingTemplate = false);
                                      }
                                    },
                              child: Text(
                                active ? 'Selected' : 'Use for school',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  ); }
}
