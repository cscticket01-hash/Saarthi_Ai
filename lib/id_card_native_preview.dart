import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'id_card_engine.dart';
import 'id_card_manifest.dart';
import 'id_card_layout.dart';
import 'id_card_identity.dart';
import 'windows_appearance.dart';

/// Native preview reads the same manifest and data as export. No PDF is built
/// or rasterized to display a card. Print export remains separately reviewed.
class NativeIdCardPreview extends StatefulWidget {
  const NativeIdCardPreview({
    super.key, required this.template, required this.data,
    this.images = const {}, this.backgrounds = const {}, this.qr = '',
    this.onDownload, this.onPrint, this.onPrintDocument,
    this.sideBuilder, this.actionsEnabled = true,
  });
  final IdCardManifest template;
  final Map<String, dynamic> data;
  final Map<String, Uint8List> images, backgrounds;
  final String qr;
  /// Legacy vector designs use the same popup, but supply their shared native layers.
  final Widget Function(String side)? sideBuilder;
  final bool actionsEnabled;

  static Future<void> open(BuildContext context, WidgetBuilder builder) =>
      showDialog<void>(context: context, barrierDismissible: false, builder: builder);
  final Future<void> Function()? onDownload;
  final Future<void> Function(bool frontOnly)? onPrintDocument;
  final Future<void> Function(
    List<({Uint8List png, int width, int height})> pages,
  )? onPrint;
  @override
  State<NativeIdCardPreview> createState() => _NativeIdCardPreviewState();
}

class _NativeIdCardPreviewState extends State<NativeIdCardPreview> {
  bool busy = false;
  String? error;
  final printBoundaries = {'front': GlobalKey(), 'back': GlobalKey()};

  TextStyle globalStyle(IdCardRegion r,double size)=>TextStyle(
    color:Color(0xff000000|int.parse(r.textColor.substring(1),radix:16)),
    fontSize:size,fontFamily:'VidyaIdCardSans',height:1.25,
    fontWeight:r.bold?FontWeight.bold:null,
    fontFamilyFallback:const ['VidyaNotoBengali','VidyaNotoDevanagari']);
  FittedIdText fitGlobal(IdCardRegion r,Map<String,dynamic> data){
    final value=r.label+(data[r.key]?.toString()??'');
    try{
      return IdCardLayout.fitText(value,width:r.contentWidth,height:r.contentHeight,
        measure:(s){
          final p=TextPainter(text:TextSpan(text:s,style:globalStyle(r,1)),
            textDirection:TextDirection.ltr,maxLines:1)..layout();
          final width=p.width;p.dispose();return width;
        },fontSize:r.fontSize,minFontSize:r.minFontSize,wrap:r.wrap,maxLines:r.maxLines,overflow:'error');
    }on FormatException catch(e){throw FormatException('${r.key} (${r.side}): ${e.message}');}
  }
  Widget content(IdCardRegion r, Map<String, dynamic> data, String qr) {
    if (r.kind == 'image') {
      final bytes = widget.images[r.key];
      if (bytes == null) return const SizedBox.shrink();
      final photo = Image.memory(
        bytes, fit: r.fit == 'cover' ? BoxFit.cover : BoxFit.contain,
        alignment: Alignment(r.focusX * 2 - 1, r.focusY * 2 - 1),
      );
      return r.shape == 'oval' ? ClipOval(child: photo) : photo;
    }
    if (r.kind == 'qr') {
      if(qr.isNotEmpty&&IdCardIdentity.isGlobalId(widget.template.id)){
        final side=math.min(r.contentWidth,r.contentHeight);
        return Center(child:SizedBox.square(dimension:side,child:QrImageView(data:qr,errorCorrectionLevel:QrErrorCorrectLevel.L,padding:EdgeInsets.all(IdCardLayout.qrPadding(qr,side)),backgroundColor:Colors.white)));
      }
      return qr.isEmpty ? const SizedBox.shrink() : QrImageView(
        data: qr,
        padding: widget.template.id == 'student-green-blue-modern-v1'
            ? const EdgeInsets.all(4) : EdgeInsets.zero,
        backgroundColor: Colors.white,
      );
    }
    final value = r.label + (data[r.key]?.toString() ?? '');
    final align = r.align == 'center' ? TextAlign.center :
      r.align == 'right' ? TextAlign.right : TextAlign.left;
    final color = Color(0xff000000 | int.parse(r.textColor.substring(1), radix: 16));
    final availableWidth = r.contentWidth;
    final availableHeight = r.contentHeight;
    final global=IdCardIdentity.isGlobalId(widget.template.id);
    if(global){
      try{
        final fit=fitGlobal(r,data);
        final text=Align(alignment:r.align=='center'?Alignment.center:r.align=='right'?Alignment.centerRight:Alignment.centerLeft,
          child:Text(fit.text,textAlign:align,style:globalStyle(r,fit.fontSize),softWrap:false,maxLines:r.maxLines));
        return r.rotation==-90?RotatedBox(quarterTurns:3,child:text):text;
      }on FormatException{return ColoredBox(color:Colors.red.shade100,child:const SizedBox.expand());}
    }
    TextStyle style(double size) => TextStyle(color: color,fontSize:size,
      fontFamily:global?'VidyaIdCardSans':null,
      fontWeight:global&&r.bold?FontWeight.bold:null,
      fontFamilyFallback:global?const ['VidyaNotoBengali','VidyaNotoDevanagari']:null);
    var size = r.fontSize;
    // Bounded fitting: do not grow beyond the reviewed manifest geometry.
    for (var i = 0; i < 150; i++) {
      final painter = TextPainter(text: TextSpan(text: value, style: style(size)),
        textAlign: align, textDirection: Directionality.of(context),
        maxLines: r.maxLines, ellipsis: r.overflow == 'ellipsis' ? '…' : null)
        ..layout(maxWidth: availableWidth);
      final fits = painter.height <= availableHeight && !painter.didExceedMaxLines;
      painter.dispose();
      if (fits || size <= r.minFontSize) break;
      size = (size - .5).clamp(r.minFontSize, r.fontSize).toDouble();
    }
    final text = Text(value, textAlign: align, style: style(size), softWrap: r.wrap,
      maxLines: r.maxLines, overflow: r.overflow == 'ellipsis' ? TextOverflow.ellipsis : TextOverflow.clip);
    return r.rotation == -90 ? RotatedBox(quarterTurns: 3, child: text) : text;
  }
  Widget side(String name, Map<String, dynamic> data, String qr, double height) {
    final m = widget.template;
    return SizedBox(
      key: ValueKey('id-card-$name'),
      width: height * m.width / m.height,
      height: height, child: FittedBox(fit: BoxFit.contain,
        child: RepaintBoundary(
          key: printBoundaries[name],
          child: SizedBox(width: m.width, height: m.height, child: ColoredBox(
          color: Colors.white, child: widget.sideBuilder?.call(name) ?? Stack(clipBehavior: Clip.hardEdge, children: [
            if (widget.backgrounds[name] != null)
              Positioned.fill(child: Image.memory(widget.backgrounds[name]!, fit: BoxFit.contain)),
            for (final r in m.regions.where((r) => r.side == name))
              Positioned(left: r.x, top: r.y, width: r.width, height: r.height,
                child: Padding(padding: EdgeInsets.all(r.padding),
                  child: ClipRect(child: content(r, data, qr)))),
          ]),
        ))),
      ),
    );
  }
  Future<void> runAction(Future<void> Function() action, String failure) async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = '$failure: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> printCards(String qr) async {
    final template = widget.template;
    if (widget.onPrintDocument != null) {
      await widget.onPrintDocument!(!template.hasBack);
      return;
    }
    final ratio = template.printWidth * 300 / 25.4 / template.width;
    final sides = template.hasBack ? const ['front', 'back'] : const ['front'];
    final pages = <({Uint8List png, int width, int height})>[];
    for (final side in sides) {
      final boundary = printBoundaries[side]?.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw StateError('Card side is unavailable.');
      }
      final image = await boundary.toImage(pixelRatio: ratio);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('Could not render the card.');
        final png = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
        if (qr.isNotEmpty && template.regions.any((r) => r.side == side && r.kind == 'qr') &&
            IdCardEngine.decodeFinalRaster(png) != qr) {
          throw const FormatException('Printed ID QR did not match the card.');
        }
        pages.add((png: png, width: image.width, height: image.height));
      } finally {
        image.dispose();
      }
    }
    if (mounted) await widget.onPrint!(pages);
  }
  @override
  Widget build(BuildContext context) {
    final data = IdCardEngine.normalizedInput(widget.template, widget.data);
    final qr = IdCardEngine.compactQr(widget.qr);
    final global=IdCardIdentity.isGlobalId(widget.template.id);
    final missing = widget.template.regions.where((r) => (r.isRequired||(global&&r.key=='confirmedUniversalStudentUid')) &&
      (r.kind == 'image' ? widget.images[r.key] == null :
        r.kind == 'qr' ? qr.isEmpty : (data[r.key]?.toString().trim().isEmpty ?? true)));
    final fittingErrors=<String>[];
    if(global)for(final r in widget.template.regions.where((r)=>r.kind=='text')){
      try{fitGlobal(r,data);}on FormatException catch(e){fittingErrors.add(e.message);}
    }
    if(global&&qr.isNotEmpty)for(final r in widget.template.regions.where((r)=>r.kind=='qr')){
      try{final side=math.min(r.contentWidth,r.contentHeight);IdCardLayout.qrPadding(qr,side,physicalSideMm:side*widget.template.printWidth/widget.template.width);}
      on FormatException catch(e){fittingErrors.add('QR: ${e.message}');}
    }
    WindowsAppearance.watch(context);
    final theme = Theme.of(context);
    final template = widget.template;
    final screen = MediaQuery.sizeOf(context);
    final ratio = template.width / template.height;
    final count = template.hasBack ? 2 : 1;
    final targetWidth = count * math.min(500.0, 420.0 * ratio) + (count - 1) * 12 + 40;
    final double dialogWidth = math.min(targetWidth.toDouble(), math.max(0.0, screen.width - 32.0));
    final actions = <Widget>[
      if (widget.onPrint != null || widget.onPrintDocument != null)
        OutlinedButton.icon(
          onPressed: busy || !widget.actionsEnabled || missing.isNotEmpty || fittingErrors.isNotEmpty ? null :
            () => runAction(() => printCards(qr), 'Print failed'),
          icon: const Icon(Icons.print),
          label: const Text('Print'),
        ),
      if (widget.onDownload != null)
        FilledButton.icon(
          onPressed: busy || !widget.actionsEnabled || missing.isNotEmpty || fittingErrors.isNotEmpty ? null :
            () => runAction(widget.onDownload!, 'PDF export failed'),
          icon: const Icon(Icons.download),
          label: const Text('Download ID Card'),
        ),
    ];
    return PopScope(canPop: !busy, child: Dialog(
      key: const ValueKey('id-card-preview-dialog'),
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: WindowsAppearance.accent.withValues(alpha: .75))),
      child: SizedBox(width: dialogWidth,
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(20), children: [
        Row(children: [
          Icon(Icons.badge_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text('ID Card Preview', style: theme.textTheme.titleLarge)),
          IconButton(tooltip: 'Close', icon: const Icon(Icons.close),
            onPressed: busy ? null : () => Navigator.of(context).maybePop()),
        ]),
        const SizedBox(height: 16),
        if (missing.isNotEmpty) Text('Missing template fields: ' + missing.map((r) => r.key).join(', '),
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if(fittingErrors.isNotEmpty)Text('Template needs correction: '+fittingErrors.join(' • '),style:TextStyle(color:theme.colorScheme.error)),
        LayoutBuilder(builder: (context, constraints) {
          final template = widget.template;
          final count = template.hasBack ? 2 : 1;
          final gap = template.hasBack
              ? math.min(12.0, constraints.maxWidth / 4) : 0.0;
          final available = (constraints.maxWidth - gap) / count;
          final maxHeight = math.min(420.0, math.max(80.0, screen.height - 220));
          final height = math.min(maxHeight,
              available * template.height / template.width);
          return Center(child: Row(mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.ltr, children: [
            side('front', data, qr, height),
            if (template.hasBack) ...[
              SizedBox(width: gap),
              side('back', data, qr, height),
            ],
          ]));
        }),
        if (error != null) ...[const SizedBox(height: 8), Text(error!,
          style: TextStyle(color: theme.colorScheme.error))],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 20),
          LayoutBuilder(builder: (context, constraints) {
            if (constraints.maxWidth < 340) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final action in actions) Padding(
                  padding: const EdgeInsets.only(bottom: 8), child: action)]);
            }
            return Row(children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: actions[i]),
              ],
            ]);
          }),
        ],
      ]))));
  }
}
