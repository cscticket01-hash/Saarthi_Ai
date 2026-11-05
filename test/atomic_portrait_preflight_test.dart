import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/windows_connect/atomic_bundle_pilot.dart';
import '../lib/windows_connect/atomic_portrait_preflight.dart';

void main() {
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const uploadKey = 'photo-staged-atomic-original-0001';

  Uint8List sourcePhoto() {
    final image = img.Image(width: 480, height: 640);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgb(x, y, (x * 7 + y * 3) % 256,
            (x + y * 5) % 256, (x * 3 + y * 11) % 256);
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  test('existing school compressor makes a SHA-verifiable 40 KiB portrait '
      'without modifying the retained original', () {
    final original = sourcePhoto();
    final copy = Uint8List.fromList(original);
    final prepared = AtomicPortraitPreflight.prepare(original);
    expect(original, copy, reason: 'original school photo is immutable');
    expect(prepared.sourceBytes, original.length);
    expect(prepared.bytes.length, lessThanOrEqualTo(40 * 1024));
    expect(prepared.mime, anyOf('image/jpeg', 'image/png'));
    expect(prepared.sha256, sha256.convert(prepared.bytes).toString());
    expect(prepared.width, greaterThan(0));
    expect(prepared.height, greaterThan(0));
    expect(img.decodeImage(prepared.bytes), isNotNull);
    AtomicPortraitPreflight.verifyStagedBytes(
        prepared.bytes, prepared.mime);
  });

  test('TEST photo stage submits only verified compressed bytes and never '
      'manufactures a Google Drive receipt', () async {
    final original = sourcePhoto();
    final retained = Uint8List.fromList(original);
    var calls = 0;
    final proof = await AtomicBundlePilot.stagePortrait(
      school: school,
      uploadKey: uploadKey,
      name: 'portrait.jpg',
      original: original,
      isolatedTest: true,
      request: (action, body) async {
        calls++;
        expect(action, 'managed/live/bundle-stage');
        expect(body['kind'], 'photo');
        expect(body['mime'], anyOf('image/jpeg', 'image/png'));
        expect(body['name'], matches(RegExp(r'portrait\\.(jpg|png)\
        final encoded = Uint8List.fromList(
            base64Decode(body['base64'] as String));
        expect(encoded.length, lessThanOrEqualTo(40 * 1024));
        expect(body['sha256'], sha256.convert(encoded).toString());
        expect(body['sizeBytes'], encoded.length);
        AtomicPortraitPreflight.verifyStagedBytes(
            encoded, body['mime'] as String);
        final id = sha256.convert(
            utf8.encode(jsonEncode([school, uploadKey]))).toString();
        return {
          'success': true,
          'schoolId': school,
          'bundleProtocol': 1,
          'mediaReady': true,
          'cloudflareAccepted': true,
          'driveVerified': false,
          'media': {
            'kind': 'photo',
            'id': id,
            'uploadKey': uploadKey,
            'sha256': body['sha256'],
            'sizeBytes': encoded.length,
            'mime': body['mime'],
          }
        };
      },
    );
    expect(calls, 1);
    expect(proof['kind'], 'photo');
    expect(proof.containsKey('driveVerified'), isFalse);
    expect(original, retained);
  });

  test('spoofed photo MIME, corrupt bytes, oversize photo and disabled '
      'TEST pilot never reach cloud', () async {
    var calls = 0;
    Future<Map<String,dynamic>> neverCalled(String _, Map<String,dynamic> __) async {
      calls++;
      return {};
    }
    final valid = AtomicPortraitPreflight.prepare(sourcePhoto());
    await expectLater(AtomicBundlePilot.stage(
      school: school, kind: 'photo', uploadKey: uploadKey,
      name: 'portrait.png',
      mime: valid.mime == 'image/png' ? 'image/jpeg' : 'image/png',
      bytes: valid.bytes, isolatedTest: true, request: neverCalled,
    ), throwsFormatException);
    await expectLater(AtomicBundlePilot.stage(
      school: school, kind: 'photo', uploadKey: uploadKey,
      name: 'portrait.jpg', mime: 'image/jpeg',
      bytes: Uint8List.fromList([
        0xff, 0xd8, 0x12, 0x23, 0x34, 0x45, 0x56,
        0x67, 0x78, 0x9a, 0xff, 0xd9,
      ]), isolatedTest: true, request: neverCalled,
    ), throwsFormatException);
    await expectLater(AtomicBundlePilot.stage(
      school: school, kind: 'photo', uploadKey: uploadKey,
      name: 'portrait.jpg', mime: 'image/jpeg',
      bytes: Uint8List(40 * 1024 + 1),
      isolatedTest: true, request: neverCalled,
    ), throwsStateError);
    await expectLater(AtomicBundlePilot.stagePortrait(
      school: school, uploadKey: uploadKey, name: 'portrait.jpg',
      original: sourcePhoto(), request: neverCalled,
    ), throwsStateError);
    expect(calls, 0);
  });
}
)));
        final encoded = Uint8List.fromList(
            base64Decode(body['base64'] as String));
        expect(encoded.length, lessThanOrEqualTo(40 * 1024));
        expect(body['sha256'], sha256.convert(encoded).toString());
        expect(body['sizeBytes'], encoded.length);
        AtomicPortraitPreflight.verifyStagedBytes(
            encoded, body['mime'] as String);
        final id = sha256.convert(
            utf8.encode(jsonEncode([school, uploadKey]))).toString();
        return {
          'success': true,
          'schoolId': school,
          'bundleProtocol': 1,
          'mediaReady': true,
          'cloudflareAccepted': true,
          'driveVerified': false,
          'media': {
            'kind': 'photo',
            'id': id,
            'uploadKey': uploadKey,
            'sha256': body['sha256'],
            'sizeBytes': encoded.length,
            'mime': body['mime'],
          }
        };
      },
    );
    expect(calls, 1);
    expect(proof['kind'], 'photo');
    expect(proof.containsKey('driveVerified'), isFalse);
    expect(original, retained);
  });

  test('spoofed photo MIME, corrupt bytes, oversize photo and disabled '
      'TEST pilot never reach cloud', () async {
    var calls = 0;
    Future<Map<String,dynamic>> neverCalled(String _, Map<String,dynamic> __) async {
      calls++;
      return {};
    }
    final valid = AtomicPortraitPreflight.prepare(sourcePhoto());
    await expectLater(AtomicBundlePilot.stage(
      school: school, kind: 'photo', uploadKey: uploadKey,
      name: 'portrait.png', mime: 'image/png',
      bytes: valid.bytes, isolatedTest: true, request: neverCalled,
    ), throwsFormatException);
    await expectLater(AtomicBundlePilot.stage(
      school: school, kind: 'photo', uploadKey: uploadKey,
      name: 'portrait.jpg', mime: 'image/jpeg',
      bytes: Uint8List.fromList([
        0xff, 0xd8, 0x12, 0x23, 0x34, 0x45, 0x56,
        0x67, 0x78, 0x9a, 0xff, 0xd9,
      ]), isolatedTest: true, request: neverCalled,
    ), throwsFormatException);
    await expectLater(AtomicBundlePilot.stage(
      school: school, kind: 'photo', uploadKey: uploadKey,
      name: 'portrait.jpg', mime: 'image/jpeg',
      bytes: Uint8List(40 * 1024 + 1),
      isolatedTest: true, request: neverCalled,
    ), throwsStateError);
    await expectLater(AtomicBundlePilot.stagePortrait(
      school: school, uploadKey: uploadKey, name: 'portrait.jpg',
      original: sourcePhoto(), request: neverCalled,
    ), throwsStateError);
    expect(calls, 0);
  });
}
