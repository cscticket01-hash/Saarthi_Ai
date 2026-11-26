import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_template_feature_access.dart';
void main(){
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',uid='test-account',now=1800000000000;
 Map<String,dynamic> policy({bool paid=true,bool global=true})=>{'success':true,'schoolId':school,
  'uid':uid,'customTemplates':paid,'uploadEnabled':global,'serverTime':now,'expiresAt':now+86400000};
 TemplateFeatureAccess access(Map<String,dynamic> data,{bool online=true,int at=now,String account=uid})=>
  WindowsTemplateFeatureAccess.decode(data,school:school,uid:account,nowMs:at,online:online);
 test('global maintenance never disables paid existing template use',(){
  final result=access(policy(global:false));
  expect(result.canUse,isTrue);expect(result.canUpload,isFalse);
  expect(result.uploadExplanation,contains('maintenance'));
 });
 test('school paid access is independent; offline use expires and uploads require online',(){
  expect(access(policy(paid:false)).canUse,isFalse);
  expect(access(policy(),online:false).canUse,isTrue);
  expect(access(policy(),online:false).canUpload,isFalse);
  expect(access(policy(),at:now+86400000).canUse,isFalse);
  expect(access(policy(),account:'another-account').canUse,isFalse);
  expect(access({...policy(),'schoolId':'foreign'}).canUse,isFalse);
  expect(access({...policy(),'expiresAt':now+86400001}).canUse,isFalse);
 });
}
