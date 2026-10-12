import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_sync_comparison.dart';
void main() {
  final row = {'schoolId':'school-a', 'documentRevision':'operation-a',
    'contentHash':'a'*64, 'studentId':'student-a', 'documentName':'ID'};
  test('exact replay is idempotent, metadata or bytes divergence is not', () {
    expect(identicalDocumentPayload(row, {...row, '_syncRevision':'receipt'}), isTrue);
    for (final changed in [ {'contentHash':'b'*64}, {'studentId':'other'},
      {'documentName':'changed'}, {'schoolId':'other'}, {'_syncDeleted':true} ]) {
      expect(identicalDocumentPayload(row, {...row, ...changed}), isFalse);
    }
  });
  test('canonical comparison ignores key order, never invents revision ordering', () {
    final local = {'schoolId':'s', 'amount':100};
    expect(compareSyncVersions({'schoolId':'s','data':local},
      {'amount':100,'schoolId':'s','_syncRevision':'uuid'}), 'identical');
    expect(compareSyncVersions({'schoolId':'s','data':local},
      {'amount':200,'schoolId':'s','_syncRevision':'uuid'}), contains('differs'));
  });
}
