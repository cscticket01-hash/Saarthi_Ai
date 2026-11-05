import 'dart:async';
import 'windows_connect/central_school_cloud.dart';

import 'live_sync_protocol.dart';
import 'windows_live_sync_store.dart';
import 'windows_local_firestore.dart';

/// Retained delivery hints are not canonical business records or upload ACKs.
class WindowsLiveIncoming {
  const WindowsLiveIncoming(this.key, this.sequence, this.collection, this.id,
      {this.bundleId, this.bundleSize=0, this.bundleIndex=-1});
  final String key, collection, id;
  final int sequence;
  final String? bundleId;
  final int bundleSize, bundleIndex;
}

abstract interface class WindowsLiveRuntimeStore implements LiveSyncStore {
  Future<List<WindowsLiveIncoming>> pending();
  /// Called only after the ordinary sync owner verified current business state.
  Future<void> applied(List<WindowsLiveIncoming> entries);
  Future<void> replaceCheckpoint(int expectedCursor, int nextCursor,
      [Set<String>? verifiedCollections]);
}

/// Uses the existing local serialized disk writer. Cursor retention and pending
/// upload protection remain owned by their existing implementations.
class WindowsLiveRuntimeLocalStore implements WindowsLiveRuntimeStore {
  WindowsLiveRuntimeLocalStore(this.db, this.school, this.profile)
      : delivery = WindowsLiveSyncStore(db);
  final FirebaseFirestore db;
  final String school, profile;
  final WindowsLiveSyncStore delivery;
  void _check() {
    if (db.activeProfileId != profile ||
        db.activeProfileIdentity['schoolSyncId'] != school) {
      throw StateError('Live runtime profile changed; incoming work retained.');
    }
  }
  @override Future<int> cursor(String school) async {
    _check();
    final value = await delivery.cursor(school);
    _check(); return value;
  }
  @override Future<void> retainPage(LiveSyncPage page) async {
    _check(); await delivery.retainPage(page); _check();
  }
  @override Future<List<WindowsLiveIncoming>> pending() async {
    _check();
    final rows = await db.collection('_windows_live_incoming').get();
    _check();
    final incoming = <WindowsLiveIncoming>[];
    for (final row in rows.docs) {
      final value = row.data(), sequence = value['sequence'];
      if (value['schoolId'] != school || value['state'] != 'retained' ||
          sequence is! int || sequence < 1 || row.id != '$school-$sequence') {
        throw StateError('Live incoming identity needs review; work retained.');
      }
      final event = <String, dynamic>{
        'sequence': sequence, 'collection': value['collection'], 'id': value['id'],
        'record': value['record'],
        if (value['retired'] == true) ...{
          'retired': true, 'source': value['source'],
          'recordAuthority': value['recordAuthority'],
        },
      };
      LiveSyncPage.parse({'success': true, 'liveProtocol': 1, 'schoolId': school,
        'cursor': sequence, 'head': sequence, 'more': false, 'events': [event]},
        school, sequence - 1);
      final bundleId=value['bundleId'];
      if(bundleId!=null &&
          (bundleId is! String ||
           !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(bundleId) ||
           value['bundleSize'] is! int || value['bundleIndex'] is! int)) {
        throw StateError('Retained atomic bundle identity invalid.');
      }
      if(bundleId==null &&
          (value.containsKey('bundleSize') || value.containsKey('bundleIndex'))) {
        throw StateError('Orphaned atomic bundle metadata.');
      }
      incoming.add(WindowsLiveIncoming(row.id, sequence,
          value['collection'] as String, value['id'] as String,
          bundleId:bundleId as String?,
          bundleSize:bundleId==null?0:value['bundleSize'] as int,
          bundleIndex:bundleId==null?-1:value['bundleIndex'] as int));
    }
    incoming.sort((a, b) => a.sequence.compareTo(b.sequence));
    // Keep every member of a retained group together when batching work.
    final safe=<WindowsLiveIncoming>[];
    for(var i=0;i<incoming.length;) {
      final first=incoming[i];
      if(first.bundleId==null) {
        if(first.bundleSize!=0||first.bundleIndex!=-1)
          throw StateError('Orphaned incoming bundle metadata.');
        if(safe.length>=100)break;
        safe.add(first);i++;continue;
      }
      final count=first.bundleSize;
      if(count<2||count>5||first.bundleIndex!=0||i+count>incoming.length)
        throw StateError('Atomic bundle incomplete in durable inbox.');
      for(var j=0;j<count;j++) {
        final member=incoming[i+j];
        if(member.bundleId!=first.bundleId||member.bundleSize!=count||
           member.bundleIndex!=j||member.sequence!=first.sequence+j)
          throw StateError('Retained atomic bundle sequence changed.');
      }
      if(safe.isNotEmpty&&safe.length+count>100)break;
      safe.addAll(incoming.sublist(i,i+count));i+=count;
    }
    return safe;
  }
  /// Only the signed school gateway can supply current authoritative rows.
  /// Retained snapshots are identities, not business truth or Drive ACKs.
  Future<bool> reconcileBundle(List<WindowsLiveIncoming> group,
      LiveSyncCall call) async {
    _check();
    if(group.length<2 || group.length>5 ||
        group.first.bundleId==null) {
      throw StateError('Atomic incoming group identity invalid.');
    }
    final rows=<Map<String,dynamic>>[];
    for(var i=0;i<group.length;i++) {
      final entry=group[i];
      if(entry.bundleId!=group.first.bundleId ||
          entry.bundleSize!=group.length || entry.bundleIndex!=i) {
        throw StateError('Atomic incoming group is incomplete.');
      }
      final stored=(await db.collection('_windows_live_incoming')
          .doc(entry.key).get()).data();
      _check();
      if(stored==null || stored['schoolId']!=school ||
          stored['sequence']!=entry.sequence ||
          stored['collection']!=entry.collection || stored['id']!=entry.id ||
          stored['bundleId']!=entry.bundleId ||
          stored['bundleIndex']!=i || stored['bundleSize']!=group.length ||
          stored['record'] is! Map) {
        throw StateError('Retained atomic bundle changed during verification.');
      }
      final verified=await call('managed/live/read',{
        'liveProtocol':1,'schoolId':school,
        'collection':entry.collection,'id':entry.id,
      });
      _check();
      final record=verified['record'];
      if(verified['success']!=true || verified['schoolId']!=school ||
          verified['liveProtocol']!=1 || record is! Map ||
          record['schoolId']!=school ||
          verified['recordRevision']!=stored['record']['_syncRevision'] ||
          record['_syncRevision']!=verified['recordRevision']) {
        // A newer version or a missing Drive readback is not the original
        // group. Keep the durable inbox for ordinary version recovery.
        return false;
      }
      rows.add({'bundleId':entry.bundleId,'bundleSize':group.length,
        'bundleIndex':i,'collection':entry.collection,'id':entry.id,
        'record':Map<String,dynamic>.from(record)});
    }
    try {
      await db.applyVerifiedLiveBundle(school,rows);
    } on StateError catch(error) {
      if(error.toString().contains('held by a local unsent edit') ||
          error.toString().contains('held by an active restore'))return false;
      rethrow;
    }
    _check();
    return true;
  }

  @override Future<void> replaceCheckpoint(int expectedCursor, int nextCursor,
      [Set<String>? verifiedCollections]) async {
    _check();
    await db.replaceLiveSyncCheckpointAfterVerifiedSnapshot(school, expectedCursor, nextCursor,
      verifiedCollections:verifiedCollections);
    _check();
  }
  @override Future<void> applied(List<WindowsLiveIncoming> entries) async {
    _check();
    final batch = db.batch();
    for (final entry in entries) {
      if (entry.key != '$school-${entry.sequence}') {
        throw StateError('Live incoming receipt differs; work retained.');
      }
      batch.delete(db.collection('_windows_live_incoming').doc(entry.key));
    }
    // Completed incoming payloads are compacted. The durable cursor remains;
    // this deletes no business row, local upload, revision or cloud backup.
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(batch.commit);
    _check();
  }
}

class _GuardedLiveStore implements LiveSyncStore {
  _GuardedLiveStore(this.store, this.check);
  final LiveSyncStore store;
  final void Function() check;
  @override Future<int> cursor(String school) async {
    check(); final value = await store.cursor(school); check(); return value;
  }
  @override Future<void> retainPage(LiveSyncPage page) async {
    check(); await store.retainPage(page); check();
  }
}

/// One replay/apply owner for a school+profile. Hints/reconnects only schedule
/// the ordinary Windows sync lane; [run] must execute inside that serial lane.
/// The injected reconciler uses existing authenticated point reads and local
/// apply guards, including pending edits, conflict handling and readback checks.
class WindowsLiveSyncRuntime {
  WindowsLiveSyncRuntime({required this.school, required this.profile,
    required String deviceId, required this.store, required LiveSyncCall call,
    required this.currentSchool, required this.currentProfile,
    required this.canRun, required this.onWork, required this.reconcile,
    this.reconcileBundle, this.recoverSnapshot}) {
    _deviceId=deviceId;
    _call = (action, body) async {
      _check(); final result = await call(action, body); _check(); return result;
    };
    _replay = LiveSyncReplay(schoolId: school, deviceId: deviceId,
      store: _GuardedLiveStore(store, _check), call: _call, currentSchool: currentSchool);
  }
  final String school, profile;
  final WindowsLiveRuntimeStore store;
  final String Function() currentSchool, currentProfile;
  final bool Function() canRun;
  final void Function() onWork;
  final Future<bool> Function(Map<String, Set<String>> targets) reconcile;
  final Future<bool> Function(List<WindowsLiveIncoming>)? reconcileBundle;
  final Future<bool> Function(Set<String> collections)? recoverSnapshot;
  late final String _deviceId;
  late final LiveSyncCall _call;
  late final LiveSyncReplay _replay;
  Future<void>? _flight;
  bool _closed = false, _needsRun = true;
  bool get pendingWork => !_closed && _needsRun;
  void _check() {
    if (_closed || currentSchool() != school || currentProfile() != profile ||
        !canRun()) {
      throw StateError('Live runtime interrupted; incoming work retained.');
    }
  }
  void hint() {
    if (!_closed && currentSchool() == school && currentProfile() == profile &&
        canRun()) { _needsRun = true; onWork(); }
  }
  void markPending() { if(!_closed)_needsRun=true; }
  void reconnect() => hint();
  void close() { _closed = true; _replay.close(); }
  Future<void> run() => _flight ??= _run().whenComplete(() => _flight = null);
  Future<void> _run() async {
    _check();
    try {
      await _replay.pull();
    } on CentralCloudException catch (error) {
      if(error.diagnosticCode!='LIVE_SNAPSHOT_REQUIRED')rethrow;
      if(!await _recoverSnapshot()){_needsRun=false;return;}
    }
    _check();
    while (true) {
      final entries = await store.pending();
      _check();
      if (entries.isEmpty) { _needsRun = false; return; }
      final targets = <String, Set<String>>{};
      final groups=<List<WindowsLiveIncoming>>[];
      for(var i=0;i<entries.length;) {
        final first=entries[i];
        if(!liveSyncCollections.contains(first.collection))
          throw StateError('Live incoming collection is not admitted.');
        if(first.bundleId==null) {
          (targets[first.collection] ??= <String>{}).add(first.id);
          i++;continue;
        }
        final count=first.bundleSize;
        if(count<2||count>5||first.bundleIndex!=0||i+count>entries.length)
          throw StateError('Incoming atomic bundle was split.');
        final members=entries.sublist(i,i+count);
        for(var j=0;j<members.length;j++) {
          final member=members[j];
          if(member.bundleId!=first.bundleId||member.bundleSize!=count||
             member.bundleIndex!=j||member.sequence!=first.sequence+j)
            throw StateError('Incoming bundle membership changed.');
        }
        groups.add(members);i+=count;
      }
      if(targets.isNotEmpty) {
        final verified=await reconcile(targets);
        _check();
        if(!verified){_needsRun=false;return;}
      }
      for(final group in groups) {
        final apply=reconcileBundle;
        // Never fall back to the ordinary per-collection reconciler for
        // grouped events: that could expose Person without ID Card.
        if(apply==null || !await apply(group)) {
          _check();_needsRun=false;return;
        }
        _check();
      }
      await store.applied(entries);
      _check();
      await Future<void>.delayed(Duration.zero);
    }
  }
  Future<bool> _recoverSnapshot() async {
    final recover = recoverSnapshot;
    if(recover==null)throw StateError('Explicit live snapshot recovery is required.');
    _check();
    final expected = await store.cursor(school);
    final head = await _call('managed/live/head', {'liveProtocol':1,'schoolId':school});
    final cursor=head['cursor'], raw=head['collections'];
    if(head['success']!=true || head['schoolId']!=school || head['liveProtocol']!=1 ||
        cursor is! int || cursor<expected || raw is! List) {
      throw StateError('Live recovery head did not verify; checkpoint retained.');
    }
    final collections=<String>{}, states=<String,String>{};
    for(final row in raw) {
      if(row is! Map || !liveSyncCollections.contains(row['collection']) ||
          !{'active','legacy','seeding'}.contains(row['state']) ||
          states.containsKey(row['collection']))
        throw StateError('Live recovery collection did not verify.');
      states[row['collection'] as String]=row['state'] as String;
      if(row['state']=='active'||row['state']=='legacy')collections.add(row['collection'] as String);
    }
    if(collections.isEmpty || !await recover(collections))return false;
    _check();
    final verified = await _call('managed/live/head', {'liveProtocol':1,'schoolId':school});
    final verifiedRows=verified['collections'];
    final verifiedStates=<String,String>{};
    if(verifiedRows is List)for(final row in verifiedRows) {
      if(row is! Map || !liveSyncCollections.contains(row['collection']) ||
          !{'active','legacy','seeding'}.contains(row['state']) ||
          verifiedStates.containsKey(row['collection']))
        throw StateError('Live recovery collection changed; checkpoint retained.');
      verifiedStates[row['collection'] as String]=row['state'] as String;
    }
    if(verified['success']!=true || verified['schoolId']!=school ||
        verified['liveProtocol']!=1 || verified['cursor']!=cursor ||
        verifiedRows is! List || verifiedStates.length!=states.length ||
        states.entries.any((entry)=>verifiedStates[entry.key]!=entry.value)) {
      throw StateError('Live recovery snapshot changed; checkpoint retained.');
    }
    await store.replaceCheckpoint(expected,cursor,collections);
    _check();
    await _call('managed/live/received',{'liveProtocol':1,'schoolId':school,
      'deviceId':_deviceId,'cursor':cursor});
    return true;
  }

}
