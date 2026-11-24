import 'dart:convert';
import 'dart:math';

import 'windows_local_firestore.dart';
import 'windows_connect/atomic_bundle_pilot.dart';
import 'windows_connect/managed_school_session.dart';

/// Isolated TEST only. This journal contains original paired intents, not
/// independent salary/loan writes. The existing sync scheduler owns retries.
class WindowsPayrollRecoveryPilot {
  static const journal='_local_payroll_recovery_journal';
  static bool _running=false;
  static String _id()=>base64Url.encode(List<int>.generate(24,(_)=>Random.secure().nextInt(256))).replaceAll('=','');
  static String _key(String collection,String id)=>base64Url.encode(utf8.encode('$collection\\n$id')).replaceAll('=','');
  static void _scope(String profile,String school){
    final db=FirebaseFirestore.instance;
    if(!AtomicBundlePilot.buildEnabled||!ManagedSchoolSession.enabled||
        db.activeProfileId!=profile||db.activeProfileIdentity['schoolSyncId']!=school||
        !RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school))throw StateError('Isolated TEST payroll recovery is unavailable.');
  }
  static Future<String> prepare(String profile,String school,{required String salaryId,required String advanceId,
      required int amountPaise,required String reference})async{
    _scope(profile,school);
    if(amountPaise<=0||reference.trim().isEmpty||reference.length>500)throw ArgumentError('Enter a positive approved recovery and reference.');
    final db=FirebaseFirestore.instance;
    await db.ensureDurableSchoolRecords();_scope(profile,school);
    if(!await db.localPersistenceEnabled())throw StateError('Durable payroll recovery storage required.');
    final salaryRef=db.collection('teacher_salary').doc(salaryId),advanceRef=db.collection('school_settings').doc(advanceId);
    final salary=(await salaryRef.get()).data(),advance=(await advanceRef.get()).data();
    if(salary==null||advance==null||salary['schoolId']!=school||advance['schoolId']!=school||
        salary['staffId']!=advance['staffId']||salary['salaryLocked']==true)throw StateError('Verified same-school salary and advance records required.');
    final staff=salary['staffId'];
    final pendingRef=db.collection(journal).doc(advanceId);
    final pending=(await pendingRef.get()).data();
    if(pending!=null&&pending['state']!='driveVerified')throw StateError('An original recovery is retained. Use Recovery Verification to resume it; do not enter another recovery.');
    final salaryQueue=db.collection('_windows_firebase_outbox').doc(_key('teacher_salary',salaryId)),
        advanceQueue=db.collection('_windows_firebase_outbox').doc(_key('school_settings',advanceId));
    if((await salaryQueue.get()).exists||(await advanceQueue.get()).exists)throw StateError('Wait for original salary and advance ACK before recovery.');
    final bundleId=_id(),eventId=_id(),salaryOperationId=_id(),advanceOperationId=_id();
    final proposal=await ManagedSchoolSession.callForSchool(school,'managed/live/payroll-recovery-preview',{
      'liveProtocol':1,'confirmIsolatedBundleTest':true,'bundleId':bundleId,'eventId':eventId,
      'salaryId':salaryId,'advanceId':advanceId,'salaryOperationId':salaryOperationId,'advanceOperationId':advanceOperationId,
      'amountPaise':amountPaise,'reference':reference.trim(),
    });
    _scope(profile,school);
    final ops=proposal['operations'];
    if(proposal['success']!=true||proposal['schoolId']!=school||proposal['bundleProtocol']!=1||
        proposal['bundleId']!=bundleId||proposal['preview']!=true||ops is! List||ops.length!=2||
        ops.any((e)=>e is! Map))throw StateError('Verified recovery proposal unavailable.');
    final a=ops[0] as Map,b=ops[1] as Map,sa=a['data'],ad=b['data'];
    if(a['collection']!='teacher_salary'||b['collection']!='school_settings'||a['id']!=salaryId||b['id']!=advanceId||
        a['operationId']!=salaryOperationId||b['operationId']!=advanceOperationId||
        a['expectedRevision']!=salary['_syncRevision']||b['expectedRevision']!=advance['_syncRevision']||
        sa is! Map||ad is! Map||sa['schoolId']!=school||ad['schoolId']!=school||
        sa['staffId']!=staff||ad['staffId']!=staff||salary['netPaise'] is! int||advance['balancePaise'] is! int||
        sa['netPaise']!=(salary['netPaise'] as int)-amountPaise||ad['balancePaise']!=(advance['balancePaise'] as int)-amountPaise)
      throw StateError('Recovery proposal differs from verified local salary or loan. Refresh and review.');
    final batch=db.batch();
    batch.requireUnchanged(salaryRef,salary);batch.requireUnchanged(advanceRef,advance);
    batch.requireUnchanged(salaryQueue,null);batch.requireUnchanged(advanceQueue,null);batch.requireUnchanged(pendingRef,pending);
    // Keep the completed previous original before replacing its active slot.
    if(pending!=null)batch.set(db.collection(journal+'_history').doc(pending['bundleId'].toString()),pending);
    batch.set(pendingRef,{'schoolId':school,'staffId':staff,'salaryId':salaryId,'advanceId':advanceId,
      'bundleId':bundleId,'operations':ops,'amountPaise':amountPaise,'state':'pending','createdAt':DateTime.now().millisecondsSinceEpoch});
    await batch.commit();_scope(profile,school);
    return bundleId;
  }
  static Future<int> run(String school,{bool Function()? canAdmit})async{
    if(!AtomicBundlePilot.buildEnabled||!ManagedSchoolSession.enabled||_running)return 0;
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    _scope(profile,school);_running=true;
    var completed=0;
    try{
      final rows=(await db.collection(journal).get()).docs;
      for(final row in rows.take(50)){
        if(canAdmit?.call()==false)break;
        _scope(profile,school);
        final original=row.data(),state=original['state'];
        if(original['schoolId']!=school||!['pending','cloudCommitted'].contains(state))continue;
        final bundleId=original['bundleId'],ops=original['operations'];
        if(bundleId is! String||ops is! List||ops.length!=2||ops.any((op)=>op is! Map))continue;
        final wire={'liveProtocol':1,'confirmIsolatedBundleTest':true,'bundleId':bundleId,'operations':ops};
        try{
          var receipt=await ManagedSchoolSession.callForSchool(school,'managed/live/payroll-recovery-receipt',wire);
          _scope(profile,school);
          if(receipt['success']!=true||receipt['schoolId']!=school||receipt['bundleProtocol']!=1)throw StateError('Recovery receipt identity unverified.');
          if(receipt['found']==false&&state=='pending'){
            if(canAdmit?.call()==false)break;
            final sent=await ManagedSchoolSession.callForSchool(school,'managed/live/payroll-recovery-publish',wire);
            _scope(profile,school);
            if(!verifiedCloud(sent,school,bundleId,ops))throw StateError('Recovery cloud acknowledgement unverified.');
            final batch=db.batch();batch.requireUnchanged(row.reference,original);
            batch.update(row.reference,{'state':'cloudCommitted','cloudReceipt':sent,'cloudAckAt':DateTime.now().millisecondsSinceEpoch});
            await batch.commit();completed++;continue;
          }
          if(receipt['found']!=true||receipt['receipt'] is! Map||
             !verifiedCloud(receipt['receipt'] as Map,school,bundleId,ops))throw StateError('Original recovery receipt unavailable.');
          final proofs=receipt['backups'];
          if(proofs is! List||proofs.length!=2)throw StateError('Both recovery backup proofs required.');
          for(var i=0;i<2;i++){
            final p=proofs[i],op=ops[i] as Map,ack=(receipt['receipt']['acknowledgements'] as List)[i];
            if(p is! Map||p['collection']!=op['collection']||p['id']!=op['id']||
                p['operationId']!=op['operationId']||p['recordRevision']!=ack['recordRevision'])
              throw StateError('Recovery backup identity mismatch.');
          }
          final verified=receipt['driveVerified']==true&&proofs.every((p)=>p['driveVerified']==true&&p['driveRevision'] is String&&(p['driveRevision'] as String).isNotEmpty);
          final batch=db.batch();batch.requireUnchanged(row.reference,original);
          batch.update(row.reference,{'state':verified?'driveVerified':'cloudCommitted','cloudReceipt':receipt['receipt'],
            'backupProofs':proofs,if(verified)'driveVerifiedAt':DateTime.now().millisecondsSinceEpoch});
          await batch.commit();if(state=='pending')completed++;
        }catch(e){
          // An uncertain request remains intact. Never regenerate IDs or write
          // either financial record separately. The next receipt lookup owns retry.
          _scope(profile,school);
          final current=(await row.reference.get()).data();
          if(current!=null&&current['bundleId']==bundleId){
            final batch=db.batch();batch.requireUnchanged(row.reference,current);
            batch.update(row.reference,{'lastCheckAt':DateTime.now().millisecondsSinceEpoch,'verificationPending':true});
            await batch.commit();
          }
        }
      }
    }finally{_running=false;}
    return completed;
  }
  static bool verifiedCloud(Map receipt,String school,String bundleId,List ops){
    final ack=receipt['acknowledgements'];
    return receipt['schoolId']==school&&receipt['bundleProtocol']==1&&receipt['bundleId']==bundleId&&
      receipt['cloudState']=='committed'&&ack is List&&ack.length==2&&ops.length==2&&
      List.generate(2,(i)=>ack[i] is Map&&ops[i] is Map&&ack[i]['operationId']==ops[i]['operationId']&&
        ack[i]['cloudState']=='committed'&&ack[i]['recordRevision'] is String&&
        (ack[i]['recordRevision'] as String).startsWith('live-')).every((v)=>v);
  }
}
