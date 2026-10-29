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

  static Future<void> open(BuildContext context, Map<String, dynamic> payment) {
    final origin = FirebaseFirestore.instance.activeProfileId;
    final receipt = bytes(Map<String, dynamic>.from(payment));
    return showDialog<void>(context: context, builder: (_) => WindowsReceiptPrintDialog(
      receipt: receipt, title: 'Receipt ${payment['receiptNo'] ?? ''}',
      subtitle: '${payment['studentName'] ?? ''} • ${payment['month'] ?? ''}',
      isCurrent: () => origin == FirebaseFirestore.instance.activeProfileId,
    ));
  }
}
