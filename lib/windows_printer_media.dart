import 'dart:convert';
import 'dart:io';
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
}
