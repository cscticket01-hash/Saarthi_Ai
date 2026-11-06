import 'live_sync_protocol.dart';

class WebAtomicPersonCard {
  const WebAtomicPersonCard(this.schoolId,this.bundleId,this.role,
    this.personId,this.documentId,this.cardSha256);
  final String schoolId,bundleId,role,personId,documentId,cardSha256;
}

/// TEST Web reuses the existing signed replay; no new queue/record authority.
/// Never display an incomplete event group or an unproven document owner.
List<WebAtomicPersonCard> verifyWebAtomicBundles(
    String school,List<LiveSyncPage> pages) {
  if(pages.isEmpty || pages.first.after!=0 || pages.last.more ||
      pages.last.schoolId!=school)
    throw StateError('TEST Web atomic replay is incomplete.');
  var cursor=0;
  final groups=<String,List<Map<String,dynamic>>>{};
  for(final page in pages){
    if(page.schoolId!=school||page.after!=cursor||page.cursor<cursor)
      throw StateError('TEST Web replay checkpoint changed.');
    cursor=page.cursor;
    for(final event in page.events){
      final id=event['bundleId'];
      if(id is String) (groups[id]??=<Map<String,dynamic>>[]).add(event);
    }
  }
  final verified=<WebAtomicPersonCard>[];
  for(final item in groups.entries){
    final rows=item.value;
    final people=rows.where((e)=>{'students_directory','teachers_directory'}
      .contains(e['collection'])).toList();
    if(people.isEmpty)continue;
    if(rows.length!=2||people.length!=1||
        rows[0]['bundleIndex']!=0||rows[1]['bundleIndex']!=1||
        rows[1]['collection']!='documents'||
        rows[0]['record'] is! Map||rows[1]['record'] is! Map)
      throw StateError('TEST Web Person/Card group is incomplete.');
    final person=rows[0]['record'] as Map,doc=rows[1]['record'] as Map;
    final role=rows[0]['collection']=='teachers_directory'?'teacher':'student';
    final generation=person['mobileStableId']??person['teacherId']??rows[0]['id'];
    final media=doc['bundleMedia'];
    if(person['schoolId']!=school||doc['schoolId']!=school||
       doc['bundleId']!=item.key||doc['bundleManifestHash'] is! String||
       doc['ownerRole']!=role||doc['personId']!=generation||
       (role=='student'?doc['studentId']:doc['teacherId'])!=rows[0]['id']||
       media is! List)
      throw StateError('TEST Web ownership proof differs.');
    final pdf=media.whereType<Map>().where((f)=>f['kind']=='idCard'&&
      f['sha256'] is String&&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(f['sha256'] as String)).toList();
    if(pdf.length!=1)throw StateError('TEST Web ID PDF proof unavailable.');
    final photos=media.whereType<Map>().where((m)=>m['kind']=='photo').toList();
    final portrait=person['atomicPortrait'];
    if(photos.length>1||(photos.isNotEmpty)!=(portrait is Map))
      throw StateError('TEST Web Person and original portrait are incomplete.');
    if(portrait is Map) {
      final photo=photos.single;
      if(portrait['bundleId']!=item.key||
         portrait['documentId']!=rows[1]['id']||
         portrait['role']!=role||
         portrait['id']!=photo['id']||
         portrait['sha256']!=photo['sha256']||
         portrait['mime']!=photo['mime']||
         portrait['sizeBytes']!=photo['sizeBytes']||
         photo['id'] is! String||
         !RegExp(r'^[a-f0-9]{64}$').hasMatch(photo['id'] as String)||
         photo['sha256'] is! String||
         !RegExp(r'^[a-f0-9]{64}$').hasMatch(photo['sha256'] as String)||
         !['image/jpeg','image/png','image/webp'].contains(photo['mime'])||
         photo['sizeBytes'] is! int||
         (photo['sizeBytes'] as int)>40*1024||
         (photo['sizeBytes'] as int)<12)
        throw StateError('TEST Web original photo SHA or owner differs.');
    }
    verified.add(WebAtomicPersonCard(school,item.key,role,
      rows[0]['id'] as String,rows[1]['id'] as String,
      pdf.single['sha256'] as String));
  }
  return verified;
}


class WebAtomicFinancialDocument {
  const WebAtomicFinancialDocument(this.schoolId,this.bundleId,this.kind,
    this.studentId,this.parentId,this.documentId,this.pdfSha256);
  final String schoolId,bundleId,kind,studentId,parentId,documentId,pdfSha256;
}

/// TEST-only financial replay view of the existing signed Cloudflare cursor.
/// A payment, its ledger and its original PDF must appear together; a marksheet
/// requires its original exam result. No partial history or forged Drive ACK.
List<WebAtomicFinancialDocument> verifyWebAtomicFinancialBundles(
    String school,List<LiveSyncPage> pages) {
  if(pages.isEmpty||pages.first.after!=0||pages.last.more||
      pages.last.schoolId!=school)
    throw StateError('TEST Web financial replay is incomplete.');
  var cursor=0;
  final groups=<String,List<Map<String,dynamic>>>{};
  for(final page in pages){
    if(page.schoolId!=school||page.after!=cursor||page.cursor<cursor)
      throw StateError('TEST Web financial checkpoint changed.');
    cursor=page.cursor;
    for(final event in page.events){
      if(event['bundleId'] is String) {
        (groups[event['bundleId'] as String]??=[]).add(event);
      }
    }
  }
  final verified=<WebAtomicFinancialDocument>[];
  for(final entry in groups.entries){
    final rows=entry.value,first=rows.first;
    final fee=first['collection']=='fee_payments';
    final exam={'exam_results','exam_center_results'}.contains(first['collection']);
    if(!fee&&!exam)continue; // Existing Person/Card handled by its own viewer.
    final count=fee?3:2;
    if(rows.length!=count||rows.last['collection']!='documents'||
       fee&&rows[1]['collection']!='fee_ledger'||
       rows.any((e)=>e['bundleId']!=entry.key||
         e['bundleSize']!=count||
         e['bundleIndex']!=rows.indexOf(e)||e['record'] is! Map))
      throw StateError('TEST Web financial bundle is incomplete.');
    final parent=first['record'] as Map,doc=rows.last['record'] as Map,
      student=parent['studentId'],media=doc['bundleMedia'];
    final kind=fee?'receipt':'marksheet';
    if(student is! String||student.isEmpty||student.length>200||
       parent['schoolId']!=school||doc['schoolId']!=school||
       doc['bundleId']!=entry.key||doc['bundleManifestHash'] is! String||
       !RegExp(r'^[a-f0-9]{64}$').hasMatch(doc['bundleManifestHash'] as String)||
       doc['studentId']!=student||doc['ownerRole']!='student'||
       doc['mimeType']!='application/pdf'||media is! List||media.length!=1||
       media.single is! Map)
      throw StateError('TEST Web financial document ownership differs.');
    final pdf=media.single as Map;
    final digest=pdf['sha256'];
    if(pdf['kind']!=kind||pdf['mime']!='application/pdf'||
       digest is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)||
       doc['contentHash']!=digest||
       pdf['sizeBytes'] is! int||
       (pdf['sizeBytes'] as int)<=0||
       (pdf['sizeBytes'] as int)>(fee?30*1024:150*1024))
      throw StateError('TEST Web financial PDF byte proof differs.');
    if(fee){
      final ledger=rows[1]['record'] as Map;
      if(parent['paymentId']!=first['id']||
         parent['receiptDocumentId']!=rows.last['id']||
         ledger['schoolId']!=school||ledger['studentId']!=student||
         ledger['lastPaymentId']!=first['id']||
         ledger['month']!=parent['month'])
        throw StateError('TEST Web receipt and ledger are not one transaction.');
    }else if(doc['examResultId']!=first['id']&&
        parent['marksheetDocumentId']!=rows.last['id']){
      throw StateError('TEST Web marksheet does not belong to exam result.');
    }
    verified.add(WebAtomicFinancialDocument(school,entry.key,kind,student,
      first['id'] as String,rows.last['id'] as String,digest));
  }
  return verified;
}
