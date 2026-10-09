import 'package:flutter_test/flutter_test.dart';
import '../lib/release_download.dart';

void main() {
  Map<String, dynamic> release(String version, {bool draft=false, bool prerelease=false, String host='github.com', bool asset=true}) => {
    'tag_name':'windows-v$version', 'draft':draft, 'prerelease':prerelease,
    'assets': asset ? [{'name':'Setup_$version.exe','browser_download_url':'https://$host/cscticket01-hash/Saarthi_Ai/releases/download/windows-v$version/Setup_$version.exe'}] : []
  };
  test('selects numeric latest despite GitHub list ordering', () {
    expect(latestReleasedInstaller([release('2.1.99'),release('2.1.100'),release('2.1.9')], 'windows')!.path, contains('windows-v2.1.100/'));
  });
  test('ignores drafts, previews, unsafe URLs and missing installers', () {
    expect(latestReleasedInstaller([release('2.1.104',draft:true),release('2.1.103',prerelease:true),release('2.1.102',host:'example.com'),release('2.1.101',asset:false),release('2.1.100')], 'windows')!.path, contains('windows-v2.1.100/'));
  });
  test('does not select Windows for Android or an empty list', () {
    expect(latestReleasedInstaller([release('2.1.100')], 'android'), isNull);
    expect(latestReleasedInstaller([], 'windows'), isNull);
  });
}
