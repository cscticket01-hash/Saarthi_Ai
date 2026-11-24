import 'dart:io';

/// Optional physical RAM probe. Failure leaves measured frame policy in charge.
/// This runs outside the startup await chain, once per glass backdrop lifetime.
Future<int?>? _probe;
Future<int?> readGlassDeviceMemory() => _probe ??= _read();
Future<int?> _read() async {
  try {
    if (Platform.isAndroid || Platform.isLinux) {
      final text = await File('/proc/meminfo').readAsString();
      final kb = int.tryParse(RegExp(r'^MemTotal:\s+(\d+)\s+kB', multiLine: true).firstMatch(text)?.group(1) ?? '');
      return kb == null ? null : kb * 1024;
    }
    if (Platform.isWindows) {
      // Use the OS installation path, not PATH or school-controlled text.
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final executable = '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      final process = await Process.start(executable, ['-NoProfile', '-NonInteractive', '-Command', '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory']);
      final output = process.stdout.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      final errors = process.stderr.drain<void>();
      try {
        final code = await process.exitCode.timeout(const Duration(seconds: 3));
        final bytes = await output;
        await errors;
        return code == 0 ? int.tryParse(String.fromCharCodes(bytes).trim()) : null;
      } finally {
        process.kill();
      }
    }
  } catch (_) { /* No reliable memory reading: use frame timings only. */ }
  return null;
}
