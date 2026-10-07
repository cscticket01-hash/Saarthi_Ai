import 'windows_local_firestore.dart';

/// Publish the durable queue for one immutable local school profile.
/// Failure leaves the queued record intact; acknowledgement is version-checked.
class WindowsPendingSchoolSync {
  static Future<void> flush({required String profileId,
    required Future<void> Function(String collection, String id, String operation, Map<String,dynamic>? data) send,
    Future<String> Function(Map<String,dynamic> item)? sendVersioned}) async {
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
        await queued.reference.update({'syncState':'needsAttention','lastError':'Invalid pending sync record retained for recovery.'});
        continue;
      }
      if(sendVersioned!=null && (item['operationId']==null || item['schoolId']==null)) {
        final ownSchool=db.activeProfileIdentity['schoolSyncId'];
        if(ownSchool is! String || ownSchool.isEmpty)throw StateError('School identity required for queue migration.');
        item['operationId']='migration-${DateTime.now().microsecondsSinceEpoch}-${queued.id.hashCode.abs()}';
        item['schoolId']=ownSchool;item['baseCloudRevision']=item['baseCloudRevision']??'';
        await queued.reference.update(item);
      }
      if (item['syncState'] == 'conflict' || item['syncState'] == 'needsAttention') continue;
      String? revision;
      try {
        revision = sendVersioned == null ? null : await sendVersioned(item);
        if (sendVersioned == null) await send(collection,id,operation,raw is Map?Map<String,dynamic>.from(raw):null);
      } catch (e) {
        unchanged();
        final latest = (await queued.reference.get()).data();
        if(latest?['operationId'] == item['operationId']) {
          await queued.reference.update({'syncState': e.toString().contains('conflict') ? 'conflict' : 'retry',
            'retryCount':(item['retryCount'] as num? ?? 0).toInt()+1, 'lastError': e.toString()});
        }
        rethrow;
      }
      unchanged();
      await db.acknowledgeOutbox(queued.reference,item,revision:revision);
    }
  }
}
