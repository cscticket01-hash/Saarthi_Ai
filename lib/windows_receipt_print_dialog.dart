import 'dart:io';
import 'dart:async';
import 'windows_print_layout.dart';
import 'windows_printer_media.dart';
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
    this.openPrinterSettings, this.systemPrintJob, this.media, this.composeLayout});
  final Future<Uint8List> receipt;
  final String title, subtitle;
  final bool Function() isCurrent;
  final Future<List<Printer>> Function()? printers;
  final ReceiptPrinterJob? printJob;
  final Future<void> Function()? openPrinterSettings;
  final Future<bool> Function(Uint8List,PdfPageFormat)? systemPrintJob;
  final Widget Function(Uint8List)? previewBuilder;
  final Future<List<WindowsPrinterPaper>> Function(Printer)? media;
  final Future<Uint8List> Function(Uint8List,PdfPageFormat)? composeLayout;
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
  static const pdfDestination = 'saarthi:save-pdf';
  List<WindowsPrinterPaper> driverMedia = [];
  bool loadingMedia = false;
  String? mediaError;
  int mediaGeneration = 0, layoutGeneration = 0;
  PdfPageFormat? originalFormat;
  Future<Uint8List>? layout;
  final rangeController = TextEditingController();
  final scaleController = TextEditingController(text:'100');
  final marginController = TextEditingController(text:'10');
  Timer? layoutDelay;
  bool customPages = false, headersFooters=false, monochrome=false;
  int perSheet = 1;
  String margins = 'None', scaling = 'Fit to page';
  bool expandedSettings = false;
  bool get locked => printing || savingPdf || openingSystemDialog;
  WindowsPrinterPaper? chosenStock;
  List<WindowsPrinterPaper> get stock {
    final base = selected == null || selected == pdfDestination || widget.printers != null && widget.media == null
      ? WindowsPrinterMedia.standard : driverMedia;
    final items = {for(final p in base)p.name:p};
    if(chosenStock!=null)items[paper]=chosenStock!;
    for(final p in WindowsPrinterMedia.standard) {
      if(p.name==paper) items.putIfAbsent(p.name,()=>p);
    }
    if(originalFormat!=null && paper=='Original') {
      final f=originalFormat!;
      final w=f.width<f.height?f.width:f.height, h=f.width<f.height?f.height:f.width;
      items['Original']=WindowsPrinterPaper('Original',w/PdfPageFormat.mm,h/PdfPageFormat.mm);
    }
    if(!items.containsKey(paper)) items[paper]=WindowsPrinterMedia.standard.first;
    return items.values.toList();
  }
  bool get driverSupportsPaper {
    if (selected==null || selected==pdfDestination) return false;
    if(widget.printers!=null && widget.media==null) return true;
    final f=paperFormat(paper);
    return !loadingMedia && driverMedia.any((p)=>
      (p.format.width-f.width).abs()<3 && (p.format.height-f.height).abs()<3);
  }

  Future<void> loadMedia() async {
    final generation=++mediaGeneration;
    final matches=printers.where((p)=>p.url==selected).toList();
    if(matches.isEmpty){
      if(mounted)setState((){driverMedia=[];loadingMedia=false;mediaError=null;});
      return;
    }
    setState((){loadingMedia=true;driverMedia=[];mediaError=null;});
    try {
      final rows=await (widget.media?.call(matches.first) ??
        (widget.printers!=null?Future.value(WindowsPrinterMedia.standard):WindowsPrinterMedia.installed(matches.first.name)));
      if(mounted && generation==mediaGeneration && widget.isCurrent())setState(()=>driverMedia=rows);
    }catch(_){
      if(mounted && generation==mediaGeneration)setState(()=>mediaError='Driver paper sizes unavailable. Refresh or use Windows system print dialog.');
    }finally{
      if(mounted && generation==mediaGeneration)setState(()=>loadingMedia=false);
    }
  }

  void changeLayout(Uint8List? source, VoidCallback update, {bool debounce=false}) {
    if(locked || source==null)return;
    layoutDelay?.cancel();
    final generation=++layoutGeneration;
    final pending=Completer<Uint8List>();
    setState((){
      update();
      paperChosen=true;
      pageFormatReady=true;
      message='';
      layout=pending.future;
    });
    void start() async {
      if(!mounted || generation!=layoutGeneration)return;
      try {
        final format=selectedFormat;
        final range=customPages?rangeController.text.trim():'';
        if(customPages && range.isEmpty)throw const FormatException('Enter a page range.');
        final margin=switch(margins){'None'=>0.0,'Minimum'=>3.0,'Default'=>10.0,
          _=>double.tryParse(marginController.text.trim())??-1};
        if(!margin.isFinite||margin<0)throw const FormatException('Enter a valid margin.');
        final double? scale=switch(scaling){'Fit to page'=>null,'Actual size'=>100.0,
          _=>double.tryParse(scaleController.text.trim())??-1};
        if(scale!=null&&(!scale.isFinite||scale<10||scale>200))throw const FormatException('Enter scale from 10 to 200 percent.');
        final bytes=await (widget.composeLayout?.call(source,format) ??
          WindowsPrintLayout.compose(source,format,range:range,perSheet:perSheet,
            marginMm:margin,scale:scale,headersFooters:headersFooters,monochrome:monochrome,
            isCurrent:()=>mounted&&widget.isCurrent()&&generation==layoutGeneration));
        pending.complete(bytes);
      }catch(e,st){pending.completeError(e,st);}
    }
    // Attach an error listener immediately: validation may finish before the
    // next widget build, and superseded jobs must not leak asynchronous errors.
    unawaited(pending.future.then<void>((_) {},onError:(Object _,StackTrace __){}));
    if(debounce){layoutDelay=Timer(const Duration(milliseconds:300),start);}
    else{scheduleMicrotask(start);}
  }
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
      customPages=false;perSheet=1;margins='None';scaling='Fit to page';headersFooters=false;monochrome=false;
      sourcePaperLabel = null; originalFormat=null; chosenStock=null; layout=null; layoutGeneration++; layoutDelay?.cancel();
      pageFormatReady = widget.previewBuilder != null;
    }
  }
  void acceptPageFormat(PdfPageFormat? format) {
    if (!mounted || !widget.isCurrent()) return;
    String? matched;
    if (format != null) {
      final width = format.width < format.height ? format.width : format.height;
      final height = format.width < format.height ? format.height : format.width;
      for (final stock in WindowsPrinterMedia.standard) {
        final candidate = stock.format;
        if ((candidate.width-width).abs() <= 2 && (candidate.height-height).abs() <= 2) {
          matched = stock.name; break;
        }
      }
    }
    setState(() {
      originalFormat=format;
      if(format!=null && matched==null) matched='Original';
      sourcePaperLabel = matched == null ? null :
        matched! + (format!.width > format.height ? ' • Landscape' : ' • Portrait');
      if (paperChosen) return;
      pageFormatReady = matched != null;
      if (matched != null) {
        paper = matched!;
        chosenStock=paper=='Original'?null:WindowsPrinterMedia.standard.firstWhere((p)=>p.name==paper);
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
    layoutGeneration++; mediaGeneration++; layoutDelay?.cancel();
    copies.dispose(); rangeController.dispose(); scaleController.dispose(); marginController.dispose();
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
        if (selected != pdfDestination && !unique.containsKey(selected)) {
          final defaults = printers.where((p) => p.isDefault);
          selected = defaults.isNotEmpty ? defaults.first.url : printers.isEmpty ? pdfDestination : printers.first.url;
        }
      });
      await loadMedia();
    } catch (e) {
      if (mounted) setState(() { selected=pdfDestination; message = 'Printers unavailable. Check the printer connection, then Refresh.'; });
      // PDF export remains available without a physical driver.
    } finally {
      if (mounted) setState(() => loadingPrinters = false);
    }
  }
  Future<void> printReceipt(Uint8List bytes) async {
    if (locked || !pageFormatReady || !widget.isCurrent()) return;
    if(selected==pdfDestination){await savePdf(bytes);return;}
    if(!driverSupportsPaper){setState(()=>message='Select paper supported by the installed printer driver.');return;}
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
  PdfPageFormat paperFormat(String value){
    if(value=='Original'&&originalFormat!=null){final f=originalFormat!;return f.width<=f.height?f:PdfPageFormat(f.height,f.width);}
    if(chosenStock?.name==value)return chosenStock!.format;
    for(final p in [...WindowsPrinterMedia.standard,...driverMedia]){if(p.name==value)return p.format;}
    return PdfPageFormat.a4;
  }

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
  Widget settings(Uint8List? source, Uint8List? bytes) => SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Print', style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
      const SizedBox(height: 20),
      if (loadingPrinters) const LinearProgressIndicator(),
      DropdownButtonFormField<String>(value: selected, isExpanded: true,
        decoration: const InputDecoration(labelText: 'Printer'),
        items: [for(final p in printers) DropdownMenuItem(value:p.url,child:Text(p.name,overflow:TextOverflow.ellipsis)),
          const DropdownMenuItem(value:pdfDestination,child:Text('Save as PDF'))],
        onChanged: locked ? null : (value) {setState(()=>selected=value);unawaited(loadMedia());}),
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
      TextField(controller: copies, enabled: !locked && selected!=pdfDestination,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Copies', helperText: '1–20')),
      const SizedBox(height: 16),
      if (!pageFormatReady && message.isEmpty)
        const Text('Detecting original paper size…'),
      DropdownButtonFormField<String>(value: paper, isExpanded: true,
        decoration: const InputDecoration(labelText: 'Paper size'),
        items: stock.map((p)=>DropdownMenuItem(value:p.name,child:Text(p.label,overflow:TextOverflow.ellipsis))).toList(),
        onChanged: locked || loadingMedia || source==null ? null : (v) {if(v!=null){final next=stock.firstWhere((p)=>p.name==v);changeLayout(source,(){paper=v;chosenStock=next;});}}),
      if(loadingMedia)const Text('Reading installed printer paper sizes…'),
      if(mediaError!=null)Text(mediaError!,style:const TextStyle(fontSize:11)),
      if(selected!=null && selected!=pdfDestination && !loadingMedia && !driverSupportsPaper)
        const Text('Current paper is not verified for this printer. Choose a supported size or use system dialog.',style:TextStyle(fontSize:11)),
      const SizedBox(height:12),
      DropdownButtonFormField<bool>(value:landscape,isExpanded:true,
        decoration:const InputDecoration(labelText:'Orientation'),
        items:const [DropdownMenuItem(value:false,child:Text('Portrait')),DropdownMenuItem(value:true,child:Text('Landscape'))],
        onChanged:locked||!pageFormatReady||source==null?null:(v){if(v!=null)changeLayout(source,()=>landscape=v);}),
      const SizedBox(height:12),
      DropdownButtonFormField<bool>(value:customPages,decoration:const InputDecoration(labelText:'Pages'),
        items:const [DropdownMenuItem(value:false,child:Text('All')),DropdownMenuItem(value:true,child:Text('Custom range'))],
        onChanged:locked||source==null?null:(v){if(v!=null)changeLayout(source,()=>customPages=v);}),
      if(customPages)TextField(controller:rangeController,enabled:!locked,decoration:const InputDecoration(hintText:'1,3-5',labelText:'Page range'),
        onChanged:(_)=>changeLayout(source,(){},debounce:true)),
      ExpansionTile(title:const Text('More settings'),initiallyExpanded:expandedSettings,
        onExpansionChanged:(v)=>expandedSettings=v,
        tilePadding:EdgeInsets.zero,children:[
          DropdownButtonFormField<int>(value:perSheet,decoration:const InputDecoration(labelText:'Pages per sheet'),
            items:[for(final n in [1,2,4,6,9,16])DropdownMenuItem(value:n,child:Text('$n'))],
            onChanged:locked||source==null?null:(v){if(v!=null)changeLayout(source,()=>perSheet=v);}),
          DropdownButtonFormField<String>(value:margins,decoration:const InputDecoration(labelText:'Margins'),
            items:[for(final v in ['None','Default','Minimum','Custom'])DropdownMenuItem(value:v,child:Text(v))],
            onChanged:locked||source==null?null:(v){if(v!=null)changeLayout(source,()=>margins=v);}),
          if(margins=='Custom')TextField(controller:marginController,enabled:!locked,keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'Margin (mm, all sides)'),onChanged:(_)=>changeLayout(source,(){},debounce:true)),
          DropdownButtonFormField<String>(value:scaling,decoration:const InputDecoration(labelText:'Scale'),
            items:[for(final v in ['Fit to page','Actual size','Custom'])DropdownMenuItem(value:v,child:Text(v))],
            onChanged:locked||source==null?null:(v){if(v!=null)changeLayout(source,()=>scaling=v);}),
          if(scaling=='Custom')TextField(controller:scaleController,enabled:!locked,keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'Scale %'),onChanged:(_)=>changeLayout(source,(){},debounce:true)),
          DropdownButtonFormField<bool>(value:monochrome,decoration:const InputDecoration(labelText:'Colour'),
            items:const [DropdownMenuItem(value:false,child:Text('Original colours')),DropdownMenuItem(value:true,child:Text('Black & white'))],
            onChanged:locked||source==null?null:(v){if(v!=null)changeLayout(source,()=>monochrome=v);}),
          CheckboxListTile(contentPadding:EdgeInsets.zero,value:headersFooters,title:const Text('Headers and footers'),
            subtitle:const Text('Print-added header and sheet number'),onChanged:locked||source==null?null:(v)=>changeLayout(source,()=>headersFooters=v??false)),
          const Text('Background graphics: embedded document artwork is preserved. PDF/image backgrounds cannot safely be removed separately.',style:TextStyle(fontSize:11)),
          TextButton(onPressed:locked?null:(){setState((){
            layoutGeneration++;layoutDelay?.cancel();layout=null;customPages=false;perSheet=1;margins='None';scaling='Fit to page';headersFooters=false;monochrome=false;paperChosen=false;chosenStock=null;
            paper='A4';landscape=false;
          });if(originalFormat!=null)acceptPageFormat(originalFormat);},child:const Text('Reset to original layout')),
          const Text('Duplex, colour hardware mode, tray and other driver-specific options: Windows system print dialog.',style:TextStyle(fontSize:11)),
        ]),
      Text(sourcePaperLabel==null?'Original document':'Original document: ${sourcePaperLabel!}'),
      if(layout!=null)const Text('Changed layout uses a print-only 300 dpi rendering. Original file is unchanged.',style:TextStyle(fontSize:11)),
      const SizedBox(height: 20),
      if (message.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(message)),
      FilledButton.icon(onPressed: locked || !pageFormatReady || loadingPrinters || selected == null || bytes == null || !widget.isCurrent() || (selected!=pdfDestination && !driverSupportsPaper)
          ? null : () => printReceipt(bytes),
        icon: const Icon(Icons.print), label: Text(printing ? 'Sending…' : selected==pdfDestination?'Save as PDF':'Print')),
      TextButton.icon(
        onPressed:locked||!pageFormatReady||bytes==null||!widget.isCurrent()
          ?null:()=>showSystemPrinterDialog(bytes),
        icon:const Icon(Icons.print_outlined),
        label:Text(openingSystemDialog?'Opening Windows print dialog…'
          :'More printers / system print dialog')),
      TextButton(onPressed:locked?null:()=>Navigator.maybePop(context),child:const Text('Cancel')),
      TextButton.icon(
        onPressed: locked || bytes == null || !widget.isCurrent()
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
          trailing: IconButton(tooltip: 'Close receipt', onPressed: locked ? null : () => Navigator.pop(context), icon: const Icon(Icons.close))),
        const Divider(height: 1),
        Expanded(child: FutureBuilder<Uint8List>(future: widget.receipt, builder: (context, snapshot) {
          if (!widget.isCurrent()) return const Center(child: Text('School changed. Reopen receipt history.'));
          return FutureBuilder<Uint8List>(future:layout,builder:(context,output){
            final changing=layout!=null;
            final ready=!changing || output.connectionState==ConnectionState.done;
            final printable=changing?(ready&&!output.hasError?output.data:null):snapshot.data;
            final preview=snapshot.hasError?const Center(child:Text('Document unavailable.')):
              output.hasError&&changing?Center(child:Text('Layout unavailable: ${output.error}')):
              printable==null?const Center(child:CircularProgressIndicator()):
              widget.previewBuilder?.call(printable)??FittedDocumentPreview(bytes:printable,
                showPaperOutline:true,onPageFormat:changing?null:acceptPageFormat);
            return LayoutBuilder(builder:(context,limits)=>limits.maxWidth>=760
              ? Row(crossAxisAlignment: CrossAxisAlignment.stretch,children:[
                Expanded(child:preview),const VerticalDivider(width:1),SizedBox(width:310,child:settings(snapshot.data,printable))])
              : Column(children:[Expanded(child:preview),const Divider(height:1),
                SizedBox(height:(limits.maxHeight*.5).clamp(100.0,320.0).toDouble(),child:settings(snapshot.data,printable))]));
          });
        })),
      ])));
  }
}
