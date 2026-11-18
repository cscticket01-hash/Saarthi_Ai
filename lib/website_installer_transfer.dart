/// A single cancellable website download session.
/// No fake progress is reported; totalBytes may be null when not supplied.
abstract class WebsiteInstallerTransfer {
  void start({
    required String url,
    required String filename,
    required void Function(int downloadedBytes, int? totalBytes) onProgress,
    required void Function() onTransferred,
    required void Function() onCancelled,
    required void Function(String error) onFailure,
  });

  void cancel();
}
