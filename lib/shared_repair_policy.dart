import 'dart:convert';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

const repairModules = {'all','students_directory','teachers_directory','documents',
  'fee_ledger','fee_payments','school_expenses','school_notices','attendance_records',
  'exams','exam_results','school_config'};
const repairCategories = {'networkPath','timeout','server','quota','conflict',
  'configuration','validation','fileMissing','unknown','idCardInputs'};
// Public, non-identifying diagnostic fingerprints only. No raw exception text.
const repairDiagnosticCodes = {'RECORD_REVISION_CONFLICT',
  'OPERATION_ID_CONFLICT','SCRIPT_RECORD_REVISION_CONFLICT',
  'SCRIPT_OPERATION_ID_CONFLICT','SCRIPT_DOCUMENT_REVISION_CONFLICT',
  'SCRIPT_TIMEOUT','SCRIPT_QUOTA_EXCEEDED','SCRIPT_PERMISSION_DENIED',
  'SCRIPT_RECORD_VERIFY_FAILED','SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED',
  'FIELD_DELTA_UNAVAILABLE','ACK_UNVERIFIED','SCRIPT_TRANSPORT_ERROR',
  'SCRIPT_RESPONSE_READ_FAILED','SCRIPT_HTTP_ERROR','SCRIPT_MIGRATION_PENDING',
  'SCRIPT_MIGRATION_CONFLICT','SCRIPT_STORAGE_NOT_PREPARED',
  'SCRIPT_JSON_READBACK_FAILED','SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED'};
const repairActionBounds = {'retry_floor':[5,900],'record_probe_cooldown':[300,3600],
  'card_probe_cooldown':[120,3600],'batch_cap':[2,10]};
void _only(Map value, Set<String> keys) {
  if(value.keys.any((k)=>k is! String || !keys.contains(k))) throw const FormatException('Unsupported repair schema');
}

/// Signed configuration only. No executable text, record edits, ACK controls,
/// credentials, URLs, selectors containing school data, or arbitrary actions.
class SharedRepairPolicy {
  SharedRepairPolicy._(this.sequence,this.expiresAt,this.enabled,this.rules,this.hash);
  final int sequence,expiresAt;
  final bool enabled;
  final String hash;
  final List<Map<String,dynamic>> rules;
  static Future<SharedRepairPolicy> verify(Map<String,dynamic> envelope, {
    required Map<String,String> trustedKeys,required int now,
    int previousSequence=0,String? previousHash,
  }) async {
    _only(envelope,{'keyId','payload','signature'});
    final encoded=envelope['payload'],signature=envelope['signature'];
    final public=trustedKeys[envelope['keyId']];
    if(public==null || encoded is! String || encoded.length>60000 ||
        signature is! String || signature.length>100 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded) ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(signature)) throw const FormatException('Untrusted repair envelope');
    final key=base64Url.decode(base64Url.normalize(public));
    final sig=base64Url.decode(base64Url.normalize(signature));
    if(key.length!=32 || sig.length!=64 || !await Ed25519().verify(utf8.encode(encoded),
      signature:Signature(sig,publicKey:SimplePublicKey(key,type:KeyPairType.ed25519)))) {
      throw const FormatException('Repair signature rejected');
    }
    final raw=jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))));
    if(raw is! Map<String,dynamic>) throw const FormatException('Repair payload rejected');
    _only(raw,{'protocol','purpose','sequence','issuedAt','expiresAt','enabled','rules'});
    final sequence=raw['sequence'],issued=raw['issuedAt'],expires=raw['expiresAt'];
    final digest=hashes.sha256.convert(utf8.encode(encoded)).toString();
    if(raw['protocol']!=1 || raw['purpose']!='vidya-sync-repair' ||
        sequence is! int || sequence<1 || sequence>2147483647 ||
        issued is! int || expires is! int || issued<0 || issued>now+300000 ||
        expires<=now || expires<=issued || expires-issued>86400000 ||
        sequence<previousSequence || sequence==previousSequence && digest!=previousHash ||
        raw['enabled'] is! bool || raw['rules'] is! List || (raw['rules'] as List).length>20 ||
        raw['enabled']==false && (raw['rules'] as List).isNotEmpty) {
      throw const FormatException('Expired, incompatible or replayed repair policy');
    }
    final rules=<Map<String,dynamic>>[],ids=<String>{};
    for(final r in raw['rules'] as List) {
      if(r is! Map<String,dynamic>) throw const FormatException('Invalid repair rule');
      _only(r,{'id','module','category','action','value','rolloutPercent'});
      final id=r['id'],action=r['action'],value=r['value'],percent=r['rolloutPercent'];
      final bounds=repairActionBounds[action];
      if(id is! String || !RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch(id) || !ids.add(id) ||
        !repairModules.contains(r['module']) || !repairCategories.contains(r['category']) ||
        bounds==null || value is! int || value<bounds[0] || value>bounds[1] ||
        percent is! int || percent<1 || percent>100 ||
        action=='retry_floor' && (!{'networkPath','timeout','server','quota'}.contains(r['category']) || r['module']!='all') ||
        action=='card_probe_cooldown' && (r['module']!='documents' || r['category']!='idCardInputs') ||
        action=='record_probe_cooldown' && r['category']!='conflict') {
        throw const FormatException('Unsupported repair action');
      }
      rules.add(Map<String,dynamic>.unmodifiable(r));
    }
    return SharedRepairPolicy._(sequence,expires,raw['enabled'] as bool,List.unmodifiable(rules),digest);
  }
  int? value(String action,{required String module,required String category,
      required String school,required int now}) {
    if(!enabled || now>=expiresAt || !RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school)) return null;
    int? result;
    for(final r in rules) {
      if(r['action']!=action || r['category']!=category ||
          r['module']!='all' && r['module']!=module) continue;
      final bytes=hashes.sha256.convert(utf8.encode('$school:${r['id']}')).bytes;
      final bucket=((bytes[0]<<24)|(bytes[1]<<16)|(bytes[2]<<8)|bytes[3]).toUnsigned(32)%100;
      if(bucket>=r['rolloutPercent']) continue;
      final v=r['value'] as int;
      if(result==null || (action=='batch_cap'?v<result:v>result)) result=v;
    }
    return result;
  }
}

/// Deliberately omit record/operation IDs, school IDs, payloads and raw errors.
List<Map<String,String>> sharedRepairObservations(List<Map<String,dynamic>> entries) {
  final unique=<String,Map<String,String>>{};
  for(final e in entries) {
    final module=e['collection'],category=e['category'];
    if(!repairModules.contains(module)||module=='all'||!repairCategories.contains(category)) continue;
    final outcome=const {'resolved':'resolved','retrying':'retry','recurred':'recurred',
      'reviewRequired':'detected'}[e['status']];
    if(outcome==null) continue;
    final code=e['failureCode'];
    final row={'module':module as String,'category':category as String,'outcome':outcome,
      if(code is String && repairDiagnosticCodes.contains(code)) 'code':code};
    unique[jsonEncode(row)]=row;
    if(unique.length>=20) break;
  }
  return unique.values.toList();
}
