/// URLs are reconstructed only from an image reference in this school's profile.
String schoolProfileImageSource(Map<String, dynamic> profile, String prefix) {
  if (!const ['logo', 'seal', 'principalSignature'].contains(prefix)) {
    throw ArgumentError('Unsupported school image');
  }
  final source = profile['${prefix}Url']?.toString().trim() ?? '';
  if (source.startsWith('data:image/')) return source;
  final uri = Uri.tryParse(source);
  if (uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty)
    return source;
  final id = profile['${prefix}FileId']?.toString().trim() ?? '';
  if (RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(id)) {
    return 'https://drive.google.com/file/d/$id/view';
  }
  return '';
}

bool verifiedGoogleProfileImageUrl(String source) {
  final uri = Uri.tryParse(source);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (uri.host == 'googleusercontent.com' ||
          uri.host.endsWith('.googleusercontent.com'));
}

Map<String, dynamic> retainedAdminGoogleProfile({
  required Map<String, dynamic> previous,
  required Map<String, dynamic> verified,
  required String uid,
  required String schoolId,
}) {
  if (verifiedGoogleProfileImageUrl(verified['photoUrl']?.toString() ?? ''))
    return verified;
  if (previous['uid'] == uid &&
      previous['schoolId'] == schoolId &&
      verifiedGoogleProfileImageUrl(previous['photoUrl']?.toString() ?? '')) {
    return {
      'photoUrl': previous['photoUrl'],
      'displayName': previous['displayName'] ?? '',
    };
  }
  return {};
}

/// The fixed hash suffix prevents UID-prefix collisions during cache recovery.
bool adminAvatarCacheBelongsTo(String fileId, String uid) {
  if (uid.isEmpty) return false;
  final prefix = 'admin-profile-$uid-';
  return fileId.startsWith(prefix) &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(fileId.substring(prefix.length));
}

/// Prefer the linked Google identity over a Firebase profile thumbnail.
String verifiedGoogleAccountPhoto(Map account) {
  final providers = account['providerUserInfo'];
  if (providers is List) {
    for (final provider in providers) {
      if (provider is Map && provider['providerId'] == 'google.com') {
        final photo = provider['photoUrl']?.toString() ?? '';
        if (verifiedGoogleProfileImageUrl(photo)) return photo;
      }
    }
  }
  final photo = account['photoUrl']?.toString() ?? '';
  return verifiedGoogleProfileImageUrl(photo) ? photo : '';
}

/// Google's thumbnail suffix can request a cropped/static rendition. Request
/// the source rendition instead; never encode, recolour or flatten its bytes.
String originalGoogleProfileImageUrl(String source) {
  if (!verifiedGoogleProfileImageUrl(source)) return '';
  final uri = Uri.parse(source);
  final path = uri.path
      .replaceFirst(RegExp(r'=[swh]\d+[^/]*$'), '=s0')
      .replaceFirst(RegExp(r'/s\d+(?:-[^/]+)?/'), '/s0/');
  final query = Map<String, String>.from(uri.queryParameters)..remove('sz');
  final original = uri.replace(path: path, query: '');
  return query.isEmpty
      ? original.toString()
      : original.replace(queryParameters: query).toString();
}
