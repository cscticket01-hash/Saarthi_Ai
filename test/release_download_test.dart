import 'package:flutter_test/flutter_test.dart';
import '../lib/release_download.dart';

void main() {
  Map<String, dynamic> release(String version, {bool draft=false, bool prerelease=false, String host='github.com', bool asset=true}) => {
    'tag_name':'windows-v$version', 'draft':draft, 'prerelease':prerelease,
    'assets': asset ? [{'name':'Vidya_Saarthi_Setup_$version.exe','browser_download_url':'https://$host/cscticket01-hash/Saarthi_Ai/releases/download/windows-v$version/Vidya_Saarthi_Setup_$version.exe'}] : []
  };
  test('selects numeric latest despite GitHub list ordering', () {
    expect(latestReleasedInstaller([release('2.1.99'),release('2.1.100'),release('2.1.9')], 'windows')!.path, contains('windows-v2.1.100/'));
  });
  test('ignores drafts, previews, unsafe URLs and missing installers', () {
    expect(latestReleasedInstaller([release('2.1.104',draft:true),release('2.1.103',prerelease:true),release('2.1.102',host:'example.com'),release('2.1.101',asset:false),release('2.1.100')], 'windows')!.path, contains('windows-v2.1.100/'));
  });
  test('Windows download ignores a non-installer EXE in a higher release', () {
    final unsafe = release('2.1.202');
    (unsafe['assets'] as List)[0] = {
      'name': 'random_app.exe',
      'browser_download_url': 'https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/windows-v2.1.202/random_app.exe',
    };
    final selected = latestReleasedInstaller(
      [unsafe, release('2.1.201')],
      'windows',
    );
    expect(selected!.path, contains('windows-v2.1.201/'));
  });

  test('Windows download refuses EXE from another Windows release tag', () {
    final wrong = release('2.1.210');
    (wrong['assets'] as List)[0] = {
      'name': 'Vidya_Saarthi_Setup_2.1.210.exe',
      'browser_download_url':
          'https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/windows-v2.1.209/Vidya_Saarthi_Setup_2.1.210.exe',
    };
    expect(
      latestReleasedInstaller([wrong, release('2.1.208')], 'windows')!.path,
      contains('windows-v2.1.208/'),
    );
  });

  test('does not select Windows for Android or an empty list', () {
    expect(latestReleasedInstaller([release('2.1.100')], 'android'), isNull);
    expect(latestReleasedInstaller([], 'windows'), isNull);
  });
}
