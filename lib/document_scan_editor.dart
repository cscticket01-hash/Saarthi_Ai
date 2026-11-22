import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'document_pipeline.dart';
import 'document_processing_engine.dart';

/// Crop handles refer to the EXIF-normalized source, never to a thumbnail
/// that has already been cropped. Preview recompression uses original bytes.
class DocumentScanEditor extends StatefulWidget {
  const DocumentScanEditor({super.key, required this.bytes,
    required this.mime, required this.scope, required this.initialEdits,
    required this.isCurrent, this.initialTool = 'all', this.deferFullApply = false});
  final Uint8List bytes;
  final String mime, scope, initialTool;
  final bool deferFullApply;
  final Map<String, dynamic> initialEdits;
  final bool Function() isCurrent;

  @override
  State<DocumentScanEditor> createState() => _DocumentScanEditorState();
}

class _DocumentScanEditorState extends State<DocumentScanEditor> {
  late final Future<Uint8List> source;
  late int rotation;
  late String filter;
  late double brightness, contrast;
  late List<Offset> corners;
  bool manual = false, busy = false;
  String? error;
  Uint8List? preview;
  final undoStack = <Map<String,dynamic>>[], redoStack = <Map<String,dynamic>>[];
  bool showOriginal = false;
  void restore(Map<String,dynamic> e) {
    final crop = e['manualCorners'] as List?;
    manual = crop != null;
    corners = crop == null ? full.toList() : [for(var i=0;i<8;i+=2)
      Offset((crop[i] as num).toDouble(),(crop[i+1] as num).toDouble())];
    rotation = ((e['manualEdit'] as List?)?[4] as num? ?? 0).toInt();
    filter = e['scanFilter']?.toString() ?? 'auto';
    brightness = (e['brightness'] as num? ?? 0).toDouble();
    contrast = (e['contrast'] as num? ?? 0).toDouble();
  }
  void stepHistory(bool redo) {
    final from = redo ? redoStack : undoStack, to = redo ? undoStack : redoStack;
    if (busy || from.isEmpty) return;
    setState(() { to.add(edits); restore(from.removeLast()); preview=null; error=null; showOriginal=false; });
  }
  static const full = [Offset.zero, Offset(1, 0), Offset(1, 1), Offset(0, 1)];
  static const filters = {
    'original': 'Original color', 'auto': 'Auto-color',
    'lightText': 'Light text', 'grayscale': 'Grayscale', 'whiteboard': 'Whiteboard',
  };

  @override
  void initState() {
    super.initState();
    source = compute(DocumentPipeline.editorImage, widget.bytes);
    final e = widget.initialEdits;
    final crop = e['manualCorners'] as List?;
    manual = crop != null;
    corners = crop == null ? full.toList() : [
      for (var i = 0; i < 8; i += 2)
        Offset((crop[i] as num).toDouble(), (crop[i + 1] as num).toDouble()),
    ];
    final edit = e['manualEdit'] as List?;
    rotation = edit == null ? 0 : (edit[4] as num).toInt();
    filter = e['scanFilter']?.toString() ?? 'auto';
    brightness = (e['brightness'] as num? ?? 0).toDouble();
    contrast = (e['contrast'] as num? ?? 0).toDouble();
    if (widget.initialTool == 'crop' && crop == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) autoDetect();
      });
    }
  }

  Map<String, dynamic> get edits => {
    if (manual || rotation != 0)
      'manualEdit': [0, 0, 1, 1, rotation],
    if (manual)
      'manualCorners': [for (final p in corners) ...[p.dx, p.dy]],
    if (filter != 'auto') 'scanFilter': filter,
    if (brightness != 0) 'brightness': brightness,
    if (contrast != 0) 'contrast': contrast,
  };

  void change(VoidCallback action) {
    setState(() {
      undoStack.add(edits);
      if (undoStack.length > 32) undoStack.removeAt(0);
      redoStack.clear();
      action();
      showOriginal = false;
      preview = null;
      error = null;
    });
  }

  Future<void> autoDetect() async {
    if (busy) return;
    setState(() { busy = true; error = null; preview = null; });
    try {
      final detected = await compute(DocumentProcessingEngine.suggestCrop, await source);
      if (!mounted) return;
      setState(() {
        undoStack.add(edits);
        redoStack.clear();
        manual = true;
        corners = detected == null ? full.toList() : [
          for (var i = 0; i < 8; i += 2) Offset(detected[i], detected[i + 1]),
        ];
        if (detected == null) error = 'No confident boundary. Adjust the four corners manually.';
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Auto-detect unavailable. Use manual crop.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> render({required bool apply}) async {
    if (busy) return;
    final requested = edits;
    setState(() { busy = true; error = null; });
    try {
      if (!widget.isCurrent()) throw StateError('School changed. Reopen the document.');
      // Preview uses the bounded original thumbnail, Apply uses full-size source.
      final bytes = apply && !widget.deferFullApply
          ? (await DocumentPipeline.process(widget.bytes, widget.mime,
              scope: widget.scope, edits: requested))['optimized'] as Uint8List
          : await DocumentPipeline.editThumbnail(await source, requested, scope:widget.scope);
      if (!mounted) return;
      if (!widget.isCurrent()) throw StateError('School changed. Reopen the document.');
      if (apply) {
        Navigator.of(context).pop(requested);
      } else {
        setState(() {preview = bytes; showOriginal = false;});
      }
    } catch (e) {
      if (mounted) setState(() => error = e is FormatException ? e.message.toString() : e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget cropCanvas(Uint8List bytes) => LayoutBuilder(builder: (context, constraints) {
    // Resolve the exact displayed image rectangle before positioning handles.
    return _CropSurface(bytes: bytes, corners: corners, enabled: manual && !busy,
      onStart: () {
        undoStack.add(edits);
        if (undoStack.length > 32) undoStack.removeAt(0);
        redoStack.clear();
      },
      onChange: (value) => setState(() { corners = value; preview = null; error = null; }));
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Smart Scan • Edit document'),
    content: SizedBox(width: 820, height: 570, child: Column(children: [
      Expanded(child: DecoratedBox(
        decoration: BoxDecoration(color: const Color(0xff24262b),
          borderRadius: BorderRadius.circular(8)),
        child: preview != null && !showOriginal
          ? InteractiveViewer(minScale:1,maxScale:5,child: Center(child: Image.memory(preview!, fit: BoxFit.contain)))
          : FutureBuilder<Uint8List>(future: source, builder: (_, snapshot) {
            if (snapshot.hasError) return const Center(child: Text('Original preview unavailable.'));
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            return cropCanvas(snapshot.data!);
          }),
      )),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 4, alignment: WrapAlignment.center, children: [
        OutlinedButton.icon(onPressed: busy ? null : autoDetect,
          icon: const Icon(Icons.auto_fix_high), label: const Text('Auto-detect')),
        OutlinedButton.icon(key: const ValueKey('scan-manual-crop'),
          onPressed: busy ? null : () => change(() => manual = !manual),
          icon: const Icon(Icons.crop), label: Text(manual ? 'Manual crop on' : 'Crop')),

        OutlinedButton.icon(onPressed: busy ? null : () {
          change(() => rotation = (rotation + 90) % 360);
          render(apply: false);
        }, icon: const Icon(Icons.rotate_right), label: Text('Rotate ${rotation}°')),
        IconButton(tooltip:'Undo', onPressed: busy || undoStack.isEmpty ? null : () => stepHistory(false), icon:const Icon(Icons.undo)),
        IconButton(tooltip:'Redo', onPressed: busy || redoStack.isEmpty ? null : () => stepHistory(true), icon:const Icon(Icons.redo)),
        OutlinedButton.icon(onPressed: busy || preview == null ? null : () => setState(() => showOriginal = !showOriginal),
          icon:const Icon(Icons.compare),label:Text(showOriginal ? 'After' : 'Before')),
        OutlinedButton.icon(onPressed: busy ? null : () => change(() {
          manual = false; corners = full.toList(); rotation = 0;
          brightness = 0; contrast = 0; filter = 'auto';
        }), icon: const Icon(Icons.restart_alt), label: const Text('Reset')),
      ]),
      const SizedBox(height: 6),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
        for (final item in filters.entries)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 3),
            child: ChoiceChip(label: Text(item.value), selected: item.key == filter,
              onSelected: busy ? null : (_) {
                change(() => filter = item.key);
                render(apply: false);
              })),
      ])),
      Row(children: [
        const SizedBox(width: 86, child: Text('Brightness')),
        Expanded(child: Slider(value: brightness, min: -0.4, max: 0.4,
          onChanged: busy ? null : (v) => change(() => brightness = v),
          onChangeEnd: busy ? null : (_) => render(apply: false))),
        const SizedBox(width: 86, child: Text('Contrast')),
        Expanded(child: Slider(value: contrast, min: -0.5, max: 0.5,
          onChanged: busy ? null : (v) => change(() => contrast = v),
          onChangeEnd: busy ? null : (_) => render(apply: false))),
      ]),
      if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error), maxLines: 2),
      if (busy) const LinearProgressIndicator(),
      Text(preview != null ? 'Processed preview' : manual
          ? 'Drag the blue corners or side handles. Preview applies perspective correction.'
          : 'Original view. Preview applies the selected adjustments.',
        style: Theme.of(context).textTheme.bodySmall),
    ])),
    actions: [
      TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
      OutlinedButton(onPressed: busy ? null : () => render(apply: false),
        child: const Text('Preview')),
      FilledButton(key: const ValueKey('scan-apply-edits'),
        onPressed: busy ? null : () => render(apply: true), child: const Text('Apply')),
    ],
  );
}

class _CropSurface extends StatefulWidget {
  const _CropSurface({required this.bytes, required this.corners,
    required this.enabled, required this.onStart, required this.onChange});
  final Uint8List bytes;
  final List<Offset> corners;
  final bool enabled;
  final VoidCallback onStart;
  final ValueChanged<List<Offset>> onChange;
  @override
  State<_CropSurface> createState() => _CropSurfaceState();
}

class _CropSurfaceState extends State<_CropSurface> {
  int? active;
  Offset? last;
  Offset clampPoint(Offset p) => Offset(p.dx.clamp(0.0,1.0).toDouble(),p.dy.clamp(0.0,1.0).toDouble());
  // The editor raster is a decoded PNG with a known IHDR size.
  Size get imageSize {
    final data = ByteData.sublistView(widget.bytes);
    return Size(data.getUint32(16).toDouble(), data.getUint32(20).toDouble());
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, c) {
    final fit = applyBoxFit(BoxFit.contain, imageSize, Size(c.maxWidth, c.maxHeight));
    final rect = Alignment.center.inscribe(fit.destination, Offset.zero & Size(c.maxWidth, c.maxHeight));
    Offset absolute(Offset p) => Offset(rect.left + p.dx * rect.width, rect.top + p.dy * rect.height);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: !widget.enabled ? null : (event) {
        double best = 30;
        active = null;
        final handles = [...widget.corners, for(var i=0;i<4;i++)
          (widget.corners[i]+widget.corners[(i+1)%4])/2];
        for (var i = 0; i < handles.length; i++) {
          final distance = (absolute(handles[i]) - event.localPosition).distance;
          if (distance < best) { best = distance; active = i; }
        }
        last = event.localPosition;
        if(active != null) widget.onStart();
      },
      onPanUpdate: !widget.enabled ? null : (event) {
        if (active == null || rect.width <= 0 || rect.height <= 0) return;
        final value = Offset((event.localPosition.dx-rect.left)/rect.width,
          (event.localPosition.dy-rect.top)/rect.height);
        final next=widget.corners.toList();
        if(active!<4){
          next[active!]=clampPoint(value);
        }else{
          final a=active!-4,b=(a+1)%4;
          final delta=event.localPosition-(last??event.localPosition);
          final dx=delta.dx/rect.width,dy=delta.dy/rect.height;
          final minX=next[a].dx<next[b].dx?next[a].dx:next[b].dx;
          final maxX=next[a].dx>next[b].dx?next[a].dx:next[b].dx;
          final minY=next[a].dy<next[b].dy?next[a].dy:next[b].dy;
          final maxY=next[a].dy>next[b].dy?next[a].dy:next[b].dy;
          final move=Offset(dx.clamp(-minX,1-maxX).toDouble(),dy.clamp(-minY,1-maxY).toDouble());
          next[a]+=move;next[b]+=move;
        }
        last=event.localPosition;
        widget.onChange(next);
      },
      onPanEnd: (_) {active=null;last=null;},
      onPanCancel: () {active=null;last=null;},
      child: Stack(fit: StackFit.expand, children: [
        Image.memory(widget.bytes, fit: BoxFit.contain, gaplessPlayback: true),
        if (widget.enabled) CustomPaint(painter: _CropOutline(
          widget.corners.map(absolute).toList())),
      ]),
    );
  });
}

class _CropOutline extends CustomPainter {
  _CropOutline(this.points);
  final List<Offset> points;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addPolygon(points, true);
    final shade = Path()..addRect(Offset.zero & size)..addPath(path, Offset.zero);
    shade.fillType = PathFillType.evenOdd;
    canvas.drawPath(shade, Paint()..color = Colors.black45);
    final paint = Paint()..color = const Color(0xff2499ff)..style = PaintingStyle.stroke..strokeWidth = 2.5;
    canvas.drawPath(path, paint);
    for (final point in points) {
      canvas.drawCircle(point, 8, Paint()..color = Colors.white);
      canvas.drawCircle(point, 8, paint);
    }
    for (var i = 0; i < points.length; i++) {
      final middle = (points[i] + points[(i + 1) % points.length]) / 2;
      canvas.drawRect(Rect.fromCenter(center: middle, width: 16, height: 5), paint);
    }
  }
  @override
  bool shouldRepaint(covariant _CropOutline oldDelegate) => true;
}
