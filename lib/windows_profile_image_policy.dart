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
  String verifiedEmail = '',
}) {
  if (verifiedGoogleProfileImageUrl(verified['photoUrl']?.toString() ?? ''))
    return verified;
  final source = previous['photoUrl']?.toString() ?? '';
  if (!verifiedGoogleProfileImageUrl(source)) return {};
  // Preserve the same managed Firebase identity's photo across password
  // sessions, including when the remote provider omits its photo field.
  final sameIdentity =
      previous['uid'] == uid && previous['schoolId'] == schoolId;
  // On the first managed login, the old school-cloud connection may already
  // have obtained this Gmail photo through explicit Google OAuth. A managed
  // Firebase password account has a different UID: reuse only this media URL
  // (never tokens or Drive credentials) when the verified emails are equal.
  final email = verifiedEmail.trim().toLowerCase();
  final previouslyGoogleAuthorized =
      previous['managed'] != true &&
      previous['accountSub'] is String &&
      (previous['accountSub'] as String).isNotEmpty &&
      email.isNotEmpty &&
      previous['email']?.toString().trim().toLowerCase() == email;
  if (!sameIdentity && !previouslyGoogleAuthorized) return {};
  return {
    'photoUrl': source,
    'displayName': previous['displayName'] ?? '',
  };
}

/// The fixed hash suffix prevents UID-prefix collisions during cache recovery.
bool adminAvatarCacheBelongsTo(String fileId, String uid) {
  if (uid.isEmpty) return false;
  final prefix = 'admin-profile-$uid-';
  return fileId.startsWith(prefix) &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(fileId.substring(prefix.length));
}

/// A school's already-connected Drive script may return its owner's profile
/// picture. It must be the SAME Gmail as the authenticated school admin.
/// Never use a developer/foreign Drive owner's avatar.
String verifiedSchoolDriveOwnerPhoto(Map<String, dynamic> reply, {
  required String schoolId,
  required String email,
}) {
  final expectedEmail = email.trim().toLowerCase();
  if (reply['success'] != true ||
      reply['storageReady'] != true ||
      reply['schoolId'] != schoolId ||
      schoolId.isEmpty ||
      expectedEmail.isEmpty ||
      reply['profilePhotoEmail']?.toString().trim().toLowerCase() != expectedEmail) {
    return '';
  }
  final source = reply['profilePhotoUrl']?.toString() ?? '';
  return verifiedGoogleProfileImageUrl(source) ? source : '';
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
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
    queryParameters: query.isEmpty ? null : query,
    fragment: uri.hasFragment ? uri.fragment : null,
  ).toString();
}
