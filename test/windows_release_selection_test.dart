import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_release_selection.dart';

Map<String, Object?> windowsRelease(
  String version, {
  bool draft = false,
  bool prerelease = false,
  bool includeInstaller = true,
  String? assetName,
  String? url,
}) {
  final tag = 'windows-v$version';
  final name = assetName ?? 'Vidya_Saarthi_Setup_$version.exe';
  return {
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'body': 'Release $version',
    'assets': includeInstaller
        ? [
            {
              'name': name,
              'browser_download_url': url ??
                  'https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/$tag/$name',
              'size': 123456,
              'digest': 'sha256:test-digest',
            },
          ]
        : [],
  };
}

void main() {
  test('numeric latest Windows release wins regardless of API ordering', () {
    final selected = latestPublishedWindowsInstaller([
      windowsRelease('2.1.189'),
      windowsRelease('2.1.192'),
      windowsRelease('2.1.9'),
      {'tag_name': 'android-v4.1.100', 'assets': []},
      windowsRelease('2.1.191'),
    ]);
    expect(selected, isNotNull);
    expect(selected!.version, '2.1.192');
    expect(selected.fileName, 'Vidya_Saarthi_Setup_2.1.192.exe');
    expect(selected.sizeBytes, 123456);
    expect(selected.digest, 'sha256:test-digest');
  });

  test('skips draft, prerelease, missing and mismatched installer assets', () {
    final selected = latestPublishedWindowsInstaller([
      windowsRelease('2.1.203', draft: true),
      windowsRelease('2.1.202', prerelease: true),
      windowsRelease('2.1.201', includeInstaller: false),
      windowsRelease('2.1.200', assetName: 'random_program.exe'),
      windowsRelease('2.1.199',
          url: 'https://example.com/unverified-installer.exe'),
      windowsRelease('2.1.198'),
    ]);
    expect(selected!.version, '2.1.198');
  });

  test('rejects fake versions and wrong GitHub asset paths', () {
    expect(
      latestPublishedWindowsInstaller([
        windowsRelease('2.1.200-preview'),
        windowsRelease('2.1.201', url:
            'https://github.com/cscticket01-hash/OtherRepo/releases/download/windows-v2.1.201/Vidya_Saarthi_Setup_2.1.201.exe'),
      ]),
      isNull,
    );
  });

  test('no eligible Windows installer means no release', () {
    expect(latestPublishedWindowsInstaller([]), isNull);
    expect(latestPublishedWindowsInstaller([
      {'tag_name': 'android-v2.1.222', 'assets': []},
      windowsRelease('2.1.223', includeInstaller: false),
    ]), isNull);
  });
}
