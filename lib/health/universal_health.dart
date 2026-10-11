import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:crypto/crypto.dart';

enum HealthState { healthy, monitoring, degraded, recovering, needsAttention, paused, unknown }
enum HealthFailure { none, offline, timeout, server, quota, authorization, identity, configuration, conflict, databaseLocked, storage, corrupt, worker, decoding, rendering, overloaded, unknown }
enum RecoveryKind { derivedView, statelessWorker, ownerRequest }

class HealthContext {
  const HealthContext(this.school, this.profile);
  final String school, profile;
  String get fingerprint => sha256.convert(utf8.encode(jsonEncode([school, profile]))).toString();
  bool same(HealthContext other) => school == other.school && profile == other.profile;
}

class HealthObservation {
  const HealthObservation(this.state, {this.failure = HealthFailure.none, this.verifiedAt, this.operation = '', this.metrics = const {}});
  final HealthState state;
  final HealthFailure failure;
  final DateTime? verifiedAt;
  // Used locally to bind recovery; never serialized or sent as telemetry.
  final String operation;
  final Map<String, num> metrics;
  static const metricKeys = {'latencyMs', 'pending', 'completed', 'lockCount', 'memoryPressure', 'progressAgeMs'};
  Map<String, num> get safeMetrics => {for (final e in metrics.entries) if (metricKeys.contains(e.key) && e.value.isFinite && e.value >= 0 && e.value <= 1e12) e.key: e.value};
}

class RecoveryLease {
  RecoveryLease(this.context, this.operation, this._valid, this.deadline, this._now);
  final HealthContext context;
  final String operation;
  final bool Function() _valid;
  final DateTime deadline;
  final DateTime Function() _now;
  bool get valid => _valid() && _now().isBefore(deadline);
  void check() { if (!valid) throw StateError('Recovery admission expired'); }
}

/// Reviewed in-process code only. No server/AI data can register a callback.
/// Actions must check the lease at their owner's admission/commit boundary.
/// A timeout does NOT cancel a Future: the component lock remains held until
/// the actual action settles. An uncooperative worker is quarantined.
class RecoveryPlaybook {
  const RecoveryPlaybook({required this.id, required this.kind, required this.failures, required this.precondition, required this.execute, required this.verify, this.maxAttempts = 2, this.timeout = const Duration(seconds: 5), this.cooldown = const Duration(minutes: 1),this.circuitWindow=const Duration(hours:1)});
  final String id;
  final RecoveryKind kind;
  final Set<HealthFailure> failures;
  final Future<bool> Function(RecoveryLease lease) precondition;
  final Future<void> Function(RecoveryLease lease) execute;
  final Future<bool> Function(RecoveryLease lease) verify;
  final int maxAttempts;
  final Duration timeout, cooldown;
  final Duration circuitWindow;
}

class HealthProvider {
  const HealthProvider({required this.id, required this.version, required this.check, this.playbooks = const [], this.dependencies = const {}});
  static const contractVersion = 2;
  final String id, version;
  final Future<HealthObservation> Function(HealthContext context) check;
  final List<RecoveryPlaybook> playbooks;
  final Set<String> dependencies;
}

class HealthEvent {
  const HealthEvent(this.component, this.failure, this.stage, this.at, this.fingerprint);
  final String component, stage, fingerprint;
  final HealthFailure failure;
  final DateTime at;
  Map<String, dynamic> toJson() => {'component': component, 'failure': failure.name, 'stage': stage, 'at': at.millisecondsSinceEpoch, 'fingerprint': fingerprint};
  static const stages = {'observed', 'started', 'verified', 'unverified', 'blocked', 'timeout', 'checkTimeout', 'circuitOpen', 'checkFailed', 'persistenceFailed'};
  static HealthEvent? parse(dynamic raw) {
    if (raw is! Map || !UniversalHealth.validId(raw['component']) || !stages.contains(raw['stage']) || raw['at'] is! int || raw['at'] <= 0 || raw['fingerprint'] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['fingerprint'])) return null;
    final failure = HealthFailure.values.where((v) => v.name == raw['failure']);
    if (failure.isEmpty) return null;
    return HealthEvent(raw['component'], failure.first, raw['stage'], DateTime.fromMillisecondsSinceEpoch(raw['at']), raw['fingerprint']);
  }
}

abstract class HealthHistoryStore {
  Future<List<HealthEvent>> load(HealthContext context);
  Future<void> save(HealthContext context, List<HealthEvent> events);
}

class HealthPrediction {
  const HealthPrediction(this.component, this.reason, this.samples, this.confidence);
  final String component, reason;
  final int samples;
  final double confidence;
}

/// Independent, bounded guardian. It owns diagnostic metadata only.
class UniversalHealth {
  UniversalHealth({DateTime Function()? now, this.store, this.maxProviders = 32, this.maxHistory = 128, this.maxConcurrentChecks = 2}) : now = now ?? DateTime.now {
    if (maxProviders < 1 || maxProviders > 64 || maxHistory < maxProviders*3+1 || maxHistory > 256 || maxConcurrentChecks < 1 || maxConcurrentChecks > 4) throw ArgumentError('Invalid health budgets');
  }
  static final instance = UniversalHealth();
  final DateTime Function() now;
  HealthHistoryStore? store;
  final int maxProviders, maxHistory, maxConcurrentChecks;
  final Map<String, HealthProvider> _providers = {};
  final Map<String, HealthObservation> _observations = {};
  final Map<String, Future<void>> _checks = {}, _repairs = {};
  final Set<String> _quarantinedChecks={},_quarantinedRepairs={};
  final Map<String, int> _attempts = {};
  final Map<String, DateTime> _nextAttempt = {}, _dedup = {};
  final Map<String, List<double>> _latencies = {};
  final ListQueue<HealthEvent> _history = ListQueue();
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  HealthContext? _context;
  int _generation = 0;
  bool _paused = false, _disposed = false;
  bool _historyReady=false;
  Timer? _timer;
  Timer? _watchdog;
  Timer? _loadTimer;
  Completer<List<HealthEvent>>? _loadGate;
  DateTime? lastHeartbeat;
  Future<void> _write = Future.value();
  int _cursor = 0;
  DateTime? lastCheckAt;
  int droppedEvents = 0;
  int get epoch => _generation;
  Map<String, HealthObservation> get observations => Map.unmodifiable({for(final e in _observations.entries)e.key:e.value.state==HealthState.healthy && (e.value.verifiedAt==null || now().difference(e.value.verifiedAt!)>const Duration(minutes:5)) ? const HealthObservation(HealthState.unknown) : e.value});
  List<HealthEvent> get history => List.unmodifiable(_history);
  int get registeredCount => _providers.length;
  int get activeRepairs => _repairs.keys.where((id)=>!_quarantinedRepairs.contains(id)).length;
  int get unsettledRepairs => _quarantinedRepairs.length;
  int get _activeChecks => _checks.keys.where((id)=>!_quarantinedChecks.contains(id)).length;
  bool get paused => _paused;
  HealthContext? get context => _context;
  static bool validId(dynamic id) => id is String && RegExp(r'^[a-z][a-z0-9_.-]{0,47}$').hasMatch(id);
  void register(HealthProvider provider) {
    if (!validId(provider.id) || !RegExp(r'^[0-9]{1,3}\.[0-9]{1,3}(\.[0-9]{1,3})?$').hasMatch(provider.version) || _providers.containsKey(provider.id) || _providers.length >= maxProviders) throw ArgumentError('Invalid or duplicate health provider');
    final ids = <String>{};
    for (final p in provider.playbooks) {
      if (!validId(p.id) || !ids.add(p.id) || p.maxAttempts < 1 || p.maxAttempts > 3 || p.timeout <= Duration.zero || p.timeout > const Duration(seconds: 30) || p.cooldown < const Duration(milliseconds: 100) || p.circuitWindow<p.cooldown || p.circuitWindow>const Duration(days:7)) throw ArgumentError('Invalid recovery contract');
    }
    _providers[provider.id] = provider;
    _observations[provider.id] = const HealthObservation(HealthState.unknown);
  }
  Future<void> bind(HealthContext context) async {
    if (_disposed || _context?.same(context) == true) return;
    final generation = ++_generation;
    _context = context;
    _historyReady=false;
    _history.clear(); _attempts.clear(); _nextAttempt.clear(); _dedup.clear(); _latencies.clear();
    _observations.updateAll((_, __) => const HealthObservation(HealthState.unknown));
    lastCheckAt = null;
    _notify();
    try {
      _loadTimer?.cancel();
      if(_loadGate?.isCompleted==false)_loadGate!.complete([]);
      final gate=Completer<List<HealthEvent>>();_loadGate=gate;
      _loadTimer=Timer(const Duration(seconds:2),(){if(!gate.isCompleted)gate.complete([]);});
      final source=store?.load(context)??Future.value(<HealthEvent>[]);
      var loaded=false;
      unawaited(source.then<void>((events){if(!gate.isCompleted){loaded=true;gate.complete(events);}},onError:(Object _,StackTrace __){if(!gate.isCompleted)gate.complete([]);}));
      final events=await gate.future;
      if(identical(_loadGate,gate)){_loadTimer?.cancel();_loadTimer=null;_loadGate=null;}
      if (generation != _generation || _disposed) return;
      _historyReady=loaded&&store!=null;
      if(events.any((e)=>e.at.isAfter(now())))_historyReady=false;
      for (final e in events.where((e) => !e.at.isAfter(now()) && now().difference(e.at) <= const Duration(days: 7)).toList().reversed.take(maxHistory).toList().reversed) {
        _history.add(e);
        // Persisted attempts keep a crash/restart from resetting repair budgets.
        if (e.stage == 'started') _attempts[e.component] = (_attempts[e.component] ?? 0) + 1;
      }
    } catch (_) { if(generation==_generation) _event('supervisor', HealthFailure.storage, 'persistenceFailed'); }
    _notify();
  }
  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) { if (!_paused) { lastHeartbeat=now();unawaited(checkAll()); } });
    Timer.run(() {if(!_disposed&&!_paused&&_timer!=null)lastHeartbeat=now();});
    _watchdog??=Timer.periodic(const Duration(seconds:90),(_){if(!_paused&&!_disposed&&lastHeartbeat!=null&&now().difference(lastHeartbeat!)>=const Duration(seconds:90))unawaited(check('monitor-worker').then((_)=>recover('monitor-worker')));});
  }
  Future<void> restartMonitor(RecoveryLease lease) async {
    lease.check();_timer?.cancel();_timer=null;start();
    final proof=Completer<void>();Timer.run(()=>proof.complete());await proof.future;lease.check();
  }
  void pause() { _paused = true; ++_generation; _notify(); }
  void resume() { if (_disposed) return; _paused = false; _notify(); unawaited(checkAll()); }
  Future<void> stop() async { _timer?.cancel(); _timer = null; _watchdog?.cancel();_watchdog=null;_loadTimer?.cancel();_loadTimer=null;if(_loadGate?.isCompleted==false)_loadGate!.complete([]);pause(); await flushHistory(); }
  Future<void> flushHistory() => _write.catchError((_) {});
  void _notify() { if (!_disposed) _changes.add(null); }
  void _event(String component, HealthFailure failure, String stage) {
    final at = now();
    final key = '$component/${failure.name}/$stage';
    if ({'observed','checkFailed'}.contains(stage) && _dedup[key] != null && at.difference(_dedup[key]!) < const Duration(seconds: 2)) { droppedEvents++; return; }
    final version = _providers[component]?.version ?? '2.0';
    final fp = sha256.convert(utf8.encode('$component/$version/${failure.name}/$stage')).toString();
    if (_dedup.length >= 512) _dedup.remove(_dedup.keys.first);
    _dedup[key] = at;
    if (_history.length >= maxHistory) {
      // Keep every admission inside its circuit window, even in a fault flood.
      final removable=_history.where((e)=>e.stage!='started'||now().difference(e.at)>(_providers[e.component]?.playbooks.firstOrNull?.circuitWindow??const Duration(hours:1))).firstOrNull;
      if(removable!=null)_history.remove(removable);else {droppedEvents++;return;}
    }
    _history.add(HealthEvent(component, failure, stage, at, fp));
    final bound = _context, events = history;
    if (bound != null && store != null) {
      // Coalesce persistence instead of retaining one full snapshot per event.
      _scheduleWrite(bound, events);
    }
    _notify();
  }
  List<HealthEvent>? _pendingWrite;
  HealthContext? _pendingContext;
  bool _writing = false;
  bool _durable = false;
  void _scheduleWrite(HealthContext context, List<HealthEvent> events) {
    _pendingContext = context; _pendingWrite = events;
    if (_writing) return;
    _writing = true;
    _write = () async {
      try {
        while (_pendingWrite != null) {
          final snapshot = _pendingWrite!, bound = _pendingContext!;
          _pendingWrite = null;
          await store!.save(bound, snapshot);
          _durable = true;
        }
      } catch (_) { _durable = false; _pendingWrite = null; /* history stays in memory */ }
      finally { _writing = false; }
    }();
  }
  void observe(String component, HealthObservation value) {
    if (_disposed || _context == null || _paused || !_providers.containsKey(component)) return;
    final at = now();
    final verified = value.verifiedAt != null && !value.verifiedAt!.isAfter(at) && at.difference(value.verifiedAt!) <= const Duration(minutes: 5);
    final normalized = HealthObservation(value.state == HealthState.healthy && !verified ? HealthState.unknown : value.state, failure: value.failure, verifiedAt: verified ? value.verifiedAt : null, operation: value.operation, metrics: value.safeMetrics);
    _observations[component] = normalized;
    final latency = normalized.metrics['latencyMs'];
    if (latency != null) {
      final samples = _latencies.putIfAbsent(component, () => []);
      if (samples.length >= 16) samples.removeAt(0);
      samples.add(latency.toDouble());
    }
    if (value.failure != HealthFailure.none) _event(component, value.failure, 'observed'); else _notify();
  }
  Future<void> checkAll() async {
    if (_paused || _disposed || _context == null || _activeChecks >= maxConcurrentChecks) return;
    final ids = _providers.keys.toList();
    if (ids.isEmpty) return;
    final work = <Future<void>>[];
    final capacity = maxConcurrentChecks - _activeChecks;
    for (var i = 0; i < ids.length && work.length < capacity; i++) {
      final id = ids[_cursor++ % ids.length];
      if (!_checks.containsKey(id) && !_repairs.containsKey(id)) work.add(check(id));
    }
    await Future.wait(work);
    for (final id in ids) { if (!_checks.containsKey(id)) unawaited(recover(id)); }
  }
  Future<void> check(String id) async {
    if (_paused || _disposed || _context == null || !_providers.containsKey(id) || _checks.containsKey(id) || _repairs.containsKey(id) || _activeChecks >= maxConcurrentChecks) return;
    final generation = _generation, bound = _context!;
    final task = Future<void>(() async {
      try {
        final value = await _providers[id]!.check(bound);
        if (generation == _generation && !_paused && !_disposed) { observe(id, value); lastCheckAt = now(); }
      } catch (_) {
        if (generation == _generation && !_paused && !_disposed) { observe(id, const HealthObservation(HealthState.needsAttention, failure: HealthFailure.unknown)); _event(id, HealthFailure.unknown, 'checkFailed'); }
      }
    });
    _checks[id] = task;
    unawaited(task.whenComplete(() { if (identical(_checks[id], task)) {_checks.remove(id);_quarantinedChecks.remove(id);} }));
    try { await task.timeout(const Duration(seconds: 2)); }
    on TimeoutException { _quarantinedChecks.add(id);if (generation == _generation) { observe(id, const HealthObservation(HealthState.needsAttention, failure: HealthFailure.timeout)); _event(id, HealthFailure.timeout, 'checkTimeout'); } }
  }
  static const _forbidden = {HealthFailure.authorization, HealthFailure.identity, HealthFailure.configuration, HealthFailure.conflict, HealthFailure.corrupt, HealthFailure.storage, HealthFailure.unknown, HealthFailure.offline, HealthFailure.none};
  Future<bool> recover(String id, {bool automatic = true}) async {
    final provider = _providers[id], observation = _observations[id], bound = _context;
    if (_disposed || _paused || !_historyReady || store == null || activeRepairs>=1 || provider == null || observation == null || bound == null || _repairs.containsKey(id) || _checks.containsKey(id) || _forbidden.contains(observation.failure)) return false;
    // Policy never grants extra authority for a manual call.
    final plays = provider.playbooks.where((p) => p.failures.contains(observation.failure)).toList();
    if (plays.isEmpty || provider.dependencies.any((d) => observations[d]?.state != HealthState.healthy)) return false;
    final p = plays.first, at = now();
    _attempts[id]=_history.where((e)=>e.component==id&&e.stage=='started'&&at.difference(e.at)<p.circuitWindow).length;
    if ((_attempts[id] ?? 0) >= p.maxAttempts) { _event(id, observation.failure, 'circuitOpen'); return false; }
    final admissions = _history.where((e)=>e.component==id&&e.stage=='started'&&at.difference(e.at)<p.circuitWindow).toList();
    if (admissions.isNotEmpty) {
      final last = admissions.map((e)=>e.at).reduce((a,b)=>a.isAfter(b)?a:b);
      final persistedCooldown = last.add(p.cooldown * admissions.length);
      if (persistedCooldown.isAfter(at)) return false;
    }
    if (_nextAttempt[id]?.isAfter(at) == true) return false;
    final generation = _generation;
    final lease = RecoveryLease(bound, observation.operation, () => !_disposed && !_paused && generation == _generation && _context!.same(bound), at.add(p.timeout), now);
    var verifiedThisAttempt = false;
    final task = Future<void>(() async {
      var admitted = false;
      try {
        lease.check();
        if (!await p.precondition(lease)) { _event(id, observation.failure, 'blocked'); return; }
        lease.check();
        admitted = true;
        _attempts[id] = (_attempts[id] ?? 0) + 1;
        _nextAttempt[id] = now().add(p.cooldown * _attempts[id]!);
        _event(id, observation.failure, 'started');
        // No action starts unless its crash-loop admission is durable.
        await flushHistory().timeout(const Duration(seconds: 2)); lease.check();
        if (!_durable) throw StateError('Recovery history could not be persisted');
        _observations[id] = HealthObservation(HealthState.recovering, failure: observation.failure, operation: observation.operation);
        _notify();
        await p.execute(lease); lease.check();
        final verified = await p.verify(lease); lease.check();
        if (!verified) throw StateError('Recovery outcome unverified');
        verifiedThisAttempt = true;
        _event(id, observation.failure, 'verified');
        // Do not reset the session budget: repeated successful-but-recurring
        // faults still trip the circuit. A reviewed restart history may rearm.
        _observations[id] = HealthObservation(HealthState.healthy, verifiedAt: now(), operation: observation.operation);
      } catch (_) {
        if (generation == _generation && !_disposed) { _observations[id] = HealthObservation(HealthState.needsAttention, failure: observation.failure, operation: observation.operation); if(!_quarantinedRepairs.contains(id)) _event(id, observation.failure, admitted ? 'unverified' : 'blocked'); }
      } finally { if (generation == _generation) _notify(); }
    });
    _repairs[id] = task;
    unawaited(task.whenComplete(() { if (identical(_repairs[id], task)) {_repairs.remove(id);_quarantinedRepairs.remove(id);} }));
    try { await task.timeout(p.timeout); }
    on TimeoutException { _quarantinedRepairs.add(id);if (generation == _generation) { _observations[id] = HealthObservation(HealthState.needsAttention, failure: observation.failure); _event(id, observation.failure, 'timeout'); } return false; }
    return verifiedThisAttempt && generation == _generation && _observations[id]?.state == HealthState.healthy;
  }
  List<HealthPrediction> get predictions {
    final result = <HealthPrediction>[];
    for (final e in _latencies.entries) {
      if (e.value.length < 8) continue;
      final first = e.value.take(4).reduce((a,b) => a+b)/4, last = e.value.skip(e.value.length-4).reduce((a,b) => a+b)/4;
      if (first > 0 && last > first * 1.5 && last-first > 20) result.add(HealthPrediction(e.key, 'Increasing measured operation latency; warning, not confirmed failure', e.value.length, 0.7));
    }
    return result;
  }
  HealthState get overall {
    if (_paused) return HealthState.paused;
    final states = observations.values.map((o) => o.state).toSet();
    if (states.isEmpty) return HealthState.unknown;
    for (final state in [HealthState.needsAttention, HealthState.recovering, HealthState.degraded, HealthState.unknown, HealthState.monitoring]) { if (states.contains(state)) return state; }
    return HealthState.healthy;
  }
  Map<String, dynamic> telemetry(String platform, String version, String installation) => {
    'schema': 2, 'platform': platform, 'version': version, 'installation': installation,
    'measuredAt':now().millisecondsSinceEpoch,
    'state': overall.name, 'registered': registeredCount,
    'healthy': observations.values.where((o) => o.state == HealthState.healthy).length,
    'issues': observations.values.where((o) => o.failure != HealthFailure.none).length,
    'verifiedRepairs': _history.where((e) => e.stage == 'verified').length,
    'failedRepairs': _history.where((e) => {'unverified','timeout'}.contains(e.stage)).length,
    'components': [for (final e in observations.entries) {'id': e.key, 'state': e.value.state.name, 'failure': e.value.failure.name}],
  };
  Future<void> dispose() async { await stop(); _disposed = true; ++_generation; await _changes.close(); }
}
