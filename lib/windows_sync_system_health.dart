import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'windows_appearance.dart';

enum SyncHealth { checking, healthy, failed, unknown }
typedef SyncHealthProbe = Future<SyncHealth> Function();
enum InternetHealth { connected, offline, unknown }

// Cancel deadlines and sockets when the owning page is disposed. A late native
// interface result must never start a new HTTP request for a closed page.
class SyncInternetProbe {
  bool _closed = false;
  final _cancel = <void Function()>{};
  final _clients = <HttpClient>{};

  Future<T?> _bounded<T>(Future<T> work, Duration limit) {
    if (_closed) return Future<T?>.value(null);
    final done = Completer<T?>();
    late final Timer timer;
    late final void Function() cancel;
    void finish(T? value) {
      if (done.isCompleted) return;
      timer.cancel();
      _cancel.remove(cancel);
      done.complete(value);
    }
    cancel = () => finish(null);
    timer = Timer(limit, cancel);
    _cancel.add(cancel);
    work.then<void>(finish, onError: (Object error, StackTrace stack) {
      if (done.isCompleted) return;
      timer.cancel();
      _cancel.remove(cancel);
      done.completeError(error, stack);
    });
    return done.future;
  }

  void dispose() {
    _closed = true;
    for (final cancel in _cancel.toList()) { cancel(); }
    for (final client in _clients.toList()) { client.close(force: true); }
    _clients.clear();
  }

  // Read-only reachability; no school credentials or data leave the device.
  Future<InternetHealth> check() async {
    if (_closed) return InternetHealth.unknown;
  try {
    final interfaces = await _bounded(NetworkInterface.list(
      includeLoopback: false, includeLinkLocal: false,
    ), const Duration(seconds: 2));
    if (_closed) return InternetHealth.unknown;
    if (interfaces != null && interfaces.isEmpty) return InternetHealth.offline;
  } catch (_) {}
  if (_closed) return InternetHealth.unknown;
  Future<InternetHealth> reach(Uri uri, int expectedCode) async {
    if (_closed) return InternetHealth.unknown;
    final client = HttpClient();
    _clients.add(client);
    try {
      return await _bounded((() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != expectedCode) return InternetHealth.unknown;
        if (expectedCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          if (!body.contains('h=www.cloudflare.com')) return InternetHealth.unknown;
        }
        return InternetHealth.connected;
      })(), const Duration(seconds: 4)) ?? InternetHealth.unknown;
    } on SocketException {
      return InternetHealth.offline;
    } on TimeoutException {
      return InternetHealth.unknown;
    } catch (_) {
      return InternetHealth.unknown;
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }
  final results = await Future.wait([
    reach(Uri.https('www.gstatic.com', '/generate_204'), 204),
    reach(Uri.https('www.cloudflare.com', '/cdn-cgi/trace'), 200),
  ]);
  if (results.contains(InternetHealth.connected)) return InternetHealth.connected;
  if (results.every((v) => v == InternetHealth.offline)) return InternetHealth.offline;
  return InternetHealth.unknown;
  }
}

class WindowsSyncSystemHealth extends StatefulWidget {
  const WindowsSyncSystemHealth({
    super.key,
    required this.schoolServer,
    required this.selfRepair,
    required this.mobileServer,
    required this.isCurrentSchool,
    this.internetProbe,
  });
  final SyncHealthProbe schoolServer, selfRepair, mobileServer;
  final bool Function() isCurrentSchool;
  final Future<InternetHealth> Function()? internetProbe;

  @override
  State<WindowsSyncSystemHealth> createState() => _WindowsSyncSystemHealthState();
}

class _WindowsSyncSystemHealthState extends State<WindowsSyncSystemHealth> {
  static const _names = [
    'Internet Connection',
    'School Server',
    'Self-Repair Engine',
    'Student Android App Server',
  ];
  final _states = List<SyncHealth>.filled(4, SyncHealth.unknown);
  final _internet = SyncInternetProbe();
  Timer? _poll;
  bool _networkBusy = false, _serversBusy = false;
  int _generation = 0;
  InternetHealth? _network;
  DateTime? _lastServerCheck;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_refresh()));
  }
  @override
  void dispose() {
    _generation++;
    _poll?.cancel();
    _internet.dispose();
    super.dispose();
  }
  bool get _current => mounted && widget.isCurrentSchool();

  Future<void> _refresh() async {
    if (!_current || _networkBusy) return;
    _networkBusy = true;
    try {
      InternetHealth internet;
      try { internet = await (widget.internetProbe ?? _internet.check)(); }
      catch (_) { internet = InternetHealth.unknown; }
      if (!_current) return;
      if (_network != internet) {
        _generation++;
        _lastServerCheck = null;
      }
      setState(() {
        _network = internet;
        _states[0] = switch (internet) {
          InternetHealth.connected => SyncHealth.healthy,
          InternetHealth.offline => SyncHealth.failed,
          InternetHealth.unknown => SyncHealth.unknown,
        };
        if (internet != InternetHealth.connected) {
          for (var i = 1; i < _states.length; i++) {
            _states[i] = SyncHealth.unknown;
          }
        }
      });
      if (internet != InternetHealth.connected) return;
      final generation = _generation;
      unawaited(_check(2, widget.selfRepair, generation));
      final now = DateTime.now();
      final last = _lastServerCheck;
      if (!_serversBusy && (last == null || now.difference(last) >= const Duration(minutes: 1))) {
        _serversBusy = true;
        _lastServerCheck = now;
        setState(() {
          _states[1] = SyncHealth.checking;
          _states[3] = SyncHealth.checking;
        });
        unawaited(Future.wait<void>([
          _check(1, widget.schoolServer, generation),
          _check(3, widget.mobileServer, generation),
        ]).whenComplete(() => _serversBusy = false).then<void>((_) {}));
      }
    } finally {
      _networkBusy = false;
    }
  }

  Future<void> _check(int index, SyncHealthProbe probe, int generation) async {
    SyncHealth result;
    try { result = await probe(); } catch (_) { result = SyncHealth.unknown; }
    if (!_current || generation != _generation || _network != InternetHealth.connected) return;
    if (_states[index] != result) setState(() => _states[index] = result);
  }
  @override
  Widget build(BuildContext context) {
    if (_network == InternetHealth.offline) {
      return const SizedBox(height: 120, child: Center(child: _OfflineRadar()));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < _names.length; i++)
        Padding(padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(_names[i], style: const TextStyle(fontWeight: FontWeight.bold))),
            const SizedBox(width: 8),
            _HealthIndicator(state: _states[i]),
          ])),
    ]);
  }
}

class _HealthIndicator extends StatelessWidget {
  const _HealthIndicator({required this.state});
  final SyncHealth state;
  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final (icon, accent, label) = switch (state) {
      SyncHealth.checking => (Icons.sync, Colors.lightBlueAccent, 'Checking'),
      SyncHealth.healthy => (Icons.check_circle_outline, Colors.greenAccent, 'Verified'),
      SyncHealth.failed => (Icons.cancel_outlined, Colors.redAccent, 'Failed'),
      SyncHealth.unknown => (Icons.error_outline, Colors.amberAccent, 'Not verified / paused'),
    };
    final color = WindowsAppearance.foreground(accent);
    final indicator = state == SyncHealth.checking && !reduceMotion
        ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: color))
        : !reduceMotion && (state == SyncHealth.healthy || state == SyncHealth.failed)
            ? TweenAnimationBuilder<double>(
                key: ValueKey('result-$state'),
                tween: Tween(begin: 0.0, end: 1.0),
                duration: Duration(milliseconds: state == SyncHealth.failed ? 1200 : 650),
                builder: (context, progress, child) {
                  final cycles = state == SyncHealth.failed ? 2 : 1;
                  final pulse = math.sin(progress * math.pi * cycles);
                  final glow = pulse * pulse;
                  return Transform.scale(scale: 1 + .12 * glow,
                    child: Icon(icon, size: 20, color: color, shadows: [
                      Shadow(color: color.withValues(alpha: .65 * glow), blurRadius: 6 * glow),
                    ]));
                })
            : Icon(icon, size: 20, color: color);
    return Tooltip(message: label,
      child: Semantics(label: label,
        child: SizedBox(width: 24, height: 24,
          child: AnimatedSwitcher(
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: Tween<double>(begin: .65, end: 1).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)), child: child)),
            child: KeyedSubtree(key: ValueKey(state), child: Center(child: indicator)),
          ))));
  }
}

// Option 03: decorative radar, not a simulated network test or progress.
class _OfflineRadar extends StatefulWidget {
  const _OfflineRadar();
  @override
  State<_OfflineRadar> createState() => _OfflineRadarState();
}
class _OfflineRadarState extends State<_OfflineRadar> with SingleTickerProviderStateMixin {
  late final _rotation = AnimationController(vsync: this, duration: const Duration(milliseconds: 2700));
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations || !TickerMode.of(context)) {
      _rotation.stop();
    } else if (!_rotation.isAnimating) {
      _rotation.repeat();
    }
  }
  @override
  void dispose() { _rotation.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final color = WindowsAppearance.foreground(Colors.redAccent);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: 68, height: 68, child: Stack(alignment: Alignment.center, children: [
        CustomPaint(size: const Size.square(68), painter: _RadarPainter(_rotation, color)),
        Icon(Icons.wifi_off, color: color, size: 30),
      ])),
      const SizedBox(height: 8),
      Text('System Offline', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    ]);
  }
}
class _RadarPainter extends CustomPainter {
  _RadarPainter(this.rotation, this.color) : super(repaint: rotation);
  final Animation<double> rotation;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero), radius = size.shortestSide / 2 - 3;
    final ring = Paint()..color = color.withValues(alpha: .25)..style = PaintingStyle.stroke..strokeWidth = 1;
    canvas.drawCircle(center, radius, ring);
    canvas.drawCircle(center, radius * .76, ring);
    final start = rotation.value * math.pi * 2 - math.pi / 2;
    final sweep = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.5..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, math.pi / 2, false, sweep);
    final end = start + math.pi / 2;
    canvas.drawCircle(center + Offset(math.cos(end), math.sin(end)) * radius, 2.5, Paint()..color = color);
  }
  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) => oldDelegate.color != color || oldDelegate.rotation != rotation;
}
