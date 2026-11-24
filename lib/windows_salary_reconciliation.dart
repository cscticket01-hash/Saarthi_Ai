import 'windows_sync_comparison.dart';

/// Three-way merge for *unsubmitted* payment-only salary edits. No guessing
/// legacy balances, corrections, owner identity, or an uncertain wire request.
Map<String,dynamic>? mergeUnsubmittedSalaryPayments(Map queued,Map baseline,Map cloud) {
  if(queued['collection']!='teacher_salary'||queued['operation']!='set'||
      queued['syncState']!='pending'||queued['retryCount']!=0||
      queued['createIntent']==true||queued['data'] is! Map||
      ['wireData','wireMode','cloudTicketId','priorCloudWrite','priorDeletion',
       'atomicBundleId','atomicState','reviewedFromOperationId'].any((k)=>queued[k]!=null))return null;
  final local=Map<String,dynamic>.from(queued['data'] as Map);
  final school=queued['schoolId'],id=queued['documentId'];
  if(school is! String||school.isEmpty||id is! String||id.isEmpty||
      baseline['schoolId']!=school||cloud['schoolId']!=school||
      (local['schoolId']!=null&&local['schoolId']!=school)||
      baseline['_syncRevision']!=queued['baseCloudRevision']||
      baseline['_syncRevision'] is! String||(baseline['_syncRevision'] as String).isEmpty||
      cloud['_syncRevision'] is! String||(cloud['_syncRevision'] as String).isEmpty||
      cloud['_syncRevision']==baseline['_syncRevision']||
      cloud['_syncOperationId']==queued['operationId'])return null;
  final net=baseline['netPaise'];
  if(net is! int||net<0||baseline['staffId'] is! String||
      (baseline['staffId'] as String).isEmpty||baseline['month'] is! String)return null;
  const mutable={'payments','paidPaise','balancePaise','status','updatedAt','schoolId','id'};
  Map<String,dynamic> fixed(Map row)=>{for(final e in row.entries)
    if(!mutable.contains(e.key)&&!e.key.toString().startsWith('_sync'))e.key.toString():e.value};
  List<Map<String,dynamic>>? events(Map row){
    if(row['_syncDeleted']==true||row['netPaise']!=net||
        (row['id']!=null&&row['id']!=id)||
        row.keys.any((k)=>k.toString().startsWith('_syncRecreates'))||
        (row['paymentCorrections']!=null&&(row['paymentCorrections'] is! List||
          (row['paymentCorrections'] as List).isNotEmpty)))return null;
    final raw=row['payments']??[];
    if(raw is! List)return null;
    final ids=<String>{},out=<Map<String,dynamic>>[];
    int sum=0;
    for(final event in raw){
      if(event is! Map||event['id'] is! String||(event['id'] as String).isEmpty||
          !ids.add(event['id'] as String)||event['amountPaise'] is! int||
          (event['amountPaise'] as int)<=0)return null;
      sum+=event['amountPaise'] as int;
      if(sum>net)return null;
      out.add(Map<String,dynamic>.from(event));
    }
    if(row['paidPaise']!=sum||row['balancePaise']!=net-sum||
        row['status']!=(sum==net?'Paid':sum==0?'Pending':'Part paid'))return null;
    return out;
  }
  bool equal(Object? a,Object? b)=>syncPayloadHash({'value':a})==syncPayloadHash({'value':b});
  if(!equal(fixed(baseline),fixed(local))||!equal(fixed(baseline),fixed(cloud)))return null;
  final base=events(baseline),mine=events(local),theirs=events(cloud);
  if(base==null||mine==null||theirs==null||mine.length<=base.length||
      theirs.length<base.length)return null;
  for(var i=0;i<base.length;i++){
    if(!equal(base[i],mine[i])||!equal(base[i],theirs[i]))return null;
  }
  final merged=[...theirs];
  var added=0;
  for(final payment in mine.skip(base.length)){
    final same=merged.where((e)=>e['id']==payment['id']).toList();
    if(same.isNotEmpty){
      if(!equal(same.single,payment))return null;
      continue;
    }
    merged.add(payment);added++;
  }
  if(added==0)return null; // exact readback uses the ordinary receipt path
  final total=merged.fold<int>(0,(sum,e)=>sum+(e['amountPaise'] as int));
  if(total>net)return null;
  final output=Map<String,dynamic>.from(cloud)..removeWhere((k,v)=>k.startsWith('_sync'));
  return {...output,'id':id,'schoolId':school,'payments':merged,'paidPaise':total,
    'balancePaise':net-total,'status':total==net?'Paid':'Part paid',
    'updatedAt':DateTime.now().millisecondsSinceEpoch};
}
