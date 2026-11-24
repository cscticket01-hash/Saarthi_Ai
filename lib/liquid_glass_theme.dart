import 'dart:ui' show ImageFilter, FrameTiming;
import 'package:flutter/scheduler.dart';
import 'glass_device_memory.dart';

import 'package:flutter/material.dart';

enum GlassPerformanceMode { low, balanced, high }

/// Frame-based hysteresis. No timers, network requests or school-data access.
/// Memory is an optional upper bound, not a fabricated performance reading.
class GlassPerformancePolicy {
  GlassPerformanceMode mode = GlassPerformanceMode.balanced;
  GlassPerformanceMode ceiling = GlassPerformanceMode.high;
  int _samples = 0, _slow = 0, _verySlow = 0, _goodWindows = 0;

  void setMemoryBytes(int? total) {
    if (total == null || total <= 0) return;
    ceiling = total <= 4 * 1024 * 1024 * 1024
        ? GlassPerformanceMode.low
        : total < 8 * 1024 * 1024 * 1024
          ? GlassPerformanceMode.balanced : GlassPerformanceMode.high;
    if (mode.index > ceiling.index) mode = ceiling;
  }

  bool observe(Iterable<Duration> frames) {
    final old = mode;
    for (final frame in frames) {
      _samples++;
      if (frame.inMicroseconds > 20000) _slow++;
      if (frame.inMicroseconds > 33000) _verySlow++;
      if (_samples < 60) continue;
      if (_verySlow >= 12 || _slow >= 24) {
        mode = GlassPerformanceMode.low;
        _goodWindows = 0;
      } else if (_slow >= 12) {
        if (mode == GlassPerformanceMode.high) mode = GlassPerformanceMode.balanced;
        _goodWindows = 0;
      } else if (_slow <= 3 && _verySlow == 0) {
        _goodWindows++;
        if (_goodWindows >= 4 && mode.index < ceiling.index) {
          mode = GlassPerformanceMode.values[mode.index + 1];
          _goodWindows = 0;
        }
      } else {
        _goodWindows = 0;
      }
      _samples = _slow = _verySlow = 0;
    }
    return old != mode;
  }
}

class _GlassPerformanceScope extends InheritedWidget {
  const _GlassPerformanceScope({required this.mode, required super.child});
  final GlassPerformanceMode mode;
  static GlassPerformanceMode of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GlassPerformanceScope>()?.mode ??
      GlassPerformanceMode.low;
  @override
  bool updateShouldNotify(_GlassPerformanceScope oldWidget) => oldWidget.mode != mode;
}

/// Presentation only. This never reads or changes school records or sync state.
/// The background is drawn locally so the native apps work offline without
/// downloading a remote video or relying on browser-only CSS/WebGL.
class LiquidGlassBackdrop extends StatefulWidget {
  const LiquidGlassBackdrop({super.key, required this.child, this.aurora = false});
  final Widget child;
  final bool aurora;

  @override
  State<LiquidGlassBackdrop> createState() => _LiquidGlassBackdropState();
}

class _LiquidGlassBackdropState extends State<LiquidGlassBackdrop>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _policy = GlassPerformancePolicy();
  bool _foreground = true;
  bool _reducedMotion = false;
  GlassPerformanceMode get _effective => _reducedMotion ? GlassPerformanceMode.low : _policy.mode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_frames);
    _readMemory();
  }

  Future<void> _readMemory() async {
    final bytes = await readGlassDeviceMemory();
    if (!mounted) return;
    final before = _effective;
    _policy.setMemoryBytes(bytes);
    if (before != _effective) setState(_updateMotion);
  }

  void _frames(List<FrameTiming> timings) {
    if (!mounted || !_foreground || _reducedMotion) return;
    if (_policy.observe(timings.map((t) => t.buildDuration > t.rasterDuration ? t.buildDuration : t.rasterDuration))) {
      setState(_updateMotion);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateMotion();
  }

  void _updateMotion() {
    if (!_foreground || _effective != GlassPerformanceMode.high) {
      _motion.stop();
    } else if (!_motion.isAnimating) {
      _motion.repeat(reverse: true);
    }
  }

  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 22),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect Android/Windows reduced-motion accessibility preferences.
    _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _updateMotion();
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_frames);
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _motion,
        child: _GlassPerformanceScope(mode: _effective, child: RepaintBoundary(child: widget.child)),
        builder: (context, child) {
          final shift = _motion.value;
          return Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: widget.aurora ? const [Color(0xFFE4F9FF), Color(0xFFB9CFFF), Color(0xFFD8CAFF)] : const [
                      Color(0xFF06121F),
                      Color(0xFF152C40),
                      Color(0xFF081926),
                    ],
                  ),
                ),
              ),
              IgnorePointer(
                child: Stack(
                  children: [
                    Positioned(
                      top: -145 + shift * 42,
                      left: -105 + shift * 58,
                      child: const _GlassGlow(
                        diameter: 430,
                        color: Color(0xFF3586C9),
                      ),
                    ),
                    Positioned(
                      right: -180 + shift * 68,
                      bottom: -210 + shift * 55,
                      child: const _GlassGlow(
                        diameter: 530,
                        color: Color(0xFF8672C7),
                      ),
                    ),
                    Positioned(
                      right: 20 + shift * 30,
                      top: 75 - shift * 35,
                      child: const _GlassGlow(
                        diameter: 310,
                        color: Color(0xFF3DAFA6),
                      ),
                    ),
                  ],
                ),
              ),
              child ?? const SizedBox.shrink(),
            ],
          );
        },
      );
}

class _GlassGlow extends StatelessWidget {
  const _GlassGlow({required this.diameter, required this.color});
  final double diameter;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: diameter,
        width: diameter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: .36),
                color.withValues(alpha: .08),
                color.withValues(alpha: 0),
              ],
              stops: const [0, .48, 1],
            ),
          ),
        ),
      );
}

/// Frosted native surface for key panels. Blur stays behind the content;
/// controls, semantics and hit testing remain intact.
class LiquidGlassPanel extends StatelessWidget {
  const LiquidGlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin = EdgeInsets.zero,
    this.radius = 22,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final corners = BorderRadius.circular(radius);
    return Padding(
      padding: margin,
      child: ClipRRect(
        borderRadius: corners,
        child: BackdropFilter(
          enabled: _GlassPerformanceScope.of(context) == GlassPerformanceMode.high,
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: corners,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0x6CFFFFFF), Color(0x332D648C)],
              ),
              border: Border.all(color: const Color(0x66E4F2FF)),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// A layout-neutral blur layer for existing Windows panels.
///
/// Unlike [LiquidGlassPanel], this widget adds no padding, tint or border: the
/// original panel retains its sizing, colors, hit targets and semantics.
/// It is opt-in so every other published Windows preset stays unchanged.
class LiquidGlassSurface extends StatelessWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.enabled = true,
    this.radius = 18,
    this.blurSigma = 10,
  });

  final Widget child;
  final bool enabled;
  final double radius;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        enabled: _GlassPerformanceScope.of(context) == GlassPerformanceMode.high,
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: child,
      ),
    );
  }
}

/// Android's default native glass appearance; Windows keeps its separately
/// managed developer-published preset, revision and App Lock activation flow.
ThemeData mobileLiquidGlassTheme() {
  const surface = Color(0xFF21384A);
  const rim = Color(0x6657A3C3);
  const scheme = ColorScheme.dark(
    primary: Color(0xFF8DDBEB),
    onPrimary: Color(0xFF052632),
    secondary: Color(0xFFB1C7FF),
    surface: surface,
    onSurface: Color(0xFFF4F8FF),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: const Color(0xDA15293B),
    cardTheme: CardThemeData(
      color: const Color(0x90284053),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: rim),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xAC19354A),
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xD01B3144),
      indicatorColor: const Color(0x8061C7DC),
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xF01D3548),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: rim),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0x662B4358),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: rim),
      ),
    ),
  );
}
