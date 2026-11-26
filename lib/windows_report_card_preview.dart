import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'windows_print_layout.dart';
import 'windows_receipt_print_dialog.dart';
import 'windows_exam_policy.dart';
import 'windows_local_firestore.dart';

/// Direct report print preview. The existing record artwork is captured only
/// into memory for the common print dialog; no saved or synced PDF is created.
class WindowsReportCardPreview extends StatefulWidget {
  const WindowsReportCardPreview({super.key, required this.record});
  final Map<String, dynamic> record;

  static Future<bool> open(
    BuildContext context,
    Map<String, dynamic> record,
  ) async {
    if (!context.mounted) return false;
    final db = FirebaseFirestore.instance;
    final profile = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    if (record['schoolId'] != null &&
        record['schoolId']?.toString() != school) {
      throw StateError('Report Card belongs to another school.');
    }
    Map<String, dynamic> branding = {};
    try {
      branding = (await db.collection('school_config')
                  .doc('school_profile_cache').get()).data() ?? {};
    } catch (_) {
      // The record can be previewed offline without school logo/branding.
    }
    if (db.activeProfileId != profile ||
        (db.activeProfileIdentity['schoolSyncId']?.toString() ?? '') != school) {
      throw StateError('School changed. Reopen this report card.');
    }
    if (!context.mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (_) => WindowsReportCardPreview(
        record: {...branding, ...record},
      ),
    );
    return true;
  }

  @override
  State<WindowsReportCardPreview> createState() => _WindowsReportCardPreviewState();
}

class _WindowsReportCardPreviewState extends State<WindowsReportCardPreview> {
  final GlobalKey _paperKey = GlobalKey();
  final Completer<Uint8List> _receipt = Completer<Uint8List>();
  final String _profile = FirebaseFirestore.instance.activeProfileId;
  final String _school = FirebaseFirestore.instance
      .activeProfileIdentity['schoolSyncId']?.toString() ?? '';
  late final List<Map<String, dynamic>> _pages;
  int _page = 0;
  bool _capturing = true;

  bool get _sameSchool {
    final db = FirebaseFirestore.instance;
    return db.activeProfileId == _profile &&
        (db.activeProfileIdentity['schoolSyncId']?.toString() ?? '') == _school;
  }

  @override
  void initState() {
    super.initState();
    final source = widget.record['marks'];
    final entries = source is Map
        ? Map<String, dynamic>.from(source).entries.toList()
        : <MapEntry<String, dynamic>>[];
    // Keep the existing native artwork, paginate instead of clipping a long
    // subject table, and repeat the whole-exam totals on every sheet.
    const perPage = 8;
    _pages = [
      for (var i = 0; i < entries.length; i += perPage)
        Map<String, dynamic>.fromEntries(entries.skip(i).take(perPage)),
    ];
    if (_pages.isEmpty) _pages.add({});
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_prepare()));
  }

  Future<void> _prepare() async {
    final images = <({Uint8List png, int width, int height})>[];
    try {
      for (var i = 0; i < _pages.length; i++) {
        if (!mounted || !_sameSchool) throw StateError('Report preview closed or school changed.');
        if (i != 0) {
          setState(() => _page = i);
          await WidgetsBinding.instance.endOfFrame;
        }
        if (!mounted || !_sameSchool) throw StateError('Report preview closed or school changed.');
        final boundary = _paperKey.currentContext?.findRenderObject();
        if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
          throw StateError('Report artwork is not ready.');
        }
        final image = await boundary.toImage(pixelRatio: 2.5);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) throw StateError('Report image could not be rendered.');
          images.add((png: data.buffer.asUint8List(), width: image.width, height: image.height));
        } finally {
          image.dispose();
        }
      }
      if (!mounted || !_sameSchool) throw StateError('Report preview closed or school changed.');
      final bytes = await WindowsPrintLayout.fromImages(images);
      if (!mounted || !_sameSchool) throw StateError('Report preview closed or school changed.');
      _receipt.complete(bytes);
    } catch (error, stack) {
      if (!_receipt.isCompleted) _receipt.completeError(error, stack);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    clipBehavior: Clip.none,
    children: [
      // Paint the record artwork behind the one visible print dialog, with no
      // hit testing or semantics. Opacity must be nonzero for toImage().
      if (_capturing) Positioned.fill(child: IgnorePointer(child: ExcludeSemantics(
        child: Opacity(opacity: 0.01, child: OverflowBox(
          alignment: Alignment.center,
          minWidth: 740, maxWidth: 740, minHeight: 0, maxHeight: double.infinity,
          child: RepaintBoundary(key: _paperKey,
            child: _ReportCardPaper(record: widget.record, visibleMarks: _pages[_page],
              page: _page + 1, pageCount: _pages.length)),
        )),
      ))),
      WindowsReceiptPrintDialog(receipt: _receipt.future,
        title: 'Report card', subtitle: 'Print preview', isCurrent: () => mounted && _sameSchool),
    ],
  );
}

class _ReportCardPaper extends StatelessWidget {
  const _ReportCardPaper({required this.record, required this.visibleMarks,
    required this.page, required this.pageCount});
  final Map<String, dynamic> record;
  final Map<String, dynamic> visibleMarks;
  final int page, pageCount;

  String value(String key, [String fallback = '—']) =>
      (record[key]?.toString().trim().isNotEmpty ?? false)
          ? record[key].toString() : fallback;

  @override
  Widget build(BuildContext context) {
    const maroon = Color(0xFF651F31);
    const gold = Color(0xFFBD9C48);
    final source = record['marks'];
    final marks = source is Map ? Map<String, dynamic>.from(source) : <String, dynamic>{};
    final full = WindowsExamPolicy.finiteNumber(record['fullMarks']) ?? 0;
    final pass = WindowsExamPolicy.finiteNumber(record['passMarks']) ?? 0;
    final total = WindowsExamPolicy.finiteNumber(record['totalMarks']) ??
        marks.values.fold<double>(0, (sum, m) =>
            sum + (WindowsExamPolicy.finiteNumber(m) ?? 0));
    final maximum = full * marks.length;
    final percentage = WindowsExamPolicy.finiteNumber(record['percentage']) ??
        (maximum > 0 ? total / maximum * 100 : 0);
    Widget info(String label, String data) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(width: 145,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
        Expanded(child: Text(data)),
      ]),
    );
    return Container(
      width: 740,
      constraints: const BoxConstraints(minHeight: 1046),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: gold, width: 2),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Color(0xFF232323), fontSize: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              color: maroon,
              child: Column(children: [
                Text(value('schoolName', 'School'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white, fontSize: 25, fontWeight: FontWeight.bold)),
                Text(value('schoolAddress', value('address', '')),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ]),
            ),
            const SizedBox(height: 20),
            const Text('STUDENT PROGRESS REPORT',
              textAlign: TextAlign.center,
              style: TextStyle(color: maroon, fontSize: 23,
                fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text('${value('examName', 'Exam')} • ${value('academicSession', 'Academic session not recorded')}',
              textAlign: TextAlign.center),
            const SizedBox(height: 18),
            const Divider(color: gold, thickness: 1.2),
            info('Student Name', value('studentName', value('name'))),
            info('Class', value('studentClass', value('class'))),
            info('Roll Number', value('rollNo')),
            info('Student ID', value('studentId')),
            const SizedBox(height: 18),
            Table(
              border: TableBorder.all(color: gold),
              columnWidths: const {
                0: FlexColumnWidth(2.8),
                1: FlexColumnWidth(),
                2: FlexColumnWidth(),
                3: FlexColumnWidth(1.5),
              },
              children: [
                TableRow(
                  decoration: const BoxDecoration(color: maroon),
                  children: [
                    for (final label in ['Subject', 'Full Marks', 'Pass Marks', 'Obtained'])
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(label, style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                  ],
                ),
                for (final entry in visibleMarks.entries)
                  TableRow(children: [
                    for (final value in [
                      entry.key,
                      full.toStringAsFixed(full % 1 == 0 ? 0 : 2),
                      pass.toStringAsFixed(pass % 1 == 0 ? 0 : 2),
                      entry.value.toString(),
                    ])
                      Padding(
                        padding: const EdgeInsets.all(9),
                        child: Text(value),
                      ),
                  ]),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border.all(color: gold),
                color: const Color(0xFFF9F3E8),
              ),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 12,
                children: [
                  Text('Total: ${total.toStringAsFixed(2)} / ${maximum.toStringAsFixed(2)}'),
                  Text('Percentage: ${percentage.toStringAsFixed(2)}%'),
                  Text('Result: ${value('result', 'Pending')}',
                    style: const TextStyle(
                      color: maroon, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 34),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Class Teacher'),
                Text('Principal'),
                Text('Parent / Guardian'),
              ],
            ),
            if (pageCount > 1) ...[
              const SizedBox(height: 16),
              Text('Page $page of $pageCount', textAlign: TextAlign.right),
            ],
          ],
        ),
      ),
    );
  }
}
