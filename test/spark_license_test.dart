import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saarthi_ai/platform/spark_client.dart';

void main(){
  SparkLicenseClient client({String school='school-one',bool revoked=false,
    String expiry='2026-10-10T00:00:00Z',bool trial=false})=>SparkLicenseClient(client:MockClient((request)async=>request.url.path.contains('/platform_school_blocks/') ? http.Response('{}',404) : http.Response(jsonEncode({'fields':{
      if(!trial) 'schoolId':{'stringValue':school},
      if(!trial) 'revoked':{'booleanValue':revoked},
      if(!trial) 'expiresAt':{'timestampValue':expiry},
      if(trial) 'createdAt':{'timestampValue':'2026-09-26T00:00:00Z'},
    }}),200,headers:{'date':'Fri, 02 Oct 2026 04:00:00 GMT'})));
  final hash=List.filled(64,'a').join();
  test('a developer school block denies both trial and licensed access before licence lookup',()async{
    for(final licence in [null,hash]) {
      var calls=0;
      final c=SparkLicenseClient(client:MockClient((request)async{
        calls++;
        expect(request.url.path,endsWith('/platform_school_blocks/school-one'));
        return http.Response(jsonEncode({'fields':{'blocked':{'booleanValue':true}}}),200,
          headers:{'date':'Fri, 02 Oct 2026 04:00:00 GMT'});
      }));
      final status=await c.schoolStatus('school-one',licenseHash:licence);
      expect(status['allowed'],false);expect(status['status'],'blocked');expect(calls,1);
      c.close();
    }
  });
  test('an explicit unblock still requires a valid licence',()async{
    final c=SparkLicenseClient(client:MockClient((request)async{
      if(request.url.path.contains('/platform_school_blocks/')) {
        return http.Response(jsonEncode({'fields':{'blocked':{'booleanValue':false}}}),200,
          headers:{'date':'Fri, 02 Oct 2026 04:00:00 GMT'});
      }
      return http.Response('{}',404);
    }));
    expect((await c.schoolStatus('school-one',licenseHash:hash))['allowed'],false);
    c.close();
  });
  test('malformed block flags fail closed and never proceed to licence lookup',()async{
    for(final body in ['invalid','[]','{}',jsonEncode({'fields':{'blocked':{'booleanValue':'false'}}}),jsonEncode({'fields':{'blocked':[]}})]) {
      var calls=0;
      final c=SparkLicenseClient(client:MockClient((_)async{
        calls++;return http.Response(body,200,headers:{'date':'Fri, 02 Oct 2026 04:00:00 GMT'});
      }));
      await expectLater(c.schoolStatus('school-one',licenseHash:hash),throwsA(isA<LicenseVerificationRejected>()));
      expect(calls,1);c.close();
    }
  });
  test('block service failures do not skip the developer check',()async{
    final c=SparkLicenseClient(client:MockClient((_)async=>http.Response('{}',503)));
    await expectLater(c.schoolStatus('school-one',licenseHash:hash),throwsStateError);
    c.close();
  });
  test('deleted central licences fail closed rather than becoming an offline network error',()async{
    final c=SparkLicenseClient(client:MockClient((_)async=>http.Response('{}',404)));
    final status=await c.schoolStatus('school-one',licenseHash:hash);
    expect(status['allowed'],false); expect(status['status'],'blocked'); expect(status['licenseHash'],hash); c.close();
  });
  test('malformed central responses cannot activate a licence',()async{
    for(final body in ['invalid','[]',jsonEncode({'fields':{'schoolId':{'stringValue':'school-one'},'revoked':{'booleanValue':false}}})]) {
      final c=SparkLicenseClient(client:MockClient((_)async=>http.Response(body,200,headers:{'date':'Fri, 02 Oct 2026 04:00:00 GMT'})));
      await expectLater(c.schoolStatus('school-one',licenseHash:hash),throwsA(isA<LicenseVerificationRejected>()));c.close();
    }
  });
  test('Windows verifies the actual school on the developer-controlled licence',()async{
    final c=client(school:'school-two');
    await expectLater(c.schoolStatus('school-one',licenseHash:hash),throwsStateError);c.close();
  });
  test('revoked and expired developer records cannot be replaced by a school-script lease',()async{
    for(final c in [client(revoked:true),client(expiry:'2026-10-01T00:00:00Z')]){
      expect((await c.schoolStatus('school-one',licenseHash:hash))['allowed'],false);c.close();
    }
  });
  test('trial expiry uses immutable Firebase creation time, not the school response',()async{
    final c=client(trial:true);final status=await c.schoolStatus('school-one');
    expect(status['allowed'],false);expect(status['status'],'expired');c.close();
  });
  test('valid school licence includes independently verified server time',()async{
    final c=client();final status=await c.schoolStatus('school-one',licenseHash:hash);
    expect(status['allowed'],true);expect(status['status'],'licensed');
    expect(status['serverTime'],DateTime.utc(2026,10,2,4).millisecondsSinceEpoch);c.close();
  });
}
