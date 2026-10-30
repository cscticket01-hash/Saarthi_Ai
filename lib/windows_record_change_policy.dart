import 'windows_sync_comparison.dart';

const fieldPatchEnvelope = '_syncFieldPatch';

/// A patch belongs to one existing logical record. Deletes, new generations and
/// versioned document bytes keep their dedicated lifecycle protocols.
Map<String,dynamic>? buildRecordFieldPatch(String collection, Map base, Map current) {
  if({'documents','backups'}.contains(collection) || base['_syncDeleted']==true ||
      base['_syncRevision'] is! String || (base['_syncRevision'] as String).isEmpty ||
      current['replacesStudentGeneration']!=base['replacesStudentGeneration'] ||
      current.keys.any((key)=>key.toString().startsWith('_syncRecreates')&&current[key]!=base[key])) return null;
  final identityKey=collection=='students_directory'?'mobileStableId':
      collection=='teachers_directory'?'teacherId':null;
  if(identityKey!=null && (base[identityKey] is! String ||
      (base[identityKey] as String).isEmpty || base[identityKey]!=current[identityKey])) return null;
  final values=<String,dynamic>{},removed=<String>[],before=<String,dynamic>{};
  final keys=<String>{...base.keys.map((k)=>k.toString()),...current.keys.map((k)=>k.toString())};
  for(final key in keys) {
    if(key=='id'||key=='schoolId'||key=='createdAt'||key.startsWith('_sync'))continue;
    if(!current.containsKey(key)) {removed.add(key);continue;}
    if(!base.containsKey(key)||syncPayloadHash({'v':base[key]})!=syncPayloadHash({'v':current[key]}))
      values[key]=current[key];
  }
  if(values.keys.every((key)=>key=='updatedAt')&&removed.isEmpty)return null;
  for(final key in {...values.keys,...removed}.where((k)=>k!='updatedAt')) {
    before[key]={'exists':base.containsKey(key),
      'revision':base['_syncFieldRevisions'] is Map && base['_syncFieldRevisions'][key] is String
        ? base['_syncFieldRevisions'][key]:base.containsKey(key)?base['_syncRevision']:'absent'};
  }
  final identity=<String,dynamic>{};
  for(final key in ['mobileStableId','teacherId','studentId','personId']) {
    if(base[key] is String && (base[key] as String).isNotEmpty) {
      if(base[key]!=current[key])return null;
      identity[key]=base[key];
    }
  }
  return {'version':1,'set':values,'remove':removed,
    'before':before,
    if(identity.isNotEmpty)'identity':identity};
}

bool recordFieldIntentSatisfied(Map queued,Map remote) {
  final patch=queued['fieldPatch'];
  if(patch is! Map || queued['operation']!='set' || remote['_syncDeleted']==true ||
    queued['schoolId']!=remote['schoolId'] || queued['documentId']!=remote['id'])return false;
  final identity=patch['identity'];
  if(identity is Map && identity.entries.any((e)=>remote[e.key]!=e.value))return false;
  final wire=queued['wireData'];
  final values=wire is Map && wire[fieldPatchEnvelope] is Map?wire[fieldPatchEnvelope]['set']:
    wire is Map?{for(final key in (patch['set'] as Map).keys)key:wire[key]}:patch['set'];
  return values is Map && values.entries.where((e)=>e.key!='updatedAt').every((e)=>
    remote.containsKey(e.key) && syncPayloadHash({'v':e.value})==syncPayloadHash({'v':remote[e.key]})) &&
    (patch['remove'] as List).every((key)=>!remote.containsKey(key));
}

bool firstCommittedCreateWins(Map queued, Map remote) =>
  queued['createIntent']==true && queued['operation']=='set' &&
  (queued['baseCloudRevision']??'')=='' && queued['priorDeletion']==null &&
  queued['schoolId']==remote['schoolId'] && queued['documentId']==remote['id'] &&
  remote['_syncDeleted']!=true && remote['_syncRevision'] is String &&
  (remote['_syncRevision'] as String).isNotEmpty &&
  queued['collection']!='documents' && queued['collection']!='backups' &&
  !{'fee_payments','fee_ledger'}.contains(queued['collection']) &&
  queued['data'] is Map && queued['data']['replacesStudentGeneration']==null &&
  !(queued['data'] as Map).keys.any((key)=>key.toString().startsWith('_syncRecreates'));

bool sameDeletedDirectoryOwner(Map intent, Map remote) {
  final identity=intent['deletedRecordIdentity'];
  final key=intent['collection']=='students_directory'?'mobileStableId':
    intent['collection']=='teachers_directory'?'teacherId':null;
  return intent['operation']=='delete' && key!=null && identity is Map &&
    identity[key] is String && (identity[key] as String).isNotEmpty &&
    identity[key]==remote[key] && remote['_syncDeleted']!=true &&
    remote['_syncRecreatesDeletedRevision']==null && remote['_syncRecycleRestoreId']==null &&
    intent['schoolId']==remote['schoolId'] && intent['documentId']==remote['id'];
}

/// Initial creates, deletion/recreation and versioned files have their own
/// immutable protocols. Ordinary edits must never fall back to a full upload.
bool registeredRecordRequiresPatch(Map item) =>
  item['operation']!='delete' && !{'documents','backups'}.contains(item['collection']) &&
  (item['updateIntent']==true || item['baseCloudRevision'] is String && (item['baseCloudRevision'] as String).isNotEmpty) &&
  item['priorDeletion']==null && item['createIntent']!=true;
