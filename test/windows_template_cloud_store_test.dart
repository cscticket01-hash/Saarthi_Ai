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

  test('unknown template version and school type return no assets',(){
    expect(WindowsTemplateCloudStore.importedTemplates(
      {'templateAssets':{'receipt':{'unknown':'not-a-manifest'}}},'receipt'),isEmpty);
    expect(WindowsTemplateCloudStore.importedTemplates(
      {'templateAssets':{'payslip':{'one':{'templateId':'one'}}}},'receipt'),isEmpty);
  });
}
