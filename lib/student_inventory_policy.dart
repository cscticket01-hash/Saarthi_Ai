/// Display policy only. No files, historical cards or sync entries are removed.
class StudentInventoryPolicy {
  static bool visible(Map<dynamic, dynamic> document) {
    // Match persisted generation metadata, never a filename/name supplied by
    // a user uploading a scanned ID as an ordinary school document.
    return document['documentKind'] != 'idCard' &&
        document['inventoryCategory'] != 'generatedIdCard';
  }
  // Imported scans are bounded separately from immutable financial/exam
  // originals and generated ID cards. Never invalidate those other modules.
  static const maxScanPages = 8;
  static const maxScanBytes = 500 * 1024;

  static bool isScan(Map<dynamic, dynamic> document) =>
      visible(document) &&
      document['deleted'] != true &&
      document['_syncDeleted'] != true &&
      !{'feeReceipt', 'marksheet'}.contains(document['documentKind']) &&
      !{'feeReceipt', 'examMarksheet'}.contains(document['inventoryCategory']);

  static ScanInventoryUsage usage(
    Iterable<Map<dynamic, dynamic>> documents, {
    String replacingId = '',
  }) {
    var bytes = 0, pages = 0;
    var unknown = false;
    for (final row in documents) {
      if (!isScan(row) ||
          (replacingId.isNotEmpty && row['documentId'] == replacingId)) {
        continue;
      }
      final size = row['sizeBytes'];
      if (size is int && size > 0) {
        bytes += size;
      } else {
        unknown = true;
      }
      final count = row['pageCount'];
      if (count is int && count > 0) {
        pages += count;
      } else {
        // Legacy photos occupy one page. Do not pretend an older multi-page
        // PDF is one page when no verified page count was retained.
        final mime = (row['optimizedMimeType'] ?? row['mimeType'] ?? '')
            .toString().toLowerCase();
        if (mime == 'image/jpeg' || mime == 'image/png') {
          pages++;
        } else {
          unknown = true;
        }
      }
    }
    return ScanInventoryUsage(bytes, pages, unknown);
  }
}

class ScanInventoryUsage {
  const ScanInventoryUsage(this.bytes, this.pages, this.unknown);
  final int bytes, pages;
  final bool unknown;

  String? problem({required int addingBytes, required int addingPages}) {
    if (unknown) {
      return 'An existing scan has unverified storage or page count. '
          'Review or replace that scan before adding more.';
    }
    if (addingPages < 1 || pages + addingPages > StudentInventoryPolicy.maxScanPages) {
      return 'This student can have at most 8 imported scan pages.';
    }
    if (addingBytes < 1 || bytes + addingBytes > StudentInventoryPolicy.maxScanBytes) {
      return 'This student can have at most 500 KB of optimized scans. '
          'Choose fewer pages or replace an existing scan.';
    }
    return null;
  }
}
