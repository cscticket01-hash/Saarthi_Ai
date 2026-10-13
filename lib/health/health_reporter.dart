import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'universal_health.dart';

enum HealthSendResult { accepted, retryable, attention, unavailable }

/// One coalesced, persistent diagnostic report; no credential is queued.
class HealthReporter {
  HealthReporter(this.engine,{required this.platform,required this.version,required this.send,DateTime Function()? now,Timer Function(Duration,void Function(Timer))? periodic,Timer Function(Duration,void Function())? once}):now=now??DateTime.now,periodic=periodic??Timer.periodic,once=once??Timer.new;
  final UniversalHealth engine;
  final DateTime Function() now;
  final String platform,version;
  final Timer Function(Duration,void Function(Timer)) periodic;
  final Timer Function(Duration,void Function()) once;
  final Future<HealthSendResult> Function(HealthContext,Map<String,dynamic>) send;
  Timer? _timer;
  Timer? _retryTimer;
  DateTime? _retryDue;
  bool _sending=false,_stopped=true;
  int _attempts=0;
  String? _blocked,_scope;
  DateTime? _next;
  DateTime? _sendStarted,_lastAccepted;
  bool _budgetInvalid=false;
  HealthObservation get deliveryObservation {
    if(_scope!=engine.context?.fingerprint)return const HealthObservation(HealthState.unknown);
    if(_stopped||engine.paused)return const HealthObservation(HealthState.paused);
    if(_budgetInvalid)return const HealthObservation(HealthState.needsAttention,failure:HealthFailure.configuration);
    if(_blocked==_scope)return const HealthObservation(HealthState.needsAttention,failure:HealthFailure.authorization);
    if(_sending)return _sendStarted!=null&&now().difference(_sendStarted!)>const Duration(seconds:8)
        ? const HealthObservation(HealthState.needsAttention,failure:HealthFailure.timeout)
        : const HealthObservation(HealthState.monitoring,metrics:{'pending':1});
    if(retryExpected&&!retryRunning)return const HealthObservation(HealthState.degraded,failure:HealthFailure.worker);
    if(_attempts>0)return const HealthObservation(HealthState.monitoring,metrics:{'pending':1});
    return _lastAccepted==null?const HealthObservation(HealthState.monitoring):HealthObservation(HealthState.healthy,verifiedAt:_lastAccepted);
  }
  bool get timerExpected => !_stopped;
  bool get timerRunning => _timer?.isActive == true;
  bool get retryExpected => !_stopped && !engine.paused && !_sending &&
      _scope == engine.context?.fingerprint && _blocked != _scope &&
      _attempts > 0 && _next != null;
  bool get retryRunning => _retryTimer?.isActive == true && _retryDue == _next;
  void repairRetry() {
    if (!retryExpected || retryRunning) return;
    _retryTimer?.cancel();
    final scope = _scope, due = _next!;
    _retryDue=due;
    final delay = due.difference(now());
    _retryTimer = once(delay.isNegative ? Duration.zero : delay, () {
      _retryTimer = null;
      _retryDue=null;
      if (_scope == scope && engine.context?.fingerprint == scope &&
          !_stopped && !engine.paused) unawaited(report());
    });
  }
  Future<void> _saveBudget(SharedPreferences preferences, String scope) async {
    await preferences.setString('universal_health_delivery_budget_v2_$scope',jsonEncode({
      'scope':scope,'attempts':_attempts,'next':_next?.millisecondsSinceEpoch,
      'blocked':_blocked==scope,
    }));
  }
  void repairTimer() {
    if (_stopped || engine.paused) throw StateError('Health reporting is paused');
    if (timerRunning) return;
    _timer?.cancel();
    _timer=periodic(const Duration(minutes:5),(_)=>unawaited(report()));
    // Preserve authentication latch, retry deadlines and pending evidence.
  }
  Future<void> start() async {
    _stopped=false;
    _timer??=periodic(const Duration(minutes:5),(_)=>unawaited(report()));
  }
  void pause(){_stopped=true;_timer?.cancel();_timer=null;_retryTimer?.cancel();_retryTimer=null;}
  Future<void> report() async {
    final bound=engine.context;
    if(_stopped||engine.paused||bound==null||bound.school.trim().isEmpty||bound.profile.trim().isEmpty||_sending)return;
    final scope=bound.fingerprint;
    if(_scope!=scope){
      // Reserve the same serial lane during persisted-budget loading. A slow
      // preferences future remains locked; no overlapping delivery is started.
      _sending=true;
      _sendStarted=now();
      try {
        final preferences=await SharedPreferences.getInstance();
        final raw=preferences.getString('universal_health_delivery_budget_v2_$scope');
        Map<String,dynamic>? budget;
        try {if(raw!=null && raw.length<=512)budget=jsonDecode(raw) as Map<String,dynamic>;}catch(_){budget=null;}
        if(engine.context?.same(bound)!=true||_stopped)return;
        _scope=scope;_attempts=0;_next=null;_blocked=null;_lastAccepted=null;_budgetInvalid=raw!=null;
        if(raw!=null)_blocked=scope; // Malformed persisted admission fails closed.
        if(budget?.keys.toSet().difference({'scope','attempts','next','blocked'}).isEmpty==true &&
            budget?['scope']==scope && budget?['attempts'] is int &&
            budget!['attempts']>=0 && budget['attempts']<=3 &&
            budget['blocked'] is bool && (budget['next']==null || budget['next'] is int)) {
          _blocked=null;_budgetInvalid=false;
          _attempts=budget['attempts'] as int;
          if(budget['blocked']==true)_blocked=scope;
          final deadline=budget['next'] as int?;
          // Persisted clocks cannot create an unbounded hold or retry storm.
          if(deadline!=null && deadline>0 && deadline<=now().add(const Duration(hours:1)).millisecondsSinceEpoch)
            _next=DateTime.fromMillisecondsSinceEpoch(deadline);
          else if(deadline!=null || _attempts>0){_blocked=scope;_budgetInvalid=true;}
        }
      } catch (_) {
        if(engine.context?.same(bound)==true){_scope=scope;_attempts=1;_next=now().add(const Duration(minutes:15));}
        return;
      } finally {_sending=false;}
      repairRetry();
    }
    if(_blocked==scope||_next?.isAfter(now())==true)return;
    // Three failed sends open a cooldown, not a permanent outage latch.
    if(_attempts>=3)_attempts=0;
    _sending=true;
    _sendStarted=now();
    var requestPending=false, releaseWhenSettled=false;
    try {
      final preferences=await SharedPreferences.getInstance();
      var id=preferences.getString('universal_health_installation_v2');
      if(id==null||!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)){
        id=sha256.convert(List.generate(32,(_)=>Random.secure().nextInt(256))).toString();
        if(!await preferences.setString('universal_health_installation_v2',id))return;
      }
      final report=engine.telemetry(platform,version,id);
      await preferences.setString('universal_health_pending_v2',jsonEncode({'scope':scope,'report':report}));
      if(_stopped||engine.context?.same(bound)!=true)return;
      final source=send(bound,report);
      requestPending=true;
      unawaited(source.then<void>((_){requestPending=false;if(releaseWhenSettled){_sending=false;repairRetry();}},onError:(Object _,StackTrace __){requestPending=false;if(releaseWhenSettled){_sending=false;repairRetry();}}));
      final result=await source.timeout(const Duration(seconds:8),onTimeout:()=>HealthSendResult.retryable);
      if(_stopped||engine.context?.same(bound)!=true)return;
      if(result==HealthSendResult.accepted){_lastAccepted=now();_attempts=0;_next=now().add(const Duration(minutes:5));_retryTimer?.cancel();_retryTimer=null;await preferences.setString('universal_health_pending_v2','');}
      else if(result==HealthSendResult.unavailable){_next=now().add(const Duration(minutes:5));}
      else if(result==HealthSendResult.attention){_blocked=scope;}
      else {_attempts++;_next=now().add(Duration(minutes:5*(1<<_attempts)));}
      await _saveBudget(preferences,scope);
    }catch(_){_attempts++;_next=now().add(const Duration(minutes:15));}
    finally{if(requestPending){releaseWhenSettled=true;}else{_sending=false;repairRetry();}}
  }
}
