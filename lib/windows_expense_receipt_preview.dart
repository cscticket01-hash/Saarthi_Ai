import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'windows_local_firestore.dart';
import 'windows_receipt_print_dialog.dart';

/// Read-only expense voucher generated from the exact existing expense row.
/// Does not create a payment, a new expense, a sync operation or a Drive file.
class WindowsExpenseReceiptPreview {
  static Future<Uint8List> bytes(Map<String, dynamic> expense, {
    String schoolName = 'SCHOOL EXPENSE',
    String schoolAddress = '',
  }) async {
    final amount = expense['amount'] is num
        ? (expense['amount'] as num).toDouble()
        : double.tryParse(expense['amount']?.toString() ?? '');
    if (amount == null || !amount.isFinite || amount <= 0) {
      throw StateError('Expense receipt requires the original saved positive amount.');
    }
    final pdf = pw.Document(title: 'School Expense Receipt');
    String value(String name, [String fallback = '—']) {
      final text = expense[name]?.toString().trim() ?? '';
      return text.isEmpty ? fallback : text;
    }
    final date = value('dateText');
    final id = value('expenseId');
    final style = pw.TextStyle(fontSize: 10);
    pw.Widget line(String label, String text) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 7),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.SizedBox(width: 135, child: pw.Text(label, style: pw.TextStyle(
          fontSize: 10, fontWeight: pw.FontWeight.bold))),
        pw.Expanded(child: pw.Text(text, style: style)),
      ]),
    );
    pdf.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(42),
      build: (_) => [
        pw.Center(child: pw.Text(schoolName,
          style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold))),
        if (schoolAddress.trim().isNotEmpty) pw.Center(child: pw.Text(schoolAddress,
          style: pw.TextStyle(fontSize: 9))),
        pw.SizedBox(height: 5),
        pw.Center(child: pw.Text('SCHOOL EXPENSE RECEIPT',
          style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold))),
        pw.SizedBox(height: 18),
        pw.Divider(),
        line('Receipt No.', id),
        line('Date', date),
        line('Expense', value('title')),
        line('Category', value('category', 'General')),
        line('Paid To / Vendor', value('paidTo')),
        line('Description', value('note')),
        pw.SizedBox(height: 10),
        pw.Divider(),
        pw.Align(alignment: pw.Alignment.centerRight,
          child: pw.Text('TOTAL: INR ${amount.toStringAsFixed(2)}',
            style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold))),
        pw.SizedBox(height: 28),
        pw.Text('This receipt reflects a saved school expense record.'),
      ]));
    return pdf.save();
  }

  static Future<void> open(BuildContext context, Map<String, dynamic> expense) {
    final db = FirebaseFirestore.instance;
    final profile = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    final owner = expense['schoolId']?.toString() ?? '';
    if (owner.isNotEmpty && owner != school) {
      throw StateError('Foreign-school expense receipt blocked.');
    }
    final original = Map<String, dynamic>.from(expense);
    bool current() => profile == db.activeProfileId &&
        school == (db.activeProfileIdentity['schoolSyncId']?.toString() ?? '');
    Future<Uint8List> receipt() async {
      if (!current()) throw StateError('School changed. Reopen receipt.');
      final details = (await db.collection('school_config')
          .doc('school_profile_cache').get()).data() ?? <String, dynamic>{};
      if (!current()) throw StateError('School changed. Reopen receipt.');
      return bytes(original,
        schoolName: (details['schoolName'] ?? 'SCHOOL EXPENSE').toString(),
        schoolAddress: (details['address'] ?? details['schoolAddress'] ?? '').toString(),
      );
    }
    return showDialog<void>(context: context,
      builder: (_) => WindowsReceiptPrintDialog(
        receipt: receipt(),
        title: 'Expense Receipt ${original['expenseId'] ?? ''}',
        subtitle: '${original['title'] ?? 'School Expense'} • ${original['dateText'] ?? ''}',
        isCurrent: current,
      ),
    );
  }
}
