import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

/// Real OOXML workbook: strings stay strings and photos are embedded media.
/// The caller supplies only a pinned school's local snapshot and image reader.
class StudentExcelExport {
  static const columns = <String, String>{
    'photo': 'Photo',
    'name': 'Student name',
    'class': 'Class',
    'rollNo': 'Roll number',
    'uniqueStudentId': 'Student UID',
    'parentName': 'Parent name',
    'parentContact': 'Parent contact',
    'dateOfBirth': 'Date of birth',
    'joiningDate': 'Admission date',
    'hostelFacility': 'Hostel',
    'address': 'Address',
    'district': 'District',
    'state': 'State',
    'pinCode': 'PIN code',
    'id': 'Record ID',
  };
  static String xml(Object? s) => (s?.toString() ?? '')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  static Future<Uint8List> build({
    required String schoolId,
    required List<Map<String, dynamic>> students,
    required Future<Uint8List?> Function(String) imageReader,
    required void Function() checkSchool,
    void Function(int done, int total)? progress,
  }) async {
    if (schoolId.isEmpty)
      throw StateError('School identity is required for export.');
    checkSchool();
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final row in students) {
      if (row['_syncDeleted'] == true || row['deleted'] == true) continue;
      if (row['schoolId'] != null && row['schoolId'] != schoolId)
        throw StateError('Foreign school student blocked.');
      final label = (row['class'] ?? 'Unassigned').toString().trim();
      groups
          .putIfAbsent(label.isEmpty ? 'Unassigned' : label, () => [])
          .add(Map<String, dynamic>.from(row));
    }
    if (groups.isEmpty) throw StateError('No students to export.');
    final archive = Archive();
    void add(String path, Object content) {
      final b = content is String ? utf8.encode(content) : content as List<int>;
      archive.addFile(ArchiveFile(path, b.length, b));
    }

    String rel(String id, String type, String target) =>
        '<Relationship Id="$id" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/$type" Target="$target"/>';
    String relationships(String body) =>
        '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$body</Relationships>';
    const main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
    const r =
        'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
    final sheets = <String>[], overrides = <String>[];
    final usedNames = <String>{};
    var done = 0;
    final labels = groups.keys.toList()
      ..sort((a, b) {
        final x = int.tryParse(a.replaceAll(RegExp(r'\D'), '')) ?? 9999,
            y = int.tryParse(b.replaceAll(RegExp(r'\D'), '')) ?? 9999;
        return x != y ? x.compareTo(y) : a.compareTo(b);
      });
    final total = groups.values.fold<int>(0, (n, g) => n + g.length);
    for (var index = 0; index < labels.length; index++) {
      final n = index + 1, label = labels[index], rows = groups[label]!;
      rows.sort((a, b) {
        final x = int.tryParse('${a['rollNo']}') ?? 999999,
            y = int.tryParse('${b['rollNo']}') ?? 999999;
        return x != y
            ? x.compareTo(y)
            : '${a['name']}'.compareTo('${b['name']}');
      });
      var name = label
          .replaceAll(RegExp(r'[\[\]:*?/\\]'), '_')
          .replaceAll("'", '');
      if (name.isEmpty) name = 'Class';
      if (name.length > 25) name = name.substring(0, 25);
      final base = name;
      var suffix = 1;
      while (!usedNames.add(name.toLowerCase())) {
        name = '$base (${suffix++})';
      }
      sheets.add('<sheet name="${xml(name)}" sheetId="$n" r:id="rId$n"/>');
      overrides.add(
        '<Override PartName="/xl/worksheets/sheet$n.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
      );
      final cells = StringBuffer(),
          anchors = StringBuffer(),
          imageRels = StringBuffer();
      var photos = 0;
      String cell(int col, int row, Object? text) =>
          '<c r="${String.fromCharCode(65 + col)}$row" t="inlineStr"><is><t xml:space="preserve">${xml(text)}</t></is></c>';
      cells.write(
        '<row r="1">${cell(0, 1, 'School: $schoolId')}<c r="B1" t="inlineStr"><is><t>${xml(label)}</t></is></c></row>',
      );
      cells.write('<row r="2">');
      var col = 0;
      for (final title in columns.values) {
        cells.write(cell(col++, 2, title));
      }
      cells.write('</row>');
      for (var i = 0; i < rows.length; i++) {
        checkSchool();
        final data = rows[i], row = i + 3;
        Uint8List? jpeg;
        final source = data['photoUrl']?.toString() ?? '';
        if (source.isNotEmpty) {
          try {
            final bytes = await imageReader(source);
            checkSchool();
            if (bytes != null && bytes.length <= 10 * 1024 * 1024) {
              final decoded = img.decodeImage(bytes);
              if (decoded != null) {
                final thumb = img.copyResize(
                  decoded,
                  width: 96,
                  height: 96,
                  maintainAspect: true,
                );
                jpeg = Uint8List.fromList(img.encodeJpg(thumb, quality: 88));
              }
            }
          } catch (_) {
            checkSchool();
          }
        }
        cells.write('<row r="$row" ht="76" customHeight="1">');
        col = 0;
        for (final key in columns.keys) {
          final value = key == 'photo'
              ? (jpeg == null ? 'Photo unavailable' : '')
              : key == 'dateOfBirth'
              ? (data[key] ?? data['dob'] ?? '')
              : key == 'uniqueStudentId'
              ? (data[key] ?? data['studentUid'] ?? '')
              : data[key];
          cells.write(cell(col++, row, value));
        }
        cells.write('</row>');
        if (jpeg != null) {
          photos++;
          final media = 'student-$n-$photos.jpg';
          add('xl/media/$media', jpeg);
          imageRels.write(rel('rId$photos', 'image', '../media/$media'));
          anchors.write(
            '<xdr:oneCellAnchor><xdr:from><xdr:col>0</xdr:col><xdr:colOff>38100</xdr:colOff><xdr:row>${row - 1}</xdr:row><xdr:rowOff>38100</xdr:rowOff></xdr:from><xdr:ext cx="914400" cy="914400"/><xdr:pic><xdr:nvPicPr><xdr:cNvPr id="$photos" name="Student photo $photos"/><xdr:cNvPicPr/></xdr:nvPicPr><xdr:blipFill><a:blip r:embed="rId$photos"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill><xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>',
          );
        }
        progress?.call(++done, total);
      }
      if (photos > 0) {
        add(
          'xl/drawings/drawing$n.xml',
          '<?xml version="1.0" encoding="UTF-8"?><xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="$r">$anchors</xdr:wsDr>',
        );
        add(
          'xl/drawings/_rels/drawing$n.xml.rels',
          relationships('$imageRels'),
        );
        add(
          'xl/worksheets/_rels/sheet$n.xml.rels',
          relationships(rel('rId1', 'drawing', '../drawings/drawing$n.xml')),
        );
        overrides.add(
          '<Override PartName="/xl/drawings/drawing$n.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>',
        );
      }
      add(
        'xl/worksheets/sheet$n.xml',
        '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="$main" xmlns:r="$r"><sheetViews><sheetView workbookViewId="0"><pane ySplit="2" topLeftCell="A3" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols><col min="1" max="1" width="16" customWidth="1"/><col min="2" max="15" width="24" customWidth="1"/></cols><sheetData>$cells</sheetData><autoFilter ref="A2:O${rows.length + 2}"/>${photos > 0 ? '<drawing r:id="rId1"/>' : ''}</worksheet>',
      );
    }
    add(
      'xl/workbook.xml',
      '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="$main" xmlns:r="$r"><sheets>${sheets.join()}</sheets></workbook>',
    );
    add(
      'xl/_rels/workbook.xml.rels',
      relationships(
        [
          for (var i = 1; i <= sheets.length; i++)
            rel('rId$i', 'worksheet', 'worksheets/sheet$i.xml'),
        ].join(),
      ),
    );
    add(
      '_rels/.rels',
      relationships(rel('rId1', 'officeDocument', 'xl/workbook.xml')),
    );
    add(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>${overrides.join()}</Types>',
    );
    checkSchool();
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}
