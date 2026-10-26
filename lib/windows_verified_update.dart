import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

final _activeInstallerTargets = <String>{};

/// Both Windows update entry points use the same bounded, verified download.
/// The installer is never exposed at its final path before digest verification.
Future<File> downloadVerifiedWindowsInstaller({
  required String url,
  required String digest,
  required int sizeBytes,
  required File destination,
  http.Client? client,
  Duration headerTimeout = const Duration(seconds: 30),
  Duration idleTimeout = const Duration(seconds: 30),
  Duration overallTimeout = const Duration(minutes: 15),
  void Function(double progress)? onProgress,
}) async {
  final uri = Uri.tryParse(url);
  final hash = digest.replaceFirst('sha256:', '');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'github.com' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !RegExp(
        r'^/cscticket01-hash/Saarthi_Ai/releases/download/windows-v[0-9]+\.[0-9]+\.[0-9]+/Vidya_Saarthi_Setup_[0-9]+\.[0-9]+\.[0-9]+\.exe$',
      ).hasMatch(uri.path) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
      sizeBytes <= 0) {
    throw StateError(
      'Verified Windows release URL, size and SHA-256 are required.',
    );
  }
  final parts = uri.pathSegments;
  final version = parts[4].substring('windows-v'.length);
  if (parts[5] != 'Vidya_Saarthi_Setup_$version.exe')
    throw StateError('Installer version does not match its release.');
  final targetKey = destination.absolute.path;
  if (!_activeInstallerTargets.add(targetKey))
    throw StateError('This installer is already downloading.');
  final transport = client ?? http.Client();
  final partial = File(
    '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.part',
  );
  IOSink? sink;
  StreamIterator<List<int>>? chunks;
  final watch = Stopwatch()..start();
  Duration budget(Duration limit) {
    final remaining = overallTimeout - watch.elapsed;
    if (remaining <= Duration.zero)
      throw TimeoutException('Windows update download deadline exceeded.');
    return remaining < limit ? remaining : limit;
  }

  try {
    final response = await transport
        .send(http.Request('GET', uri))
        .timeout(budget(headerTimeout));
    if (response.statusCode != 200 ||
        response.contentLength != null && response.contentLength != sizeBytes) {
      throw StateError('Windows installer size or response did not verify.');
    }
    await destination.parent.create(recursive: true);
    sink = partial.openWrite();
    chunks = StreamIterator(response.stream);
    var received = 0;
    while (await chunks.moveNext().timeout(budget(idleTimeout))) {
      received += chunks.current.length;
      if (received > sizeBytes)
        throw StateError('Windows installer exceeds verified size.');
      sink.add(chunks.current);
      await sink.flush().timeout(budget(idleTimeout));
      onProgress?.call(received / sizeBytes);
    }
    await sink.close().timeout(budget(idleTimeout));
    sink = null;
    if (received != sizeBytes ||
        (await sha256
                    .bind(partial.openRead())
                    .first
                    .timeout(budget(idleTimeout)))
                .toString() !=
            hash) {
      throw StateError(
        'Windows installer verification failed. Download again.',
      );
    }
    if (await destination.exists()) await destination.delete();
    return await partial.rename(destination.path);
  } finally {
    _activeInstallerTargets.remove(targetKey);
    transport.close();
    if (chunks != null) await chunks.cancel();
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
    }
    if (await partial.exists()) await partial.delete();
  }
}
