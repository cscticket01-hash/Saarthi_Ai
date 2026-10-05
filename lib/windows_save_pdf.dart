import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Native Save As. Cancellation never reports a successful download.
class WindowsSavePdf {
  static Future<String?> save(Uint8List bytes, String filename, {
    Future<String?> Function(String)? choosePath,
    bool csv = false,
  }) async {
    final path = await (choosePath ?? ((name) => _choosePath(name, csv: csv)))(filename);
    if (path == null) return null;
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  static Future<String?> _choosePath(String filename, {bool csv = false}) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows Save As required');
    final safeName = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    // Pass the filename as base64, never as executable PowerShell text.
    final encodedName = base64Encode(utf8.encode(safeName));
    final script = '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.SaveFileDialog
\$dialog.Filter = '${csv ? 'CSV spreadsheet (*.csv)|*.csv' : 'PDF document (*.pdf)|*.pdf'}'
\$dialog.DefaultExt = '${csv ? 'csv' : 'pdf'}'
\$dialog.AddExtension = \$true
\$dialog.OverwritePrompt = \$true
\$dialog.FileName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedName'))
try {
  if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    [Console]::Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(\$dialog.FileName)))
  }
} finally { \$dialog.Dispose() }
''';
    final utf16 = <int>[];
    for (final unit in script.codeUnits) {
      utf16.addAll([unit & 255, unit >> 8]);
    }
    final result = await Process.run('powershell.exe',
        ['-NoProfile', '-STA', '-EncodedCommand', base64Encode(utf16)]);
    if (result.exitCode != 0) throw StateError('Windows Save As could not open');
    final output = result.stdout.toString().trim();
    if (output.isEmpty) return null;
    final path = utf8.decode(base64Decode(output));
    return path;
  }
}
