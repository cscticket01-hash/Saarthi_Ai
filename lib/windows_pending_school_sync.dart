import 'windows_local_firestore.dart';

/// Publish the durable queue for one immutable local school profile.
/// Failure leaves the queued record intact; acknowledgement is version-checked.
class WindowsPendingSchoolSync {
  static Future<void> flush({required String profileId,
    required Future<void> Function(String collection, String id, String operation, Map<String,dynamic>? data) send}) async {
    final db=FirebaseFirestore.instance;
    void unchanged() { if(db.activeProfileId != profileId) throw StateError('School changed during sync.'); }
    unchanged();
    final snapshot=await db.collection('_windows_firebase_outbox').get();
    unchanged();
    int time(Map<String,dynamic> d) {
      final value=d['queuedAt'];
      return value is Timestamp ? value.millisecondsSinceEpoch : value is num ? value.toInt() : 0;
    }
    final docs=snapshot.docs.toList()..sort((a,b)=>time(a.data()).compareTo(time(b.data())));
    for(final queued in docs) {
      unchanged();queued.reference.requireOriginProfile();
      final item=queued.data();
      final collection=item['collection']?.toString()??'';
      final id=item['documentId']?.toString()??'';
      final operation=item['operation']?.toString()??'';
      final raw=item['data'];
      if(collection.isEmpty || id.isEmpty || !{'set','update','delete'}.contains(operation) || operation != 'delete' && raw is! Map) {
        throw StateError('Invalid pending sync record retained for recovery.');
      }
      await send(collection,id,operation,raw is Map?Map<String,dynamic>.from(raw):null);
      unchanged();
      await db.acknowledgeOutbox(queued.reference,item);
    }
  }
}
