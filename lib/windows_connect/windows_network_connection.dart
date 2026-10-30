import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Best-effort *local* connection type of the Windows default-route adapter.
/// This is display telemetry only: it never authorizes device access and never
/// includes SSIDs, IP addresses, MAC addresses or adapter names in cloud data.
class WindowsNetworkConnection {
  static String? _cached;
  static DateTime? _checkedAt;
  static Future<String?>? _pending;

  /// Never confuse an active adapter with a verified internet connection.
  /// Ambiguous/VPN/virtual adapters remain unknown instead of guessing.
  static String? classifyRoute(String output) {
    final result = output.trim();
    if (result == 'WiFi' || result == 'LAN') return result;
    return null;
  }

  static Future<String?> detect() async {
    if (kIsWeb || !Platform.isWindows) return null;
    final now = DateTime.now();
    if (_checkedAt != null &&
        now.difference(_checkedAt!).inSeconds < 120) return _cached;
    return _pending ??= _read().whenComplete(() { _pending = null; });
  }

  static Future<String?> _read() async {
    String? type;
    try {
      // Choose an UP adapter used by a Windows default route, not any merely
      // connected adapter; prefer the lowest route + interface metric.
      const command = r"""
$routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object -Property RouteMetric,InterfaceMetric)
foreach ($route in $routes) {
    $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    if ($null -eq $adapter -or $adapter.Status -ne 'Up') { continue }
    $label = [string]$adapter.Name + ' ' + [string]$adapter.InterfaceDescription
    if ($label -match '(?i)Wi-?Fi|WLAN|Wireless|802[.]11') { 'WiFi'; exit }
    if ($label -match '(?i)Ethernet|802[.]3|Local Area Connection') { 'LAN'; exit }
}
""";
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', command],
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0) type = classifyRoute(result.stdout.toString());
    } catch (_) {
      // Network metadata is optional and cannot block login, sync or access.
    } finally {
      _cached = type;
      _checkedAt = DateTime.now();
    }
    return type;
  }

  /// Intentionally omit unknown metadata so an older PC's last verified type
  /// is not overwritten by a failing local probe.
  static Future<Map<String, dynamic>> reportedMetadata() async {
    final type = await detect();
    return type == null ? <String, dynamic>{} : {'connectionType': type};
  }
}
