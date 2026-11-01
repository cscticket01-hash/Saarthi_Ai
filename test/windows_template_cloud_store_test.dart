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

  test('unknown template version and school type return no assets',(){
    expect(WindowsTemplateCloudStore.importedTemplates(
      {'templateAssets':{'receipt':{'unknown':'not-a-manifest'}}},'receipt'),isEmpty);
    expect(WindowsTemplateCloudStore.importedTemplates(
      {'templateAssets':{'payslip':{'one':{'templateId':'one'}}}},'receipt'),isEmpty);
  });
}
