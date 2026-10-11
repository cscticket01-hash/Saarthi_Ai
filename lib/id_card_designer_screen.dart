import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'id_card_designer.dart';
import 'id_card_manifest.dart';

/// Draft-only editor; the caller owns school authorization and durable saving.
class IdCardDesignerScreen extends StatefulWidget {
  const IdCardDesignerScreen({
    super.key,
    required this.designer,
    required this.onSave,
    this.templateVersion = 'schema-v1',
    this.data = const {},
    this.images = const {},
    this.qr = '',
  });
  final IdCardDesigner designer;
  /// Stable schema/template version supplied by the hosting school UI.
  final String templateVersion;
  final Future<void> Function(Map<String, dynamic>) onSave;
  final Map<String, dynamic> data;
  final Map<String, Uint8List> images;
  final String qr;
  @override
  State<IdCardDesignerScreen> createState() => _DesignerState();
}

class _DesignerState extends State<IdCardDesignerScreen> {
  String side = 'front';
  Offset dragAnchor = Offset.zero;
  String? selected;
  bool saving = false;
  String? error;
  IdCardDesigner get editor => widget.designer;
  void edit(void Function() action) {
    try {
      action();
      setState(() => error = null);
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      await widget.onSave(
        editor.exportDraft(
          templateVersion: widget.templateVersion,
        ),
      );
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = 'Draft could not be saved: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final template = editor.template;
    final regions = template.regions.where((r) => r.side == side).toList();
    IdCardRegion? active;
    for (final r in regions) {
      if (r.key == selected) active = r;
    }
    final current = active;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ID Card designer'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: editor.canUndo ? () => setState(editor.undo) : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: editor.canRedo ? () => setState(editor.redo) : null,
            icon: const Icon(Icons.redo),
          ),
          TextButton(
            onPressed: saving ? null : save,
            child: Text(saving ? 'Saving…' : 'Save draft'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'front', label: Text('Front')),
              ButtonSegment(value: 'back', label: Text('Back')),
            ],
            selected: {side},
            onSelectionChanged: (v) => setState(() {
              side = v.single;
              selected = null;
            }),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 16),
          SizedBox(
            height: 430,
            child: FittedBox(
              child: SizedBox(
                width: template.width,
                height: template.height,
                child: ColoredBox(
                  color: Colors.white,
                  child: Stack(
                    children: [
                      for (final r in regions)
                        Positioned(
                          left: r.x,
                          top: r.y,
                          width: r.width,
                          height: r.height,
                          child: GestureDetector(
                            key: ValueKey('designer-$side-${r.key}'),
                            onTap: () => setState(() => selected = r.key),
                            // Drag coordinates stay in the same design space as the PDF.
                            onPanStart: (details) =>
                                dragAnchor = details.localPosition,
                            onPanUpdate: (details) => edit(
                              () => editor.move(
                                side,
                                r.key,
                                (r.x + details.localPosition.dx - dragAnchor.dx)
                                    .clamp(0.0, template.width - r.width)
                                    .toDouble(),
                                (r.y + details.localPosition.dy - dragAnchor.dy)
                                    .clamp(0.0, template.height - r.height)
                                    .toDouble(),
                              ),
                            ),
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: r.key == selected
                                      ? Colors.blue
                                      : Colors.grey.shade300,
                                ),
                              ),
                              child: ClipRect(
                                child:
                                    r.kind == 'image' &&
                                        widget.images[r.key] != null
                                    ? Image.memory(
                                        widget.images[r.key]!,
                                        fit: r.fit == 'cover'
                                            ? BoxFit.cover
                                            : BoxFit.contain,
                                        alignment: Alignment(
                                          r.focusX * 2 - 1,
                                          r.focusY * 2 - 1,
                                        ),
                                      )
                                    : r.kind == 'qr' && widget.qr.isNotEmpty
                                    ? QrImageView(
                                        data: widget.qr,
                                        padding: EdgeInsets.all(r.padding),
                                      )
                                    : Text(
                                        r.kind == 'text'
                                            ? '${r.label}${widget.data[r.key] ?? r.key}'
                                            : r.key,
                                        style: TextStyle(
                                          fontSize: r.fontSize,
                                          color: Colors.black,
                                        ),
                                        maxLines: r.maxLines,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (current != null) ...[
            Text('Selected: ${current.key}'),
            Slider(
              min: current.padding * 2,
              max: template.width - current.x,
              value: current.width
                  .clamp(current.padding * 2, template.width - current.x)
                  .toDouble(),
              label: 'Width',
              onChanged: (v) => edit(
                () => editor.resize(side, current.key, v, current.height),
              ),
            ),
            Slider(
              min: current.padding * 2,
              max: template.height - current.y,
              value: current.height
                  .clamp(current.padding * 2, template.height - current.y)
                  .toDouble(),
              label: 'Height',
              onChanged: (v) => edit(
                () => editor.resize(side, current.key, current.width, v),
              ),
            ),
            if (current.kind == 'image' && current.key == 'photo') ...[
              const Text('Photo horizontal focus'),
              Slider(
                value: current.focusX,
                onChanged: (v) => edit(
                  () => editor.editRegion(side, current.key, {'focusX': v}),
                ),
              ),
              const Text('Photo vertical focus'),
              Slider(
                value: current.focusY,
                onChanged: (v) => edit(
                  () => editor.editRegion(side, current.key, {'focusY': v}),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
