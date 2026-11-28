import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/global_id_card_offline_policy.dart';
void main(){
  final row=<String,dynamic>{'id':'gid-${List.filled(32,'a').join()}','name':'Synthetic','kind':'studentId',
    'state':'published','mappingState':'verified','accessType':'free','pricePaise':0,'unlocked':true,
    'version':2,'packageSha256':List.filled(64,'b').join()};
  Map<String,dynamic> lease()=>{'success':true,'schoolId':'school','uid':'account','paymentEnabled':false,
    'serverTime':1000000,'expiresAt':2000000,'templates':[Map<String,dynamic>.of(row)]};
  bool valid(Map<String,dynamic> d,{String school='school',String uid='account',int now=1500000})=>
    GlobalIdCardOfflinePolicy.valid(d,school:school,uid:uid,nowMs:now);
  test('free cached lease is school/account/time bounded',(){
    expect(valid(lease()),true);expect(valid(lease(),uid:'other'),false);
    expect(valid(lease(),school:'other'),false);expect(valid(lease(),now:2000000),false);
    expect(valid(lease(),now:1),false);
    expect(valid({...lease(),'expiresAt':1000000+GlobalIdCardOfflinePolicy.maxOfflineMs+1}),false);
  });
  test('exact free package only; never premium, foreign version or changed hash',(){
    bool has(Map<String,dynamic> d,int v,String h)=>GlobalIdCardOfflinePolicy.contains(d,id:row['id'],version:v,hash:h);
    expect(has(lease(),2,row['packageSha256']),true);
    expect(has(lease(),1,row['packageSha256']),false);
    expect(has(lease(),2,List.filled(64,'c').join()),false);
    expect(has({...lease(),'templates':[{...row,'accessType':'premium'}]},2,row['packageSha256']),false);
    expect(valid({...lease(),'templates':[row,row]}),false);
  });
}
