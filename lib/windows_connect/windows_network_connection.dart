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
        now.difference(_checkedAt!).inSeconds < (_cached == null ? 15 : 120)) return _cached;
    return _pending ??= _read().whenComplete(() { _pending = null; });
  }

  @visibleForTesting
  static String get windowsRouteProbe => _routeProbe;

  // Keep command visible to tests without launching PowerShell in Flutter tests.
  static const String _routeProbe = r"""
# Best-effort classification of the interface actually carrying a default
# IPv4/IPv6 route. Output is ONLY WiFi or LAN: no device identifiers leave PC.
$ErrorActionPreference = 'SilentlyContinue'
$routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
if ($routes.Count -eq 0) {
    $routes = @(Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue)
}
foreach ($route in @($routes | Sort-Object -Property RouteMetric)) {
    $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    if ($null -eq $adapter -or $adapter.Status -ne 'Up') { continue }
    $label = ([string]$adapter.Name + ' ' + [string]$adapter.InterfaceDescription)
    # A VPN or virtual network may expose an Ethernet-shaped interface.
    if ($label -match '(?i)VPN|WireGuard|OpenVPN|TAP[- ]|TUN[- ]|Hyper-V|VMware|VirtualBox|Loopback|Tailscale|ZeroTier|vEthernet|Bluetooth|Pseudo') { continue }
    $medium = [string]$adapter.NdisPhysicalMedium + ' ' + [string]$adapter.PhysicalMediaType
    if ($medium -match '(?i)802[._ -]?11|Wireless.LAN|Native.802' -or
        $label -match '(?i)Wi-?Fi|WLAN|Wireless|802[.]11') { 'WiFi'; exit 0 }
    if ($medium -match '(?i)802[._ -]?3|Ethernet' -or
        $label -match '(?i)Ethernet|GbE|Gigabit|10/100|802[.]3|Local Area Connection') { 'LAN'; exit 0 }
    # Some physical Ethernet drivers (e.g. old Realtek) have no usable label.
    $nic = Get-CimInstance Win32_NetworkAdapter -Filter "InterfaceIndex=$($route.InterfaceIndex)" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $nic -and $nic.PhysicalAdapter -eq $true -and
        $nic.AdapterTypeID -eq 0) { 'LAN'; exit 0 }
}
""";

  static Future<String?> _read() async {
    String? type;
    try {
      // Choose an UP adapter used by a Windows default route, not any merely
      // connected adapter; prefer the lowest route + interface metric.
      const command = _routeProbe;
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', command],
      ).timeout(const Duration(seconds: 7));
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
