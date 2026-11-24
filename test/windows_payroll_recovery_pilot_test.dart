import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_payroll_recovery_pilot.dart';

void main(){
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',bundle='payroll-bundle-test-00001';
  final ops=[{'operationId':'salary-original-op'},{'operationId':'advance-original-op'}];
  final ack={'schoolId':school,'bundleProtocol':1,'bundleId':bundle,'cloudState':'committed',
    'acknowledgements':[
      {'operationId':'salary-original-op','recordRevision':'live-salary','cloudState':'committed'},
      {'operationId':'advance-original-op','recordRevision':'live-advance','cloudState':'committed'},
    ]};
  test('paired Cloudflare acknowledgement requires both original operation identities',(){
    expect(WindowsPayrollRecoveryPilot.verifiedCloud(ack,school,bundle,ops),true);
    expect(WindowsPayrollRecoveryPilot.verifiedCloud(ack,'other-school',bundle,ops),false);
    expect(WindowsPayrollRecoveryPilot.verifiedCloud(ack,school,'other-bundle',ops),false);
    expect(WindowsPayrollRecoveryPilot.verifiedCloud({...ack,'acknowledgements':[(ack['acknowledgements'] as List).first]},school,bundle,ops),false);
    expect(WindowsPayrollRecoveryPilot.verifiedCloud({...ack,'acknowledgements':(ack['acknowledgements'] as List).reversed.toList()},school,bundle,ops),false);
  });
  test('local preview or receipt without committed authority cannot acknowledge a pair',(){
    expect(WindowsPayrollRecoveryPilot.verifiedCloud({...ack,'cloudState':'pending'},school,bundle,ops),false);
    expect(WindowsPayrollRecoveryPilot.verifiedCloud({...ack,'acknowledgements':[
      {'operationId':'salary-original-op','recordRevision':'drive-salary','cloudState':'committed'},
      {'operationId':'advance-original-op','recordRevision':'live-advance','cloudState':'committed'},
    ]},school,bundle,ops),false);
  });
}
