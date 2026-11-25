import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';

class WindowsPrinterPaper {
  const WindowsPrinterPaper(this.name,this.widthMm,this.heightMm);
  final String name;
  final double widthMm,heightMm;
  PdfPageFormat get format => switch(name) {
    'A4' when widthMm==210 && heightMm==297 => PdfPageFormat.a4,
    'Legal' when widthMm==215.9 && heightMm==355.6 => PdfPageFormat.legal,
    'Letter' when widthMm==215.9 && heightMm==279.4 => PdfPageFormat.letter,
    _ => PdfPageFormat(widthMm*PdfPageFormat.mm,heightMm*PdfPageFormat.mm),
  };
  String get label => '$name (${widthMm.round()} × ${heightMm.round()} mm)';
}

enum WindowsDuplexMode { driverDefault, singleSided, longEdge, shortEdge }

class WindowsPrinterCapabilities {
  const WindowsPrinterCapabilities({required this.canDuplex,required this.supportsColor});
  final bool canDuplex,supportsColor;
}

/// The Windows installed driver's PaperSizes collection is the source of
/// available physical media, not an invented fixed list.
class WindowsPrinterMedia {
  static const standard = <WindowsPrinterPaper>[
    WindowsPrinterPaper('A4',210,297), WindowsPrinterPaper('Letter',215.9,279.4),
    WindowsPrinterPaper('Legal',215.9,355.6), WindowsPrinterPaper('A3',297,420),
    WindowsPrinterPaper('A5',148,210), WindowsPrinterPaper('A6',105,148),
    WindowsPrinterPaper('B4',250,353), WindowsPrinterPaper('B5',176,250),
    WindowsPrinterPaper('B6',125,176), WindowsPrinterPaper('11x17',279.4,431.8),
    WindowsPrinterPaper('Executive',184.15,266.7),
  ];
  static Future<List<WindowsPrinterPaper>> installed(String name) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows printer driver required.');
    // Pass printer identity through the environment, not a shell expression.
    final result = await Process.run('powershell.exe',[
      '-NoProfile','-NonInteractive','-Command',
      r'''$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Drawing;
      $p=New-Object System.Drawing.Printing.PrinterSettings;
      $p.PrinterName=$env:SAARTHI_PRINT_QUEUE;
      if(-not $p.IsValid){throw 'Printer driver unavailable'}
      @($p.PaperSizes | ForEach-Object { [PSCustomObject]@{name=$_.PaperName;width=$_.Width;height=$_.Height} }) | ConvertTo-Json -Compress''',
    ],environment:{'SAARTHI_PRINT_QUEUE':name}).timeout(const Duration(seconds:12));
    if (result.exitCode!=0) throw StateError('Printer media could not be read.');
    final raw=jsonDecode(result.stdout.toString().trim());
    final rows=raw is List?raw:[raw];
    final resultPapers=<String,WindowsPrinterPaper>{};
    for(final row in rows) {
      if(row is! Map || row['width'] is! num || row['height'] is! num) continue;
      final w=(row['width'] as num).toDouble()*.254, h=(row['height'] as num).toDouble()*.254;
      if(w<10||h<10||w>2000||h>2000)continue;
      final width=w<h?w:h,height=w<h?h:w;
      final match=standard.where((p)=>(p.widthMm-width).abs()<1 && (p.heightMm-height).abs()<1);
      final label=match.isNotEmpty?match.first.name:row['name']?.toString().trim()??'Custom';
      if(label.isEmpty)continue;
      final stock=match.isNotEmpty?match.first:WindowsPrinterPaper(label,width,height);
      final key=stock.name;
      if(resultPapers.containsKey(key) && ((resultPapers[key]!.widthMm-width).abs()>1 || (resultPapers[key]!.heightMm-height).abs()>1)) {
        final unique='$label ${width.round()}x${height.round()}';
        resultPapers[unique]=WindowsPrinterPaper(unique,width,height);
      } else { resultPapers[key]=stock; }
    }
    if(resultPapers.isEmpty)throw StateError('No supported paper sizes reported by the driver.');
    return resultPapers.values.toList();
  }
  static Future<WindowsPrinterCapabilities> capabilities(String name) async {
    if(!Platform.isWindows)throw UnsupportedError('Windows printer driver required.');
    final result=await Process.run('powershell.exe',[
      '-NoProfile','-NonInteractive','-Command',
      r'''$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Drawing;
      $p=New-Object System.Drawing.Printing.PrinterSettings;
      $p.PrinterName=$env:SAARTHI_PRINT_QUEUE;
      if(-not $p.IsValid){throw 'Printer unavailable'}
      [PSCustomObject]@{duplex=$p.CanDuplex;color=$p.SupportsColor} | ConvertTo-Json -Compress''',
    ],environment:{'SAARTHI_PRINT_QUEUE':name}).timeout(const Duration(seconds:12));
    if(result.exitCode!=0)throw StateError('Driver capabilities unavailable.');
    final raw=jsonDecode(result.stdout.toString().trim());
    if(raw is! Map || raw['duplex'] is! bool || raw['color'] is! bool)throw const FormatException('Invalid printer capabilities.');
    return WindowsPrinterCapabilities(canDuplex:raw['duplex'] as bool,supportsColor:raw['color'] as bool);
  }

  /// Explicit per-job sides setting. Do not modify the Windows printer's
  /// persisted defaults. Original PDF output continues through the existing
  /// printing plugin when the user leaves Driver default selected.
  /// Raster sheets and physical stock are checked before opening the spooler;
  /// no automatic fallback/retry is permitted after a submission attempt.
  static Future<bool> printWithSides(Printer printer,Uint8List bytes,PdfPageFormat format,
      WindowsDuplexMode mode,{required String title,required bool Function() isCurrent}) async {
    if(!Platform.isWindows || mode==WindowsDuplexMode.driverDefault)throw UnsupportedError('Explicit Windows driver sides required.');
    final pages=<String>[];
    var byteCount=0;
    const dpi=300.0;
    await for(final page in Printing.raster(bytes,dpi:dpi)){
      if(!isCurrent())throw StateError('School changed. Print stopped.');
      if((page.width*72/dpi-format.width).abs()>2 || (page.height*72/dpi-format.height).abs()>2){
        throw const FormatException('All sheets must match selected paper. Prepare a uniform layout first.');
      }
      final png=await page.toPng();
      byteCount+=png.length;
      if(byteCount>40*1024*1024 || pages.length>=100)throw const FormatException('Sides job too large. Choose a smaller page range.');
      pages.add(base64Encode(png));
    }
    if(pages.isEmpty||!isCurrent())throw StateError('No current printable sheets.');
    final landscape=format.width>format.height;
    final width=(landscape?format.height:format.width)*100/72;
    final height=(landscape?format.width:format.height)*100/72;
    final input=jsonEncode({
      'name':printer.name,'title':title,'width':width,'height':height,'landscape':landscape,
      'duplex':switch(mode){WindowsDuplexMode.singleSided=>'Simplex',WindowsDuplexMode.longEdge=>'Vertical',
        WindowsDuplexMode.shortEdge=>'Horizontal',_=>throw StateError('Invalid sides mode')},'pages':pages,
    });
    if(!isCurrent())throw StateError('School changed.');
    // Fixed script only; all user/document data passes through stdin.
    // Images exist in memory only, not a public or persisted temporary folder.
    final process=await Process.start('powershell.exe',['-NoProfile','-NonInteractive','-Command',r'''
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
[Console]::InputEncoding=[System.Text.Encoding]::UTF8
$j=ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd())
$d=New-Object System.Drawing.Printing.PrintDocument
try {
  $d.PrinterSettings.PrinterName=[string]$j.name
  if(-not $d.PrinterSettings.IsValid){throw 'Driver unavailable'}
  if($j.duplex -ne 'Simplex' -and -not $d.PrinterSettings.CanDuplex){throw 'Duplex unavailable'}
  $stock=$null
  foreach($p in $d.PrinterSettings.PaperSizes){
    if(([Math]::Abs($p.Width-[double]$j.width) -le 3 -and [Math]::Abs($p.Height-[double]$j.height) -le 3) -or
       ([Math]::Abs($p.Height-[double]$j.width) -le 3 -and [Math]::Abs($p.Width-[double]$j.height) -le 3)){
      $stock=$p; break
    }
  }
  if($null -eq $stock){throw 'Paper unsupported'}
  $d.PrinterSettings.Duplex=[System.Drawing.Printing.Duplex]$j.duplex
  $d.PrinterSettings.Copies=1
  $d.DefaultPageSettings.PaperSize=$stock
  $d.DefaultPageSettings.Landscape=[bool]$j.landscape
  $d.DefaultPageSettings.Margins=New-Object System.Drawing.Printing.Margins(0,0,0,0)
  $d.OriginAtMargins=$false
  $d.DocumentName=[string]$j.title
  $d.PrintController=New-Object System.Drawing.Printing.StandardPrintController
  $script:saarthiPages=@($j.pages)
  $script:saarthiIndex=0
  $d.add_PrintPage({
    param($sender,$e)
    $stream=[System.IO.MemoryStream]::new([Convert]::FromBase64String([string]$script:saarthiPages[$script:saarthiIndex]))
    $image=$null
    try {
      $image=[System.Drawing.Image]::FromStream($stream)
      $e.Graphics.PageUnit=[System.Drawing.GraphicsUnit]::Display
      $e.Graphics.TranslateTransform(-[single]$e.PageSettings.HardMarginX,-[single]$e.PageSettings.HardMarginY)
      $e.Graphics.DrawImage($image,[System.Drawing.RectangleF]::new(0,0,[single]$e.PageBounds.Width,[single]$e.PageBounds.Height))
      $script:saarthiIndex++
      $e.HasMorePages=($script:saarthiIndex -lt $script:saarthiPages.Count)
    } finally {
      if($null -ne $image){$image.Dispose()}
      $stream.Dispose()
    }
  })
  $d.Print()
  if($script:saarthiIndex -ne $script:saarthiPages.Count){throw 'Print submission incomplete'}
  [Console]::WriteLine('SAARTHI_SUBMITTED')
} finally { $d.Dispose() }
'''],runInShell:false);
    final stdout=process.stdout.transform(utf8.decoder).join();
    final stderr=process.stderr.transform(utf8.decoder).join();
    try{
      if(!isCurrent())throw StateError('School changed.');
      final code=await (() async{
        process.stdin.add(utf8.encode(input));
        await process.stdin.close();
        return process.exitCode;
      })().timeout(const Duration(seconds:120));
      final output=await stdout;
      await stderr;
      return code==0 && output.trim()=='SAARTHI_SUBMITTED';
    }catch(_){
      process.kill();
      // A timed-out job may already be in the Windows spooler.
      rethrow;
    }
  }

}
