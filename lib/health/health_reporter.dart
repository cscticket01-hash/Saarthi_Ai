import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'universal_health.dart';

enum HealthSendResult { accepted, retryable, attention, unavailable }

/// One coalesced, persistent diagnostic report; no credential is queued.
class HealthReporter {
  HealthReporter(this.engine,{required this.platform,required this.version,required this.send,DateTime Function()? now,Timer Function(Duration,void Function(Timer))? periodic}):now=now??DateTime.now,periodic=periodic??Timer.periodic;
  final UniversalHealth engine;
  final DateTime Function() now;
  final String platform,version;
  final Timer Function(Duration,void Function(Timer)) periodic;
  final Future<HealthSendResult> Function(HealthContext,Map<String,dynamic>) send;
  Timer? _timer;
  bool _sending=false,_stopped=true;
  int _attempts=0;
  String? _blocked,_scope;
  DateTime? _next;
  bool get timerExpected => !_stopped;
  bool get timerRunning => _timer?.isActive == true;
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
  void pause(){_stopped=true;_timer?.cancel();_timer=null;}
  Future<void> report() async {
    final bound=engine.context;
    if(_stopped||engine.paused||bound==null||bound.school.isEmpty||_sending)return;
    final scope=bound.fingerprint;
    if(_scope!=scope){_scope=scope;_attempts=0;_next=null;_blocked=null;}
    if(_blocked==scope||_next?.isAfter(now())==true)return;
    // Three failed sends open a cooldown, not a permanent outage latch.
    if(_attempts>=3)_attempts=0;
    _sending=true;
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
      unawaited(source.then<void>((_){requestPending=false;if(releaseWhenSettled)_sending=false;},onError:(Object _,StackTrace __){requestPending=false;if(releaseWhenSettled)_sending=false;}));
      final result=await source.timeout(const Duration(seconds:8),onTimeout:()=>HealthSendResult.retryable);
      if(_stopped||engine.context?.same(bound)!=true)return;
      if(result==HealthSendResult.accepted){_attempts=0;_next=now().add(const Duration(minutes:5));await preferences.setString('universal_health_pending_v2','');}
      else if(result==HealthSendResult.unavailable){_next=now().add(const Duration(minutes:5));}
      else if(result==HealthSendResult.attention){_blocked=scope;}
      else {_attempts++;_next=now().add(Duration(minutes:5*(1<<_attempts)));}
    }catch(_){_attempts++;_next=now().add(const Duration(minutes:15));}
    finally{if(requestPending){releaseWhenSettled=true;}else{_sending=false;}}
  }
}
