/// Shared, pure selection policy for website-compatible Windows releases.
///
/// GitHub's releases endpoint is not a guarantee of highest semantic version:
/// Android releases and later backfills may appear first. Only a published
/// Windows release with its exact matching official installer is eligible.
class PublishedWindowsInstaller {
  const PublishedWindowsInstaller({
    required this.version,
    required this.fileName,
    required this.url,
    required this.notes,
    required this.digest,
    required this.sizeBytes,
  });

  final String version;
  final String fileName;
  final String url;
  final String notes;
  final String digest;
  final int sizeBytes;
}

/// Picks the highest valid numeric Windows version, independent of API order.
///
/// Does not fetch or download anything. The actual download remains protected
/// by the existing SHA-256/size verification policy.
PublishedWindowsInstaller? latestPublishedWindowsInstaller(List releases) {
  final tagPattern = RegExp(r'^windows-v(\d+)\.(\d+)\.(\d+)$');
  List<int>? bestParts;
  PublishedWindowsInstaller? best;

  for (final raw in releases) {
    if (raw is! Map || raw['draft'] == true || raw['prerelease'] == true) {
      continue;
    }
    final tag = raw['tag_name']?.toString() ?? '';
    final match = tagPattern.firstMatch(tag);
    if (match == null || raw['assets'] is! List) continue;

    final parts = [
      for (var index = 1; index <= 3; index++)
        int.tryParse(match.group(index)!) ?? -1,
    ];
    if (parts.any((part) => part < 0)) continue;
    if (bestParts != null) {
      var order = 0;
      for (var index = 0; index < 3; index++) {
        order = parts[index].compareTo(bestParts[index]);
        if (order != 0) break;
      }
      if (order <= 0) continue;
    }

    final version = parts.join('.');
    final fileName = 'Vidya_Saarthi_Setup_$version.exe';
    for (final rawAsset in raw['assets'] as List) {
      if (rawAsset is! Map || rawAsset['name'] != fileName) continue;
      final download = rawAsset['browser_download_url'];
      if (download is! String) continue;
      final uri = Uri.tryParse(download);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        continue;
      }
      final expected = [
        'cscticket01-hash',
        'Saarthi_Ai',
        'releases',
        'download',
        tag,
        fileName,
      ];
      if (uri.pathSegments.length != expected.length) continue;
      var valid = true;
      for (var index = 0; index < expected.length; index++) {
        if (uri.pathSegments[index] != expected[index]) {
          valid = false;
          break;
        }
      }
      if (!valid) continue;
      bestParts = parts;
      best = PublishedWindowsInstaller(
        version: version,
        fileName: fileName,
        url: download,
        notes: raw['body']?.toString() ?? '',
        digest: rawAsset['digest']?.toString() ?? '',
        sizeBytes: rawAsset['size'] is num
            ? (rawAsset['size'] as num).toInt()
            : 0,
      );
      break;
    }
  }
  return best;
}
