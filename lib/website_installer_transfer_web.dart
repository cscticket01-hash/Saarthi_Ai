import 'dart:async';
import 'dart:html' as html;

import 'website_installer_transfer.dart';

WebsiteInstallerTransfer createWebsiteInstallerTransfer() =>
    _BrowserWebsiteInstallerTransfer();

/// XHR is used only for the public, origin-allowlisted installer endpoint.
/// The native browser download starts only AFTER the cancellable transfer
/// finishes; the page never claims to cancel a native download already saved.
class _BrowserWebsiteInstallerTransfer implements WebsiteInstallerTransfer {
  html.HttpRequest? _request;
  bool _settled = false;
  bool _cancelled = false;

  @override
  void start({
    required String url,
    required String filename,
    required void Function(int downloadedBytes, int? totalBytes) onProgress,
    required void Function() onTransferred,
    required void Function() onCancelled,
    required void Function(String error) onFailure,
  }) {
    if (_request != null) {
      onFailure('Another download is already active.');
      return;
    }
    final req = html.HttpRequest();
    _request = req;
    void fail(String message) {
      if (_settled || _cancelled) return;
      _settled = true;
      onFailure(message);
    }

    req.onProgress.listen((event) {
      if (_settled || _cancelled) return;
      onProgress(event.loaded, event.lengthComputable ? event.total : null);
    });
    req.onError.listen((_) => fail(
        'The download server is unavailable. Please retry.'));
    req.onTimeout.listen((_) => fail(
        'The download timed out. Please retry.'));
    req.onAbort.listen((_) {
      if (_settled) return;
      _settled = true;
      _cancelled = true;
      onCancelled();
    });
    req.onLoad.listen((_) {
      if (_settled || _cancelled) return;
      if (req.status != 200 || req.response is! html.Blob) {
        fail('Unable to download installer (HTTP ${req.status}).');
        return;
      }
      final blob = req.response as html.Blob;
      if (blob.size == 0) {
        fail('The installer download was empty.');
        return;
      }
      try {
        // The verified file is handed to the browser only after transfer;
        // this does not claim the browser has saved it to disk.
        final objectUrl = html.Url.createObjectUrlFromBlob(blob);
        final link = html.AnchorElement(href: objectUrl)
          ..download = filename
          ..style.display = 'none';
        html.document.body?.append(link);
        link.click();
        link.remove();
        // Do not revoke synchronously: Chrome needs time to read the Blob.
        Future<void>.delayed(const Duration(seconds: 45), () {
          html.Url.revokeObjectUrl(objectUrl);
        });
        _settled = true;
        onTransferred();
      } catch (_) {
        fail('Unable to save the installer in this browser.');
      }
    });
    try {
      req
        ..open('GET', url, async: true)
        ..responseType = 'blob'
        ..timeout = 240000;
      req.send();
    } catch (_) {
      fail('The download could not be started.');
    }
  }

  @override
  void cancel() {
    if (_settled || _cancelled) return;
    _cancelled = true;
    _request?.abort();
    // req.onAbort is responsible for signalling the UI.
  }
}
