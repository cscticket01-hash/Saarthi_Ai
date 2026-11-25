import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_local_firestore.dart' as local;
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_support_history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = local.FirebaseFirestore.instance;
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  Future<Map<String,dynamic>> identity() async =>
      {'managed':true,'schoolId':school,'uid':'test-admin'};
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('support-${DateTime.now().microsecondsSinceEpoch}', identity: {'schoolSyncId':school});
  });

  test('offline request survives client recreation; wrong receipt cannot clear queue', () async {
    final offline = SchoolSupportClient(readIdentity:identity, request: (_,a,b) async {
      throw StateError('Network unavailable');
    });
    final sent = await offline.send('Synthetic support ticket', 'test');
    expect(sent,false);
    final pending = (await offline.pending()).single;
    final id = pending['id'];
    final invalid = SchoolSupportClient(readIdentity:identity, request: (_,a,b) async =>
      {'success':true,'schoolId':school,'complaintId':'wrong'});
    await invalid.flushPending();
    expect((await invalid.pending()).single['id'],id);
    final recovered = SchoolSupportClient(readIdentity:identity, request: (_,a,b) async {
      expect(b['complaintId'],id);
      expect(b['message'],'Synthetic support ticket');
      return {'success':true,'schoolId':school,'complaintId':id};
    });
    await recovered.flushPending();
    expect(await recovered.pending(),isEmpty);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  });

  test('new complaint is not blocked by another pending complaint; profile change is rejected', () async {
    final client = SchoolSupportClient(readIdentity:identity, request: (_,a,b) async {
      throw StateError('Offline');
    });
    await client.send('Original support ticket','test');
    await client.send('Another support ticket','test');
    expect(await client.pending(),hasLength(2));
    await db.switchProfile('foreign-test', identity:{'schoolSyncId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'});
    await expectLater(client.flushPending(),throwsStateError);
    expect((await db.collection('_windows_support_outbox').get()).docs,isEmpty);
  });
}
