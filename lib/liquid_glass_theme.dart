import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Presentation only. This never reads or changes school records or sync state.
/// The background is drawn locally so the native apps work offline without
/// downloading a remote video or relying on browser-only CSS/WebGL.
class LiquidGlassBackdrop extends StatefulWidget {
  const LiquidGlassBackdrop({super.key, required this.child});
  final Widget child;

  @override
  State<LiquidGlassBackdrop> createState() => _LiquidGlassBackdropState();
}

class _LiquidGlassBackdropState extends State<LiquidGlassBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 22),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect Android/Windows reduced-motion accessibility preferences.
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _motion.stop();
    } else if (!_motion.isAnimating) {
      _motion.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _motion,
        child: widget.child,
        builder: (context, child) {
          final shift = _motion.value;
          return Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
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
