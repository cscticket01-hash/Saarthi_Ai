import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'windows_receipt_print_dialog.dart';

import 'windows_backend_bridge.dart';
import 'windows_document_templates.dart';
import 'windows_local_firestore.dart';

/// Receipts stay inside the application. Drive is read through the authenticated
/// owner; no public URLs, browser navigation or new Google sign-in window.
class WindowsFeeReceiptPreview {
  static Future<Uint8List> bytes(Map<String, dynamic> payment) async {
    final db = FirebaseFirestore.instance,
        origin = FirebaseFirestore.instance.activeProfileId;
    void scope() {
      if (origin != db.activeProfileId ||
          payment['schoolId'] != null &&
              payment['schoolId'] != db.activeProfileIdentity['schoolSyncId'])
        throw StateError('School changed. Reopen receipt history.');
    }

    scope();
    final id = payment['receiptDocumentId']?.toString() ?? '';
    if (id.isNotEmpty) {
      final local =
          (await db.collection('_local_student_documents').doc(id).get())
              .data();
      final cloud = (await db.collection('documents').doc(id).get()).data();
      scope();
      final document = local ?? cloud;
      if (document == null ||
          document['studentId'] != payment['studentId'] ||
          document['deleted'] == true ||
          document['_syncDeleted'] == true)
        throw StateError(
          'Original receipt is pending download. Retry after sync.',
        );
      final result = await WindowsBackendBridge.documentBytes(document);
      scope();
      return result;
    }
    // Older payments store the complete receipt snapshot, without a document ID.
    final result = await WindowsDocumentTemplates.selected('receipt', payment);
    scope();
    if (result == null) throw StateError('Receipt record cannot be rendered.');
    return result;
  }

  /// Both collection and transaction history open this one direct preview.
  /// Preview bytes are temporary; Payment Save never calls this path.
  static Future<void> print(BuildContext context, Map<String, dynamic> payment) =>
      open(context, payment);

  static Future<void> open(BuildContext context, Map<String, dynamic> payment) {
    final db = FirebaseFirestore.instance;
    final profile = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId'];
    final saved = Map<String, dynamic>.from(payment);
    if (saved['schoolId'] != null && saved['schoolId'] != school) {
      throw StateError('Another school receipt cannot be displayed.');
    }
    bool current() => profile == db.activeProfileId &&
        school == db.activeProfileIdentity['schoolSyncId'];
    // Preserve saved historical PDF originals. Record-only payments render
    // from the school's currently selected receipt template, not a stale
    // template snapshot. Never mutate the payment or historical document.
    Future<Uint8List> prepare() async {
      if (!current()) throw StateError('School changed. Reopen receipt history.');
      final source = Map<String, dynamic>.of(saved)..remove('receiptTemplateSelection');
      final result = await bytes(source);
      if (!current()) throw StateError('School changed. Reopen receipt history.');
      return result;
    }
    return WindowsReceiptPrintDialog.openPrepared(context,prepare:prepare,
      title:'Receipt ${saved['receiptNo'] ?? ''}',
      subtitle:'${saved['studentName'] ?? ''} • ${saved['month'] ?? ''}',
      isCurrent:current);
  }
}
