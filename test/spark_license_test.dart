import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saarthi_ai/platform/spark_client.dart';

void main(){
  SparkLicenseClient client({String school='school-one',bool revoked=false,
    String expiry='2026-10-10T00:00:00Z',bool trial=false})=>SparkLicenseClient(client:MockClient((request)async=>http.Response(jsonEncode({'fields':{
      if(!trial) 'schoolId':{'stringValue':school},
      if(!trial) 'revoked':{'booleanValue':revoked},
      if(!trial) 'expiresAt':{'timestampValue':expiry},
      if(trial) 'createdAt':{'timestampValue':'2026-09-26T00:00:00Z'},
    }}),200,headers:{'date':'Fri, 02 Oct 2026 04:00:00 GMT'})));
  final hash=List.filled(64,'a').join();
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
