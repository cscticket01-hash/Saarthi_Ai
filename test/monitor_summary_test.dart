import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/platform/monitor_summary.dart';

void main() {
  test('10 school summaries represent 30000 registered students without storing their sessions', () {
    const now=1800000000000;
    final schools=List.generate(10,(i)=><String,dynamic>{'id':'school-$i',
      'lastSeenAt':now,'studentCount':3000,'studentAppUsers':3000,'onlineStudents':30,
      'purchased':true,'licenseExpiresAt':now+7*86400000});
    final result=monitorSummary(schools,now);
    expect(result['totalSchools'],10);expect(result['totalStudents'],30000);
    expect(result['studentAppUsers'],30000);expect(result['onlineStudents'],300);
    expect(result['purchasedSchools'],10);expect(result['expiringSchools'],10);
  });
  test('stale summaries clear online counts and separate inactive and expired schools', () {
    const now=1800000000000;
    final result=monitorSummary([
      {'lastSeenAt':now-11*60000,'onlineStudents':100,'licenseExpiresAt':now-1},
      {'lastSeenAt':now-2*86400000,'reportedAt':now,'onlineStudents':100,'licenseExpiresAt':now+30*86400000},
    ],now);
    expect(result['onlineStudents'],0);expect(result['activeSchools'],1);
    expect(result['inactiveSchools'],1);expect(result['expiringSchools'],0);
  });
}
