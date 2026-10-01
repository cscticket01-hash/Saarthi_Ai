/// Firebase administrator proof may be sent only to Google Apps Script hosts.
void requireSchoolBackendUri(Uri uri) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
      !{'script.google.com', 'script.googleusercontent.com'}.contains(uri.host)) {
    throw StateError('Untrusted school backend or redirect was blocked.');
  }
}
