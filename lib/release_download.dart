Uri? latestReleasedInstaller(List releases, String platform) {
  final pattern = RegExp('^'+platform+r'-v(\d+)\.(\d+)\.(\d+)$');
  List<int>? best;
  Uri? selected;
  for (final release in releases) {
    if (release is! Map || release['draft'] == true || release['prerelease'] == true) continue;
    final match = pattern.firstMatch(release['tag_name'].toString());
    if (match == null || release['assets'] is! List) continue;
    final version = [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
    if (best != null) {
      var comparison = 0;
      for (var i = 0; i < 3; i++) {
        comparison = version[i].compareTo(best[i]);
        if (comparison != 0) break;
      }
      if (comparison <= 0) continue;
    }
    for (final asset in release['assets'] as List) {
      if (asset is! Map || !asset['name'].toString().endsWith(platform == 'windows' ? '.exe' : '.apk')) continue;
      final uri = Uri.tryParse(asset['browser_download_url'].toString());
      if (uri == null || uri.scheme != 'https' || uri.host != 'github.com' ||
          !uri.path.startsWith('/cscticket01-hash/Saarthi_Ai/releases/download/')) continue;
      best = version;
      selected = uri;
      break;
    }
  }
  return selected;
}
