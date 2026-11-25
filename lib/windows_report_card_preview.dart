import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'windows_browser_print.dart';
import 'windows_exam_policy.dart';
import 'windows_local_firestore.dart';
import 'windows_save_pdf.dart';

/// Record-only report-card preview. Neither opening this dialog nor printing
/// it invokes the PDF renderer. Only Download Report Card calls createPdf.
class WindowsReportCardPreview extends StatefulWidget {
  const WindowsReportCardPreview({
    super.key,
    required this.record,
    required this.createPdf,
  });

  final Map<String, dynamic> record;
  final Future<Uint8List?> Function() createPdf;

  static Future<bool> open(
    BuildContext context,
    Map<String, dynamic> record, {
    required Future<Uint8List?> Function() createPdf,
  }) async {
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
        createPdf: createPdf,
      ),
    );
    return true;
  }

  @override
  State<WindowsReportCardPreview> createState() =>
      _WindowsReportCardPreviewState();
}

class _WindowsReportCardPreviewState extends State<WindowsReportCardPreview> {
  final GlobalKey _paperKey = GlobalKey();
  final String _profile = FirebaseFirestore.instance.activeProfileId;
  final String _school = FirebaseFirestore.instance
      .activeProfileIdentity['schoolSyncId']?.toString() ?? '';
  bool _busy = false;

  bool get _sameSchool {
    final db = FirebaseFirestore.instance;
    return db.activeProfileId == _profile &&
        (db.activeProfileIdentity['schoolSyncId']?.toString() ?? '') == _school;
  }

  void _guardSchool() {
    if (!_sameSchool) {
      throw StateError('School changed. Reopen this report card.');
    }
  }

  Future<void> _perform(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _guardSchool();
      await task();
      _guardSchool();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Report Card: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _print() => _perform(() async {
    // Flutter paints a PNG; the shared dialog builds temporary print-only bytes.
    await WidgetsBinding.instance.endOfFrame;
    _guardSchool();
    final boundary = _paperKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      throw StateError('Report preview is not ready to print.');
    }
    final image = await boundary.toImage(pixelRatio: 2.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final width = image.width;
    final height = image.height;
    image.dispose();
    if (data == null) throw StateError('Report image could not be rendered.');
    _guardSchool();
    if(!mounted)return;
    await WindowsBrowserPrint.openImages(context,[
      (png: data.buffer.asUint8List(), width: width, height: height),
    ],title:'Report card',isCurrent:()=>_sameSchool);
  });

  Future<void> _download() => _perform(() async {
    // This is intentionally the ONLY PDF-rendering action in this widget.
    _guardSchool();
    final pdf = await widget.createPdf();
    _guardSchool();
    if (pdf == null || pdf.isEmpty) {
      throw StateError('Selected report-card template unavailable.');
    }
    final exam = widget.record['examId']?.toString() ?? 'Exam';
    final student = widget.record['studentId']?.toString() ?? 'Student';
    final saved = await WindowsSavePdf.save(
      pdf, 'Report-Card-$exam-$student.pdf');
    _guardSchool();
    if (saved != null && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Report Card PDF saved.')),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    if (!_sameSchool) {
      return AlertDialog(
        title: const Text('School changed'),
        content: const Text('Close and reopen the report card.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
        ],
      );
    }
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 850),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Report Card Preview'),
              subtitle: const Text(
                'Record preview • No PDF is generated until Download Report Card'),
              trailing: IconButton(
                tooltip: 'Close preview',
                icon: const Icon(Icons.close),
                onPressed: _busy ? null : () => Navigator.pop(context),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: RepaintBoundary(
                    key: _paperKey,
                    child: _ReportCardPaper(record: widget.record),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _print,
                    icon: const Icon(Icons.print),
                    label: const Text('Print Report Card'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _download,
                    icon: const Icon(Icons.download),
                    label: const Text('Download Report Card'),
                  ),
                  if (_busy) const SizedBox(
                    height: 24, width: 24,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportCardPaper extends StatelessWidget {
  const _ReportCardPaper({required this.record});
  final Map<String, dynamic> record;

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
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: gold, width: 2),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Color(0xFF232323), fontSize: 14),
        child: Column(
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
                for (final entry in marks.entries)
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

          ],
        ),
      ),
    );
  }
}
