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
  const HealthObservation(this.state, {this.failure = HealthFailure.none, this.verifiedAt, this.operation = '', this.metrics = const {}, this.ownerCategory = ''});
  final HealthState state;
  final HealthFailure failure;
  final DateTime? verifiedAt;
  // Used locally to bind recovery; never serialized or sent as telemetry.
  final String operation;
  final Map<String, num> metrics;
  // Local typed owner diagnosis only; never a raw exception or cloud telemetry.
  final String ownerCategory;
  String get safeOwnerCategory => const {'networkPath','timeout','server','quota','authorization','configuration','conflict','validation','fileMissing','unknown'}.contains(ownerCategory) ? ownerCategory : '';
  static const metricKeys = {'latencyMs', 'pending', 'completed', 'lockCount', 'memoryPressure', 'progressAgeMs', 'conflicts', 'needsAttention', 'verifiedReceipts'};
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
  const HealthEvent(this.component, this.failure, this.stage, this.at, this.fingerprint, {this.playbook = '', this.providerVersion = ''});
  final String component, stage, fingerprint, playbook, providerVersion;
  final HealthFailure failure;
  final DateTime at;
  Map<String, dynamic> toJson() => {'component': component, 'failure': failure.name, 'stage': stage, 'at': at.millisecondsSinceEpoch, 'fingerprint': fingerprint, if (playbook.isNotEmpty) 'playbook': playbook, if (providerVersion.isNotEmpty) 'providerVersion': providerVersion};
  static const stages = {'observed', 'started', 'verified', 'unverified', 'blocked', 'timeout', 'checkTimeout', 'quarantineVerified', 'circuitOpen', 'checkFailed', 'persistenceFailed'};
  static HealthEvent? parse(dynamic raw) {
    if (raw is! Map || !UniversalHealth.validId(raw['component']) || !stages.contains(raw['stage']) || raw['at'] is! int || raw['at'] <= 0 || raw['fingerprint'] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['fingerprint'])) return null;
    if (raw['playbook'] != null && !UniversalHealth.validId(raw['playbook'])) return null;
    if (raw['providerVersion'] != null && (raw['providerVersion'] is! String || !RegExp(r'^[0-9]{1,3}\.[0-9]{1,3}(\.[0-9]{1,3})?$').hasMatch(raw['providerVersion']))) return null;
    final failure = HealthFailure.values.where((v) => v.name == raw['failure']);
    if (failure.isEmpty) return null;
    return HealthEvent(raw['component'], failure.first, raw['stage'], DateTime.fromMillisecondsSinceEpoch(raw['at']), raw['fingerprint'], playbook: raw['playbook'] as String? ?? '', providerVersion: raw['providerVersion'] as String? ?? '');
  }
}

abstract class HealthHistoryStore {
  Future<List<HealthEvent>> load(HealthContext context);
  Future<void> save(HealthContext context, List<HealthEvent> events);
}

class HealthSample {
  const HealthSample(this.at, this.score);
  final DateTime at;
  final int? score; // Unknown is a gap, never a synthetic zero.
}
abstract class HealthSampleStore {
  Future<List<HealthSample>> loadSamples(HealthContext context);
  Future<void> saveSamples(HealthContext context, List<HealthSample> samples);
}

class HealthPrediction {
  const HealthPrediction(this.component, this.reason, this.samples, this.confidence);
  final String component, reason;
  final int samples;
  final double confidence;
}

class HealthDiagnosticResult {
  const HealthDiagnosticResult(this.checked, this.skipped, {this.interrupted = false});
  final List<String> checked, skipped;
  final bool interrupted;
}

/// Independent, bounded guardian. It owns diagnostic metadata only.
class UniversalHealth {
  UniversalHealth({DateTime Function()? now, this.store, this.maxProviders = 32, this.maxHistory = 128, this.maxConcurrentChecks = 2}) : now = now ?? DateTime.now {
    if (maxProviders < 1 || maxProviders > 64 || maxHistory < maxProviders*4 || maxHistory > 256 || maxConcurrentChecks < 1 || maxConcurrentChecks > 4) throw ArgumentError('Invalid health budgets');
  }
  static final instance = UniversalHealth();
  final DateTime Function() now;
  HealthHistoryStore? store;
  HealthSampleStore? sampleStore;
  final List<HealthSample> _samples = [];
  bool _samplesReady = false;
  int _sampleEpoch = 0;
  Future<void> _sampleLoad = Future.value();
  Future<void> get sampleHistoryLoaded => _sampleLoad;
  Future<void> _sampleWrite = Future.value();
  bool _writingSamples = false;
  // One pending snapshot: slow storage must not retain a seven-day list for
  // every minute indefinitely. A school switch drains the old scope first.
  List<HealthSample>? _pendingSamples;
  HealthContext? _pendingSampleContext;
  List<HealthSample> get samples => List.unmodifiable(_samples);
  int get reviewedPlaybookCount => _providers.values.fold(0, (n, p) => n + p.playbooks.length);
  int? get measuredScore {
    final entries = observations.values.toList();
    if (context == null || paused || entries.isEmpty || entries.length != registeredCount) return null;
    var total = 0;
    for (final entry in entries) {
      switch(entry.state) {
        case HealthState.healthy: total += 100;
        case HealthState.degraded: total += 50;
        case HealthState.recovering: total += 25;
        case HealthState.needsAttention: break;
        default: return null;
      }
    }
    return (total / entries.length).round();
  }
  Future<void> _loadSamples(HealthContext bound, int epoch) async {
    try {
      final loaded = await (() async {
        await _sampleWrite;
        return await (sampleStore?.loadSamples(bound) ?? Future.value(<HealthSample>[]));
      })()
          .timeout(const Duration(seconds:2));
      if (_disposed || epoch != _sampleEpoch || _context?.same(bound) != true) return;
      final at = now();
      _samples.addAll(loaded.where((s) => !s.at.isAfter(at) && at.difference(s.at) <= const Duration(days:7)).take(10080));
    } catch (_) { /* Missing/corrupt diagnostic history is not health proof. */ }
    if (!_disposed && epoch == _sampleEpoch && _context?.same(bound) == true) { _samplesReady = true; _notify(); }
  }
  void _captureSample() {
    final bound = _context;
    if (!_samplesReady || bound == null) return;
    final at = now();
    _samples.removeWhere((s) => s.at.isAfter(at) || at.difference(s.at) > const Duration(days:7));
    if (_samples.isNotEmpty && at.difference(_samples.last.at) < const Duration(minutes:1)) return;
    _samples.add(HealthSample(at, measuredScore));
    if (_samples.length > 10080) _samples.removeAt(0);
    final snapshot = List<HealthSample>.of(_samples);
    if (sampleStore == null) return;
    _pendingSamples = snapshot;
    _pendingSampleContext = bound;
    if (_writingSamples) return;
    _writingSamples = true;
    _sampleWrite = () async {
      try {
        while (_pendingSamples != null) {
          final samples = _pendingSamples!, scope = _pendingSampleContext!;
          _pendingSamples = null;
          try { await sampleStore!.saveSamples(scope, samples); } catch (_) {
            // Trend gaps never authorize a repair or change school records.
          }
        }
      } finally { _writingSamples = false; }
    }();
  }

  final int maxProviders, maxHistory, maxConcurrentChecks;
  final Map<String, HealthProvider> _providers = {};
  final Map<String, HealthObservation> _observations = {};
  final Map<String, Future<void>> _checks = {}, _repairs = {};
  final Set<String> _quarantinedChecks={},_quarantinedRepairs={};
  final Map<String, HealthEvent> _restartQuarantine = {};
  final Map<String, int> _attempts = {};
  final Map<String, DateTime> _nextAttempt = {}, _dedup = {};
  final Map<String, List<double>> _latencies = {};
  final ListQueue<HealthEvent> _history = ListQueue();
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  HealthContext? _context;
  int _generation = 0;
  bool _paused = false, _disposed = false;
  bool _restartOnResume = false;
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
  Map<String, HealthObservation> get observations {
    final at = now();
    return Map.unmodifiable({for(final e in _observations.entries)e.key:e.value.state==HealthState.healthy && (e.value.verifiedAt==null || e.value.verifiedAt!.isAfter(at) || at.difference(e.value.verifiedAt!)>const Duration(minutes:5)) ? const HealthObservation(HealthState.unknown) : e.value});
  }
  List<HealthEvent> get history => List.unmodifiable(_history);
  int get registeredCount => _providers.length;
  int get activeRepairs => _repairs.keys.where((id)=>!_quarantinedRepairs.contains(id)).length;
  int get unsettledRepairs => _quarantinedRepairs.length;
  int get pendingQuarantineVerification => _restartQuarantine.length;
  int get _activeChecks => _checks.keys.where((id)=>!_quarantinedChecks.contains(id)).length;
  bool get paused => _paused;
  bool get monitoringActive => !_disposed && !_paused && _timer != null &&
      _context != null && _context!.school.isNotEmpty && registeredCount > 0;
  bool get admissionHistoryVerified => _historyReady && store != null;
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
    _samples.clear(); _samplesReady = false;
    _sampleLoad = _loadSamples(context, ++_sampleEpoch);
    unawaited(_sampleLoad);
    _historyReady=false;
    _history.clear(); _attempts.clear(); _nextAttempt.clear(); _dedup.clear(); _latencies.clear(); _restartQuarantine.clear();
    _observations.updateAll((_, __) => const HealthObservation(HealthState.unknown));
    lastCheckAt = null;
    _notify();
    try {
      _loadTimer?.cancel();
      if(_loadGate?.isCompleted==false)_loadGate!.complete([]);
      final gate=Completer<List<HealthEvent>>();_loadGate=gate;
      _loadTimer=Timer(const Duration(seconds:2),(){if(!gate.isCompleted)gate.complete([]);});
      // A -> B -> A must not reload A before A's durable admission settles.
      // The existing load deadline fails closed when that write is stalled.
      final source=() async {
        await _write;
        return await (store?.load(context)??Future.value(<HealthEvent>[]));
      }();
      var loaded=false;
      unawaited(source.then<void>((events){if(!gate.isCompleted){loaded=true;gate.complete(events);}},onError:(Object _,StackTrace __){if(!gate.isCompleted)gate.complete([]);}));
      final events=await gate.future;
      if(identical(_loadGate,gate)){_loadTimer?.cancel();_loadTimer=null;_loadGate=null;}
      if (generation != _generation || _disposed) return;
      _historyReady=loaded&&store!=null&&events.length<=maxHistory;
      if(events.any((e)=>e.at.isAfter(now())))_historyReady=false;
      final unfinished = <String,HealthEvent>{};
      for (final e in events.where((e)=>!e.at.isAfter(now()))) {
        if(e.stage=='started')unfinished[e.component]=e;
        if(e.stage=='verified'||e.stage=='unverified')unfinished.remove(e.component);
        if(e.stage=='timeout'||e.stage=='checkTimeout')_restartQuarantine[e.component]=e;
        if(e.stage=='quarantineVerified'){_restartQuarantine.remove(e.component);unfinished.remove(e.component);}
      }
      // A crash can happen after durable admission and before a terminal event
      // is saved. Missing completion is not permission to retry the action.
      for(final e in unfinished.entries){_restartQuarantine.putIfAbsent(e.key,()=>e.value);}
      for (final e in events.where((e) => !e.at.isAfter(now()) && (now().difference(e.at) <= const Duration(days: 7) || _pinnedQuarantine(e))).toList().reversed.take(maxHistory).toList().reversed) {
        _history.add(e);
        // Persisted attempts keep a crash/restart from resetting repair budgets.
        if (e.stage == 'started') _attempts[e.component] = (_attempts[e.component] ?? 0) + 1;
      }
      for(final e in _restartQuarantine.entries) {
        if(_providers.containsKey(e.key))_observations[e.key]=HealthObservation(HealthState.needsAttention,failure:e.value.failure);
      }
    } catch (_) { if(generation==_generation) _event('supervisor', HealthFailure.storage, 'persistenceFailed'); }
    _notify();
  }
  void start() {
    if (_disposed || _timer != null) return;
    if (_paused) { _restartOnResume = true; return; }
    _timer = Timer.periodic(const Duration(seconds: 30), (_) { if (!_paused) { lastHeartbeat=now();unawaited(checkAll()); } });
    Timer.run(() {if(!_disposed&&!_paused&&_timer!=null)lastHeartbeat=now();});
    _watchdog??=Timer.periodic(const Duration(seconds:90),(_){if(!_paused&&!_disposed&&lastHeartbeat!=null&&now().difference(lastHeartbeat!)>=const Duration(seconds:90))unawaited(check('monitor-worker').then((_)=>recover('monitor-worker')));});
  }
  Future<void> restartMonitor(RecoveryLease lease) async {
    lease.check();_timer?.cancel();_timer=null;start();
    final proof=Completer<void>();Timer.run(()=>proof.complete());await proof.future;lease.check();
  }
  void pause() {
    _restartOnResume = _restartOnResume || _timer != null;
    _timer?.cancel(); _timer = null;
    _watchdog?.cancel(); _watchdog = null;
    _paused = true; ++_generation; _notify();
  }
  void resume() {
    if (_disposed) return;
    _paused = false;
    if (_restartOnResume) { _restartOnResume = false; start(); }
    _notify(); unawaited(checkAll());
  }
  Future<void> stop() async { pause(); _restartOnResume=false; _loadTimer?.cancel();_loadTimer=null;if(_loadGate?.isCompleted==false)_loadGate!.complete([]);await flushHistory(); }
  Future<void> flushHistory() async { await _write.catchError((_) {}); await _sampleWrite.catchError((_) {}); }
  void _notify() { if (!_disposed) { _captureSample(); _changes.add(null); } }
  bool _pinnedQuarantine(HealthEvent event) => _restartQuarantine[event.component]?.at == event.at && _restartQuarantine[event.component]?.stage == event.stage;
  void _quarantine(String id, HealthFailure failure, String stage, {String playbook = ''}) {
    final at=now(),version=_providers[id]?.version??'2.0';
    _restartQuarantine[id]=HealthEvent(id,failure,stage,at,sha256.convert(utf8.encode('$id/$version/${failure.name}/$stage')).toString(), playbook: playbook, providerVersion: version);
    if(!_event(id,failure,stage,recordedAt:at, playbook:playbook))_historyReady=false;
  }
  bool _event(String component, HealthFailure failure, String stage, {DateTime? recordedAt, String playbook = ''}) {
    final at = recordedAt ?? now();
    final key = '$component/${failure.name}/$stage';
    if ({'observed','checkFailed'}.contains(stage) && _dedup[key] != null && at.difference(_dedup[key]!) < const Duration(seconds: 2)) { droppedEvents++; return false; }
    final version = _providers[component]?.version ?? '2.0';
    final fp = sha256.convert(utf8.encode('$component/$version/${failure.name}/$stage')).toString();
    if (_dedup.length >= 512) _dedup.remove(_dedup.keys.first);
    _dedup[key] = at;
    if (_history.length >= maxHistory) {
      // Keep every admission inside its circuit window, even in a fault flood.
      final removable=_history.where((e)=>!_pinnedQuarantine(e)&&(e.stage!='started'||now().difference(e.at)>(_providers[e.component]?.playbooks.map((p)=>p.circuitWindow).fold<Duration>(const Duration(hours:1),(a,b)=>a>b?a:b)??const Duration(hours:1)))).firstOrNull;
      if(removable!=null)_history.remove(removable);else {droppedEvents++;return false;}
    }
    _history.add(HealthEvent(component, failure, stage, at, fp, playbook: playbook, providerVersion: version));
    final bound = _context, events = history;
    if (bound != null && store != null && _historyReady) {
      // Coalesce persistence instead of retaining one full snapshot per event.
      _scheduleWrite(bound, events);
    }
    _notify();
    return true;
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
    final normalized = HealthObservation(value.state == HealthState.healthy && !verified ? HealthState.unknown : value.state, failure: value.failure, verifiedAt: verified ? value.verifiedAt : null, operation: value.operation, metrics: value.safeMetrics, ownerCategory: value.safeOwnerCategory);
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
  Future<HealthDiagnosticResult>? _diagnostics;
  /// A manual sweep visits every registered component, retaining the existing
  /// concurrency/timeouts and underlying locks. It never submits business data
  /// or invokes recovery; absent provider evidence stays Unknown.
  Future<HealthDiagnosticResult> runDiagnostics() {
    if (_diagnostics != null) return _diagnostics!;
    final task = _runDiagnostics();
    _diagnostics = task;
    unawaited(task.then<void>((_) { if (identical(_diagnostics, task)) _diagnostics = null; },
      onError: (Object _, StackTrace __) { if (identical(_diagnostics, task)) _diagnostics = null; }));
    return task;
  }
  Future<HealthDiagnosticResult> _runDiagnostics() async {
    final generation = _generation, bound = _context;
    final ids = _providers.keys.toList(), checked = <String>[], skipped = <String>[];
    bool valid() => !_paused && !_disposed && bound != null &&
        bound.school.isNotEmpty && generation == _generation && _context?.same(bound) == true;
    if (!valid()) return HealthDiagnosticResult([], ids, interrupted: true);
    var cursor = 0;
    while (cursor < ids.length) {
      if (!valid()) return HealthDiagnosticResult(checked, [...skipped, ...ids.skip(cursor)], interrupted: true);
      final work = <Future<void>>[];
      while (cursor < ids.length && work.length < maxConcurrentChecks) {
        final id = ids[cursor++];
        if (_checks.containsKey(id) || _repairs.containsKey(id) || _activeChecks >= maxConcurrentChecks) {
          skipped.add(id);
        } else {
          checked.add(id);
          work.add(check(id));
        }
      }
      await Future.wait(work);
    }
    return HealthDiagnosticResult(checked, skipped, interrupted: !valid());
  }
  Future<void> check(String id) async {
    if (_paused || _disposed || _context == null || !_providers.containsKey(id) || _checks.containsKey(id) || _repairs.containsKey(id) || _activeChecks >= maxConcurrentChecks) return;
    final generation = _generation, bound = _context!;
    final task = Future<void>(() async {
      try {
        if (generation != _generation || _paused || _disposed) return;
        final value = await _providers[id]!.check(bound);
        if (generation == _generation && !_paused && !_disposed) {
          observe(id, value); lastCheckAt = now();
          final marker=_restartQuarantine[id];
          if(marker!=null&&observations[id]?.state==HealthState.healthy&&value.failure==HealthFailure.none&&value.verifiedAt?.isAfter(marker.at)==true) {
            _restartQuarantine.remove(id);_event(id,HealthFailure.none,'quarantineVerified');
          }
        }
      } catch (_) {
        if (generation == _generation && !_paused && !_disposed) { observe(id, const HealthObservation(HealthState.needsAttention, failure: HealthFailure.unknown)); _event(id, HealthFailure.unknown, 'checkFailed'); }
      }
    });
    _checks[id] = task;
    unawaited(task.whenComplete(() { if (identical(_checks[id], task)) {_checks.remove(id);_quarantinedChecks.remove(id);} }));
    try { await task.timeout(const Duration(seconds: 2)); }
    on TimeoutException { _quarantinedChecks.add(id);if (generation == _generation) { observe(id, const HealthObservation(HealthState.needsAttention, failure: HealthFailure.timeout)); _quarantine(id, HealthFailure.timeout, 'checkTimeout'); } }
  }
  static const _forbidden = {HealthFailure.authorization, HealthFailure.identity, HealthFailure.configuration, HealthFailure.conflict, HealthFailure.corrupt, HealthFailure.storage, HealthFailure.unknown, HealthFailure.offline, HealthFailure.none};
  Future<bool> recover(String id, {bool automatic = true}) async {
    final provider = _providers[id], observation = _observations[id], bound = _context;
    if (_disposed || _paused || !_historyReady || store == null || activeRepairs>=1 || provider == null || observation == null || bound == null || bound.school.trim().isEmpty || bound.profile.trim().isEmpty || _restartQuarantine.containsKey(id) || _repairs.containsKey(id) || _checks.containsKey(id) || _forbidden.contains(observation.failure)) return false;
    // Policy never grants extra authority for a manual call.
    final plays = provider.playbooks.where((p) => p.failures.contains(observation.failure)).toList();
    if (plays.isEmpty || provider.dependencies.any((d) => observations[d]?.state != HealthState.healthy)) return false;
    final at = now();
    // Persisted, verified outcomes rank reviewed alternatives only. Registration
    // order breaks ties; history cannot create actions or bypass admission.
    var p = plays.first;
    for (final alternative in plays.skip(1)) {
      if (HealthRepairLearning.forPlaybook(history, id, alternative.id, at, failure: observation.failure, providerVersion: provider.version).preference >
          HealthRepairLearning.forPlaybook(history, id, p.id, at, failure: observation.failure, providerVersion: provider.version).preference) p = alternative;
    }
    final circuitWindow = plays.map((play) => play.circuitWindow).reduce((a,b) => a > b ? a : b);
    final attemptLimit = plays.map((play) => play.maxAttempts).reduce((a,b) => a < b ? a : b);
    final cooldown = plays.map((play) => play.cooldown).reduce((a,b) => a > b ? a : b);
    _attempts[id]=_history.where((e)=>e.component==id&&e.stage=='started'&&at.difference(e.at)<circuitWindow).length;
    if ((_attempts[id] ?? 0) >= attemptLimit) { _event(id, observation.failure, 'circuitOpen', playbook: p.id); return false; }
    final admissions = _history.where((e)=>e.component==id&&e.stage=='started'&&at.difference(e.at)<circuitWindow).toList();
    if (admissions.isNotEmpty) {
      final last = admissions.map((e)=>e.at).reduce((a,b)=>a.isAfter(b)?a:b);
      final persistedCooldown = last.add(cooldown * admissions.length);
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
        if (!await p.precondition(lease)) { _event(id, observation.failure, 'blocked', playbook: p.id); return; }
        lease.check();
        admitted = true;
        _attempts[id] = (_attempts[id] ?? 0) + 1;
        _nextAttempt[id] = now().add(cooldown * _attempts[id]!);
        if(!_event(id, observation.failure, 'started', playbook: p.id))throw StateError('Recovery admission history is full');
        // No action starts unless its crash-loop admission is durable.
        await flushHistory().timeout(const Duration(seconds: 2)); lease.check();
        if (!_durable) throw StateError('Recovery history could not be persisted');
        _observations[id] = HealthObservation(HealthState.recovering, failure: observation.failure, operation: observation.operation);
        _notify();
        await p.execute(lease); lease.check();
        final verified = await p.verify(lease); lease.check();
        if (!verified) throw StateError('Recovery outcome unverified');
        if (!_event(id, observation.failure, 'verified', playbook: p.id)) throw StateError('Verified outcome audit unavailable');
        verifiedThisAttempt = true;
        // Do not reset the session budget: repeated successful-but-recurring
        // faults still trip the circuit. A reviewed restart history may rearm.
        _observations[id] = HealthObservation(HealthState.healthy, verifiedAt: now(), operation: observation.operation);
      } catch (_) {
        if (generation == _generation && !_disposed) { _observations[id] = HealthObservation(HealthState.needsAttention, failure: observation.failure, operation: observation.operation); if(!_quarantinedRepairs.contains(id)) _event(id, observation.failure, admitted ? 'unverified' : 'blocked', playbook: p.id); }
      } finally { if (generation == _generation) _notify(); }
    });
    _repairs[id] = task;
    unawaited(task.whenComplete(() { if (identical(_repairs[id], task)) {_repairs.remove(id);_quarantinedRepairs.remove(id);} }));
    try { await task.timeout(p.timeout); }
    on TimeoutException { _quarantinedRepairs.add(id);if (generation == _generation) { _observations[id] = HealthObservation(HealthState.needsAttention, failure: observation.failure); _quarantine(id, observation.failure, 'timeout', playbook: p.id); } return false; }
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
    for (final state in [HealthState.needsAttention, HealthState.recovering, HealthState.degraded, HealthState.unknown, HealthState.monitoring, HealthState.paused]) { if (states.contains(state)) return state; }
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
  Future<void> dispose() async { if(_disposed)return;await stop(); _disposed = true; ++_generation; await _changes.close(); }
}

class HealthRepairLearning {
  const HealthRepairLearning(this.started, this.verified, this.failed);
  final int started, verified, failed;
  static HealthRepairLearning forPlaybook(Iterable<HealthEvent> history,
      String component, String playbook, DateTime now, {HealthFailure? failure, String? providerVersion}) {
    var starts = 0, success = 0, failures = 0;
    HealthEvent? pending;
    for (final event in history) {
      if (event.component != component || event.playbook != playbook ||
          failure != null && event.failure != failure ||
          providerVersion != null && event.providerVersion != providerVersion ||
          event.at.isAfter(now)) continue;
      if (event.stage == 'started') { pending = event; starts++; }
      if (pending != null && !event.at.isBefore(pending.at) &&
          {'verified', 'unverified', 'timeout'}.contains(event.stage)) {
        if (event.stage == 'verified') { success++; } else { failures++; }
        pending = null;
      }
    }
    return HealthRepairLearning(starts, success, failures);
  }
  int get preference => verified - failed * 2;
}
