import 'website_installer_transfer.dart';

WebsiteInstallerTransfer createWebsiteInstallerTransfer() =>
    _UnsupportedWebsiteInstallerTransfer();

class _UnsupportedWebsiteInstallerTransfer implements WebsiteInstallerTransfer {
  @override
  void start({
    required String url,
    required String filename,
    required void Function(int downloadedBytes, int? totalBytes) onProgress,
    required void Function() onTransferred,
    required void Function() onCancelled,
    required void Function(String error) onFailure,
  }) {
    onFailure('Website downloads are supported in a browser only.');
  }

  @override
  void cancel() {}
}
