import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as image;

import '../document_processing_engine.dart';
import '../school_image_input.dart';
import 'universal_health.dart';

class ImageWorkerFault implements Exception {
  const ImageWorkerFault();
}

/// Fixed pure image code only: no paths, writes, network, PDF/native plugin or
/// business callback enters this isolate. Catalog data cannot select code.
void _imageEntry(List<dynamic> args) {
  final port = args[0] as SendPort;
  try {
    final input = args[1] as Map<String, dynamic>;
    final result = DocumentProcessingEngine.process(input);
    result['__imageInputFingerprint'] = DocumentWorkerOwner.inputFingerprint(
      input,
    );
    Isolate.exit(port, {'kind': 'result', 'value': result});
  } on FormatException {
    Isolate.exit(port, {'kind': 'invalid'});
  } catch (_) {
    Isolate.exit(port, {'kind': 'fault'});
  }
}

abstract class ImageWorkerHandle {
  Future<Map<String, dynamic>> get result;
  Future<void> get exited;
  void stop();
}

class _IsolatedImageHandle implements ImageWorkerHandle {
  _IsolatedImageHandle(Map<String, dynamic> input) {
    _port.listen((message) {
      if (message is Map && message['kind'] == 'result') {
        if (!_result.isCompleted)
          _result.complete(Map<String, dynamic>.from(message['value'] as Map));
      } else if (message is Map && message['kind'] == 'invalid') {
        if (!_result.isCompleted)
          _result.completeError(
            const FormatException('Owned image input was rejected.'),
          );
      } else if (message == null) {
        if (!_exit.isCompleted) _exit.complete();
        // The result and exit notification can be delivered on separate VM
        // turns. An exit without a result is a typed infrastructure fault.
        Timer.run(() {
          if (!_result.isCompleted)
            _result.completeError(const ImageWorkerFault());
        });
        _port.close();
      } else {
        if (!_result.isCompleted)
          _result.completeError(const ImageWorkerFault());
      }
    });
    Isolate.spawn(
      _imageEntry,
      [_port.sendPort, input],
      onExit: _port.sendPort,
      onError: _port.sendPort,
      errorsAreFatal: true,
    ).then(
      (isolate) {
        _isolate = isolate;
        if (_stopRequested) isolate.kill(priority: Isolate.immediate);
      },
      onError: (Object _, StackTrace __) {
        if (!_result.isCompleted)
          _result.completeError(const ImageWorkerFault());
        if (!_exit.isCompleted) _exit.complete();
        _port.close();
      },
    );
  }
  final _port = ReceivePort();
  final _result = Completer<Map<String, dynamic>>(), _exit = Completer<void>();
  Isolate? _isolate;
  bool _stopRequested = false;
  @override
  Future<Map<String, dynamic>> get result => _result.future;
  @override
  Future<void> get exited => _exit.future;
  @override
  void stop() {
    _stopRequested = true;
    _isolate?.kill(priority: Isolate.immediate);
  }
}

class _ImageTask {
  _ImageTask(this.key, this.scope, this.input);
  final String key;
  final HealthContext? scope;
  final Map<String, dynamic> input;
  bool settled = true;
  int repairs = 0;
  HealthFailure failure = HealthFailure.none;
}

/// Bounded processing-owner recovery. Retains at most one failed input and
/// one completed derived result. It never uploads or persists school data.
class DocumentWorkerOwner {
  DocumentWorkerOwner(
    this.engine, {
    ImageWorkerHandle Function(Map<String, dynamic>)? spawn,
    this.deadline = const Duration(seconds: 20),
    this.exitDeadline = const Duration(seconds: 2),
    this.autoRecover = false,
  }) : spawn = spawn ?? _IsolatedImageHandle {
    if (deadline <= Duration.zero ||
        deadline > const Duration(seconds: 20) ||
        exitDeadline <= Duration.zero ||
        exitDeadline > const Duration(seconds: 2))
      throw ArgumentError('Unbounded image worker recovery contract');
  }
  static final instance = DocumentWorkerOwner(
    UniversalHealth.instance,
    autoRecover: true,
  );
  final UniversalHealth engine;
  final ImageWorkerHandle Function(Map<String, dynamic>) spawn;
  final Duration deadline, exitDeadline;
  final bool autoRecover;
  final Map<String, Future<Map<String, dynamic>>> _active = {};
  final Map<String, HealthContext?> _activeScopes = {};
  final Map<String, Future<Map<String, dynamic>>> _requests = {};
  final List<Completer<void>> _waiting = [];
  int _running = 0, _reservedBytes = 0;
  _ImageTask? _failed;
  String? _cacheKey;
  HealthContext? _cacheScope;
  Map<String, dynamic>? _cache;
  DateTime? _verifiedAt;
  static String inputFingerprint(Map<String, dynamic> input) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            sha256.convert(input['bytes'] as Uint8List).toString(),
            input['kind'],
            input['targetBytes'],
          ]),
        ),
      )
      .toString();
  bool _scopeMatches(HealthContext? scope) =>
      scope != null && engine.context?.same(scope) == true;
  bool get canRepair =>
      !engine.paused &&
      _active.isEmpty &&
      _failed != null &&
      _scopeMatches(_failed!.scope) &&
      _failed!.settled &&
      _failed!.repairs == 0 &&
      {HealthFailure.worker, HealthFailure.timeout}.contains(_failed!.failure);
  Map<String, dynamic> _copy(Map<String, dynamic> value) => {
    for (final e in value.entries)
      if (e.key != '__imageInputFingerprint')
        e.key: e.value is Uint8List
            ? Uint8List.fromList(e.value as Uint8List)
            : e.value,
  };
  Future<void> _acquire() {
    if (_running < 2) {
      _running++;
      return Future.value();
    }
    final gate = Completer<void>();
    _waiting.add(gate);
    return gate.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  void _validate(_ImageTask task, Map<String, dynamic> result) {
    final bytes = result['optimized'], high = result['highQuality'];
    if (result['__imageInputFingerprint'] != inputFingerprint(task.input) ||
        bytes is! Uint8List ||
        high is! Uint8List ||
        result['originalBytes'] != (task.input['bytes'] as Uint8List).length ||
        result['actualBytes'] != bytes.length ||
        !{'image/png', 'image/jpeg'}.contains(result['mimeType']))
      throw const FormatException('Image owner result verification failed.');
    SchoolImageInput.validate(bytes);
    SchoolImageInput.validate(high);
    final info = image.findDecoderForData(bytes)?.startDecode(bytes);
    if (info == null ||
        info.width != result['width'] ||
        info.height != result['height'])
      throw const FormatException(
        'Image owner dimensions verification failed.',
      );
  }

  Future<Map<String, dynamic>> process(Map<String, dynamic> input) {
    final bytes = input['bytes'] as Uint8List;
    if (bytes.length > DocumentProcessingEngine.sourceLimit)
      return Future.error(
        const FormatException(
          'Image processing capacity unavailable; original retained.',
        ),
      );
    final scope = engine.context;
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              scope?.fingerprint,
              sha256.convert(bytes).toString(),
              input['kind'],
              input['targetBytes'],
            ]),
          ),
        )
        .toString();
    if (_requests.containsKey(key)) return _requests[key]!;
    if (_active.containsKey(key)) return _active[key]!;
    if (_cacheKey == key && _cache != null && _scopeMatches(scope))
      return Future.value(_copy(_cache!));
    if (_requests.length >= 8 ||
        _reservedBytes + bytes.length > 100 * 1024 * 1024)
      return Future.error(
        const FormatException(
          'Image processing capacity unavailable; original retained.',
        ),
      );
    final task = _ImageTask(key, scope, _copy(input));
    final future = _run(task);
    _requests[key] = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_requests[key], future)) _requests.remove(key);
        },
        onError: (Object _, StackTrace __) {
          if (identical(_requests[key], future)) _requests.remove(key);
        },
      ),
    );
    return future;
  }

  Future<Map<String, dynamic>> _run(_ImageTask task, {RecoveryLease? lease}) {
    final completer = Completer<Map<String, dynamic>>();
    _active[task.key] = completer.future;
    _activeScopes[task.key] = task.scope;
    _reservedBytes += (task.input['bytes'] as Uint8List).length;
    unawaited(() async {
      await _acquire();
      ImageWorkerHandle? handle;
      var released = false;
      void release() {
        if (released) return;
        released = true;
        _active.remove(task.key);
        _activeScopes.remove(task.key);
        _reservedBytes -= (task.input['bytes'] as Uint8List).length;
        _release();
      }

      try {
        lease?.check();
        task.settled = false;
        handle = spawn(_copy(task.input));
        final result = await handle.result.timeout(deadline);
        // Completion must also prove the owned process settled; do not admit
        // another worker while a timed-out or uncooperative isolate is alive.
        await handle.exited.timeout(exitDeadline);
        task.settled = true;
        lease?.check();
        _validate(task, result);
        lease?.check();
        if (_scopeMatches(task.scope)) {
          _cacheKey = task.key;
          _cacheScope = task.scope;
          _cache = _copy(result);
          _verifiedAt = engine.now();
          if (_failed?.key == task.key) _failed = null;
        }
        task.failure = HealthFailure.none;
        completer.complete(_copy(result));
      } catch (error, stack) {
        task.failure = error is TimeoutException
            ? HealthFailure.timeout
            : error is ImageWorkerFault
            ? HealthFailure.worker
            : error is FormatException
            ? HealthFailure.decoding
            : HealthFailure.unknown;
        if (handle != null) {
          handle.stop();
          try {
            await handle.exited.timeout(exitDeadline);
            task.settled = true;
          } catch (_) {
            unawaited(
              handle.exited.then((_) {
                task.settled = true;
                release();
              }),
            );
          }
        } else {
          task.settled = true;
        }
        if (_scopeMatches(task.scope)) _failed = task;
        if (task.settled) release();
        if (autoRecover &&
            lease == null &&
            canRepair &&
            engine.hasProvider('document-worker')) {
          try {
            engine.observe(
              'document-worker',
              HealthObservation(
                HealthState.degraded,
                failure: task.failure,
                operation: task.key,
              ),
            );
            if (await engine.recover('document-worker') &&
                _scopeMatches(task.scope) &&
                _cacheKey == task.key &&
                _cache != null) {
              completer.complete(_copy(_cache!));
              return;
            }
          } catch (_) {
            /* Optional guardian failure preserves the owner failure. */
          }
        }
        completer.completeError(error, stack);
      } finally {
        if (task.settled) release();
      }
    }());
    return completer.future;
  }

  HealthProvider provider() => HealthProvider(
    id: 'document-worker',
    version: '2.1',
    check: (scope) async {
      if (!_scopeMatches(scope))
        return const HealthObservation(HealthState.unknown);
      if (_failed != null && _scopeMatches(_failed!.scope) && !_failed!.settled)
        return HealthObservation(
          HealthState.needsAttention,
          failure: _failed!.failure,
        );
      final scopedPending=_activeScopes.values.where((c)=>c?.same(scope)==true).length;
      if (scopedPending>0)
        return HealthObservation(
          HealthState.monitoring,
          metrics: {'pending': scopedPending},
        );
      final failed = _failed;
      if (failed != null && _scopeMatches(failed.scope))
        return HealthObservation(
          HealthState.needsAttention,
          failure: failed.failure,
          operation: failed.key,
        );
      if (_cache != null && _cacheScope?.same(scope) == true)
        return HealthObservation(HealthState.healthy, verifiedAt: _verifiedAt);
      return const HealthObservation(HealthState.monitoring);
    },
    playbooks: [
      RecoveryPlaybook(
        id: 'restart-owned-image-worker',
        kind: RecoveryKind.statelessWorker,
        failures: {HealthFailure.worker, HealthFailure.timeout},
        timeout: const Duration(seconds: 30),
        cooldown: const Duration(minutes: 5),
        maxAttempts: 2,
        precondition: (lease) async =>
            lease.valid && canRepair && lease.operation == _failed?.key,
        execute: (lease) async {
          lease.check();
          if (!canRepair || lease.operation != _failed?.key)
            throw const ImageWorkerFault();
          final task = _failed!;
          task.repairs++;
          await _run(task, lease: lease);
          lease.check();
        },
        verify: (lease) async =>
            lease.valid &&
            _scopeMatches(lease.context) &&
            _active.isEmpty &&
            _failed == null &&
            _cacheKey == lease.operation &&
            _cache != null &&
            _verifiedAt != null &&
            !_verifiedAt!.isBefore(
              engine.now().subtract(const Duration(seconds: 30)),
            ),
      ),
    ],
  );
}
