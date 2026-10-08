import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_connect/managed_school_session.dart';
void main() {
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const url = 'https://script.google.com/macros/s/SchoolDeployment/exec';
  test('storage readiness requires real success, readiness and the same school', () {
    for (final result in <Map<String,dynamic>>[
      {}, {'success':true,'schoolId':school,'storageReady':false},
      {'success':false,'schoolId':school,'storageReady':true},
      {'success':true,'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','storageReady':true},
    ]) {
      expect(() => ManagedSchoolSession.verifyStorageResponse(result,school),throwsStateError);
    }
    expect(() => ManagedSchoolSession.verifyStorageResponse({'success':true,'schoolId':school,'storageReady':true},school),returnsNormally);
  });
  test('connection must verify the exact deployment pasted in Settings', () {
    final result = {'success':true,'schoolId':school,'storageReady':true,'scriptUrl':url};
    expect(() => ManagedSchoolSession.verifyStorageResponse(result,school,scriptUrl:url),returnsNormally);
    expect(() => ManagedSchoolSession.verifyStorageResponse({...result,'scriptUrl':'https://script.google.com/macros/s/OtherSchool/exec'},school,scriptUrl:url),throwsStateError);
  });
}
