/// Local, current-school profile only. A configured URL is authoritative;
/// do not revive an older base64 copy if that URL is unavailable.
String? idCardBrandingSource(Map<String,dynamic> profile, String prefix) {
  if (!const {'logo','principalSignature','seal'}.contains(prefix)) {
    throw ArgumentError('Unknown school branding slot');
  }
  final url = profile['${prefix}Url']?.toString().trim() ?? '';
  if (url.isNotEmpty) return url;
  final id = profile['${prefix}FileId']?.toString().trim() ?? '';
  if (id.isNotEmpty) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(id)) {
      throw const FormatException('Invalid saved school branding file ID');
    }
    return 'https://drive.google.com/file/d/$id/view';
  }
  final raw = profile['${prefix}Base64']?.toString().trim() ?? '';
  if (raw.isEmpty) return null;
  if (raw.startsWith('data:image/')) return raw;
  final mime = profile['${prefix}MimeType']?.toString() ?? 'image/png';
  if (!RegExp(r'^image/[a-zA-Z0-9.+-]+$').hasMatch(mime)) {
    throw const FormatException('Invalid saved school branding MIME type');
  }
  return 'data:$mime;base64,$raw';
}
