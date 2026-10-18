import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'windows_ui_localization.dart';

/// Settings-only decoration. No timers, services or network image dependencies.
class WindowsSettingsBody extends StatelessWidget {
  const WindowsSettingsBody({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity, height: double.infinity,
    decoration: const BoxDecoration(gradient: LinearGradient(
      begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: [Color(0xFF0B1429), Color(0xFF0B1934), Color(0xFF091226)],
    )),
    child: LayoutBuilder(builder: (context, constraints) {
      final inset = constraints.maxWidth < 700 ? 16.0 : constraints.maxWidth * .067;
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(inset, 20, inset, 28),
        child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        )),
      );
    }),
  );
}

class WindowsSettingsCard extends StatelessWidget {
  const WindowsSettingsCard({super.key, required this.title,
    required this.subtitle, required this.icon, required this.sync,
    required this.success, required this.content, required this.actions});
  final String title, subtitle;
  final IconData icon;
  final bool sync, success;
  final Widget content, actions;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFF294777)),
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [Color(0xFF152644), Color(0xFF102039), Color(0xFF122342)]),
      boxShadow: const [BoxShadow(color: Color(0x30000000), blurRadius: 20, offset: Offset(0, 8))],
    ),
    child: LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth / MediaQuery.textScalerOf(context).scale(1) >= 760;
      final compact = constraints.maxWidth < 480;
      final accent = sync ? const Color(0xFF57E6C4) : const Color(0xFF7DABFF);
      final heading = Text(title, style: TextStyle(color: Colors.white, fontSize: compact ? 21 : 24, fontWeight: FontWeight.w700));
      final description = Text(subtitle, style: const TextStyle(color: Color(0xFFB7C3DA), fontSize: 15, height: 1.4));
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: compact ? 48 : 64, height: compact ? 48 : 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(compact ? 14 : 18),
              border: Border.all(color: accent.withValues(alpha: .55)),
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: sync ? [const Color(0xFF087B83), const Color(0xFF084452)]
                  : [const Color(0xFF294FAD), const Color(0xFF102653)]),
              boxShadow: [BoxShadow(color: accent.withValues(alpha: .08), blurRadius: 24)],
            ), child: Icon(icon, color: accent, size: compact ? 26 : 36)),
          SizedBox(width: compact ? 12 : 20),
          Expanded(child: compact ? heading : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            heading,
            const SizedBox(height: 8),
            description,
            const SizedBox(height: 12),
            content,
          ])),
          if (wide) ...[
            const SizedBox(width: 24),
            ExcludeSemantics(child: SizedBox(width: 150, height: sync ? 126 : 104,
              child: CustomPaint(painter: _SettingsIllustration(sync: sync, success: success)))),
          ],
        ]),
        if (compact) ...[
          const SizedBox(height: 12), description,
          const SizedBox(height: 12), content,
        ],
        const SizedBox(height: 12),
        actions,
      ]);
    }),
  );
}

class WindowsSettingsButton extends StatelessWidget {
  const WindowsSettingsButton({super.key, required this.onPressed, required this.icon,
    required this.label, this.purple = false});
  final VoidCallback? onPressed;
  final Widget icon;
  final String label;
  final bool purple;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(30),
      gradient: LinearGradient(colors: onPressed == null
        ? [const Color(0xFF273750), const Color(0xFF29314B)]
        : purple ? [const Color(0xFF1A2853), const Color(0xFF27224E), const Color(0xFF223565)]
          : [const Color(0xFF17366B), const Color(0xFF292F7C), const Color(0xFF193C91)]),
    ),
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white, disabledForegroundColor: const Color(0xFFADBBD4),
        minimumSize: const Size(double.infinity, 46),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        side: BorderSide(color: purple ? const Color(0xFF6B5FC1) : const Color(0xFF5B91EF)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        icon, const SizedBox(width: 12),
        Flexible(child: Text(label, textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
      ]),
    ),
  );
}

class _SettingsIllustration extends CustomPainter {
  const _SettingsIllustration({required this.sync, required this.success});
  final bool sync, success;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 230, size.height / 164);
    final glow = Paint()..color = const Color(0xFF244B80).withValues(alpha: .19);
    for (final radius in [79.0, 65.0, 51.0]) { canvas.drawCircle(const Offset(120, 82), radius, glow); }
    final fill = Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Color(0xFF66ADFF), Color(0xFF2356A8)]).createShader(const Rect.fromLTWH(25, 35, 180, 100));
    if (sync) {
      final cloud = Path()..moveTo(58, 106)..cubicTo(21, 106, 22, 64, 51, 61)
        ..cubicTo(54, 20, 111, 18, 128, 49)..cubicTo(163, 27, 189, 55, 184, 76)
        ..cubicTo(210, 82, 204, 111, 179, 112)..lineTo(58, 112)..close();
      canvas.drawPath(cloud, fill);
      final arrows = Paint()..color = const Color(0xFFB8D9FF)..strokeWidth = 6..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
      canvas.drawPath(Path()..moveTo(92, 108)..lineTo(92, 69)..moveTo(80, 81)..lineTo(92, 69)..lineTo(104, 81)
        ..moveTo(132, 73)..lineTo(132, 113)..moveTo(120, 101)..lineTo(132, 113)..lineTo(144, 101), arrows);
    } else {
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(42, 30, 147, 95), const Radius.circular(9)), fill);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(49, 37, 133, 80), const Radius.circular(4)), Paint()..color = const Color(0xFF102C64));
      final logo = Paint()..color = const Color(0xFF7DB8FF);
      for (final x in [95.0, 114.0]) { for (final y in [59.0, 78.0]) {
        canvas.drawRect(Rect.fromLTWH(x, y, 16, 16), logo);
      }}
      canvas.drawPath(Path()..moveTo(42, 125)..lineTo(16, 140)..quadraticBezierTo(9, 147, 29, 148)
        ..lineTo(205, 148)..quadraticBezierTo(220, 146, 210, 140)..lineTo(189, 125)..close(), fill);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(89, 128, 51, 5), const Radius.circular(2)), Paint()..color = const Color(0xFF9DC6FF));
    }
    if (success) {
      canvas.drawCircle(const Offset(180, 119), 24, Paint()..color = const Color(0xFF173A48));
      canvas.drawCircle(const Offset(180, 119), 20, Paint()..color = const Color(0xFF30D8A3));
      canvas.drawPath(Path()..moveTo(170, 119)..lineTo(177, 126)..lineTo(190, 112),
        Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
    }
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant _SettingsIllustration oldDelegate) => sync != oldDelegate.sync || success != oldDelegate.success;
}
