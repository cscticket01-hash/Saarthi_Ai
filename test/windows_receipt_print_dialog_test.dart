import 'dart:typed_data';
import 'dart:async';
import 'package:image/image.dart' as img;
import 'package:printing/src/interface.dart';
import 'package:printing/src/method_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import '../lib/windows_receipt_print_dialog.dart';
import '../lib/windows_print_layout.dart';
import '../lib/windows_printer_media.dart';

// Synthetic OS raster boundary: physical geometry comes from raster dimensions;
// preview pixels are tiny because this test verifies settings, not printer hardware.
class PaperSizeRaster extends PdfRaster {
  PaperSizeRaster(int width, int height) : super(width,height,Uint8List(width*height*4));
  @override
  Future<Uint8List> toPng() async => Uint8List.fromList(img.encodePng(img.Image(width:2,height:2)));
}
class PaperSizePrinting extends MethodChannelPrinting {
  PaperSizePrinting(this.width,this.height,{this.gate});
  final int width,height;
  final Future<void>? gate;
  int rasterCalls=0;
  @override
  Stream<PdfRaster> raster(Uint8List document,List<int>? pages,double dpi) async* {
    rasterCalls++;
    if(gate!=null)await gate;
    yield PaperSizeRaster(width,height);
  }
}

void main() {
  const printer = Printer(url: 'test-epson', name: 'EPSON L3110', isDefault: true, isAvailable: true);
  test('paper layout geometry preserves aspect and rejects invalid pages and clipping',(){
    expect(WindowsPrintLayout.parseRange('1,3-5,3'),{1,3,4,5});
    expect(()=>WindowsPrintLayout.parseRange('4-2'),throwsFormatException);
    expect(WindowsPrintLayout.grid(6,false),(columns:2,rows:3));
    final size=WindowsPrintLayout.imageSize(sourceWidth:200,sourceHeight:100,cellWidth:100,cellHeight:100);
    expect(size.width,100);expect(size.height,50);
    expect(()=>WindowsPrintLayout.imageSize(sourceWidth:200,sourceHeight:100,cellWidth:100,cellHeight:100,scale:100),throwsFormatException);
    expect(WindowsPrinterMedia.standard.firstWhere((p)=>p.name=='Legal').format.height,PdfPageFormat.legal.height);
  });
  testWidgets('driver stock selection prepares one shared layout for preview and printing',(tester)async{
    await tester.binding.setSurfaceSize(const Size(1200,1000));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    final original=Uint8List.fromList([1,2,3]),prepared=Uint8List.fromList([4,5,6]);
    Uint8List? sent;PdfPageFormat? sentFormat;
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:WindowsReceiptPrintDialog(
      receipt:Future.value(original),title:'Print test',subtitle:'School',isCurrent:()=>true,
      printers:()async=>[printer],media:(_)async=>const [WindowsPrinterPaper('A4',210,297),WindowsPrinterPaper('FLS',220,330)],
      composeLayout:(bytes,format)async{expect(identical(bytes,original),isTrue);expect(format.width,220*PdfPageFormat.mm);return prepared;},
      previewBuilder:(bytes)=>Text(identical(bytes,prepared)?'Prepared preview':'Original preview'),
      printJob:(_,bytes,format)async{sent=bytes;sentFormat=format;return true;}
    ))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('A4 (210 × 297 mm)'));
    await tester.tap(find.text('A4 (210 × 297 mm)'));await tester.pumpAndSettle();
    expect(find.text('Legal (216 × 356 mm)'),findsNothing);
    await tester.tap(find.text('FLS (220 × 330 mm)').last);await tester.pumpAndSettle();
    expect(find.text('Prepared preview'),findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(FilledButton,'Print'));
    await tester.tap(find.widgetWithText(FilledButton,'Print'));await tester.pumpAndSettle();
    expect(identical(sent,prepared),isTrue);expect(sentFormat!.height,330*PdfPageFormat.mm);
    expect(original,[1,2,3]);
  });
  for(final landscape in [false,true]) {
    testWidgets('Legal ${landscape?'landscape':'portrait'} preview selects matching printer stock without another raster', (tester) async {
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=const Size(1200,1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final native=PrintingPlatform.instance;
      final platform=PaperSizePrinting(landscape?2800:1700,landscape?1700:2800);
      PrintingPlatform.instance=platform;
      addTearDown(()=>PrintingPlatform.instance=native);
      final bytes=Uint8List.fromList([37,80,68,70,45]);
      PdfPageFormat? sent;
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:WindowsReceiptPrintDialog(
        receipt:Future.value(bytes),title:'Legal receipt',subtitle:'School',isCurrent:()=>true,
        printers:()async=>[printer],printJob:(_,original,format) async {
          expect(identical(original,bytes),isTrue);sent=format;return true;
        }))));
      await tester.pumpAndSettle();
      expect(find.text('Legal (216 × 356 mm)'),findsOneWidget);
      expect(find.text(landscape?'Landscape':'Portrait'),findsOneWidget);
      await tester.ensureVisible(find.widgetWithText(FilledButton,'Print'));
      await tester.tap(find.widgetWithText(FilledButton,'Print'));
      await tester.pumpAndSettle();
      expect(sent?.width,landscape?PdfPageFormat.legal.height:PdfPageFormat.legal.width);
      expect(sent?.height,landscape?PdfPageFormat.legal.width:PdfPageFormat.legal.height);
      expect(platform.rasterCalls,1,reason:'Reuse the normal preview raster for paper detection');
      expect(tester.takeException(),isNull);
    });
  }
  testWidgets('late preview detection preserves explicit school paper selection', (tester) async {
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1200,1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final native=PrintingPlatform.instance;
    final gate=Completer<void>();
    PrintingPlatform.instance=PaperSizePrinting(1654,2339,gate:gate.future);
    addTearDown(()=>PrintingPlatform.instance=native);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:WindowsReceiptPrintDialog(
      receipt:Future.value(Uint8List(1)),title:'Receipt',subtitle:'School',isCurrent:()=>true,
      printers:()async=>[printer],composeLayout:(source,format)async=>source))));
    await tester.pump();await tester.pump();
    await tester.ensureVisible(find.text('A4 (210 × 297 mm)'));
    await tester.tap(find.text('A4 (210 × 297 mm)'));
    await tester.pump(const Duration(milliseconds:300));
    await tester.tap(find.text('Legal (216 × 356 mm)').last);
    await tester.pump(const Duration(milliseconds:300));
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Legal (216 × 356 mm)'),findsOneWidget);
    expect(tester.takeException(),isNull);
  });
  testWidgets('full app preview defaults A4, never auto prints, and sends exact bytes for each copy', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final bytes = Uint8List.fromList([37,80,68,70,45]);
    final calls = <Uint8List>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WindowsReceiptPrintDialog(
      receipt: Future.value(bytes), title: 'Receipt TEST', subtitle: 'Student', isCurrent: () => true,
      printers: () async => [printer], previewBuilder: (_) => const Center(child: Text('Full page preview')),
      printJob: (selected, original, format) async {
        expect(selected.url, printer.url); expect(format.width, PdfPageFormat.a4.width);
        calls.add(original); return true;
      }))));
    await tester.pumpAndSettle();
    expect(find.text('Full page preview'), findsOneWidget);
    expect(find.text('Save PDF'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.text('A4 (210 × 297 mm)'), findsOneWidget);
    expect(calls, isEmpty);
    await tester.enterText(find.byType(TextField), '2');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Print'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Print'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(2)); expect(identical(calls[0], bytes), true);
    expect(identical(calls[1], bytes), true);
    expect(find.text('2 copies sent to printer.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('all Windows-installed printers remain visible and Add printer opens settings', (tester) async {
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1200,900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const offline=Printer(url:'installed-hp',name:'HP offline USB',
      isDefault:false,isAvailable:false);
    var opened=0,systemDialog=0;
    await tester.pumpWidget(MaterialApp(home:Scaffold(
      body:WindowsReceiptPrintDialog(
        receipt:Future.value(Uint8List.fromList([37,80,68,70,45])),
        title:'Printer TEST',subtitle:'Any school printer',isCurrent:()=>true,
        printers:()async=>[printer,offline],
        openPrinterSettings:()async{opened++;},
        systemPrintJob:(bytes,format)async{
          systemDialog++;
          expect(format.width,PdfPageFormat.legal.width);
          expect(bytes.take(5).toList(),[37,80,68,70,45]);
          return true;
        },
        previewBuilder:(_)=>const SizedBox(),composeLayout:(source,format)async=>source))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add printer'));
    await tester.tap(find.text('Add printer'));
    await tester.pumpAndSettle();
    expect(opened,1);
    await tester.ensureVisible(find.text('EPSON L3110'));
    await tester.tap(find.text('EPSON L3110'));
    await tester.pumpAndSettle();
    expect(find.text('HP offline USB'),findsOneWidget,
      reason:'Temporary offline status must not hide installed printers');
    await tester.tap(find.text('HP offline USB').last);
    await tester.pumpAndSettle();
    // Select Legal with the synthetic layout hook; original bytes stay immutable.
    await tester.ensureVisible(find.text('A4 (210 × 297 mm)'));
    await tester.tap(find.text('A4 (210 × 297 mm)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Legal (216 × 356 mm)').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('More printers / system print dialog'));
    await tester.tap(find.text('More printers / system print dialog'));
    await tester.pumpAndSettle();
    expect(systemDialog,1);
    expect(tester.takeException(),isNull);
  });

  testWidgets('printer list refreshes when returning from Windows settings', (tester) async {
    tester.view.devicePixelRatio=1;
    tester.view.physicalSize=const Size(1200,900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var lookups=0;
    const installed=Printer(url:'network-laser',
      name:'Newly installed network printer',isDefault:false,isAvailable:true);
    await tester.pumpWidget(MaterialApp(home:Scaffold(
      body:WindowsReceiptPrintDialog(
        receipt:Future.value(Uint8List.fromList([37,80,68,70,45])),
        title:'Install printer',subtitle:'School',isCurrent:()=>true,
        printers:()async{
          lookups++;
          return lookups==1?[printer]:[printer,installed];
        },
        previewBuilder:(_)=>const SizedBox()))));
    await tester.pumpAndSettle();
    expect(lookups,1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(lookups,2);
    await tester.ensureVisible(find.text('EPSON L3110'));
    await tester.tap(find.text('EPSON L3110'));
    await tester.pumpAndSettle();
    expect(find.text('Newly installed network printer'),findsOneWidget);
  });

  testWidgets('invalid copies and a school switch cannot submit another print', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var current = true, calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WindowsReceiptPrintDialog(
      receipt: Future.value(Uint8List(1)), title: 'Receipt', subtitle: 'Student', isCurrent: () => current,
      printers: () async => [printer], previewBuilder: (_) => const SizedBox(),
      printJob: (_, __, ___) async { calls++; return true; }))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Print'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Print'));
    await tester.pumpAndSettle();
    expect(find.text('Enter 1 to 20 copies.'), findsOneWidget); expect(calls, 0);
    current = false;
    await tester.enterText(find.byType(TextField), '1');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Print'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Print'));
    await tester.pumpAndSettle(); expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}
