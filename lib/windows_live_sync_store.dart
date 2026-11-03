import 'live_sync_protocol.dart';
import 'windows_local_firestore.dart';

class WindowsLiveSyncStore implements LiveSyncStore {
  WindowsLiveSyncStore(this.db);
  final FirebaseFirestore db;
  @override Future<int> cursor(String school) async {
    if(db.activeProfileIdentity['schoolSyncId']!=school) {
      throw StateError('Live checkpoint school differs.');
    }
    final ref=db.collection('_windows_live_checkpoints').doc(school);
    final row=(await ref.get()).data();ref.requireOriginProfile();
    if(row==null)return 0;
    final cursor=row['cursor'];
    if(row['schoolId']!=school||cursor is! int||cursor<0) {
      throw StateError('Live checkpoint needs recovery.');
    }
    return cursor;
  }
  @override Future<void> retainPage(LiveSyncPage page)=>db.retainLiveSyncPage(page);
}
