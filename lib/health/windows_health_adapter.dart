import '../windows_connect/managed_school_session.dart';
import '../windows_connect/central_school_cloud.dart';
import 'health_reporter.dart';
import 'dart:async';
import '../windows_local_storage.dart';
import '../windows_local_firestore.dart';
import '../windows_sync_engine.dart';
import '../school_cloud_state.dart';
import '../sync_recovery_policy.dart';
import '../windows_service_status.dart';
import 'universal_health.dart';
import 'health_history_io.dart';
import 'health_runtime.dart';

class WindowsHealthAdapter {
  static final instance=WindowsHealthAdapter();
  bool _started=false;
  final guardian=UniversalHealth.instance;
  late final reporter=HealthReporter(guardian,platform:'windows',version:const String.fromEnvironment('APP_VERSION',defaultValue:'2.0'),send:(bound,report)async {try {final r=await ManagedSchoolSession.callForSchool(bound.school,'managed/health/report',{'report':report},observationOnly:true);return r['accepted']==true?HealthSendResult.accepted:HealthSendResult.retryable;}on CentralCloudException catch(e){return {429,502,503,504}.contains(e.status)?HealthSendResult.retryable:HealthSendResult.attention;}on TimeoutException{return HealthSendResult.retryable;}catch(_){return HealthSendResult.attention;}});
  HealthContext current()=>HealthContext(FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']?.toString()??'',FirebaseFirestore.instance.activeProfileId);
  Future<void> initialize() async {
    if(_started)return;
    _started=true;
    guardian.store=FileHealthHistory(() async => WindowsLocalStorage.controlDirectory);
    // Approved repair changes the sync DISPLAY projection only. The Smart
    // Sync owner retains queue, IDs, schedule, retries and ACK authority.
    guardian.register(HealthProvider(id:'sync-view',version:'2.0',check:(context) async {
      if(!current().same(context))return const HealthObservation(HealthState.unknown);
      final data=WindowsSyncEngine.instance.details.value;
      return data.isEmpty ? const HealthObservation(HealthState.degraded,failure:HealthFailure.worker) : HealthObservation(HealthState.monitoring,metrics:{'pending':(data['pending'] as num?)??0});
    },playbooks:[RecoveryPlaybook(id:'refresh-sync-view',kind:RecoveryKind.derivedView,failures:{HealthFailure.worker},precondition:(lease)async=>lease.valid&&current().same(lease.context)&&!WindowsSyncEngine.instance.isSyncing,execute:(lease)async {lease.check();if(!current().same(lease.context))throw StateError('School changed');await WindowsSyncEngine.instance.refreshDetails();lease.check();},verify:(lease)async=>lease.valid&&current().same(lease.context)&&WindowsSyncEngine.instance.details.value.isNotEmpty)]));
    for(final id in HealthRuntime.components.where((id)=>id!='sync-view')) {
      guardian.register(HealthProvider(id:id,version:'2.0',check:(_)async=>guardian.observations[id]??const HealthObservation(HealthState.unknown)));
    }
    await guardian.bind(current());
    WindowsSyncEngine.instance.state.addListener(_syncSignal);
    WindowsSyncEngine.instance.details.addListener(_syncSignal);
    WindowsServiceStatus.instance.addListener(_databaseSignal);
    guardian.start();
    unawaited(reporter.start());
    guardian.observe('startup',HealthObservation(HealthState.healthy,verifiedAt:DateTime.now()));
    _syncSignal();_databaseSignal();
  }
  void _databaseSignal(){try{
    final status=WindowsServiceStatus.instance.health(WindowsServiceType.localStorage);
    guardian.observe('database',HealthObservation(switch(status.state){WindowsHealthState.healthy=>HealthState.healthy,WindowsHealthState.unhealthy=>HealthState.needsAttention,_=>HealthState.unknown},failure:status.state==WindowsHealthState.unhealthy?HealthFailure.storage:HealthFailure.none,verifiedAt:status.state==WindowsHealthState.healthy?status.updatedAt:null));
  }catch(_){} }
  void _syncSignal(){try{
    final context=current();
    if(guardian.context?.same(context)!=true){unawaited(guardian.bind(context).then((_)=>_syncSignal()));return;}
    final sync=WindowsSyncEngine.instance, kind=sync.recoveryDecision?.kind;
    final failure=switch(kind){SyncFailureKind.authorization=>HealthFailure.authorization,SyncFailureKind.configuration=>HealthFailure.configuration,SyncFailureKind.conflict=>HealthFailure.conflict,SyncFailureKind.timeout=>HealthFailure.timeout,SyncFailureKind.networkPath=>HealthFailure.offline,SyncFailureKind.server=>HealthFailure.server,SyncFailureKind.quota=>HealthFailure.quota,_=>HealthFailure.none};
    guardian.observe('smart-sync',HealthObservation(sync.isPaused?HealthState.paused:failure!=HealthFailure.none?HealthState.degraded:sync.state.value==SchoolCloudState.synced?HealthState.healthy:HealthState.monitoring,failure:failure,verifiedAt:sync.lastSuccessfulSync,metrics:{'pending':(sync.details.value['pending'] as num?)??0}));
  }catch(_){} }
}
