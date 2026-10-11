import 'health_reporter.dart';
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import '../mobile/school_session.dart';
import 'universal_health.dart';
import 'health_runtime.dart';
import 'health_history_io.dart';

/// Hidden, in-process only. No service, new permission or user-facing route.
class MobileHealthAdapter with WidgetsBindingObserver {
  static final instance=MobileHealthAdapter();
  bool _started=false;
  int _generation=0;
  Timer? _contextTimer;
  final engine=UniversalHealth.instance;
  late final reporter=HealthReporter(engine,platform:'android',version:const String.fromEnvironment('APP_VERSION',defaultValue:'2.0'),send:(bound,report)async {try{final code=await SchoolSession.instance.sendHealthReport(report);return code==200?HealthSendResult.accepted:{429,502,503,504}.contains(code)?HealthSendResult.retryable:HealthSendResult.attention;}on TimeoutException{return HealthSendResult.retryable;}catch(_){return HealthSendResult.attention;}});
  HealthContext current(){final link=SchoolSession.instance.link;return HealthContext(link?.schoolId??'',link?.personId??'signed-out');}
  Future<void> initialize() async {
    if(_started)return;_started=true;
    final generation=++_generation;
    HealthRuntime.registerPassive();
    engine.store=FileHealthHistory(getApplicationSupportDirectory);
    await engine.bind(current());
    if(generation!=_generation||!_started)return;
    WidgetsBinding.instance.addObserver(this);
    SchoolSession.instance.attendanceChanges.addListener(_attendance);
    _contextTimer=Timer.periodic(const Duration(seconds:30),(_)=>_attendance());
    engine.start();
    unawaited(reporter.start());
    engine.observe('startup',HealthObservation(HealthState.healthy,verifiedAt:DateTime.now()));
  }
  void _attendance(){try{
    final bound=current();
    if(engine.context?.same(bound)!=true){unawaited(engine.bind(bound).then((_)=>_attendance()));return;}
    final session=SchoolSession.instance;
    engine.observe('attendance',HealthObservation(session.attendanceStatusReady?session.attendanceFailure.isEmpty?HealthState.monitoring:HealthState.degraded:HealthState.unknown,metrics:{'pending':session.attendancePending}));
  }catch(_){} }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if(state==AppLifecycleState.resumed){_contextTimer??=Timer.periodic(const Duration(seconds:30),(_)=>_attendance());engine.start();engine.resume();unawaited(reporter.start());_attendance();}
    else {_contextTimer?.cancel();_contextTimer=null;reporter.pause();engine.pause();}
  }
  Future<void> dispose() async {_started=false;_generation++;_contextTimer?.cancel();reporter.pause();WidgetsBinding.instance.removeObserver(this);SchoolSession.instance.attendanceChanges.removeListener(_attendance);await engine.stop();}
}

class MobileHealthLifetime extends StatefulWidget {
  const MobileHealthLifetime({super.key,required this.child});
  final Widget child;
  @override State<MobileHealthLifetime> createState()=>_MobileHealthLifetimeState();
}
class _MobileHealthLifetimeState extends State<MobileHealthLifetime>{
  @override void dispose(){unawaited(MobileHealthAdapter.instance.dispose());super.dispose();}
  @override Widget build(BuildContext context)=>widget.child;
}
