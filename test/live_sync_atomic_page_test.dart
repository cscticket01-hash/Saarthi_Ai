import 'package:flutter_test/flutter_test.dart';
import '../lib/live_sync_protocol.dart';

void main(){
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const bundle='sync3-complete-person-card-0001';
  Map<String,dynamic> item(int sequence,String collection,String id,
      {int? index,int? size,String bundleId=bundle}) => {
    'sequence':sequence,'collection':collection,'id':id,
    'record':{'schoolId':school,'_syncRevision':'live-$sequence'},
    if(index!=null)...{'bundleId':bundleId,'bundleSize':size,'bundleIndex':index}
  };
  Map<String,dynamic> page(List<Map<String,dynamic>> events,{int after=0,int? head}) => {
    'success':true,'liveProtocol':1,'schoolId':school,
    'events':events,'cursor':after+events.length,
    'head':head??after+events.length,
    'more':(head??after+events.length)>after+events.length,
  };
  test('complete Person + ID document is accepted as one replay page',(){
    final result=LiveSyncPage.parse(page([
      item(1,'students_directory','s1',index:0,size:2),
      item(2,'documents','id1',index:1,size:2),
    ]),school,0);
    expect(result.events.map((e)=>e['bundleIndex']),[0,1]);
    expect(result.cursor,2);
  });
  test('page splitting a bundle cannot advance a checkpoint',(){
    expect(()=>LiveSyncPage.parse(page([
      item(1,'students_directory','s1',index:0,size:2),
    ],head:2),school,0),throwsStateError);
    expect(()=>LiveSyncPage.parse(page([
      item(2,'documents','id1',index:1,size:2),
    ],after:1),school,1),throwsStateError);
  });
  test('tampered group order, identity and size fail closed',(){
    final first=item(1,'students_directory','s1',index:0,size:2);
    for(final second in [
      item(2,'documents','id1',index:0,size:2),
      item(2,'documents','id1',index:1,size:3),
      item(2,'documents','id1',index:1,size:2,bundleId:'another-bundle-identity-0001'),
      item(2,'documents','id1'),
    ]) {
      expect(()=>LiveSyncPage.parse(page([first,second]),school,0),throwsStateError);
    }
    final bad=item(1,'students_directory','s1',index:0,size:2);
    bad['bundleId']='bad!';
    expect(()=>LiveSyncPage.parse(page([
      bad,item(2,'documents','id1',index:1,size:2),
    ]),school,0),throwsStateError);
  });
  test('legacy ordinary records remain compatible',(){
    final response=LiveSyncPage.parse(page([
      item(1,'school_expenses','one'),item(2,'school_notices','two'),
    ]),school,0);
    expect(response.events.length,2);
  });
}
