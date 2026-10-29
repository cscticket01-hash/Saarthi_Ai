import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'fitted_document_preview.dart';

typedef ReceiptPrinterJob = Future<bool> Function(Printer printer, Uint8List bytes, PdfPageFormat format);

/// App-owned preview/settings. Direct printing never opens the legacy Windows
/// Print Setup dialog and never changes the retained original PDF.
class WindowsReceiptPrintDialog extends StatefulWidget {
  const WindowsReceiptPrintDialog({super.key, required this.receipt,
    required this.title, required this.subtitle, required this.isCurrent,
    this.printers, this.printJob, this.previewBuilder});
  final Future<Uint8List> receipt;
  final String title, subtitle;
  final bool Function() isCurrent;
  final Future<List<Printer>> Function()? printers;
  final ReceiptPrinterJob? printJob;
  final Widget Function(Uint8List)? previewBuilder;
  @override
  State<WindowsReceiptPrintDialog> createState() => _WindowsReceiptPrintDialogState();
}

class _WindowsReceiptPrintDialogState extends State<WindowsReceiptPrintDialog> {
  final copies = TextEditingController(text: '1');
  List<Printer> printers = [];
  String? selected;
  bool loadingPrinters = true, printing = false;
  String paper = 'A4';
  String message = '';
  int submitted = 0;
  @override
  void initState() { super.initState(); loadPrinters(); }
  @override
  void dispose() { copies.dispose(); super.dispose(); }
  Future<void> loadPrinters() async {
    setState(() { loadingPrinters = true; message = ''; });
    try {
      final rows = await (widget.printers ?? Printing.listPrinters)();
      if (!mounted || !widget.isCurrent()) return;
      final unique = {for (final row in rows.where((p) => p.isAvailable)) row.url: row};
      setState(() {
        printers = unique.values.toList();
        if (!unique.containsKey(selected)) {
          final defaults = printers.where((p) => p.isDefault);
          selected = defaults.isNotEmpty ? defaults.first.url : printers.isEmpty ? null : printers.first.url;
        }
      });
    } catch (e) {
      if (mounted) setState(() => message = 'Printers unavailable. Check the printer connection, then Refresh.');
    } finally {
      if (mounted) setState(() => loadingPrinters = false);
    }
  }
  Future<void> printReceipt(Uint8List bytes) async {
    if (printing || !widget.isCurrent()) return;
    final count = int.tryParse(copies.text.trim());
    if (count == null || count < 1 || count > 20) {
      setState(() => message = 'Enter 1 to 20 copies.'); return;
    }
    final matches = printers.where((p) => p.url == selected);
    if (matches.isEmpty) { setState(() => message = 'Select an available printer.'); return; }
    final printer = matches.first;
    final format = paper == 'A4' ? PdfPageFormat.a4 : PdfPageFormat.letter;
    setState(() { printing = true; submitted = 0; message = ''; });
    try {
      for (var i = 0; i < count; i++) {
        if (!mounted || !widget.isCurrent()) throw StateError('School changed. Printing stopped.');
        final accepted = await (widget.printJob ?? (printer, bytes, format) async =>
          await Printing.directPrintPdf(printer: printer, name: widget.title,
            format: format, dynamicLayout: false, usePrinterSettings: false,
            onLayout: (_) async {
              if (!widget.isCurrent()) throw StateError('School changed.');
              return bytes;
            }))(printer, bytes, format).timeout(const Duration(seconds: 60));
        if (!accepted) throw StateError('Print job was cancelled.');
        submitted++;
      }
      if (mounted) setState(() => message = '$submitted ${submitted == 1 ? 'copy' : 'copies'} sent to printer.');
    } catch (e) {
      if (mounted) setState(() => message = '$submitted copies confirmed. Could not confirm the next copy. Check the printer before retrying.');
    } finally {
      if (mounted) setState(() => printing = false);
    }
  }
  Widget settings(Uint8List? bytes) => SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Print', style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
      const SizedBox(height: 20),
      if (loadingPrinters) const LinearProgressIndicator(),
      DropdownButtonFormField<String>(value: selected, isExpanded: true,
        decoration: const InputDecoration(labelText: 'Printer'),
        items: printers.map((p) => DropdownMenuItem(value: p.url, child: Text(p.name, overflow: TextOverflow.ellipsis))).toList(),
        onChanged: printing ? null : (value) => setState(() => selected = value)),
      Align(alignment: Alignment.centerRight, child: TextButton.icon(
        onPressed: printing || loadingPrinters ? null : loadPrinters,
        icon: const Icon(Icons.refresh, size: 16), label: const Text('Refresh printers'))),
      const SizedBox(height: 12),
      TextField(controller: copies, enabled: !printing,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Copies', helperText: '1–20')),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(value: paper, isExpanded: true,
        decoration: const InputDecoration(labelText: 'Paper size'),
        items: const [DropdownMenuItem(value: 'A4', child: Text('A4 (210 × 297 mm)', overflow: TextOverflow.ellipsis)),
          DropdownMenuItem(value: 'Letter', child: Text('Letter (216 × 279 mm)', overflow: TextOverflow.ellipsis))],
        onChanged: printing ? null : (v) => setState(() => paper = v ?? 'A4')),
      const SizedBox(height: 20),
      const Text('Pages: All receipt pages'),
      const SizedBox(height: 8),
      const Text('Layout: Original receipt'),
      const SizedBox(height: 20),
      if (message.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(message)),
      FilledButton.icon(onPressed: printing || loadingPrinters || selected == null || bytes == null || !widget.isCurrent()
          ? null : () => printReceipt(bytes),
        icon: const Icon(Icons.print), label: Text(printing ? 'Sending…' : 'Print')),
      TextButton(onPressed: printing ? null : () => Navigator.pop(context), child: const Text('Cancel')),
    ]));
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(insetPadding: const EdgeInsets.all(16), child: SizedBox(
      width: (size.width - 32).clamp(280.0, 1200.0).toDouble(),
      height: (size.height - 32).clamp(300.0, 900.0).toDouble(),
      child: Column(children: [
        ListTile(title: Text(widget.title), subtitle: Text(widget.subtitle),
          trailing: IconButton(tooltip: 'Close receipt', onPressed: printing ? null : () => Navigator.pop(context), icon: const Icon(Icons.close))),
        const Divider(height: 1),
        Expanded(child: FutureBuilder<Uint8List>(future: widget.receipt, builder: (context, snapshot) {
          if (!widget.isCurrent()) return const Center(child: Text('School changed. Reopen receipt history.'));
          final preview = snapshot.hasError ? Center(child: Text('Receipt unavailable: ${snapshot.error}'))
              : !snapshot.hasData ? const Center(child: CircularProgressIndicator())
              : widget.previewBuilder?.call(snapshot.data!) ?? FittedDocumentPreview(bytes: snapshot.data!);
          return LayoutBuilder(builder: (context, limits) => limits.maxWidth >= 760
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: preview), const VerticalDivider(width: 1), SizedBox(width: 290, child: settings(snapshot.data))])
            : Column(children: [Expanded(child: preview), const Divider(height: 1),
                SizedBox(height: (limits.maxHeight * .5).clamp(100.0, 320.0).toDouble(), child: settings(snapshot.data))]));
        })),
      ])));
  }
}
