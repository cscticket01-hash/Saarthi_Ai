import 'dart:convert';
import 'dart:io';
import '../lib/health/universal_health.dart';

Future<void> main()async{
 final engine=UniversalHealth();await engine.bind(const HealthContext('synthetic-school','synthetic-profile'));
 engine.register(HealthProvider(id:'documents',version:'2.0',check:(_)async=>HealthObservation(HealthState.healthy,verifiedAt:DateTime.now())));
 final before=ProcessInfo.currentRss,watch=Stopwatch()..start();
 for(var i=0;i<100000;i++){engine.observe('documents',HealthObservation(HealthState.degraded,failure:HealthFailure.worker,metrics:{'latencyMs':i%100}));}
 final us=watch.elapsedMicroseconds;watch.stop();
 final report={'fixture':'synthetic fault flood, hosted Dart VM; not installed Windows hardware','events':100000,'elapsedMicros':us,'eventsPerSecond':100000*1e6/us,'rssDeltaBytes':ProcessInfo.currentRss-before,'historySize':engine.history.length,'deduplicated':engine.droppedEvents,'registered':engine.registeredCount,'pendingDiagnosticsBound':1,'idleCpuPercent':null,'uiBlockingMillis':null,'physicalStartupImpactMillis':null};
 final file=File('build/universal-health/benchmark.json');await file.parent.create(recursive:true);await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));print(jsonEncode(report));await engine.dispose();
}
