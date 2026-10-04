import 'windows_connect/school_drive_images.dart';
import 'windows_ui_localization.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'package:printing/printing.dart';

import 'windows_local_firestore.dart';
import 'school_document_renderer.dart';
import 'windows_student_id_cards.dart';

class WindowsDocumentTemplates {
  static Future<Map<String, dynamic>> selections() async =>
      (await FirebaseFirestore.instance
              .collection('school_settings')
              .doc('document_templates')
              .get())
          .data() ??
      {};
  static Future<Uint8List?> _image(dynamic raw) async {
    final source = raw?.toString().trim() ?? '';
    if (source.startsWith('data:image/')) {
      try {
        return Uint8List.fromList(UriData.parse(source).contentAsBytes());
      } catch (_) {
        return null;
      }
    }
    final u = Uri.tryParse(raw?.toString() ?? '');
    if (u == null || u.scheme != 'https') return null;
    try {
      return await schoolImageBytes(u.toString());
    } catch (_) {}
    return null;
  }

  static Future<Uint8List?> selected(
    String kind,
    Map<String, dynamic> data, {
    String qr = '',
  }) async {
    final v = (await selections())[kind];
    final profile = (await FirebaseFirestore.instance
                .collection('school_config')
                .doc('school_profile_cache')
                .get())
            .data() ??
        {};
    if (kind == 'studentId') {
      return renderWindowsStudentId(
        template: windowsStudentIdIndex(v),
        data: {
          'schoolName': profile['schoolName'] ?? profile['name'] ?? '',
          ...data,
        },
        qr: qr,
        photo: await _image(data['photoUrl']),
        logo: await _image(data['schoolLogoUrl'] ?? profile['logoUrl']),
        signature: await _image(
          data['principalSignatureUrl'] ?? profile['principalSignatureUrl'],
        ),
      );
    }
    return renderSchoolDocument(
      kind: kind,
      template: v is num ? v.toInt() : -1,
      data: {
        'schoolName': profile['schoolName'] ?? profile['name'] ?? '',
        ...data,
      },
      qr: qr,
      photo: await _image(data['photoUrl']),
      logo: await _image(data['schoolLogoUrl'] ?? profile['logoUrl']),
    );
  }

  static Future<void> preview(
    BuildContext context,
    Uint8List bytes, {
    String title = 'Document preview',
    VoidCallback? onDownload,
    VoidCallback? onPrint,
  }) =>
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: SizedBox(
            width: 900,
            height: 680,
            child: Column(
              children: [
                ListTile(
                  title: Text(title),
                  trailing: IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                  ),
                ),
                Expanded(
                  child: PdfPreview(
                    build: (_) => bytes,
                    allowPrinting: true,
                    allowSharing: true,
                    canChangePageFormat: false,
                    canChangeOrientation: false,
                  ),
                ),
                if (onDownload != null || onPrint != null)
                  Padding(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(spacing: 12, children: [
                        if (onPrint != null)
                          OutlinedButton.icon(
                              onPressed: onPrint,
                              icon: const Icon(Icons.print),
                              label: const Text('Print ID Card')),
                        if (onDownload != null)
                          FilledButton.icon(
                              onPressed: onDownload,
                              icon: const Icon(Icons.download),
                              label: const Text('Download PDF')),
                      ])),
              ],
            ),
          ),
        ),
      );
  static Future<bool> previewReport(
    BuildContext context,
    Map<String, dynamic> data,
  ) async {
    final bytes = await selected('reportCard', data);
    if (bytes == null) return false;
    if (context.mounted) await preview(context, bytes, title: 'Report card');
    return true;
  }
}

class SchoolDocumentTemplatesScreen extends StatefulWidget {
  const SchoolDocumentTemplatesScreen({super.key});
  @override
  State<SchoolDocumentTemplatesScreen> createState() =>
      _SchoolDocumentTemplatesScreenState();
}

class _SchoolDocumentTemplatesScreenState
    extends State<SchoolDocumentTemplatesScreen> {
  static final _names = <String, List<String>>{
    ...schoolTemplateNames,
    'studentId': windowsStudentIdNames,
  };
  String _kind = 'studentId';
  Map<String, dynamic> _selected = {};
  bool _loading = true;
  final Map<int, Future<Uint8List>> _thumbnails = {};

  Future<Uint8List> _thumbnail(int index) =>
      _thumbnails.putIfAbsent(index, () async {
        final bytes = await renderWindowsStudentId(
          template: index,
          data: _sample,
        );
        final page = await Printing.raster(bytes, pages: [0], dpi: 100).first;
        return page.toPng();
      });
  @override
  void initState() {
    super.initState();
    WindowsDocumentTemplates.selections().then((v) {
      if (mounted)
        setState(() {
          _selected = v;
          _loading = false;
        });
    });
  }

  Map<String, dynamic> get _sample => {
        'schoolName': 'Your School',
        'name': _kind == 'teacherId' ? 'Ananya Sharma' : 'Arup Das',
        'teacherId': 'T-0001',
        'designation': 'Senior Teacher',
        'subject': 'Mathematics',
        'class': 'Class 5',
        'studentClass': 'Class 5',
        'rollNo': '12',
        'parentName': 'Bikash Das',
        'contact': '9876543210',
        'address': '12 School Road, Silchar',
        'district': 'Cachar',
        'state': 'Assam',
        'pinCode': '788001',
        'dob': '15/03/2015',
        'examName': 'Final Examination',
        'marks': {'English': 84, 'Mathematics': 91, 'Science': 87},
        'fullMarks': 100,
        'totalMarks': 262,
        'percentage': '87.3',
        'result': 'PASS',
        'receiptNo': 'VS-000124',
        'dateText': '01/10/2026',
        'feeItems': {'Tuition fee': 1000, 'Exam fee': 200},
        'totalAmount': 1200,
        'paymentMode': 'Cash',
      };
  Future<void> _preview(int index) async {
    final bytes = _kind == 'studentId'
        ? await renderWindowsStudentId(
            template: index,
            data: _sample,
            qr: 'VIDYA_SAARTHI_PREVIEW_ONLY',
          )
        : await renderSchoolDocument(
            kind: _kind,
            template: index,
            data: _sample,
            qr: 'VIDYA_SAARTHI_PREVIEW_ONLY',
          );
    if (mounted)
      await WindowsDocumentTemplates.preview(
        context,
        bytes,
        title: index < 0 ? 'Default preview' : _names[_kind]![index],
      );
  }

  Future<void> _select(int index) async {
    await FirebaseFirestore.instance
        .collection('school_settings')
        .doc('document_templates')
        .set({
      _kind: index,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    if (mounted) setState(() => _selected[_kind] = index);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('School document templates')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _names.keys
                    .map(
                      (k) => ChoiceChip(
                        label: Text(
                          {
                            'studentId': 'Student ID',
                            'teacherId': 'Teacher ID',
                            'reportCard': 'Report card',
                            'receipt': 'Fee receipt',
                          }[k]!,
                        ),
                        selected: _kind == k,
                        onSelected: (_) => setState(() => _kind = k),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 14),
              const Text(
                'Preview first, then select one layout for the whole school. Student and teacher ID layouts are stored separately.',
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 20),
              if (_loading) const LinearProgressIndicator(),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 350,
                    mainAxisExtent: 360,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: _kind == 'studentId' ? 4 : 5,
                  itemBuilder: (ctx, n) {
                    final i = _kind == 'studentId' ? n : n - 1;
                    final chosen = _kind == 'studentId'
                        ? windowsStudentIdIndex(_selected[_kind])
                        : (_selected[_kind] as num?)?.toInt() ?? -1;
                    final active = i == chosen;
                    final portrait =
                        (_kind == 'studentId' || _kind == 'teacherId') &&
                            (_kind == 'studentId' ? i < 2 : i >= 2);
                    return Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color:
                              active ? const Color(0xFF00D9A5) : Colors.white12,
                          width: active ? 2 : 1,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _kind == 'teacherId'
                                      ? Icons.school_outlined
                                      : _kind == 'studentId'
                                          ? Icons.badge_outlined
                                          : Icons.description_outlined,
                                  color: Colors.tealAccent,
                                ),
                                const Spacer(),
                                if (active)
                                  const Icon(
                                    Icons.check_circle,
                                    color: Colors.tealAccent,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            if (_kind == 'studentId') ...[
                              Expanded(
                                child: Center(
                                  child: FutureBuilder<Uint8List>(
                                    future: _thumbnail(i),
                                    builder: (context, snapshot) => snapshot
                                            .hasData
                                        ? Image.memory(
                                            snapshot.data!,
                                            fit: BoxFit.contain,
                                          )
                                        : snapshot.hasError
                                            ? const Text(
                                                'Use Preview to view this design',
                                              )
                                            : const CircularProgressIndicator(),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            Text(
                              i < 0 ? 'Default' : _names[_kind]![i],
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              i < 0
                                  ? 'Standard school layout'
                                  : portrait
                                      ? 'Portrait • 54 × 85.6 mm'
                                      : _kind.endsWith('Id')
                                          ? 'Landscape • 85.6 × 54 mm'
                                          : 'Printable school document',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                            if (_kind != 'studentId') const Spacer(),
                            Row(
                              children: [
                                OutlinedButton(
                                  onPressed: () => _preview(i),
                                  child: const Text('Preview'),
                                ),
                                const SizedBox(width: 10),
                                FilledButton(
                                  onPressed: active ? null : () => _select(i),
                                  child: Text(
                                    active ? 'Selected' : 'Use for school',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
}
