import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saarthi_ai/windows_verified_update.dart';

const url =
    'https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/windows-v2.1.999/Vidya_Saarthi_Setup_2.1.999.exe';

class StreamClient extends http.BaseClient {
  StreamClient(this.response);
  final http.StreamedResponse response;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response;
  @override
  void close() {
    closed = true;
  }
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('verified-installer-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  final bytes = utf8.encode('synthetic executable bytes'),
      digest = sha256
          .convert(utf8.encode('synthetic executable bytes'))
          .toString();
  test('verified exact release bytes reach final file only after hash and size check', () async {
    final target = File('${dir.path}/setup.exe');
    final file = await downloadVerifiedWindowsInstaller(
      url: url,
      digest: 'sha256:$digest',
      sizeBytes: bytes.length,
      destination: target,
      client: MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    expect(await file.readAsBytes(), bytes);
    expect(await dir.list().length, 1);
  });
  test('truncated or corrupt installer never replaces an existing file and removes temporary bytes', () async {
    for (final payload in [
      bytes.sublist(1),
      List<int>.filled(bytes.length, 42),
    ]) {
      final target = File('${dir.path}/setup.exe');
      await target.writeAsString('existing verified installer');
      await expectLater(
        downloadVerifiedWindowsInstaller(
          url: url,
          digest: digest,
          sizeBytes: bytes.length,
          destination: target,
          client: MockClient((_) async => http.Response.bytes(payload, 200)),
        ),
        throwsStateError,
      );
      expect(await target.readAsString(), 'existing verified installer');
      expect(await dir.list().length, 1);
    }
  });
  test(
    'stalled response body times out and leaves no executable or partial file',
    () async {
      final body = StreamController<List<int>>(),
          client = StreamClient(http.StreamedResponse(body.stream, 200));
      await expectLater(
        downloadVerifiedWindowsInstaller(
          url: url,
          digest: digest,
          sizeBytes: bytes.length,
          destination: File('${dir.path}/setup.exe'),
          client: client,
          idleTimeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(client.closed, true);
      expect(await dir.list().length, 0);
      await body.close();
    },
  );
  test('headers are bounded and insecure, foreign and unverified releases are rejected', () async {
    for (final bad in [
      url.replaceFirst('https:', 'http:'),
      url.replaceFirst('github.com', 'foreign.example'),
    ]) {
      await expectLater(
        downloadVerifiedWindowsInstaller(
          url: bad,
          digest: digest,
          sizeBytes: bytes.length,
          destination: File('${dir.path}/setup.exe'),
        ),
        throwsStateError,
      );
    }
    await expectLater(
      downloadVerifiedWindowsInstaller(
        url: url,
        digest: '',
        sizeBytes: bytes.length,
        destination: File('${dir.path}/setup.exe'),
      ),
      throwsStateError,
    );
  });
}
