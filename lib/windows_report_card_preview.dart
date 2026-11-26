import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'windows_receipt_print_dialog.dart';
import 'windows_local_firestore.dart';

/// The common print dialog consumes the existing selected report renderer's
/// in-memory PDF. No hidden Flutter artwork, screenshot, file or sync write.
class WindowsReportCardPreview extends StatefulWidget {
  const WindowsReportCardPreview({super.key, required this.record,
    required this.createPdf});
  final Map<String, dynamic> record;
  final Future<Uint8List?> Function(Map<String, dynamic>) createPdf;

  static Future<bool> open(
    BuildContext context,
    Map<String, dynamic> record, {
    required Future<Uint8List?> Function(Map<String, dynamic>) createPdf,
  }) async {
    if (!context.mounted) return false;
    final db = FirebaseFirestore.instance;
    final profile = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    if (record['schoolId'] != null &&
        record['schoolId']?.toString() != school) {
      throw StateError('Report Card belongs to another school.');
    }
    // The existing selected renderer already resolves school branding,
    // template choice and student identity. Do not fetch them a second time.
    if (db.activeProfileId != profile ||
        (db.activeProfileIdentity['schoolSyncId']?.toString() ?? '') != school ||
        !context.mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (_) => WindowsReportCardPreview(
        record: Map<String, dynamic>.of(record), createPdf: createPdf,
      ),
    );
    return true;
  }

  @override
  State<WindowsReportCardPreview> createState() => _WindowsReportCardPreviewState();
}

class _WindowsReportCardPreviewState extends State<WindowsReportCardPreview> {
  final String _profile = FirebaseFirestore.instance.activeProfileId;
  final String _school = FirebaseFirestore.instance
      .activeProfileIdentity['schoolSyncId']?.toString() ?? '';
  late Future<Uint8List> _receipt;
  int _generation = 0;

  bool get _sameSchool {
    final db = FirebaseFirestore.instance;
    return db.activeProfileId == _profile &&
        (db.activeProfileIdentity['schoolSyncId']?.toString() ?? '') == _school;
  }

  @override
  void initState() {
    super.initState();
    _receipt = _prepare(++_generation);
  }

  Future<Uint8List> _prepare(int generation) async {
    bool current() => mounted && _sameSchool && generation == _generation;
    try {
      if (!current() ||
          (widget.record['schoolId'] != null &&
            widget.record['schoolId'].toString() != _school)) {
        throw StateError('School changed. Reopen this report card.');
      }
      final bytes = await widget.createPdf(Map<String, dynamic>.of(widget.record))
          .timeout(const Duration(seconds: 30));
      if (!current()) throw StateError('School changed. Reopen this report card.');
      if (bytes == null || bytes.length < 16 ||
          String.fromCharCodes(bytes.take(5)) != '%PDF-' ||
          !String.fromCharCodes(bytes.skip(bytes.length > 2048 ? bytes.length - 2048 : 0))
              .contains('%%EOF')) {
        throw const FormatException('Report renderer returned an incomplete PDF.');
      }
      return bytes;
    } catch (error) {
      // Do not log student data, URLs, credentials, or document contents.
      debugPrint('Report card preparation failed: ${error.runtimeType}');
      rethrow;
    }
  }

  void _retry() {
    if (!mounted || !_sameSchool) return;
    final next = _prepare(++_generation);
    setState(() { _receipt = next; });
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WindowsReceiptPrintDialog(
    receipt: _receipt,
    title: 'Report card',
    subtitle: 'Print preview',
    isCurrent: () => mounted && _sameSchool,
    onRetryDocument: _retry,
  );
}
