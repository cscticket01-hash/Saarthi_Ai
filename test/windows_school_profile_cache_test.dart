import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/school_profile_policy.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cache readback cannot replace a queued school profile or generate another operation', () async {
    final db = FirebaseFirestore.instance;
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('cache-fixture',identity:{'schoolSyncId':'school-a'});
    final ref = db.collection('school_config').doc('school_profile_cache');
    expect(() => requireSchoolProfile({'logoFileId':'asset'}),throwsA(isA<BlankSchoolProfile>()));
    await ref.set({'logoFileId':'legacy-asset'});
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    expect((await ref.get()).data()?['logoFileId'],'legacy-asset');
    await ref.set({'schoolName':'Unsent local school','principalName':'Principal','schoolContactNo':'123'});
    final original = (await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    await db.applySyncedDocument(ref, {'schoolName':'Old cloud school','principalName':'Old','schoolContactNo':'456'});
    expect((await ref.get()).data()?['schoolName'],'Unsent local school');
    final retained=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    expect(retained['operationId'],original['operationId']);
    expect(retained['data'],original['data']);
    expect((retained['queuedAt'] as Timestamp).millisecondsSinceEpoch,(original['queuedAt'] as Timestamp).millisecondsSinceEpoch);
    await ref.update({'schoolName':''});
    expect((await ref.get()).data()?['schoolName'],'Unsent local school');
  });
}
