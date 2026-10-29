import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

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
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 1050,
          height: 760,
          child: Column(
            children: [
              ListTile(
                title: Text('Receipt ${payment['receiptNo'] ?? ''}'),
                subtitle: Text(
                  '${payment['studentName'] ?? ''} • ${payment['month'] ?? ''}',
                ),
                trailing: IconButton(
                  tooltip: 'Close receipt',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<Uint8List>(
                  future: receipt,
                  builder: (context, snapshot) {
                    if (origin != FirebaseFirestore.instance.activeProfileId)
                      return const Center(
                        child: Text('School changed. Reopen receipt history.'),
                      );
                    if (snapshot.hasError)
                      return Center(
                        child: SelectableText(
                          'Receipt unavailable: ${snapshot.error}',
                        ),
                      );
                    if (!snapshot.hasData)
                      return const Center(child: CircularProgressIndicator());
                    return PdfPreview(
                      build: (_) async {
                        if (origin !=
                            FirebaseFirestore.instance.activeProfileId)
                          throw StateError(
                            'School changed. Reopen receipt history.',
                          );
                        return snapshot.data!;
                      },
                      pdfFileName: '${payment['receiptNo'] ?? 'Receipt'}.pdf',
                      allowSharing: false,
                      allowPrinting: true,
                      canDebug: false,
                      canChangePageFormat: false,
                      canChangeOrientation: false,
                    );
                  },
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(10),
                child: Text(
                  'Print: choose printer, copies and pages in the system print settings.',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
