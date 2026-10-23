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
