import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/rendering.dart';

import '../lib/windows_google_profile.dart';
import '../lib/windows_connect/google_authorization.dart';
import '../lib/windows_appearance.dart';
import '../lib/windows_theme_presets.dart';
import '../lib/windows_admin_settings_design.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_admin_avatar.dart';
import '../lib/windows_profile_image_policy.dart';

void main() {
  test('verified Gmail photo survives password sessions without storing OAuth credentials', () async {
    final values = <String, String>{};
    final store = WindowsGoogleProfileStore(
      read: (key) async => values[key],
      write: (key, value) async {
        values[key] = value;
      },
    );
    const account = GoogleSetupAccount(
      'google-sub',
      'admin@gmail.com',
      'secret-access-token',
      photoUrl: 'https://lh3.googleusercontent.com/photo.gif',
      refreshToken: 'secret-refresh-token',
    );
    await store.save(
      account,
      uid: 'school-user',
      school: 'school-a',
      email: 'ADMIN@gmail.com',
      isCurrent: () async => true,
    );
    expect(
      await store.photo(
        uid: 'school-user',
        school: 'school-a',
        email: 'admin@gmail.com',
      ),
      account.photoUrl,
    );
    for (final identity in [
      ('other-user', 'school-a', 'admin@gmail.com'),
      ('school-user', 'school-b', 'admin@gmail.com'),
      ('school-user', 'school-a', 'other@gmail.com'),
    ]) {
      expect(
        await store.photo(
          uid: identity.$1,
          school: identity.$2,
          email: identity.$3,
        ),
        '',
      );
    }
    expect(values.values.single, isNot(contains('secret-')));
    final original = Map<String, String>.from(values);
    await expectLater(
      store.save(
        account,
        uid: 'school-user',
        school: 'school-a',
        email: 'wrong@gmail.com',
        isCurrent: () async => true,
      ),
      throwsStateError,
    );
    await expectLater(
      store.save(
        account,
        uid: 'school-user',
        school: 'school-a',
        email: 'admin@gmail.com',
        isCurrent: () async => false,
      ),
      throwsStateError,
    );
    expect(values, original);
  });
  testWidgets(
    'passive avatar fallback and original photo render in every Settings theme',
    (tester) async {
      final original = WindowsAppearance.brandData;
      addTearDown(() {
        WindowsAppearance.applyBrand(original, persist: false);
        tester.binding.setSurfaceSize(null);
      });
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      final bytes = base64Decode(
        'R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7',
      );
      final key = GlobalKey();
      Widget page(bool photo) => MaterialApp(
        theme: WindowsAppearance.theme(
          WindowsAppearance.mode.value == ThemeMode.light
              ? Brightness.light
              : Brightness.dark,
        ),
        home: RepaintBoundary(
          key: key,
          child: WindowsAdminSettingsLayout(
            email: 'admin@gmail.com',
            name: '',
            authenticated: true,
            avatar: OriginalGoogleProfilePhoto(
              bytes: photo ? bytes : null,
              initial: 'A',
            ),
            year: '2026–27',
            month: 1,
            loadingYear: false,
            onMonthChanged: (_) {},
            onDevices: () {},
            onSchool: () {},
            onPasswords: () {},
            onAdvanced: () {},
          ),
        ),
      );
      for (final preset in windowsThemePresets) {
        WindowsAppearance.applyBrand({
          'schemaVersion': 1,
          'revision': 'test',
          'red': 0,
          'green': 140,
          'blue': 120,
          'presetId': preset.id,
        }, persist: false);
        expect(WindowsAppearance.presetId, preset.id);
        await tester.pumpWidget(page(false));
        await tester.pump();
        expect(find.text('A'), findsOneWidget);
        expect(find.textContaining('Connect Gmail'), findsNothing);
        expect(find.byType(OriginalGoogleProfilePhoto), findsOneWidget);
        await tester.pumpWidget(page(true));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        final provider =
            tester.widget<Image>(find.byType(Image)).image as MemoryImage;
        expect(provider.bytes, same(bytes));
        expect(find.byType(ColorFiltered), findsNothing);
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final shot = await boundary.toImage();
          final png = await shot.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/google-profile-review/${preset.id}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
          shot.dispose();
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
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
  testWidgets('missing Google photo uses a passive, non-clickable initial', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OriginalGoogleProfilePhoto(bytes: null, initial: 'School'),
        ),
      ),
    );
    expect(find.text('S'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Connect'), findsNothing);
    expect(tester.takeException(), isNull);
  });
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
