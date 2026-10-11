/// Isolated bulk rendering core. No issuance, storage, sync or UI activation.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'id_card_engine.dart';
import 'id_card_manifest.dart';
import 'school_qr_link.dart';

Object? _canonical(Object? value, [int depth = 0]) {
  if (depth > 16) throw const FormatException('Bulk data nesting too deep.');
  if (value is Map) {
    if (value.length > 128)
      throw const FormatException('Too many bulk data fields.');
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('Bulk data keys must be strings.');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key], depth + 1)};
  }
  if (value is List) {
    if (value.length > 512)
      throw const FormatException('Bulk data list too long.');
    return value.map((item) => _canonical(item, depth + 1)).toList();
  }
  if (value == null ||
      value is String ||
      value is bool ||
      (value is num && value.isFinite))
    return value;
  throw const FormatException('Bulk data must be finite JSON values.');
}

String _digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();

Map<String, dynamic> _serializeTemplate(IdCardManifest template) => {
  'version': 1,
  'id': template.id,
  'canvasWidth': template.width,
  'canvasHeight': template.height,
  'printWidthMm': template.printWidth,
  'printHeightMm': template.printHeight,
  'regions': [
    for (final r in template.regions)
      {
        'key': r.key,
        'side': r.side,
        'kind': r.kind,
        'fit': r.fit,
        'align': r.align,
        'label': r.label,
        'required': r.isRequired,
        'padding': r.padding,
        'x': r.x,
        'y': r.y,
        'width': r.width,
        'height': r.height,
        'fontSize': r.fontSize,
        'minFontSize': r.minFontSize,
        'wrap': r.wrap,
        'maxLines': r.maxLines,
        'overflow': r.overflow,
        'focusX': r.focusX,
        'focusY': r.focusY,
        'allowOverlapWith': List<String>.from(r.allowOverlapWith),
      },
  ],
};

Map<String, Uint8List> _copyAssets(Map<String, Uint8List> assets) {
  if (assets.length > 16 ||
      assets.values.fold<int>(0, (sum, bytes) => sum + bytes.length) >
          8 * 1024 * 1024) {
    throw const FormatException('Per-card asset budget exceeded.');
  }
  return {for (final e in assets.entries) e.key: Uint8List.fromList(e.value)};
}

/// Inputs reference existing identities; this class never issues/replaces a QR.
class IdCardBulkStudent {
  IdCardBulkStudent({
    required this.schoolId,
    required this.classId,
    required this.studentId,
    required this.cardIssueId,
    required String qr,
    required Map<String, dynamic> data,
    Map<String, Uint8List> images = const {},
    Map<String, Uint8List> backgrounds = const {},
  }) : qr = IdCardEngine.compactQr(qr),
       _dataJson = jsonEncode(_canonical(data)),
       _images = _copyAssets(images),
       _backgrounds = _copyAssets(backgrounds) {
    if ([
      schoolId,
      classId,
      studentId,
      cardIssueId,
    ].any((v) => v.trim().isEmpty)) {
      throw const FormatException(
        'Bulk selection requires school, class, student and existing issue identity.',
      );
    }
    final link = SchoolLink.parse(this.qr);
    final issuingSchool = link.managed ? link.schoolId : link.projectId;
    if (issuingSchool != schoolId ||
        link.personId != studentId ||
        link.role != 'student') {
      throw const FormatException(
        'Existing QR does not match selected school/student.',
      );
    }
  }
  final String schoolId, classId, studentId, cardIssueId, qr, _dataJson;
  final Map<String, Uint8List> _images, _backgrounds;
  Map<String, dynamic> get durableSnapshot => {
    'schoolId': schoolId,
    'classId': classId,
    'studentId': studentId,
    'cardIssueId': cardIssueId,
    'qr': qr,
    'data': data,
    'images': {
      for (final e in _images.entries) e.key: base64Encode(e.value),
    },
    'backgrounds': {
      for (final e in _backgrounds.entries) e.key: base64Encode(e.value),
    },
  };
  static IdCardBulkStudent fromDurableSnapshot(Map<String, dynamic> value) {
    Map<String, Uint8List> bytes(Object? raw) {
      if (raw is! Map || raw.length > 16) {
        throw const FormatException('Invalid bulk assets.');
      }
      return {
        for (final entry in raw.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: base64Decode(entry.value as String),
      };
    }
    return IdCardBulkStudent(
      schoolId: value['schoolId'] as String,
      classId: value['classId'] as String,
      studentId: value['studentId'] as String,
      cardIssueId: value['cardIssueId'] as String,
      qr: value['qr'] as String,
      data: Map<String, dynamic>.from(value['data'] as Map),
      images: bytes(value['images']),
      backgrounds: bytes(value['backgrounds']),
    );
  }
  Map<String, dynamic> get data =>
      Map<String, dynamic>.from(jsonDecode(_dataJson) as Map);
  Map<String, Uint8List> get images => {
    for (final e in _images.entries) e.key: Uint8List.fromList(e.value),
  };
  Map<String, Uint8List> get backgrounds => {
    for (final e in _backgrounds.entries) e.key: Uint8List.fromList(e.value),
  };
  Map<String, dynamic> get _identity => {
    'schoolId': schoolId,
    'classId': classId,
    'studentId': studentId,
    'cardIssueId': cardIssueId,
    'qrSha256': sha256.convert(utf8.encode(qr)).toString(),
    'dataSha256': _digest(jsonDecode(_dataJson)),
    'imageHashes': {
      for (final e in _images.entries)
        e.key: sha256.convert(e.value).toString(),
    },
    'backgroundHashes': {
      for (final e in _backgrounds.entries)
        e.key: sha256.convert(e.value).toString(),
    },
  };
}

/// Explicit placement only; real duplex flip/calibration must be device-tested.
enum IdCardBackPlacement { samePositions, mirrorColumns, mirrorRows }

class IdCardBulkPlan {
  IdCardBulkPlan({
    required IdCardManifest template,
    required List<IdCardBulkStudent> students,
    this.landscape = false,
    this.gapMm = 3,
    this.minimumMarginMm = 10,
    this.backPlacement = IdCardBackPlacement.mirrorColumns,
  }) : _printWidthMm = template.printWidth,
       _printHeightMm = template.printHeight,
       _templateJson = jsonEncode(_canonical(_serializeTemplate(template))),
       students = List.unmodifiable(students) {
    if (students.isEmpty ||
        students.length > 500 ||
        !gapMm.isFinite ||
        gapMm < 0 ||
        gapMm > 20 ||
        !minimumMarginMm.isFinite ||
        minimumMarginMm < 0 ||
        minimumMarginMm > 50) {
      throw const FormatException(
        'Bulk selection/layout outside bounded limits.',
      );
    }
    final school = students.first.schoolId, classId = students.first.classId;
    final studentIds = <String>{}, issueIds = <String>{};
    var assetBytes = 0;
    if (template.regions.length > 128)
      throw const FormatException('Bulk template region limit exceeded.');
    for (final student in students) {
      assetBytes += [
        ...student._images.values,
        ...student._backgrounds.values,
      ].fold<int>(0, (sum, bytes) => sum + bytes.length);
      if (assetBytes > 128 * 1024 * 1024 || student._dataJson.length > 65536) {
        throw const FormatException('Bulk asset/data budget exceeded.');
      }
      if (student.schoolId != school ||
          student.classId != classId ||
          !studentIds.add(student.studentId) ||
          !issueIds.add(student.cardIssueId)) {
        throw const FormatException(
          'Bulk selection must contain unique students/issues from one school/class.',
        );
      }
      // Reject missing required content before generating any page.
      for (final region in template.regions.where((r) => r.isRequired)) {
        if (region.kind == 'image'
            ? student._images[region.key] == null
            : region.kind == 'qr'
            ? student.qr.isEmpty
            : (student.data[region.key]?.toString().trim().isEmpty ?? true)) {
          throw FormatException(
            'Required bulk field missing for selected student: ${region.key}',
          );
        }
      }
    }
    if (columns < 1 || rows < 1 || capacity > 64) {
      throw const FormatException(
        'Card template does not fit bounded A4 imposition.',
      );
    }
  }
  final String _templateJson;
  final double _printWidthMm, _printHeightMm;
  final List<IdCardBulkStudent> students;
  final bool landscape;
  final double gapMm, minimumMarginMm;
  final IdCardBackPlacement backPlacement;
  IdCardManifest get template => IdCardManifest.fromJson(
    Map<String, dynamic>.from(jsonDecode(_templateJson) as Map),
  );
  double get paperWidthMm => landscape ? 297 : 210;
  double get paperHeightMm => landscape ? 210 : 297;
  int get columns =>
      ((paperWidthMm - 2 * minimumMarginMm + gapMm) / (_printWidthMm + gapMm))
          .floor();
  int get rows =>
      ((paperHeightMm - 2 * minimumMarginMm + gapMm) / (_printHeightMm + gapMm))
          .floor();
  int get capacity => columns * rows;
  int get sheetCount => (students.length / capacity).ceil();
  double get leftMarginMm =>
      (paperWidthMm - columns * _printWidthMm - (columns - 1) * gapMm) / 2;
  double get topMarginMm =>
      (paperHeightMm - rows * _printHeightMm - (rows - 1) * gapMm) / 2;
  Map<String, dynamic> placement(int index, {required bool back}) {
    if (index < 0 || index >= students.length)
      throw RangeError.index(index, students);
    final slot = index % capacity;
    var row = slot ~/ columns, column = slot % columns;
    if (back && backPlacement == IdCardBackPlacement.mirrorColumns)
      column = columns - 1 - column;
    if (back && backPlacement == IdCardBackPlacement.mirrorRows)
      row = rows - 1 - row;
    return {
      'page': 2 * (index ~/ capacity) + (back ? 1 : 0),
      'leftMm': leftMarginMm + column * (_printWidthMm + gapMm),
      'topMm': topMarginMm + row * (_printHeightMm + gapMm),
      'widthMm': _printWidthMm,
      'heightMm': _printHeightMm,
    };
  }

  Map<String, dynamic> get manifest => {
    'version': 1,
    'schoolId': students.first.schoolId,
    'classId': students.first.classId,
    'templateSha256': _digest(jsonDecode(_templateJson)),
    'paperMm': [paperWidthMm, paperHeightMm],
    'gapMm': gapMm,
    'minimumMarginMm': minimumMarginMm,
    'backPlacement': backPlacement.name,
    'pageCount': sheetCount * 2,
    'cards': [
      for (var i = 0; i < students.length; i++)
        {
          ...students[i]._identity,
          'front': placement(i, back: false),
          'back': placement(i, back: true),
        },
    ],
  };
  String get selectionFingerprint => _digest(manifest);

  /// Self-contained, immutable school-scoped input for offline crash recovery.
  /// Contains student and image data: the caller MUST use protected app-local
  /// storage and never upload this checkpoint to analytics or a central server.
  Map<String, dynamic> get durableSnapshot => {
    'version': 1,
    'selectionFingerprint': selectionFingerprint,
    'template': jsonDecode(_templateJson),
    'landscape': landscape,
    'gapMm': gapMm,
    'minimumMarginMm': minimumMarginMm,
    'backPlacement': backPlacement.name,
    'students': [for (final item in students) item.durableSnapshot],
  };

  static IdCardBulkPlan fromDurableSnapshot(Map<String, dynamic> value) {
    if (value['version'] != 1 || value['students'] is! List) {
      throw const FormatException('Unsupported bulk checkpoint.');
    }
    final name = value['backPlacement'];
    final modes = IdCardBackPlacement.values.where((m) => m.name == name);
    if (modes.length != 1) {
      throw const FormatException('Invalid bulk back placement.');
    }
    final plan = IdCardBulkPlan(
      template: IdCardManifest.fromJson(
        Map<String, dynamic>.from(value['template'] as Map),
      ),
      students: [
        for (final row in value['students'] as List)
          IdCardBulkStudent.fromDurableSnapshot(
            Map<String, dynamic>.from(row as Map),
          ),
      ],
      landscape: value['landscape'] == true,
      gapMm: (value['gapMm'] as num).toDouble(),
      minimumMarginMm: (value['minimumMarginMm'] as num).toDouble(),
      backPlacement: modes.single,
    );
    if (value['selectionFingerprint'] != plan.selectionFingerprint) {
      throw const FormatException('Bulk checkpoint selection drift detected.');
    }
    return plan;
  }
}

class IdCardBulkCancelled implements Exception {
  const IdCardBulkCancelled(this.selectionFingerprint, this.completedStudents);
  final String selectionFingerprint;
  final int completedStudents;
  @override
  String toString() => 'Bulk rendering cancelled; no export committed.';
}

class IdCardBulkResult {
  IdCardBulkResult(
    Uint8List pdf,
    this.selectionFingerprint,
    Map<String, dynamic> manifest,
  ) : _pdf = Uint8List.fromList(pdf),
      _manifestJson = jsonEncode(_canonical(manifest));
  final Uint8List _pdf;
  final String _manifestJson, selectionFingerprint;
  Uint8List get pdf => Uint8List.fromList(_pdf);
  Map<String, dynamic> get manifest =>
      Map<String, dynamic>.from(jsonDecode(_manifestJson) as Map);
  String get pdfSha256 => sha256.convert(_pdf).toString();
}

class IdCardBulkEngine {
  /// Rebuilds the exact immutable selection. It does not publish partial PDFs.
  /// A caller persisting cancellation can pass the fingerprint to reject drift.
  static Future<IdCardBulkResult> render(
    IdCardBulkPlan plan, {
    bool Function()? isCancelled,
    void Function(int completed, int total)? onProgress,
    String? resumeSelectionFingerprint,
  }) async {
    final fingerprint = plan.selectionFingerprint;
    if (resumeSelectionFingerprint != null &&
        resumeSelectionFingerprint != fingerprint) {
      throw const FormatException(
        'Bulk resume selection/template changed; explicit new approval required.',
      );
    }
    var completed = 0;
    void guard() {
      if (isCancelled?.call() ?? false)
        throw IdCardBulkCancelled(fingerprint, completed);
    }

    guard();
    final font = await IdCardEngine.loadFont();
    guard();
    final pdf = pw.Document(theme: pw.ThemeData.withFont(base: font));
    final template = plan.template;
    for (var sheet = 0; sheet < plan.sheetCount; sheet++) {
      final start = sheet * plan.capacity;
      final end = math.min(start + plan.capacity, plan.students.length);
      final prepared = <PreparedIdCard>[];
      for (var index = start; index < end; index++) {
        guard();
        final student = plan.students[index];
        prepared.add(
          await IdCardEngine.prepare(
            template,
            student.data,
            qr: student.qr,
            images: student.images,
            backgrounds: student.backgrounds,
            font: font,
          ),
        );
      }
      for (final back in [false, true]) {
        guard();
        pdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat(
              plan.paperWidthMm * PdfPageFormat.mm,
              plan.paperHeightMm * PdfPageFormat.mm,
            ),
            margin: pw.EdgeInsets.zero,
            build: (_) => pw.Stack(
              children: [
                for (var index = start; index < end; index++)
                  pw.Positioned(
                    left:
                        (plan.placement(index, back: back)['leftMm']
                            as double) *
                        PdfPageFormat.mm,
                    top:
                        (plan.placement(index, back: back)['topMm'] as double) *
                        PdfPageFormat.mm,
                    child: pw.SizedBox(
                      width: template.printWidth * PdfPageFormat.mm,
                      height: template.printHeight * PdfPageFormat.mm,
                      child: pw.FittedBox(
                        fit: pw.BoxFit.contain,
                        child: prepared[index - start].buildSide(
                          back ? 'back' : 'front',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      }
      completed = end;
      onProgress?.call(completed, plan.students.length);
      // Let a UI cancellation event run; no queue/cloud operation is involved.
      await Future<void>.delayed(Duration.zero);
      guard();
    }
    final bytes = await pdf.save();
    guard();
    return IdCardBulkResult(bytes, fingerprint, plan.manifest);
  }
}
