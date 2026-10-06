// Review-only native plugin harness. Never connects to a school or cloud.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../lib/document_upload_dialog.dart';
import '../lib/document_pipeline.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('Native document picker review — isolated fixtures only'),
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => review());
}

Future<void> review() async {
  final folder = Directory(Platform.environment['SAARTHI_PICKER_REVIEW']!);
  await folder.create(recursive: true);
  void state(Map<String, dynamic> data) {
    final temp = File('${folder.path}/state.tmp');
    temp.writeAsStringSync(jsonEncode(data), flush: true);
    final target = File('${folder.path}/state.json');
    if (target.existsSync()) target.deleteSync();
    temp.renameSync(target.path);
  }

  try {
    final image = img.Image(width: 600, height: 800);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 80; y < 720; y += 24)
      img.drawLine(
        image,
        x1: 40,
        y1: y,
        x2: 560,
        y2: y,
        color: img.ColorRgb8(0, 0, 0),
        thickness: 2,
      );
    final jpeg = Uint8List.fromList(img.encodeJpg(image));
    final png = Uint8List.fromList(img.encodePng(image));
    final pdf = pw.Document();
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Image(pw.MemoryImage(png)),
      ),
    );
    final fixtures = <String, Uint8List>{
      'scan.jpg': jpeg,
      'scan.jpeg': jpeg,
      'scan.png': png,
      'scan.pdf': await pdf.save(),
    };
    final results = <Map<String, dynamic>>[];
    for (final entry in fixtures.entries) {
      final path = '${folder.path}/${entry.key}';
      await File(path).writeAsBytes(entry.value, flush: true);
      state({'stage': 'select', 'file': path});
      final selected = await DocumentFilePicker.pick();
      if (selected == null ||
          selected.name != entry.key ||
          base64Encode(selected.bytes) != base64Encode(entry.value))
        throw StateError('Native selected file mismatch: ${entry.key}');
      final output = await DocumentPipeline.process(
        selected.bytes,
        selected.mime,
        scope: 'isolated-review',
      );
      if ((output['optimized'] as Uint8List).isEmpty ||
          (output['highQuality'] as Uint8List).isEmpty)
        throw StateError('Processing returned empty output');
      if (base64Encode(await File(path).readAsBytes()) !=
          base64Encode(entry.value))
        throw StateError('Original fixture changed');
      results.add({
        'file': entry.key,
        'mime': selected.mime,
        'optimizedBytes': (output['optimized'] as Uint8List).length,
        'originalRetained': true,
      });
    }
    state({'stage': 'cancel'});
    if (await DocumentFilePicker.pick() != null)
      throw StateError('Native cancellation must return null');
    state({
      'stage': 'done',
      'passed': true,
      'results': results,
      'cancelledWithoutSelection': true,
    });
    exit(0);
  } catch (e, stack) {
    state({'stage': 'done', 'passed': false, 'error': '$e', 'stack': '$stack'});
    exit(1);
  }
}
