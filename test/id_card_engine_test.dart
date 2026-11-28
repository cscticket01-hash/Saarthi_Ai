import '../lib/school_qr_link.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../lib/developer_global_id_mapping_tracker.dart';

import 'package:flutter_test/flutter_test.dart';

import '../lib/id_card_manifest.dart';
import '../lib/id_card_engine.dart';
import '../lib/id_card_catalog.dart';
import '../lib/id_card_identity.dart';
import '../lib/developer_global_id_preview.dart';
import '../lib/global_id_card_review.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> manifest() => Map<String, dynamic>.from(
    jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync()),
  );
  test('maroon template aliases preserve live student fields and real QR', () async {
    final entry=await IdCardCatalog.find('student-maroon-gold-v1');
    final prepared=await IdCardEngine.prepare(await entry.manifest(), {
      'studentName':'Actual Student','studentClass':'VII', 'roll':'024',
      'fatherName':'Actual Parent','parentContact':'0012345678',
      'streetAddress':'Actual address','pin':'788001','academicSession':'2026-27',
    },qr:'actual-qr-payload', backgrounds:await entry.backgrounds());
    expect(prepared.data['name'],'Actual Student');
    expect(prepared.data['parentName'],'Actual Parent');
    expect(prepared.data['contact'],'0012345678');
    expect(prepared.data['pinCode'],'788001');
    expect(prepared.data['session'],'2026-27');
    expect(prepared.qr,'actual-qr-payload');
    expect(prepared.backgrounds.keys,containsAll(['front','back']));
    final raw=jsonDecode(File('assets/student_maroon_gold_manifest.json').readAsStringSync()) as Map<String,dynamic>;
    (raw['regions'] as List).first['textColor']='not-a-color';
    expect(()=>IdCardManifest.fromJson(raw),throwsFormatException);
  });
  test('bundled catalog validates manifests and rejects external or traversing assets', () async {
    final entries = await IdCardCatalog.load();
    expect(
      entries.where((e)=>e.kinds.contains('studentId')).map((e)=>e.id).toList(),
      ['student-maroon-gold-v1', 'student-svn-navy-green-v1',
        if (File(IdCardCatalogEntry.greenBlueAsset).existsSync()) IdCardCatalogEntry.greenBlueId],
    );
    for(final entry in entries) { expect((await entry.manifest()).id, entry.id); }
    final svn = await IdCardCatalog.find('student-svn-navy-green-v1');
    expect((await svn.manifest()).hasBack, isTrue);
    expect((await svn.backgrounds()).keys, unorderedEquals(['front', 'back']));
    for (final asset in [
      'https://evil.example/card.json',
      'assets/../private.json',
    ]) {
      expect(
        () => IdCardCatalogEntry({
          'id': 'test-id',
          'name': 'Test',
          'manifest': asset,
          'kinds': ['studentId'],
        }),
        throwsFormatException,
      );
    }
  });
  test('Green Blue Modern is front-only with confirmed UID, oval photo and exact geometry', () {
    final raw = jsonDecode(File('assets/student_green_blue_modern_manifest.json').readAsStringSync()) as Map<String,dynamic>;
    final template = IdCardManifest.fromJson(raw);
    expect(template.hasBack, isFalse);
    expect(template.regions.singleWhere((r)=>r.key=='photo').shape, 'oval');
    expect(template.regions.singleWhere((r)=>r.key=='confirmedUniversalStudentUid').rotation, -90);
    expect(IdCardEngine.normalizedInput(template, {'studentId':'legacy','studentUid':'temporary'})['confirmedUniversalStudentUid'], '');
    expect(IdCardEngine.normalizedInput(template, {'_greenBlueVerifiedUid':'STU-DEMO-TEST-000001'})['confirmedUniversalStudentUid'], 'Student ID - STU-DEMO-TEST-000001');
    expect(template.printWidth, closeTo(85.598, .001));
    expect(template.printHeight, closeTo(54.102, .001));
  });
  test('Green Blue Modern release asset matches exact original 600 DPI master', () async {
    final asset = File(IdCardCatalogEntry.greenBlueAsset);
    expect(asset.existsSync(), isTrue, reason: 'Upload the approved original PNG before merging.');
    final bytes = await asset.readAsBytes();
    expect(IdCardCatalogEntry.isApprovedGreenBlueArtwork(bytes), isTrue);
    final entry = await IdCardCatalog.find(IdCardCatalogEntry.greenBlueId);
    expect(await entry.hasApprovedGreenBlueArtwork(), isTrue);
    final card = await IdCardEngine.renderLocalDownload(await entry.manifest(),
      {'schoolName':'Synthetic School','name':'Synthetic Student'}, backgrounds:await entry.backgrounds());
    expect(latin1.decode(card).startsWith('%PDF'), isTrue);
    expect(RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(card)).length, 1);
  });
  test('manifest rejects overflow, duplicate regions, unknown version and distorted print dimensions', () {
    final raw = manifest();
    final valid = IdCardManifest.fromJson(raw);
    expect(valid.printWidth, 54);
    expect(valid.printHeight, 85.6);
    expect(valid.regions.map((r) => r.side).toSet(), {'front', 'back'});
    expect(
      () => IdCardManifest.fromJson({...raw, 'version': 2}),
      throwsFormatException,
    );
    expect(
      () => IdCardManifest.fromJson({...raw, 'printWidthMm': 85.6}),
      throwsFormatException,
    );
    expect(
      () => IdCardManifest.fromJson({
        ...raw,
        'regions': [...raw['regions'], raw['regions'][0]],
      }),
      throwsFormatException,
    );
    expect(
      () => IdCardManifest.fromJson({
        ...raw,
        'regions': [
          {...raw['regions'][0], 'x': 215},
          ...raw['regions'].skip(1),
        ],
      }),
      throwsFormatException,
    );
  });
  test('shared manifest renders Student Teacher and Other Staff as one physical front/back PDF page', () async {
    final template = IdCardManifest.fromJson(manifest());
    for (final role in ['Student', 'Teacher', 'Other Staff']) {
      final bytes = await IdCardEngine.render(template, {
        'schoolName': 'Own School',
        'name': 'Arup Das',
        'designation': role,
        'address': 'School Road, Silchar',
        'rollNo': '12',
      }, qr: SchoolLink.encodeCompact(Map<String,dynamic>.from((jsonDecode(File('test/fixtures/windows_person_qr.json').readAsStringSync()) as List).first)));
      final text = latin1.decode(bytes);
      expect(text.startsWith('%PDF'), true);
      expect(RegExp(r'/Type\s*/Page\b').allMatches(text).length, 1);
      final box = RegExp(
        r'/MediaBox\s*\[\s*0(?:\.0+)?\s+0(?:\.0+)?\s+([\d.]+)\s+([\d.]+)',
      ).firstMatch(text);
      expect(box, isNotNull);
      expect(double.parse(box!.group(1)!), closeTo(116 * 72 / 25.4, 0.02));
      expect(double.parse(box.group(2)!), closeTo(85.6 * 72 / 25.4, 0.02));
      final folder = Directory('build/reference-document-previews');
      await folder.create(recursive: true);
      await File('${folder.path}/manifest_${role.replaceAll(' ', '_')}.pdf')
          .writeAsBytes(bytes);
    }
  });
  test('developer sample preview never uses real identity or a login QR',() async {
    final data=DeveloperGlobalIdPreview.demoData('studentId');
    expect(data['name'],'Demo Student');
    expect(data['contact'],'0000000000');
    expect(DeveloperGlobalIdPreview.qr,'SAARTHI-DEMO-NOT-A-LOGIN');
    final images=DeveloperGlobalIdPreview.demoImages();
    expect(images.keys,unorderedEquals(['photo','logo','signature','seal']));
    final raw=manifest();
    final m=IdCardManifest.fromJson({...raw,'id':'gid-00000000000000000000000000000001'});
    final pdf=await IdCardEngine.render(m,data,images:images,qr:DeveloperGlobalIdPreview.qr);
    expect(latin1.decode(pdf).startsWith('%PDF'),true);
  });

  test('automatic preparation requires name, QR and every explicit placeholder',(){
    final pages=[<String,dynamic>{'side':'front','labelSlots':[{'role':'logo'}]}];
    final slots=[<String,dynamic>{'side':'front','key':'name'},
      <String,dynamic>{'side':'front','key':'qr'}];
    expect(GlobalIdCardReview.canAutoPrepare(pages,slots),false);
    slots.add({'side':'front','key':'logo'});
    expect(GlobalIdCardReview.canAutoPrepare(pages,slots),true);
    slots.add({'side':'front','key':''});
    expect(GlobalIdCardReview.canAutoPrepare(pages,slots),false);
  });

  test('sparse horizontal ink and circular marks are distinct from a generic full-page image',(){
    final ink=img.ColorRgba8(20,30,40,255),white=img.ColorRgba8(255,255,255,255);
    final sign=img.Image(width:160,height:48,numChannels:4);
    img.fill(sign,color:white);img.fillRect(sign,x1:10,y1:22,x2:150,y2:27,color:ink);
    expect(GlobalIdCardReview.pixelRole(sign,.03,.8),'signature');
    final seal=img.Image(width:100,height:100,numChannels:4);
    img.fill(seal,color:white);img.fillCircle(seal,x:50,y:50,radius:43,color:ink);
    img.fillCircle(seal,x:50,y:50,radius:30,color:white);
    expect(GlobalIdCardReview.pixelRole(seal,.03,.8),'seal');
    expect(GlobalIdCardReview.pixelRole(seal,.9,.5),isNull);
  });
  test('uncertain image mapping blocks automatic preparation',(){
    final pages=[<String,dynamic>{'side':'front'}];
    final slots=[<String,dynamic>{'side':'front','key':'name'},<String,dynamic>{'side':'front','key':'qr'},
      <String,dynamic>{'side':'front','key':'photo','roleConfidence':'low'}];
    expect(GlobalIdCardReview.canAutoPrepare(pages,slots),false);
  });

  test('shared identity policy preserves exact Windows catalog semantics',(){
    for(final id in ['gid-demo','gid-00000000000000000000000000000001','student-green-blue-modern-v1']){
      expect(IdCardIdentity.isGlobalId(id),IdCardCatalog.isGlobalId(id));
    }
    expect(IdCardIdentity.greenBlueSha256,IdCardCatalogEntry.greenBlueSha256);
  });

  testWidgets('manual mapping draws a missing logo and saves its shape and geometry',(tester)async{
    await tester.binding.setSurfaceSize(const Size(1200,900));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    final image=img.Image(width:240,height:150,numChannels:4);
    img.fill(image,color:img.ColorRgba8(255,255,255,255));
    final raw=<String,dynamic>{'mode':'private_reference','sourceSha256':'synthetic-hash','mappingRevision':0,
      'rasters':{'front':base64Encode(img.encodePng(image))},
      'analysis':{'pages':[{'side':'front','canvasWidth':240,'canvasHeight':150,
        'printWidthMm':84.67,'printHeightMm':52.92,'candidates':[]}]}};
    Map<String,dynamic>? saved;
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:DeveloperGlobalIdMappingTracker(
      name:'Synthetic',kind:'studentId',data:Future.value(raw),save:(payload)async{saved=payload;return {'mappingRevision':1};}))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manual Mapping'));await tester.pumpAndSettle();
    await tester.tap(find.text('Circle'));await tester.pumpAndSettle();
    final imageFinder=find.byType(Image).first;
    await tester.ensureVisible(imageFinder);await tester.pumpAndSettle();
    final bounds=tester.getRect(imageFinder);
    final start=bounds.topLeft+Offset(bounds.width*.10,bounds.height*.10);
    final delta=Offset(bounds.width*.18,bounds.height*.30);
    final gesture=await tester.startGesture(start,kind:PointerDeviceKind.mouse);
    await gesture.moveBy(delta);await gesture.up();await tester.pumpAndSettle();
    await tester.tap(find.text('Save Mapping'));await tester.pumpAndSettle();
    expect(saved,isNotNull);
    final row=(saved!['slots'] as List).single as Map;
    expect(row['key'],'logo');expect(row['oval'],true);
    expect(row['manual'],true);expect(row['sampleOval'],true);expect(row['width'],closeTo(row['height'] as num,0.01));
    expect(saved!['mappingRevision'],0);
  });

  test('readable region repair expands a tiny class without changing sample mask',(){
    final pages=[<String,dynamic>{'side':'front','canvasWidth':240,'canvasHeight':150}];
    final slots=[<String,dynamic>{'side':'front','key':'class','x':130,'y':80,'width':4,'height':5}];
    final result=GlobalIdCardReview.fitOutputRegions(pages,slots).single;
    expect(result['sample_width'],4);expect(result['sample_height'],5);
    expect(result['width'],greaterThanOrEqualTo(13));expect(result['height'],greaterThanOrEqualTo(7.5));
    expect(GlobalIdCardReview.readabilityIssue(result),isNull);
    expect(slots.single['width'],4);
  });
  test('safe fit refuses overlap and identifies the exact field',(){
    final pages=[<String,dynamic>{'side':'front','canvasWidth':240,'canvasHeight':150}];
    final slots=[<String,dynamic>{'side':'front','key':'rollNo','x':130,'y':80,'width':4,'height':5},
      <String,dynamic>{'side':'front','key':'photo','x':135,'y':60,'width':30,'height':50}];
    final result=GlobalIdCardReview.fitOutputRegions(pages,slots).first;
    expect(result['width'],4);expect(GlobalIdCardReview.readabilityIssue(result),contains('rollNo (front)'));
  });
  test('vertical ID uses width as readable line height',(){
    final pages=[<String,dynamic>{'side':'front','canvasWidth':240,'canvasHeight':150}];
    final slots=[<String,dynamic>{'side':'front','key':'confirmedUniversalStudentUid','rotation':-90,'x':12,'y':60,'width':4,'height':50}];
    final result=GlobalIdCardReview.fitOutputRegions(pages,slots).single;
    expect(result['rotation'],-90);expect(result['width'],greaterThanOrEqualTo(7.5));
    expect(result['sample_width'],4);expect(GlobalIdCardReview.readabilityIssue(result),isNull);
  });

  test('real PDF renderer reports the failed field and accepts the repaired region',()async{
    final pages=[<String,dynamic>{'side':'front','canvasWidth':240,'canvasHeight':150}];
    final slots=[<String,dynamic>{'side':'front','key':'class','kind':'text','x':130,'y':80,'width':4,'height':5,'fontSize':6,'minFontSize':6}];
    IdCardManifest make(List<Map<String,dynamic>> regions)=>IdCardManifest.fromJson({
      'id':'gid-00000000000000000000000000000001','version':1,'canvasWidth':240,'canvasHeight':150,
      'printWidthMm':84.8,'printHeightMm':53,'regions':regions,
    });
    final image=img.Image(width:480,height:300,numChannels:4);
    img.fill(image,color:img.ColorRgba8(255,255,255,255));
    final backgrounds={'front':img.encodePng(image)};
    await expectLater(IdCardEngine.render(make(slots),{'class':'VIII'},backgrounds:backgrounds,printOnly:true),
      throwsA(isA<FormatException>().having((e)=>e.message,'message',contains('class (front)'))));
    final repaired=GlobalIdCardReview.fitOutputRegions(pages,slots);
    final pdf=await IdCardEngine.render(make(repaired),{'class':'VIII'},backgrounds:backgrounds,printOnly:true);
    expect(latin1.decode(pdf).startsWith('%PDF'),true);
  });

  test('global output refuses truncated text even in an old ellipsis manifest',()async{
    final m=IdCardManifest.fromJson({'id':'gid-00000000000000000000000000000001','version':1,'canvasWidth':240,'canvasHeight':150,
      'printWidthMm':84.8,'printHeightMm':53,'regions':[{'side':'front','key':'name','kind':'text','x':10,'y':20,'width':18,'height':12,'fontSize':8,'minFontSize':6,'overflow':'ellipsis'}]});
    final image=img.Image(width:480,height:300,numChannels:4);img.fill(image,color:img.ColorRgba8(255,255,255,255));
    await expectLater(IdCardEngine.render(m,{'name':'Alex Morgan Williams'},backgrounds:{'front':img.encodePng(image)},printOnly:true),
      throwsA(isA<FormatException>().having((e)=>e.message,'message',contains('name (front)'))));
  });
  test('mapped global student UID cannot be replaced with an unverified ID',()async{
    final m=IdCardManifest.fromJson({'id':'gid-00000000000000000000000000000001','version':1,'canvasWidth':240,'canvasHeight':150,
      'printWidthMm':84.8,'printHeightMm':53,'regions':[{'side':'front','key':'confirmedUniversalStudentUid','kind':'text','x':10,'y':20,'width':170,'height':12}]});
    await expectLater(IdCardEngine.prepare(m,{'studentId':'unverified'}),throwsA(isA<FormatException>().having((e)=>e.message,'message',contains('confirmedUniversalStudentUid'))));
  });

}
