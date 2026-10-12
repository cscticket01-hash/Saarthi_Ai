import 'universal_health.dart';

/// Evidence-based candidates, never authority to execute a repair.
class HealthDiagnosis {
 const HealthDiagnosis(this.component,this.failure,this.evidence,this.possibleSharedCause);
 final String component,evidence;
 final HealthFailure failure;
 final String? possibleSharedCause;
}
class HealthDiagnostics {
 static List<HealthDiagnosis> diagnose(UniversalHealth engine){
  final observations=engine.observations,history=engine.history;
  final storage=observations['database'];
  return [for(final entry in observations.entries)if(entry.value.failure!=HealthFailure.none)HealthDiagnosis(entry.key,entry.value.failure,'${history.where((e)=>e.component==entry.key&&e.failure==entry.value.failure&&e.stage=='observed').length} retained distinct observations; ${history.where((e)=>e.component==entry.key&&e.stage=='unverified').length} unverified repair outcomes',entry.key!='database'&&storage!=null&&{HealthFailure.storage,HealthFailure.databaseLocked,HealthFailure.corrupt}.contains(storage.failure)?'Concurrent database failure; correlation only, root cause unconfirmed':null)];
 }
 /// Explicit optional advisor. Only component enums and bounded counts leave
 /// this interface. No credentials, school IDs, file paths, operations or stacks.
 /// Returned text is untrusted advice; it has no reference to recovery execution.
 static Future<String?> advisory(UniversalHealth engine,Future<String> Function(Map<String,dynamic>)? advisor)async{
  if(advisor==null)return null;
  final request={'schema':2,'components':[for(final e in engine.observations.entries.take(32)){'id':e.key,'state':e.value.state.name,'failure':e.value.failure.name}],'retainedEvents':engine.history.length};
  try{final advice=await advisor(request).timeout(const Duration(seconds:5));if(advice.length>2000||advice.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]')))return null;return advice;}catch(_){return null;}
 }
}
