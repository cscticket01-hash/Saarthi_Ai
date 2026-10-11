/// Display policy only. No files, historical cards or sync entries are removed.
class StudentInventoryPolicy {
  static bool visible(Map<String, dynamic> document) {
    // Match persisted generation metadata, never a filename/name supplied by
    // a user uploading a scanned ID as an ordinary school document.
    return document['documentKind'] != 'idCard' &&
        document['inventoryCategory'] != 'generatedIdCard';
  }
}
