import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/document_upload_dialog.dart';

void main() {
  final bytes = Uint8List.fromList(
    img.encodePng(img.Image(width: 40, height: 60)),
  );
  Future<Map<String, dynamic>> processed(
    Uint8List b,
    String m, {
    String scope = '',
  }) async => {'optimized': bytes, 'mimeType': 'image/jpeg'};
  Future<void> host(
    WidgetTester t, {
    required Future<SelectedDocument?> Function() picker,
    Future<Map<String, dynamic>> Function(Uint8List, String, {String scope})?
    processor,
    bool Function()? current,
    required void Function(SelectedDocument?) result,
  }) async {
    t.view.physicalSize = const Size(1200, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              child: const Text('Add Document'),
              onPressed: () async {
                final name = await showDialog<String>(
                  context: context,
                  builder: (_) => const DocumentNameDialog(),
                );
                if (name == null || !context.mounted) return;
                final file = await showDialog<SelectedDocument>(
                  context: context,
                  builder: (_) => DocumentUploadDialog(
                    name: name,
                    scope: 'school-A',
                    isCurrent: current ?? () => true,
                    picker: picker,
                    processor: processor ?? processed,
                  ),
                );
                result(file);
              },
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Add Document'));
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const ValueKey('document-name')),
      'Birth Certificate',
    );
    await t.tap(find.byKey(const ValueKey('document-name-continue')));
    await t.pumpAndSettle();
  }

  for (final ext in ['jpg', 'jpeg', 'png', 'pdf']) {
    testWidgets('name → picker → $ext → processed preview → explicit Save', (
      t,
    ) async {
      var calls = 0, writes = 0;
      await host(
        t,
        picker: () async {
          calls++;
          return SelectedDocument(
            'scan.$ext',
            ext == 'pdf'
                ? 'application/pdf'
                : ext == 'png'
                ? 'image/png'
                : 'image/jpeg',
            bytes,
          );
        },
        result: (r) {
          if (r != null) writes++;
        },
      );
      expect(calls, 0);
      expect(writes, 0);
      expect(
        t
            .widget<ElevatedButton>(
              find.byKey(const ValueKey('document-confirm-save')),
            )
            .onPressed,
        isNull,
      );
      await t.tap(find.byKey(const ValueKey('document-select-file')));
      await t.pumpAndSettle();
      expect(calls, 1);
      expect(writes, 0);
      expect(find.textContaining('optimized'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('document-confirm-save')));
      await t.pumpAndSettle();
      expect(writes, 1);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('native picker cancellation returns safely without a record', (
    t,
  ) async {
    var writes = 0;
    await host(
      t,
      picker: () async => null,
      result: (r) {
        if (r != null) writes++;
      },
    );
    await t.tap(find.byKey(const ValueKey('document-select-file')));
    await t.pumpAndSettle();
    expect(find.byType(DocumentUploadDialog), findsNothing);
    expect(writes, 0);
  });
  testWidgets(
    'processing failure preserves original and prevents Save; retry succeeds',
    (t) async {
      var failures = true, writes = 0;
      final original = List<int>.from(bytes);
      await host(
        t,
        picker: () async => SelectedDocument('scan.jpg', 'image/jpeg', bytes),
        processor: (b, m, {String scope = ''}) async {
          if (failures) throw const FormatException('bad scan');
          return processed(b, m, scope: scope);
        },
        result: (r) {
          if (r != null) writes++;
        },
      );
      await t.tap(find.byKey(const ValueKey('document-select-file')));
      await t.pumpAndSettle();
      expect(bytes, original);
      expect(find.textContaining('Original file is unchanged'), findsOneWidget);
      expect(
        t
            .widget<ElevatedButton>(
              find.byKey(const ValueKey('document-confirm-save')),
            )
            .onPressed,
        isNull,
      );
      expect(writes, 0);
      failures = false;
      await t.tap(find.byKey(const ValueKey('document-select-file')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('document-confirm-save')));
      await t.pumpAndSettle();
      expect(writes, 1);
    },
  );
  testWidgets('school change rejects stale processing completion', (t) async {
    var current = true, writes = 0;
    final future = Completer<Map<String, dynamic>>();
    await host(
      t,
      current: () => current,
      picker: () async => SelectedDocument('scan.jpg', 'image/jpeg', bytes),
      processor: (b, m, {String scope = ''}) => future.future,
      result: (r) {
        if (r != null) writes++;
      },
    );
    await t.tap(find.byKey(const ValueKey('document-select-file')));
    await t.pump();
    current = false;
    future.complete(await processed(bytes, 'image/jpeg'));
    await t.pumpAndSettle();
    expect(find.textContaining('School changed'), findsOneWidget);
    expect(writes, 0);
    expect(
      t
          .widget<ElevatedButton>(
            find.byKey(const ValueKey('document-confirm-save')),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets('cancel during processing discards late completion', (t) async {
    var writes = 0;
    final future = Completer<Map<String, dynamic>>();
    await host(
      t,
      picker: () async => SelectedDocument('scan.jpg', 'image/jpeg', bytes),
      processor: (b, m, {String scope = ''}) => future.future,
      result: (r) {
        if (r != null) writes++;
      },
    );
    await t.tap(find.byKey(const ValueKey('document-select-file')));
    await t.pump();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    future.complete(await processed(bytes, 'image/jpeg'));
    await t.pumpAndSettle();
    expect(writes, 0);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'picker platform error stays visible and cannot create an empty record',
    (t) async {
      await host(
        t,
        picker: () async => throw StateError('native picker unavailable'),
        result: (r) => fail('must not save'),
      );
      await t.tap(find.byKey(const ValueKey('document-select-file')));
      await t.pumpAndSettle();
      expect(find.textContaining('native picker unavailable'), findsOneWidget);
      expect(
        t
            .widget<ElevatedButton>(
              find.byKey(const ValueKey('document-confirm-save')),
            )
            .onPressed,
        isNull,
      );
    },
  );
}
