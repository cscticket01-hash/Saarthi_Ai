import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'fitted_document_preview.dart';
import 'windows_save_pdf.dart';

typedef ReceiptPrinterJob = Future<bool> Function(Printer printer, Uint8List bytes, PdfPageFormat format);

/// App-owned preview/settings. Direct printing never opens the legacy Windows
/// Print Setup dialog and never changes the retained original PDF.
class WindowsReceiptPrintDialog extends StatefulWidget {
  const WindowsReceiptPrintDialog({super.key, required this.receipt,
    required this.title, required this.subtitle, required this.isCurrent,
    this.printers, this.printJob, this.previewBuilder,
    this.openPrinterSettings, this.systemPrintJob});
  final Future<Uint8List> receipt;
  final String title, subtitle;
  final bool Function() isCurrent;
  final Future<List<Printer>> Function()? printers;
  final ReceiptPrinterJob? printJob;
  final Future<void> Function()? openPrinterSettings;
  final Future<bool> Function(Uint8List,PdfPageFormat)? systemPrintJob;
  final Widget Function(Uint8List)? previewBuilder;
  @override
  State<WindowsReceiptPrintDialog> createState() => _WindowsReceiptPrintDialogState();
}

class _WindowsReceiptPrintDialogState extends State<WindowsReceiptPrintDialog>
    with WidgetsBindingObserver {
  final copies = TextEditingController(text: '1');
  List<Printer> printers = [];
  String? selected;
  bool loadingPrinters = true, printing = false;
  String paper = 'A4';
  bool landscape = false, paperChosen = false;
  late bool pageFormatReady;
  String message = '';
  String? sourcePaperLabel;
  int submitted = 0;
  bool savingPdf = false, openingSystemDialog = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    pageFormatReady = widget.previewBuilder != null;
    loadPrinters();
  }
  @override
  void didUpdateWidget(covariant WindowsReceiptPrintDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.receipt != widget.receipt) {
      paper = 'A4'; landscape = false; paperChosen = false;
      sourcePaperLabel = null;
      pageFormatReady = widget.previewBuilder != null;
    }
  }
  void acceptPageFormat(PdfPageFormat? format) {
    if (!mounted || !widget.isCurrent()) return;
    String? matched;
    if (format != null) {
      final width = format.width < format.height ? format.width : format.height;
      final height = format.width < format.height ? format.height : format.width;
      for (final stock in ['A4','Legal','Letter']) {
        final candidate = paperFormat(stock);
        if ((candidate.width-width).abs() <= 2 && (candidate.height-height).abs() <= 2) {
          matched = stock; break;
        }
      }
    }
    setState(() {
      sourcePaperLabel = matched == null ? null :
        matched! + (format!.width > format.height ? ' • Landscape' : ' • Portrait');
      if (paperChosen) return;
      pageFormatReady = matched != null;
      if (matched != null) {
        paper = matched!;
        landscape = format!.width > format.height;
      } else {
        message = 'Could not identify the original paper size. Select paper size before printing.';
      }
    });
  }
  PdfPageFormat get selectedFormat => landscape ? paperFormat(paper).landscape : paperFormat(paper);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from Windows "Add printer" should enumerate the newly
    // installed USB/network driver without requiring the school to relaunch.
    if(state==AppLifecycleState.resumed && mounted &&
       !printing && !loadingPrinters && widget.isCurrent()){
      loadPrinters();
    }
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    copies.dispose();
    super.dispose();
  }
  Future<void> loadPrinters() async {
    setState(() { loadingPrinters = true; message = ''; });
    try {
      final rows = await (widget.printers ?? Printing.listPrinters)();
      if (!mounted || !widget.isCurrent()) return;
      // Windows can mark an installed USB/network printer temporarily
      // unavailable. Keep it visible; let the driver report send failure.
      final unique = {for(final row in rows) if(row.url.trim().isNotEmpty)
        row.url:row};
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
    if (printing || !pageFormatReady || !widget.isCurrent()) return;
    final count = int.tryParse(copies.text.trim());
    if (count == null || count < 1 || count > 20) {
      setState(() => message = 'Enter 1 to 20 copies.'); return;
    }
    final matches = printers.where((p) => p.url == selected);
    if (matches.isEmpty) { setState(() => message = 'Select an available printer.'); return; }
    final printer = matches.first;
    final format = selectedFormat;
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
  static PdfPageFormat paperFormat(String value)=>switch(value){
    'Legal'=>PdfPageFormat.legal,
    'Letter'=>PdfPageFormat.letter,
    _=>PdfPageFormat.a4,
  };

  Future<void> addPrinter() async {
    if(printing || openingSystemDialog || !widget.isCurrent())return;
    try{
      if(widget.openPrinterSettings!=null){
        await widget.openPrinterSettings!();
      }else if(Platform.isWindows){
        await Process.start('explorer.exe',['ms-settings:printers'],
          runInShell:false);
      }else{
        throw const FormatException('Add printer through system settings.');
      }
      if(mounted)setState(()=>message='Use Windows Add device / Add printer, '
        'then select Refresh printers in Vidya Saarthi.');
    }catch(_){
      if(mounted)setState(()=>message='Could not open printer settings. '
        'Open Windows Settings > Bluetooth & devices > Printers & scanners.');
    }
  }

  Future<void> showSystemPrinterDialog(Uint8List bytes) async {
    if(printing||openingSystemDialog||!pageFormatReady||!widget.isCurrent())return;
    setState(()=>openingSystemDialog=true);
    try{
      final format=selectedFormat;
      final submitted=await (widget.systemPrintJob!=null
        ?widget.systemPrintJob!(bytes,format)
        :Printing.layoutPdf(name:widget.title,format:format,
          dynamicLayout:false,usePrinterSettings:true,
          onLayout:(_ ) async {
            if(!widget.isCurrent())throw StateError('School changed.');
            return bytes;
          }));
      if(mounted)setState(()=>message=submitted
        ?'Print request sent to the Windows printer dialog.'
        :'System printing was cancelled.');
    }catch(_){
      if(mounted)setState(()=>message='System print dialog failed. '
        'Check Windows printer installation and retry.');
    }finally{
      if(mounted)setState(()=>openingSystemDialog=false);
    }
  }

  Future<void> savePdf(Uint8List bytes) async {
    if (savingPdf || printing || !widget.isCurrent()) return;
    setState(() { savingPdf = true; message = ''; });
    try {
      final filename = widget.title.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
      final saved = await WindowsSavePdf.save(bytes, '${filename.isEmpty ? 'Receipt' : filename}.pdf');
      if (!mounted || !widget.isCurrent()) return;
      setState(() => message = saved == null ? '' : 'PDF saved to: $saved');
    } catch (e) {
      if (mounted) setState(() => message = 'PDF could not be saved. Choose a writable folder and retry.');
    } finally {
      if (mounted) setState(() => savingPdf = false);
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
      Wrap(alignment:WrapAlignment.end,spacing:8,runSpacing:4,children:[
        TextButton.icon(
          onPressed:printing||openingSystemDialog?null:addPrinter,
          icon:const Icon(Icons.add, size:16),
          label:const Text('Add printer')),
        TextButton.icon(
          onPressed:printing||loadingPrinters?null:loadPrinters,
          icon:const Icon(Icons.refresh,size:16),
          label:const Text('Refresh printers')),
      ]),
      const SizedBox(height: 12),
      TextField(controller: copies, enabled: !printing,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Copies', helperText: '1–20')),
      const SizedBox(height: 16),
      if (!pageFormatReady && message.isEmpty)
        const Text('Detecting original paper size…'),
      DropdownButtonFormField<String>(value: paper, isExpanded: true,
        decoration: const InputDecoration(labelText: 'Paper size'),
        items: const [DropdownMenuItem(value: 'A4', child: Text('A4 (210 × 297 mm)', overflow: TextOverflow.ellipsis)),
          DropdownMenuItem(value: 'Letter', child: Text('Letter (216 × 279 mm)', overflow: TextOverflow.ellipsis)),
          DropdownMenuItem(value: 'Legal', child: Text('Legal (216 × 356 mm)', overflow: TextOverflow.ellipsis))],
        onChanged: printing ? null : (v) => setState(() {
          paper = v ?? 'A4'; paperChosen = true; pageFormatReady = true;
          if (message.startsWith('Could not identify')) message = '';
        })),
      const SizedBox(height: 12),
      DropdownButtonFormField<bool>(value: landscape, isExpanded: true,
        decoration: const InputDecoration(labelText: 'Orientation'),
        items: const [DropdownMenuItem(value: false, child: Text('Portrait')),
          DropdownMenuItem(value: true, child: Text('Landscape'))],
        onChanged: printing || !pageFormatReady ? null : (value) => setState(() {
          landscape = value ?? false; paperChosen = true; pageFormatReady = true;
        })),
      const SizedBox(height: 20),
      const Text('Pages: All receipt pages'),
      const SizedBox(height: 8),
      Text(sourcePaperLabel == null ? 'Layout: Original receipt'
        : 'Original document: '+sourcePaperLabel!),
      const SizedBox(height: 5),
      const Text('For full-size Legal artwork, generate a Legal-size '
        'document. Changing printer paper does not resize an existing PDF.',
        style:TextStyle(fontSize:11)),
      const SizedBox(height: 20),
      if (message.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(message)),
      FilledButton.icon(onPressed: printing || !pageFormatReady || loadingPrinters || selected == null || bytes == null || !widget.isCurrent()
          ? null : () => printReceipt(bytes),
        icon: const Icon(Icons.print), label: Text(printing ? 'Sending…' : 'Print')),
      TextButton.icon(
        onPressed:printing||openingSystemDialog||!pageFormatReady||bytes==null||!widget.isCurrent()
          ?null:()=>showSystemPrinterDialog(bytes),
        icon:const Icon(Icons.print_outlined),
        label:Text(openingSystemDialog?'Opening Windows print dialog…'
          :'More printers / system print dialog')),
      TextButton.icon(
        onPressed: printing || savingPdf || bytes == null || !widget.isCurrent()
            ? null : () => savePdf(bytes),
        icon: const Icon(Icons.picture_as_pdf_outlined),
        label: Text(savingPdf ? 'Saving PDF…' : 'Save PDF'),
      ),
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
              : widget.previewBuilder?.call(snapshot.data!) ?? FittedDocumentPreview(bytes: snapshot.data!,
                  onPageFormat: (format) => acceptPageFormat(format));
          return LayoutBuilder(builder: (context, limits) => limits.maxWidth >= 760
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: preview), const VerticalDivider(width: 1), SizedBox(width: 290, child: settings(snapshot.data))])
            : Column(children: [Expanded(child: preview), const Divider(height: 1),
                SizedBox(height: (limits.maxHeight * .5).clamp(100.0, 320.0).toDouble(), child: settings(snapshot.data))]));
        })),
      ])));
  }
}
