import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Local, bounded evidence only. Never grants an ACK, edits records, changes
/// credentials or executes code. Existing repair owners retain all authority.
class WindowsRepairMemory {
  static const limit = 100;
  // Compact repair patterns survive the 24-hour per-operation display expiry.
  // A fixed schema limits storage and cannot encode school, record or person IDs.
  static const patternLimit = 1000;
  static const _patternModules = {'students_directory','teachers_directory',
    'school_notices','school_calendar','attendance_records','attendance_logs',
    'teacher_attendance','exam_results','fee_payments','fee_ledger',
    'school_expenses','teacher_salary','school_config','school_settings','documents'};
  static const _knownCodes = {'UNCLASSIFIED','RECORD_REVISION_CONFLICT',
    'OPERATION_ID_CONFLICT','SCRIPT_RECORD_REVISION_CONFLICT',
    'SCRIPT_OPERATION_ID_CONFLICT','SCRIPT_DOCUMENT_REVISION_CONFLICT',
    'SCRIPT_TIMEOUT','SCRIPT_QUOTA_EXCEEDED','SCRIPT_PERMISSION_DENIED',
    'SCRIPT_RECORD_VERIFY_FAILED','SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED',
    'FIELD_DELTA_UNAVAILABLE','ACK_UNVERIFIED','SCRIPT_TRANSPORT_ERROR',
    'SCRIPT_RESPONSE_READ_FAILED','SCRIPT_HTTP_ERROR','SCRIPT_MIGRATION_PENDING',
    'SCRIPT_MIGRATION_CONFLICT','SCRIPT_STORAGE_NOT_PREPARED',
    'SCRIPT_JSON_READBACK_FAILED','SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED'};
  final _entries = <String, Map<String, dynamic>>{};
  final _patterns = <String, Map<String, dynamic>>{};
  List<Map<String,dynamic>> get patterns =>
    _patterns.values.map((e)=>Map<String,dynamic>.from(e)).toList();
  static String _code(Object? code) =>
    code is String && _knownCodes.contains(code) ? code : 'UNCLASSIFIED';
  // No arbitrary error text, script URL, data, record ID or operation ID.
  void _rememberPattern(Map<String,dynamic> entry, int now, {required bool resolved}) {
    final module=entry['collection'],category=entry['category'];
    if(!_patternModules.contains(module)||!categories.contains(category))return;
    final code=_code(entry['failureCode']),key='$module:$category:$code';
    final previous=_patterns[key];
    final p=previous==null?<String,dynamic>{
      'collection':module,'category':category,'failureCode':code,'firstAt':now,
      'lastAt':now,'observations':0,'verifiedRepairs':0,'recurrences':0,
      'status':'detected',
    }:Map<String,dynamic>.from(previous);
    if(resolved){
      p['verifiedRepairs']=(p['verifiedRepairs'] as int)+1;
      p['lastResolvedAt']=now;
      p['status']='resolved';
    }else{
      p['observations']=(p['observations'] as int)+1;
      if(p['status']=='resolved'){
        p['recurrences']=(p['recurrences'] as int)+1;
        p['status']='recurred';
      }else if(p['status']!='recurred')p['status']='detected';
    }
    p['lastAt']=now;
    if(entry['resolvedInVersion'] is String)p['resolvedInVersion']=entry['resolvedInVersion'];
    _patterns.remove(key);_patterns[key]=p;
    if(_patterns.length>patternLimit){
      // Prefer retaining proven recipes; only bounded oldest patterns expire.
      final oldest=_patterns.entries.toList()..sort((a,b){
        final aScore=(a.value['verifiedRepairs'] as int)>0?1:0;
        final bScore=(b.value['verifiedRepairs'] as int)>0?1:0;
        if(aScore!=bScore)return aScore.compareTo(bScore);
        return (a.value['lastAt'] as int).compareTo(b.value['lastAt'] as int);
      });
      _patterns.remove(oldest.first.key);
    }
  }
  List<Map<String, dynamic>> get entries =>
      _entries.values.map((e) => Map<String, dynamic>.from(e)).toList();
  void clear() {_entries.clear();_patterns.clear();}
  void pruneResolved(int now) => _entries.removeWhere((_,e)=>e['status']=='resolved'&&
    e['lastAt'] is int&&now>=e['lastAt']&&now-e['lastAt']>=const Duration(hours:24).inMilliseconds);
  static const issueStages = {'retry', 'conflict', 'needsAttention',
    'unauthorized', 'repairDiagnosed', 'automaticRepair', 'duplicateReconciled'};
  static const verifiedOutcomes = {'verified_cloud_reconciled',
    'verified_published_card_retained'};
  static const categories = {'networkPath', 'timeout', 'server', 'quota',
    'authorization', 'configuration', 'conflict', 'validation', 'fileMissing',
    'localStorage', 'unknown', 'idCardInputs', 'recoverable', 'verifiedDuplicate'};
  static String? _token(Object? value, {int max = 200}) => value is String &&
      value.isNotEmpty && value.length <= max &&
      !RegExp(r'[\x00-\x1f/\\]').hasMatch(value) ? value : null;
  static String? _version(Object? value) => value is String && RegExp(r'^\d+\.\d+\.\d+(?:[+-][A-Za-z0-9.-]+)?$').hasMatch(value) && value.length <= 60 ? value : null;
  static String _hash(List<Object?> parts) => sha256.convert(utf8.encode(jsonEncode(parts))).toString();
  static String? scope(Map event, String school) {
    if (event['schoolId'] != school || _token(school) == null) return null;
    final queue = _token(event['queueCollection']), collection = _token(event['collection']);
    final record = _token(event['documentId']) ?? _token(event['queueId']);
    final operation = _token(event['operationId']) ?? _token(event['inputRevision']);
    if (record == null || operation == null || queue == null && collection == null) return null;
    return _hash([school, queue, collection, record, operation]);
  }
  bool observe(Map<String, dynamic> event, String school, int now) {
    final stage = event['stage'], identity = scope(event, school);
    if (identity == null || now < 0 ||
        !issueStages.contains(stage) && stage != 'verified') return false;
    final appVersion = _version(event['appVersion']);
    final candidates = _entries.values.where((e) => e['scope'] == identity).toList();
    if (stage == 'verified') {
      // Transport completion/empty queues are never passed as verified evidence.
      if (candidates.isEmpty) return false;
      var changed = false;
      for (final entry in candidates) {
        if (entry['status'] == 'resolved') continue;
        changed = true;
        entry['status'] = 'resolved'; entry['resolvedAt'] = now;
        entry['verifiedRepairs'] = (entry['verifiedRepairs'] as int) + 1;
        entry['lastAt'] = now;
        if (appVersion != null) {
          entry['resolvedInVersion'] = appVersion;
          entry['firstAppVersion'] ??= appVersion;
          entry['lastAppVersion'] = appVersion;
          final versions = <String>{...((entry['observedVersions'] as List?) ?? []).whereType<String>(), appVersion}.toList();
          entry['observedVersions'] = versions.length > 8 ? versions.sublist(versions.length - 8) : versions;
        }
        _rememberPattern(entry,now,resolved:true);
      }
      return changed;
    }
    final category = categories.contains(event['failureCategory'])
      ? event['failureCategory'] as String
      : stage == 'conflict' ? 'conflict' : 'unknown';
    final key = _hash([identity, category]);
    final previous = _entries[key];
    final outcome = _token(event['outcome'], max: 100) ?? stage.toString();
    final verified = stage == 'duplicateReconciled' ||
      stage == 'repairDiagnosed' && verifiedOutcomes.contains(outcome);
    final entry = previous ?? <String, dynamic>{
      'key': key, 'scope': identity, 'schoolId': school,
      'collection': _token(event['collection']) ?? 'unknown',
      'recordId': _token(event['documentId']) ?? _token(event['queueId']),
      'category': category, 'failureCode': _code(event['failureCode']),
      'firstAt': now, 'observations': 0,
      'verifiedRepairs': 0, 'recurrences': 0,
    };
    if(entry['failureCode']=='UNCLASSIFIED' && _code(event['failureCode'])!='UNCLASSIFIED')
      entry['failureCode']=_code(event['failureCode']);
    // Repeated log emission is an observation, not a new repair attempt.
    entry['observations'] = (entry['observations'] as int) + 1;
    if (previous?['status'] == 'resolved' && !verified) {
      entry['recurrences'] = (entry['recurrences'] as int) + 1;
      entry['status'] = 'recurred';
    } else if (verified) {
      if (previous?['status'] != 'resolved') entry['verifiedRepairs'] = (entry['verifiedRepairs'] as int) + 1;
      entry['status'] = 'resolved'; entry['resolvedAt'] = now;
    } else if (entry['status'] != 'recurred') {
      entry['status'] = stage == 'retry' || stage == 'automaticRepair' || outcome == 'retry_admitted'
        ? 'retrying' : 'reviewRequired';
    }
    if (appVersion != null) {
      entry['firstAppVersion'] ??= appVersion;
      entry['lastAppVersion'] = appVersion;
      final versions = <String>{...((entry['observedVersions'] as List?) ?? []).whereType<String>(), appVersion}.toList();
      entry['observedVersions'] = versions.length > 8 ? versions.sublist(versions.length - 8) : versions;
      if (verified) entry['resolvedInVersion'] = appVersion;
    }
    entry['lastAt'] = now; entry['outcome'] = outcome;
    entry['learnedAction'] = verified
      ? stage == 'duplicateReconciled' ? 'retain_verified_cloud' : 'retain_verified_evidence'
      : {'networkPath', 'timeout', 'server', 'quota'}.contains(category)
      ? 'retry_original_with_backoff' : 'review_without_overwrite';
    _entries.remove(key); _entries[key] = entry;
    _rememberPattern(entry,now,resolved:verified && previous?['status']!='resolved');
    while (_entries.length > limit) { _entries.remove(_entries.keys.first); }
    return true;
  }
  Map<String, dynamic> snapshot(String school) => {
    'version': 2, 'schoolId': school, 'entries': entries,
    'patterns': patterns,
  };
  void restore(Object? raw, String school) {
    clear();
    if (raw is! Map || !{1,2}.contains(raw['version']) || raw['schoolId'] != school || raw['entries'] is! List) return;
    for (final value in (raw['entries'] as List).take(limit)) {
      if (value is! Map || value['schoolId'] != school ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['key']?.toString() ?? '') ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['scope']?.toString() ?? '') ||
          !categories.contains(value['category']) ||
          !{'resolved','retrying','reviewRequired','recurred'}.contains(value['status']) ||
          value['key'] != _hash([value['scope'], value['category']]) ||
          ['firstAt','lastAt','observations','verifiedRepairs','recurrences'].any((k) =>
            value[k] is! int || (value[k] as int) < 0)) continue;
      final entry = <String, dynamic>{
        for (final key in ['key','scope','schoolId','category','status','firstAt','lastAt',
          'observations','verifiedRepairs','recurrences']) key: value[key],
        for (final key in ['firstAppVersion', 'lastAppVersion', 'resolvedInVersion'])
          if (_version(value[key]) != null) key: _version(value[key]),
        'observedVersions': value['observedVersions'] is List
          ? (value['observedVersions'] as List).map(_version).whereType<String>().take(8).toList() : <String>[],
        'collection': _token(value['collection']) ?? 'unknown',
        'failureCode':_code(value['failureCode']),
        'recordId': _token(value['recordId']),
        'outcome': _token(value['outcome'], max:100) ?? 'unknown',
        'learnedAction': {'retain_verified_cloud','retain_verified_evidence',
          'retry_original_with_backoff','review_without_overwrite'}.contains(value['learnedAction'])
          ? value['learnedAction'] : 'review_without_overwrite',
        if (value['resolvedAt'] is int && value['resolvedAt'] >= 0) 'resolvedAt': value['resolvedAt'],
      };
      _entries[entry['key'] as String] = entry;
    }
    if(raw['version']==2 && raw['patterns'] is List){
      for(final value in (raw['patterns'] as List).take(patternLimit)){
        if(value is! Map || !_patternModules.contains(value['collection']) ||
            !categories.contains(value['category']) ||
            !_knownCodes.contains(value['failureCode']) ||
            !{'detected','recurred','resolved'}.contains(value['status']) ||
            ['firstAt','lastAt','observations','verifiedRepairs','recurrences']
              .any((k)=>value[k] is! int || value[k]<0) ||
            value['lastAt']<value['firstAt'] ||
            value['lastResolvedAt']!=null && (value['lastResolvedAt'] is! int || value['lastResolvedAt']<0))
          continue;
        final p=<String,dynamic>{
          for(final k in ['collection','category','failureCode','status',
            'firstAt','lastAt','observations','verifiedRepairs','recurrences'])k:value[k],
          if(value['lastResolvedAt'] is int)'lastResolvedAt':value['lastResolvedAt'],
          if(_version(value['resolvedInVersion'])!=null)'resolvedInVersion':value['resolvedInVersion'],
        };
        _patterns['${p['collection']}:${p['category']}:${p['failureCode']}']=p;
      }
    }else{
      // Backward-compatible upgrade of older v1 local snapshots.
      for(final e in _entries.values) {
        _rememberPattern(e,e['lastAt'] as int,resolved:e['status']=='resolved');
      }
    }
  }
}

/// Known unchanged review conflicts need no repeated automatic readback within
/// the current hour. New local inputs, changed cloud heads and manual review
/// always return to the authoritative repair owner.
bool repeatedRepairProbe(Map? prior, {required String signature,
  required String? cloudRevision, required int now, bool explicitRetry = false, int? cooldownSeconds}) {
  final at = prior?['verifiedReadbackAt'];
  return !explicitRetry && cloudRevision != null && cloudRevision.isNotEmpty &&
    prior?['outcome'] == 'review_required' && prior?['inputSignature'] == signature &&
    prior?['cloudManifestRevision'] == cloudRevision && at is int &&
    at <= now && now - at < Duration(seconds:(cooldownSeconds??3600).clamp(300,3600).toInt()).inMilliseconds;
}

String repairMemoryStatusText(Object? value) => const {
  'resolved': 'Verified resolved', 'retrying': 'Retry pending',
  'reviewRequired': 'Review required', 'recurred': 'Problem recurred',
}[value] ?? 'Unverified';
String repairMemoryActionText(Object? value) => const {
  'retain_verified_cloud': 'Keep the verified cloud version',
  'retain_verified_evidence': 'Keep verified published evidence',
  'retry_original_with_backoff': 'Retry the original operation after its wait',
  'review_without_overwrite': 'Review both versions before changing data',
}[value] ?? 'Verify evidence before retrying';

/// An update admits one read-only diagnosis per operation, capped across
/// upgrades. It does not reset upload retries, grant ACKs or resolve money conflicts.
bool admitUpdatedRuntimeProbe(Map? prior, String version) =>
    RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) && prior != null &&
    prior['diagnosedAppVersion'] != version &&
    (prior['runtimeUpgradeProbes'] is! num ||
      (prior['runtimeUpgradeProbes'] as num) < 3);
