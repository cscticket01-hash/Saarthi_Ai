import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'document_pipeline.dart';
import 'fitted_document_preview.dart';

class SelectedDocument {
  SelectedDocument(this.name, this.mime, this.bytes);
  final String name, mime;
  final Uint8List bytes;
}

class DocumentFilePicker {
  static const types = XTypeGroup(
    label: 'Student documents',
    extensions: ['jpg', 'jpeg', 'png', 'pdf'],
    mimeTypes: ['image/jpeg', 'image/png', 'application/pdf'],
  );
  static Future<SelectedDocument?> pick() async {
    final file = await openFile(acceptedTypeGroups: [types]);
    if (file == null) return null;
    if (await file.length() > 50 * 1024 * 1024) {
      throw const FormatException(
        'Source exceeds 50 MB. Select a smaller file.',
      );
    }
    final extension = file.name.toLowerCase().split('.').last;
    final mime = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'pdf' => 'application/pdf',
      _ => throw const FormatException('Select JPG, JPEG, PNG or PDF.'),
    };
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw const FormatException('Selected file is empty.');
    return SelectedDocument(file.name, mime, bytes);
  }
}

/// The same name step is used by the production documents screen and native
/// picker integration harness. No record is created by this dialog.
class DocumentNameDialog extends StatefulWidget {
  const DocumentNameDialog({super.key, this.current = ''});
  final String current;
  @override
  State<DocumentNameDialog> createState() => _DocumentNameDialogState();
}

class _DocumentNameDialogState extends State<DocumentNameDialog> {
  late final controller = TextEditingController(text: widget.current);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Document Name'),
        content: TextField(
          key: const ValueKey('document-name'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Aadhaar Card / Birth Certificate / Marksheet',
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('document-name-cancel'),
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            key: const ValueKey('document-name-continue'),
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) Navigator.pop(context, name);
            },
            child: const Text('Continue'),
          ),
        ],
      );
}

class DocumentUploadDialog extends StatefulWidget {
  const DocumentUploadDialog({
    super.key,
    required this.name,
    required this.scope,
    required this.isCurrent,
    this.picker = DocumentFilePicker.pick,
    this.processor = DocumentPipeline.process,
  });
  final String name, scope;
  final bool Function() isCurrent;
  final Future<SelectedDocument?> Function() picker;
  final Future<Map<String, dynamic>> Function(Uint8List, String, {String scope})
      processor;
  @override
  State<DocumentUploadDialog> createState() => _DocumentUploadDialogState();
}

class _DocumentUploadDialogState extends State<DocumentUploadDialog> {
  SelectedDocument? selected;
  Map<String, dynamic>? processed;
  bool busy = false;
  String? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    // Name confirmation opens this production dialog. Start the native picker
    // once the route is mounted; the button remains available for retry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(pick());
    });
  }
  Future<void> pick() async {
    if (busy) return;
    final current = ++generation;
    setState(() {
      busy = true;
      selected = null;
      processed = null;
      error = null;
    });
    try {
      final file = await widget.picker();
      if (!mounted || current != generation) return;
      if (!widget.isCurrent())
        throw StateError('School changed. Reopen documents.');
      if (file == null) {
        Navigator.pop(context);
        return;
      }
      selected = file; // Original stays untouched, even when processing fails.
      final result = await widget.processor(
        file.bytes,
        file.mime,
        scope: widget.scope,
      );
      if (!mounted || current != generation) return;
      if (!widget.isCurrent())
        throw StateError('School changed. Reopen documents.');
      if (result['optimized'] is! Uint8List ||
          (result['optimized'] as Uint8List).isEmpty) {
        throw const FormatException('Processing returned no readable output.');
      }
      setState(() => processed = result);
    } catch (e) {
      if (mounted && current == generation)
        setState(
          () => error =
              'Unable to process document: $e. Original file is unchanged. Select another file.',
        );
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Preview: ${widget.name}'),
        content: SizedBox(
          width: 700,
          height: 520,
          child: Column(
            children: [
              OutlinedButton.icon(
                key: const ValueKey('document-select-file'),
                onPressed: busy ? null : pick,
                icon: const Icon(Icons.file_open),
                label: const Text('Select file — JPG / JPEG / PNG / PDF'),
              ),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
              if (processed != null) ...[
                Text(
                  '${selected!.name} • optimized ${(processed!['optimized'] as Uint8List).length} bytes • original ${selected!.bytes.length} bytes',
                ),
                const Text(
                  'About 300 KB for 7–8 documents is a target; readability takes priority.',
                ),
                Expanded(
                  child: processed!['mimeType'] == 'application/pdf'
                      ? FittedDocumentPreview(
                          bytes: processed!['optimized'] as Uint8List,
                        )
                      : Image.memory(
                          processed!['optimized'] as Uint8List,
                          fit: BoxFit.contain,
                        ),
                ),
              ] else
                const Expanded(
                  child: Center(
                    child: Text(
                      'Select a file to process and preview before saving.',
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('document-cancel'),
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            key: const ValueKey('document-confirm-save'),
            onPressed: busy || processed == null
                ? null
                : () {
                    if (!widget.isCurrent()) {
                      setState(() {
                        processed = null;
                        error = 'School changed. Reopen documents.';
                      });
                      return;
                    }
                    Navigator.pop(context, selected);
                  },
            child: const Text('Save'),
          ),
        ],
      );
}
