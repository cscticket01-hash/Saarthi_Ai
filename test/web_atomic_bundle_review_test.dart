import 'package:flutter_test/flutter_test.dart';
import '../lib/live_sync_protocol.dart';
import '../lib/web_atomic_bundle_review.dart';

void main(){
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',bundle='atomic-web-person-card-0001';
 final group=<Map<String,dynamic>>[
  {'sequence':1,'collection':'students_directory','id':'person',
    'bundleId':bundle,'bundleSize':2,'bundleIndex':0,
    'record':{'schoolId':school,'mobileStableId':'p-generation',
      '_syncRevision':'live-person-one'}},
  {'sequence':2,'collection':'documents','id':'card',
    'bundleId':bundle,'bundleSize':2,'bundleIndex':1,
    'record':{'schoolId':school,'personId':'p-generation','studentId':'person',
      'ownerRole':'student','bundleId':bundle,'bundleManifestHash':'c'*64,
      'bundleMedia':[{'kind':'idCard','sha256':'d'*64}],
      '_syncRevision':'live-card-one'}},
 ];
 LiveSyncPage parse(List<Map<String,dynamic>> records)=>LiveSyncPage.parse({
  'success':true,'liveProtocol':1,'schoolId':school,
  'cursor':records.length,'head':records.length,
  'more':false,'events':records},school,0);
 test('TEST Web renders a complete same-school person/card atomically',(){
   final r=verifyWebAtomicBundles(school,[parse(group)]);
   expect(r.length,1);expect(r.single.personId,'person');
   expect(r.single.documentId,'card');expect(r.single.cardSha256,'d'*64);
 });
 test('TEST Web never accepts partial, mismatched or foreign group',(){
   expect(()=>parse(group.sublist(0,1)),throwsStateError);
   final forged=[...group.map((e)=>Map<String,dynamic>.from(e))];
   forged[1]['record']={...(forged[1]['record'] as Map),'personId':'other'};
   expect(()=>verifyWebAtomicBundles(school,[parse(forged)]),throwsStateError);
   expect(()=>verifyWebAtomicBundles('vs-'+'b'*32,[parse(group)]),throwsStateError);
 });
}
