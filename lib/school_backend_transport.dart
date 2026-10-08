import 'platform/platform_config.dart';

/// Firebase administrator proof may be sent only to Google Apps Script hosts.
void requireSchoolBackendUri(Uri uri) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
      !{'script.google.com', 'script.googleusercontent.com'}.contains(uri.host)) {
    throw StateError('Untrusted school backend or redirect was blocked.');
  }
}

void requireSchoolProjectId(String project) {
  if(project == platformProjectId || !RegExp(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$').hasMatch(project)) {
    throw StateError('Use this school’s separate Firebase project. The developer Firebase is only for website monitoring and licensing.');
  }
}
