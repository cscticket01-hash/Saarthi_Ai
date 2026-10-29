/// Compiled actions only. A learned rule never supplies record values or an ACK.
class WindowsLearnedSyncRules {
  static const modules={'students_directory','teachers_directory','school_notices','school_calendar','attendance_records','attendance_logs','teacher_attendance','exam_results','fee_payments','fee_ledger','school_expenses','teacher_salary','school_config','school_settings','documents'};
  static const transient={'networkPath','timeout','server'};
  final _rules=<String,Map<String,dynamic>>{};
  final _pending=<String,Map<String,String>>{};
  final _applied=<String,String>{};
  final _seenSuccess=<String>{};
  String key(String module,String category)=>'$module:$category';
  void clear(){_rules.clear();_pending.clear();_applied.clear();_seenSuccess.clear();}
  String? recommend(String school,String module,String category){
    final r=_rules[key(module,category)];
    if(r==null||r['schoolId']!=school||r['successes']<=r['failures'])return null;
    return module=='documents'?'verify_original':transient.contains(category)?'replay_original':category=='conflict'?'verify_original':null;
  }
  List<Map<String,dynamic>> get rules=>_rules.values.map((r)=>Map<String,dynamic>.from(r)).toList();
  bool observe(Map<String,dynamic> e,String school){
    if(e['schoolId']!=school||e['operationId'] is! String||!modules.contains(e['collection']))return false;
    final op=e['operationId'] as String,module=e['collection'] as String,stage=e['stage'];
    final category=e['failureCategory'];
    if(stage=='learnedActionApplied'&&transient.contains(category)){
      _applied[op]=key(module,category);_pending[op]={'module':module,'category':category};
      while(_applied.length>100){_applied.remove(_applied.keys.first);}
      return false;
    }
    if(stage=='automaticRepair'&&transient.contains(category))_pending[op]={'module':module,'category':category};
    if({'retry','needsAttention','unauthorized','conflict'}.contains(stage)){
      final applied=_applied.remove(op);
      if(applied!=null&&_rules[applied]!=null){_rules[applied]!['failures']=(_rules[applied]!['failures'] as int)+1;return true;}
      if(transient.contains(category))_pending[op]={'module':module,'category':category};
      while(_pending.length>100){_pending.remove(_pending.keys.first);}
      return false;
    }
    var learned=_pending.remove(op);
    if(stage=='duplicateReconciled'||stage=='repairDiagnosed'&&{'verified_cloud_reconciled','verified_published_card_retained'}.contains(e['outcome'])){
      learned={'module':module,'category':'conflict'};
    }else if(stage!='verified'){
      if(learned!=null)_pending[op]=learned;
      return false;
    }
    _applied.remove(op);
    if(learned==null)return false;
    if(!_seenSuccess.add('$module:$op'))return false;
    while(_seenSuccess.length>100){_seenSuccess.remove(_seenSuccess.first);}
    final recipe=learned;
    final k=key(recipe['module']!,recipe['category']!);
    final r=_rules.putIfAbsent(k,()=>{'schoolId':school,'module':recipe['module'],'category':recipe['category'],'successes':0,'failures':0});
    r['successes']=(r['successes'] as int)+1;
    while(_rules.length>50){_rules.remove(_rules.keys.first);}
    return true;
  }
  void seedVerified(Iterable<Map<String,dynamic>> memory,String school){
    if(_rules.isNotEmpty)return;
    for(final e in memory){
      final module=e['collection'],category=e['category']=='verifiedDuplicate'?'conflict':e['category'];
      if(e['schoolId']!=school||e['status']!='resolved'||(e['verifiedRepairs'] as num? ?? 0)<=0||!modules.contains(module)||!{...transient,'conflict'}.contains(category))continue;
      final k=key(module,category);
      _rules.putIfAbsent(k,()=>{'schoolId':school,'module':module,'category':category,'successes':1,'failures':0});
      if(_rules.length>=50)break;
    }
  }
  Map<String,dynamic> snapshot(String school)=>{'version':1,'schoolId':school,'rules':rules,'verifiedOps':_seenSuccess.toList()};
  void restore(Object? raw,String school){
    clear();if(raw is! Map||raw['version']!=1||raw['schoolId']!=school||raw['rules'] is! List)return;
    if(raw['verifiedOps'] is List)_seenSuccess.addAll((raw['verifiedOps'] as List).whereType<String>().where((v)=>v.length<=300).take(100));
    for(final r in (raw['rules'] as List).take(50)){
      if(r is! Map||r['schoolId']!=school||!modules.contains(r['module'])||!{...transient,'conflict'}.contains(r['category'])||r['successes'] is! int||r['successes']<0||r['failures'] is! int||r['failures']<0)continue;
      _rules[key(r['module'],r['category'])]={for(final k in ['schoolId','module','category','successes','failures'])k:r[k]};
    }
  }
}
