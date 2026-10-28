import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_admin_avatar.dart';
import '../lib/windows_profile_image_policy.dart';

void main() {
  test('linked Google photo takes priority over Firebase thumbnail', () {
    expect(
      verifiedGoogleAccountPhoto({
        'photoUrl': 'https://lh3.googleusercontent.com/old=s96-c',
        'providerUserInfo': [
          {'providerId': 'password', 'photoUrl': 'https://example.com/fake'},
          {
            'providerId': 'google.com',
            'photoUrl': 'https://lh3.googleusercontent.com/original=s96-c-rp',
          },
        ],
      }),
      'https://lh3.googleusercontent.com/original=s96-c-rp',
    );
    expect(
      verifiedGoogleAccountPhoto({'photoUrl': 'https://example.com/fake'}),
      '',
    );
  });
  test(
    'source rendition removes static crop instructions and preserves GIF URLs',
    () {
      expect(
        originalGoogleProfileImageUrl(
          'https://lh3.googleusercontent.com/photo=s96-c-rp',
        ),
        'https://lh3.googleusercontent.com/photo=s0',
      );
      expect(
        originalGoogleProfileImageUrl(
          'https://lh3.googleusercontent.com/a/s96-c/photo.jpg?sz=96',
        ),
        'https://lh3.googleusercontent.com/a/s0/photo.jpg',
      );
      expect(
        originalGoogleProfileImageUrl(
          'https://lh3.googleusercontent.com/a/photo.gif',
        ),
        'https://lh3.googleusercontent.com/a/photo.gif',
      );
      expect(
        originalGoogleProfileImageUrl('https://example.com/photo.gif'),
        '',
      );
    },
  );
  testWidgets(
    'original GIF retains two frames and animates without colour filtering',
    (tester) async {
      final bytes = base64Decode(
        'R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7',
      );
      final codec = await ui.instantiateImageCodec(bytes);
      expect(codec.frameCount, 2);
      codec.dispose();
      await tester.pumpWidget(
        MaterialApp(home: OriginalGoogleProfilePhoto(bytes: bytes)),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      final first = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(first, isNotNull);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image,
        isNot(same(first)),
      );
      expect(find.byType(ColorFiltered), findsNothing);
      expect(
        (tester.widget<Image>(find.byType(Image)).image as MemoryImage).bytes,
        same(bytes),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
