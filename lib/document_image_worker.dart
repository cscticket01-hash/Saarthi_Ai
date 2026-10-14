import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as image;

import 'document_processing_engine.dart';
import 'school_image_input.dart';

class ImageWorkerFault implements Exception {
  const ImageWorkerFault();
}

/// Fixed pure image code only: no paths, writes, network, PDF/native plugin or
/// business callback enters this isolate. No external callback selects worker code.
void _imageEntry(List<dynamic> args) {
  final port = args[0] as SendPort;
  try {
    final input = args[1] as Map<String, dynamic>;
    final result = DocumentProcessingEngine.process(input);
    result['__imageInputFingerprint'] = DocumentImageWorker.inputFingerprint(
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
  _ImageTask(this.key, this.input);
  final String key;
  final Map<String, dynamic> input;
  bool settled = true;
}

/// Document processing only: bounded workers, validated bytes and no recovery
/// engine, monitoring, telemetry, automatic retry, persistence or uploads.
class DocumentImageWorker {
  DocumentImageWorker({
    ImageWorkerHandle Function(Map<String, dynamic>)? spawn,
    this.deadline = const Duration(seconds: 20),
    this.exitDeadline = const Duration(seconds: 2),
  }) : spawn = spawn ?? _IsolatedImageHandle.new {
    if (deadline <= Duration.zero ||
        deadline > const Duration(seconds: 20) ||
        exitDeadline <= Duration.zero ||
        exitDeadline > const Duration(seconds: 2)) {
      throw ArgumentError('Unbounded image worker lifetime');
    }
  }
  static final instance = DocumentImageWorker();
  final ImageWorkerHandle Function(Map<String, dynamic>) spawn;
  final Duration deadline, exitDeadline;
  final Map<String, Future<Map<String, dynamic>>> _requests = {};
  final List<Completer<void>> _waiting = [];
  int _running = 0, _reservedBytes = 0;
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

  Future<Map<String, dynamic>> process(
    Map<String, dynamic> input, {
    String scope = '',
  }) {
    final bytes = input['bytes'] as Uint8List;
    if (bytes.length > DocumentProcessingEngine.sourceLimit) {
      return Future.error(
        const FormatException(
          'Image processing capacity unavailable; original retained.',
        ),
      );
    }
    final key = jsonEncode([scope, inputFingerprint(input)]);
    final existing = _requests[key];
    if (existing != null) return existing.then(_copy);
    if (_requests.length >= 8 ||
        _reservedBytes + bytes.length > 100 * 1024 * 1024) {
      return Future.error(
        const FormatException(
          'Image processing capacity unavailable; original retained.',
        ),
      );
    }
    final task = _ImageTask(key, _copy(input));
    final completer = Completer<Map<String, dynamic>>();
    _requests[key] = completer.future;
    _reservedBytes += bytes.length;
    unawaited(() async {
      await _acquire();
      ImageWorkerHandle? handle;
      var released = false;
      void release() {
        if (released) return;
        released = true;
        if (identical(_requests[key], completer.future)) _requests.remove(key);
        _reservedBytes -= (task.input['bytes'] as Uint8List).length;
        _release();
      }

      try {
        task.settled = false;
        handle = spawn(_copy(task.input));
        final result = await handle.result.timeout(deadline);
        await handle.exited.timeout(exitDeadline);
        task.settled = true;
        _validate(task, result);
        completer.complete(_copy(result));
      } catch (error, stack) {
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
        completer.completeError(error, stack);
      } finally {
        if (task.settled) release();
      }
    }());
    return completer.future.then(_copy);
  }
}
