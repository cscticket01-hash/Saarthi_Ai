import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/platform/github_updates.dart';

void main(){
  Map<String,dynamic> update()=>{'versionCode':473,'versionName':'1.0.473',
    'apkUrl':'https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/android-v1.0.473/Vidya-Saarthi-v1.0.473.apk',
    'sha256':List.filled(64,'a').join()};
  test('only this repository and the matching signed-APK release filename are accepted',(){
    validateAndroidUpdate(update());
    for(final changed in [
      {'apkUrl':'https://github.com/other/repo/releases/download/android-v1.0.473/Vidya-Saarthi-v1.0.473.apk'},
      {'versionCode':474},{'versionName':'windows-v2.1.80'},{'sha256':'invalid'},
      {'apkUrl':'https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/android-v1.0.473/another.apk'},
    ]){expect(()=>validateAndroidUpdate({...update(),...changed}),throwsStateError);}
  });
  test('static update transport failure uses validated release API fallback', () async {
    var calls = 0;
    final result = await latestAndroidUpdate(client: MockClient((request) async {
      calls++;
      if (request.url.host == 'github.com') throw TimeoutException('private provider text');
      return http.Response('[{"tag_name":"android-v1.0.473","assets":[{"name":"Vidya-Saarthi-v1.0.473.apk","browser_download_url":"https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/android-v1.0.473/Vidya-Saarthi-v1.0.473.apk"}]}]', 200);
    }));
    expect(calls, 2); expect(result['success'], true);
  });
  test('update diagnostics classify timeout and sanitize unexpected failures', () {
    expect(androidUpdateErrorMessage(TimeoutException('secret')), contains('took too long'));
    expect(androidUpdateErrorMessage(http.ClientException('secret')), contains('Check your connection'));
    expect(androidUpdateErrorMessage(StateError('secret')), isNot(contains('secret')));
  });
  test('stalled APK stream is cancelled and partial file removed, old APK retained', () async {
    final dir = await Directory.systemTemp.createTemp('update-test-');
    final destination = File('${dir.path}/update.apk');
    await destination.writeAsString('previous-download');
    final stream = StreamController<List<int>>();
    var cancelled = false;
    stream.onCancel = () { cancelled = true; };
    final client = _StreamClient(Stream<List<int>>.multi((controller) {
      final subscription = stream.stream.listen(controller.add, onError: controller.addError, onDone: controller.close);
      controller.onCancel = subscription.cancel;
      stream.add([1, 2, 3]);
    }));
    try {
      await expectLater(downloadAndroidUpdate(update(), destination, client: client,
        idleTimeout: const Duration(milliseconds: 15)), throwsA(isA<TimeoutException>()));
      expect(cancelled, true); expect(client.closed, true);
      expect(await File('${destination.path}.part').exists(), false);
      expect(await destination.readAsString(), 'previous-download');
    } finally { await stream.close(); await dir.delete(recursive: true); }
  });
  test('continuous download still has an overall deadline', () async {
    final dir = await Directory.systemTemp.createTemp('update-test-');
    final destination = File('${dir.path}/update.apk');
    final client = _StreamClient(Stream<List<int>>.periodic(const Duration(milliseconds: 5), (_) => [1]));
    try {
      await expectLater(downloadAndroidUpdate(update(), destination, client: client,
        idleTimeout: const Duration(seconds: 1), overallTimeout: const Duration(milliseconds: 25)),
        throwsA(isA<TimeoutException>()));
      expect(client.closed, true);
      expect(await File('${destination.path}.part').exists(), false);
      expect(await destination.exists(), false);
    } finally { await dir.delete(recursive: true); }
  });
  test('download progress reports real streamed bytes without guessing total', () async {
    final dir = await Directory.systemTemp.createTemp('update-progress-');
    final destination = File('${dir.path}/update.apk');
    final data = [1,2,3,4,5];
    final points = <int>[];
    final totals = <int?>[];
    try {
      final result = await downloadAndroidUpdate(
        {...update(), 'sha256':sha256.convert(data).toString()},
        destination,
        client:_StreamClient(Stream.fromIterable([[1,2],[3,4,5]])),
        onProgress:(received,total) { points.add(received);totals.add(total); });
      expect(await result.readAsBytes(), data);
      expect(points, [0,2,5,5]);
      expect(totals, everyElement(isNull));
    } finally { await dir.delete(recursive:true); }
  });

  test('verified APK is completed only after hash validation', () async {
    final dir = await Directory.systemTemp.createTemp('update-test-');
    final destination = File('${dir.path}/update.apk');
    final bytes = [1, 2, 3];
    try {
      final result = await downloadAndroidUpdate({...update(), 'sha256': sha256.convert(bytes).toString()}, destination,
        client: _StreamClient(Stream.value(bytes)));
      expect(await result.readAsBytes(), bytes);
      expect(await File('${destination.path}.part').exists(), false);
      await expectLater(downloadAndroidUpdate(update(), destination,
        client: _StreamClient(Stream.value(bytes))), throwsStateError);
      expect(await destination.readAsBytes(), bytes);
      expect(await File('${destination.path}.part').exists(), false);
    } finally { await dir.delete(recursive: true); }
  });

}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.stream);
  final Stream<List<int>> stream;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => http.StreamedResponse(stream, 200);
  @override
  void close() { closed = true; }
}
