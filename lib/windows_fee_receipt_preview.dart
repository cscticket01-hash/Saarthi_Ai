import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'windows_receipt_print_dialog.dart';

import 'windows_backend_bridge.dart';
import 'windows_document_templates.dart';
import 'windows_save_pdf.dart';
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

  /// New record-only payments display saved fields, without rendering a PDF.
  /// Historical receiptDocumentId payments retain the original PDF/print UI.
  static Future<void> open(BuildContext context, Map<String, dynamic> payment) {
    final db = FirebaseFirestore.instance;
    final origin = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId'];
    final saved = Map<String, dynamic>.from(payment);
    if (saved['schoolId'] != null && saved['schoolId'] != school) {
      throw StateError('Another school receipt cannot be displayed.');
    }
    final id = saved['receiptDocumentId']?.toString() ?? '';
    if (id.isNotEmpty) {
      final receipt = bytes(saved);
      return showDialog<void>(context: context,
        builder: (_) => WindowsReceiptPrintDialog(
          receipt: receipt, title: 'Receipt ${saved['receiptNo'] ?? ''}',
          subtitle: '${saved['studentName'] ?? ''} • ${saved['month'] ?? ''}',
          isCurrent: () => origin == db.activeProfileId &&
              school == db.activeProfileIdentity['schoolSyncId'],
        ));
    }
    String field(String key) {
      final value = saved[key]?.toString().trim() ?? '';
      return value.isEmpty ? '—' : value;
    }
    Widget line(String label, String key) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 110, child: Text(label,
          style: const TextStyle(fontWeight: FontWeight.bold))),
        Expanded(child: Text(field(key))),
      ]),
    );
    final safeNo = field('receiptNo').replaceAll(
      RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return showDialog<void>(context: context, builder: (dialog) => AlertDialog(
      title: Text('Fee Receipt ${field('receiptNo')}'),
      content: SizedBox(width: 430, child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Saved school record · No PDF generated on preview',
            style: TextStyle(fontSize: 12)),
          const Divider(),
          line('Student', 'studentName'),
          line('Student ID', 'studentId'),
          line('Class', 'class'),
          line('Roll', 'rollNo'),
          line('Month', 'month'),
          line('Receipt', 'receiptNo'),
          if (saved.containsKey('paidAmount')) line('Paid', 'paidAmount'),
          if (saved.containsKey('amount')) line('Amount', 'amount'),
          if (saved.containsKey('amountPaise')) line('Amount (paise)', 'amountPaise'),
          if (saved.containsKey('paymentDate')) line('Date', 'paymentDate'),
          if (saved.containsKey('paymentMode')) line('Payment mode', 'paymentMode'),
        ]),
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog),
          child: const Text('Close')),
        FilledButton.icon(
          onPressed: () async {
            if (db.activeProfileId != origin ||
                db.activeProfileIdentity['schoolSyncId'] != school) {
              Navigator.pop(dialog);
              return;
            }
            Navigator.pop(dialog);
            try {
              // This user-triggered action is the ONLY new receipt PDF render.
              final pdf = await bytes(saved);
              if (db.activeProfileId != origin ||
                  db.activeProfileIdentity['schoolSyncId'] != school) {
                throw StateError('School changed during receipt download.');
              }
              await WindowsSavePdf.save(pdf,
                'Fee_Receipt_${safeNo.isEmpty ? 'record' : safeNo}.pdf');
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Receipt download failed: $e')));
              }
            }
          },
          icon: const Icon(Icons.download_outlined),
          label: const Text('Download PDF'),
        ),
      ],
    ));
  }
}
