import 'dart:convert';
import 'dart:io';
import '../lib/health/universal_health.dart';

class BenchmarkHistory implements HealthHistoryStore {
 final List<HealthEvent> events=[];
 @override Future<List<HealthEvent>> load(HealthContext context)async=>List.of(events);
 @override Future<void> save(HealthContext context,List<HealthEvent> value)async{events..clear()..addAll(value);}
}
Future<int?> cpuTicks()async{
 if(!Platform.isLinux)return null;
 try{final text=await File('/proc/self/stat').readAsString();final fields=text.substring(text.lastIndexOf(')')+2).split(' ');return int.parse(fields[11])+int.parse(fields[12]);}catch(_){return null;}
}
Future<void> main()async{
 final rssBefore=ProcessInfo.currentRss,history=BenchmarkHistory();
 final engine=UniversalHealth(store:history);await engine.bind(const HealthContext('synthetic-school','synthetic-profile'));
 engine.register(HealthProvider(id:'documents',version:'2.0',check:(_)async=>HealthObservation(HealthState.healthy,verifiedAt:DateTime.now()),playbooks:[RecoveryPlaybook(id:'fixture-view',kind:RecoveryKind.derivedView,failures:{HealthFailure.worker},precondition:(_)async=>true,execute:(lease)async{lease.check();},verify:(lease)async=>lease.valid)]));
 int? hz;
 if(Platform.isLinux){final r=await Process.run('getconf',['CLK_TCK']);hz=int.tryParse(r.stdout.toString().trim());}
 final cpuBefore=await cpuTicks(),watch=Stopwatch()..start();
 for(var i=0;i<100000;i++){engine.observe('documents',HealthObservation(HealthState.degraded,failure:HealthFailure.worker,metrics:{'latencyMs':i%100}));}
 final floodUs=watch.elapsedMicroseconds;watch.stop();await engine.flushHistory();final cpuAfter=await cpuTicks();
 final repairWatch=Stopwatch()..start();final repaired=await engine.recover('documents');repairWatch.stop();
 engine.start();final idleBefore=await cpuTicks(),idleWatch=Stopwatch()..start();await Future<void>.delayed(const Duration(seconds:31));idleWatch.stop();final idleAfter=await cpuTicks();
 double? percent(int? before,int? after,int micros)=>hz==null||before==null||after==null?null:100*(after-before)/hz!*1e6/micros;
 final report={'fixture':'Synthetic hosted Linux Dart VM; own process CPU, shared runner. Not physical Windows/Android acceptance.','events':100000,'elapsedMicros':floodUs,'eventsPerSecond':100000*1e6/floodUs,'activeProcessCpuPercent':percent(cpuBefore,cpuAfter,floodUs),'incrementalRssBytes':ProcessInfo.currentRss-rssBefore,'historySize':engine.history.length,'historySerializedBytes':jsonEncode(history.events.map((e)=>e.toJson()).toList()).length,'deduplicated':engine.droppedEvents,'registered':engine.registeredCount,'fixtureRepairVerified':repaired,'fixtureRepairAndVerificationMicros':repairWatch.elapsedMicroseconds,'idleSampleMillis':idleWatch.elapsedMilliseconds,'idleProcessCpuPercent':percent(idleBefore,idleAfter,idleWatch.elapsedMicroseconds),'pendingDiagnosticsBound':1,'uiBlockingMillis':null,'physicalStartupImpactMillis':null,'heavyStudentWorkloadOverhead':null};
 final file=File('build/universal-health/benchmark.json');await file.parent.create(recursive:true);await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));print(jsonEncode(report));await engine.dispose();
}
