import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_template_cloud_store.dart';

void main(){
  test('template versions keep the active selection while exposing newest upload first',(){
    final old={
      'version':1,'approved':true,'templateId':'old-id',
      'sourceHash':'old-source','filename':'Old receipt',
    };
    final latest={
      'version':1,'approved':true,'templateId':'new-id',
      'sourceHash':'new-source','filename':'New receipt',
    };
    final settings={
      'receipt':'imported:old-id',
      'templateAssetLatest':{'receipt':'new-id'},
      'templateAssets':{
        'receipt':{'old-id':old,'new-id':latest},
      },
    };
    final templates=WindowsTemplateCloudStore.importedTemplates(settings,'receipt');
    expect(templates.map((v)=>v['templateId']).toList(),['new-id','old-id']);
    expect(WindowsTemplateCloudStore.importedAsset(settings,'receipt')?['templateId'],'old-id');
    expect(WindowsTemplateCloudStore.importedAsset(
      settings,'receipt',templateId:'new-id')?['templateId'],'new-id');
  });

  test('single-manifest format remains readable during migration',(){
    final manifest={
      'version':1,'approved':true,'sourceHash':'legacy-hash',
      'filename':'Legacy receipt',
    };
    final settings={'templateAssets':{'receipt':manifest}};
    expect(WindowsTemplateCloudStore.importedTemplates(settings,'receipt').single,
      manifest);
    expect(WindowsTemplateCloudStore.importedAsset(settings,'receipt')?['sourceHash'],
      'legacy-hash');
  });


  test('catalog indexes exclude foreign, unapproved and wrong-kind templates',(){
    const school='vs-db8afb01a3be46a983c8284714d06e5d';
    const foreign='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final settings={
      'templateAssetLatest':{'receipt':'good-new'},
      'templateAssets':{'receipt':{
        'unapproved':{'approved':false,'schoolId':school,'kind':'receipt',
          'templateId':'unapproved','filename':'Draft'},
        'foreign':{'approved':true,'schoolId':foreign,'kind':'receipt',
          'templateId':'foreign','filename':'Another school'},
        'wrong-kind':{'approved':true,'schoolId':school,'kind':'payslip',
          'templateId':'wrong-kind','filename':'Salary slip'},
        'good-old':{'approved':true,'schoolId':school,'kind':'receipt',
          'templateId':'good-old','filename':'Old receipt'},
        'good-new':{'approved':true,'schoolId':school,'kind':'receipt',
          'templateId':'good-new','filename':'New receipt'},
      }},
    };
    final visible=WindowsTemplateCloudStore.availableSchoolTemplates(
      settings,'receipt',school);
    expect(visible.map((v)=>v['templateId']).toList(),
      ['good-new','good-old']);
    expect(WindowsTemplateCloudStore.availableSchoolTemplates(
      settings,'receipt',foreign).map((v)=>v['templateId']).toList(),
      ['foreign']);
    expect(WindowsTemplateCloudStore.availableSchoolTemplates(
      settings,'receipt','../other'),isEmpty);
  });

  test('foreign-school documents are rejected before downloaded templates are used',(){
    const school='vs-db8afb01a3be46a983c8284714d06e5d';
    const other='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    expect(()=>WindowsTemplateCloudStore.verifyRecordSchool(
      {'schoolId':school,'studentName':'Mira'},school),returnsNormally);
    expect(()=>WindowsTemplateCloudStore.verifyRecordSchool(
      {'studentName':'Mira'},school),returnsNormally);
    expect(()=>WindowsTemplateCloudStore.verifyRecordSchool(
      {'schoolId':other,'studentName':'Foreign student'},school),throwsStateError);
    expect(()=>WindowsTemplateCloudStore.verifyRecordSchool(
      {'schoolId':school},'../invalid'),throwsStateError);
  });

  test('Drive image reuse is restricted by verified school and file identity',(){
    const school='vs-db8afb01a3be46a983c8284714d06e5d';
    const other='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const hash='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final asset=<String,dynamic>{
      'schoolId':school,'kind':'receipt','approved':true,
      'contentHash':hash,'fileId':'school_asset_123',
      'fileUrl':'https://drive.google.com/file/d/school_asset_123/view',
    };
    bool reusable(Map<String,dynamic> item)=>
      WindowsTemplateCloudStore.canReuseVerifiedAsset(item,
        schoolId:school,kind:'receipt',contentHash:hash);
    expect(reusable(asset),isTrue);
    expect(reusable({...asset,'schoolId':other}),isFalse);
    expect(reusable({...asset,'kind':'reportCard'}),isFalse);
    expect(reusable({...asset,'approved':false}),isFalse);
    expect(reusable({...asset,'contentHash':'other'}),isFalse);
    expect(reusable({...asset,'fileId':'another_file'}),isFalse);
    expect(reusable({...asset,
      'fileUrl':'https://other.example/file/d/school_asset_123/view'}),
      isFalse);
  });

  test('1/2/5-device upload history retains every version and rollback',(){
    const school='vs-db8afb01a3be46a983c8284714d06e5d';
    Map<String,dynamic> history={};
    for(var device=1;device<=5;device++){
      final id='sha-from-pc-$device';
      history=WindowsTemplateCloudStore.appendedVersionHistory(
        history,id,{
          'version':1,'approved':true,'schoolId':school,
          'kind':'receipt','sourceHash':id,'contentHash':'hash-$device',
          'templateId':id,'filename':'PC $device',
        });
      expect(history.length,device);
      expect(history.keys,contains('sha-from-pc-1'));
    }
    final initial={'templateAssets':{'receipt':history},
      'receipt':'imported:sha-from-pc-1'};
    expect(WindowsTemplateCloudStore.importedAsset(initial,'receipt')
      ?['templateId'],'sha-from-pc-1');
    expect(WindowsTemplateCloudStore.containsExpectedVersions(
      initial,'receipt',history.keys),isTrue);
    // Idempotent retry never adds a duplicate manifest or drops a version.
    final old=Map<String,dynamic>.from(history['sha-from-pc-3'] as Map);
    final retried=WindowsTemplateCloudStore.appendedVersionHistory(
      history,'sha-from-pc-3',old);
    expect(retried.length,5);
    expect(retried.keys.toList(),history.keys.toList());
    expect(()=>WindowsTemplateCloudStore.appendedVersionHistory(
      history,'sha-from-pc-1',{...old,'templateId':'sha-from-pc-1'}),
      throwsStateError,reason:'An immutable rollback version cannot be overwritten');
  });

  test('history capacity rejects uploads rather than evicting rollback copies',(){
    Map<String,dynamic> history={};
    for(var n=0;n<WindowsTemplateCloudStore.maxStoredVersions;n++){
      history=WindowsTemplateCloudStore.appendedVersionHistory(
        history,'v-$n',{'version':1,'sourceHash':'v-$n',
          'contentHash':'hash-$n','schoolId':'school',
          'kind':'receipt','templateId':'v-$n'});
    }
    final last=Map<String,dynamic>.from(history['v-0'] as Map);
    expect(()=>WindowsTemplateCloudStore.appendedVersionHistory(
      history,'v-overflow',{...last,'templateId':'v-overflow',
        'sourceHash':'v-overflow','contentHash':'different'}),
      throwsStateError);
    expect(history.keys.first,'v-0');
    expect(history.length,WindowsTemplateCloudStore.maxStoredVersions);
  });

  test('five-device manifest ACK simulation detects lost peer updates',(){
    const school='vs-db8afb01a3be46a983c8284714d06e5d';
    final assets=<String,dynamic>{
      for(var device=1;device<=5;device++)
        'pc-$device':{
          'templateId':'pc-$device','schoolId':school,
          'kind':'receipt','approved':true,
        },
    };
    final all={'templateAssets':{'receipt':assets},
      'receipt':'imported:pc-2',
      'templateAssetLatest':{'receipt':'pc-5'}};
    expect(WindowsTemplateCloudStore.containsExpectedVersions(
      all,'receipt',assets.keys),isTrue);
    final stale={'templateAssets':{'receipt':{
      'pc-1':assets['pc-1'],'pc-2':assets['pc-2'],'pc-5':assets['pc-5'],
    }}};
    expect(WindowsTemplateCloudStore.containsExpectedVersions(
      stale,'receipt',assets.keys),isFalse);
    // A newly published file must not silently change the active school
    // selection, and a rollback must still find the older version.
    expect(WindowsTemplateCloudStore.importedAsset(
      all,'receipt')?['templateId'],'pc-2');
    expect(WindowsTemplateCloudStore.importedAsset(
      all,'receipt',templateId:'pc-1')?['templateId'],'pc-1');
  });

  test('unknown template version and school type return no assets',(){
    expect(WindowsTemplateCloudStore.importedTemplates(
      {'templateAssets':{'receipt':{'unknown':'not-a-manifest'}}},'receipt'),isEmpty);
    expect(WindowsTemplateCloudStore.importedTemplates(
      {'templateAssets':{'payslip':{'one':{'templateId':'one'}}}},'receipt'),isEmpty);
  });
}
