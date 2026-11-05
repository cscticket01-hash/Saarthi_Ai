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
    verified.add(WebAtomicPersonCard(school,item.key,role,
      rows[0]['id'] as String,rows[1]['id'] as String,
      pdf.single['sha256'] as String));
  }
  return verified;
}
