import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

const schoolAttendanceRadiusMeters = 200.0;

class SchoolMapPin {
  const SchoolMapPin(this.latitude, this.longitude, {this.name = ''});
  final double latitude;
  final double longitude;
  final String name;
  bool get valid => latitude.isFinite && longitude.isFinite &&
      latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180;
  String get coordinates => '${latitude.toStringAsFixed(7)}, ${longitude.toStringAsFixed(7)}';
  Uri get mapsUri => schoolMapsSearchUri(coordinates);
}

Uri schoolMapsSearchUri(String query) => Uri.https('www.google.com', '/maps/search/',
    {'api': '1', 'query': query.trim().isEmpty ? 'school' : query.trim()});

bool _googleMapsHost(String host) => const {
  'google.com', 'www.google.com', 'maps.google.com',
  'google.co.in', 'www.google.co.in', 'maps.google.co.in',
  'maps.app.goo.gl', 'goo.gl',
}.contains(host.toLowerCase());

SchoolMapPin? _pair(String text) {
  final match = RegExp(r'^\s*\(?\s*([+-]?(?:\d+(?:\.\d+)?|\.\d+))\s*[,\s]\s*([+-]?(?:\d+(?:\.\d+)?|\.\d+))\s*\)?\s*$').firstMatch(text);
  if (match == null) return null;
  final pin = SchoolMapPin(double.parse(match[1]!), double.parse(match[2]!));
  return pin.valid ? pin : null;
}

/// Accept the selected point, never arbitrary numbers or a map camera centre.
SchoolMapPin? parseSchoolMapPin(String raw) {
  final text = raw.trim();
  final direct = _pair(text);
  if (direct != null) return direct;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443) || !_googleMapsHost(uri.host) ||
      !uri.path.startsWith('/maps')) return null;
  for (final key in ['query', 'q', 'destination', 'daddr']) {
    final pair = _pair(uri.queryParameters[key] ?? '');
    if (pair != null) return pair;
  }
  String decoded;
  try { decoded = Uri.decodeComponent(uri.path); } on FormatException { return null; }
  final matches = RegExp(r'!3d([+-]?[\d.]+)!4d([+-]?[\d.]+)').allMatches(decoded).toList();
  if (matches.length != 1) return null;
  final pin = _pair('${matches.single[1]},${matches.single[2]}');
  if (pin == null) return null;
  final place = RegExp(r'/place/([^/]+)').firstMatch(decoded);
  return SchoolMapPin(pin.latitude, pin.longitude,
      name: place?[1]?.replaceAll('+', ' ') ?? '');
}

class WindowsSchoolMaps {
  static Future<void> open(Uri uri, {Future<bool> Function(Uri)? opener}) async {
    if (uri.scheme != 'https' || !_googleMapsHost(uri.host)) {
      throw ArgumentError('Only a Google Maps HTTPS link can be opened.');
    }
    final opened = await (opener ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
    if (!opened) throw StateError('Google Maps browser mein nahi khula. Default browser check karein.');
  }

  static Future<SchoolMapPin?> resolve(String text, {http.Client? client}) async {
    final direct = parseSchoolMapPin(text);
    if (direct != null) return direct;
    var uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'https' ||
        !(uri.host == 'maps.app.goo.gl' || (uri.host == 'goo.gl' && uri.path.startsWith('/maps/')))) {
      return null;
    }
    final transport = client ?? http.Client();
    try {
      for (var i = 0; i < 5; i++) {
        final current = uri!;
        final request = http.Request('GET', current)..followRedirects = false;
        final response = await transport.send(request).timeout(const Duration(seconds: 10));
        // Drain the response so the connection is not left open.
        await response.stream.drain<void>().timeout(const Duration(seconds: 10));
        final location = response.headers['location'];
        if (response.statusCode < 300 || response.statusCode >= 400 || location == null) return null;
        final next = current.resolve(location);
        if (next.scheme != 'https' || !_googleMapsHost(next.host) ||
            next.userInfo.isNotEmpty || (next.hasPort && next.port != 443)) return null;
        final pin = parseSchoolMapPin(next.toString());
        if (pin != null) return pin;
        uri = next;
      }
      return null;
    } finally {
      if (client == null) transport.close();
    }
  }
}

double schoolDistanceMeters(SchoolMapPin a, SchoolMapPin b) {
  if (!a.valid || !b.valid) return double.infinity;
  double rad(double v) => v * pi / 180;
  final h = pow(sin(rad(b.latitude - a.latitude) / 2), 2) +
      cos(rad(a.latitude)) * cos(rad(b.latitude)) * pow(sin(rad(b.longitude - a.longitude) / 2), 2);
  final clamped = h.toDouble().clamp(0.0, 1.0);
  return 6371000 * 2 * atan2(sqrt(clamped), sqrt(1 - clamped));
}

bool schoolAttendancePositionAllowed(SchoolMapPin school, SchoolMapPin device,
    {required double accuracyMeters}) {
  return accuracyMeters.isFinite && accuracyMeters >= 0 && accuracyMeters <= 100 &&
      schoolDistanceMeters(school, device) + accuracyMeters <= schoolAttendanceRadiusMeters;
}
