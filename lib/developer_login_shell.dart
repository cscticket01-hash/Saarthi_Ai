import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'developer_account_widgets.dart';

/// Public website landing surface. Authentication remains owned by the
/// existing developer portal; this widget only changes the presentation.
class DeveloperLoginShell extends StatefulWidget {
  const DeveloperLoginShell({super.key, required this.form});

  final Widget form;

  @override
  State<DeveloperLoginShell> createState() => _DeveloperLoginShellState();
}

class _DeveloperLoginShellState extends State<DeveloperLoginShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _floating = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat(reverse: true);

  static const _ink = Color(0xFF162A55);
  static const _blue = Color(0xFF1268F3);

  @override
  void dispose() {
    _floating.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lightTheme = Theme.of(context).copyWith(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _blue,
        brightness: Brightness.light,
      ),
      textTheme: Theme.of(context).textTheme.apply(
        bodyColor: _ink,
        displayColor: _ink,
      ),
      scaffoldBackgroundColor: const Color(0xFFF1F6FF),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.86),
        hintStyle: const TextStyle(color: Color(0xFF7182A0)),
        contentPadding:
            const EdgeInsets.symmetric(vertical: 19, horizontal: 18),
        prefixIconColor: const Color(0xFF7488AD),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Color(0xFFDDE7FA)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: _blue, width: 1.7),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
      ),
    );

    return Theme(
      data: lightTheme,
      child: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFFF9FBFF),
                      Color(0xFFE6F0FF),
                      Color(0xFFF3F9FF),
                    ],
                  ),
                ),
              ),
            ),
            // Motion is purely decorative: never used to imply download progress.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _floating,
                  builder: (context, _) {
                    final phase = _floating.value * 2 * math.pi;
                    return Stack(
                      children: [
                        Positioned(
                          left: -52,
                          top: 100 + 18 * math.sin(phase),
                          child: _orb(205, const Color(0xFFE4EDFF)),
                        ),
                        Positioned(
                          right: -30,
                          top: 130 + 24 * math.cos(phase),
                          child: _orb(155, const Color(0xFFDAEAFF)),
                        ),
                        Positioned(
                          left: 86,
                          bottom: 110 + 14 * math.cos(phase),
                          child: _orb(58, const Color(0xFFD1EAFF)),
                        ),
                        Positioned(
                          right: 110,
                          bottom: 90 + 20 * math.sin(phase),
                          child: _orb(82, const Color(0xFFDDF8FF)),
                        ),
                        Positioned(
                          left: 150,
                          top: 310 + 12 * math.sin(phase),
                          child: _orb(24, const Color(0xFF93D7FF)),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, viewport) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: viewport.maxHeight),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1280),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 26,
                            vertical: 20,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _header(),
                              const SizedBox(height: 48),
                              LayoutBuilder(
                                builder: (context, size) {
                                  final wide = size.maxWidth >= 900;
                                  return wide
                                      ? Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            Expanded(
                                              flex: 9,
                                              child: _loginCard(),
                                            ),
                                            const SizedBox(width: 48),
                                            const Expanded(
                                              flex: 10,
                                              child: _DownloadSection(),
                                            ),
                                          ],
                                        )
                                      : Column(
                                          children: [
                                            ConstrainedBox(
                                              constraints:
                                                  const BoxConstraints(
                                                maxWidth: 510,
                                              ),
                                              child: _loginCard(),
                                            ),
                                            const SizedBox(height: 42),
                                            ConstrainedBox(
                                              constraints: BoxConstraints(
                                                maxWidth: 550,
                                              ),
                                              child: _DownloadSection(),
                                            ),
                                          ],
                                        );
                                },
                              ),
                              const SizedBox(height: 44),
                              _features(),
                              const SizedBox(height: 38),
                              const Divider(color: Color(0xFFD7E3F6)),
                              const SizedBox(height: 12),
                              const Wrap(
                                alignment: WrapAlignment.center,
                                crossAxisAlignment:
                                    WrapCrossAlignment.center,
                                spacing: 14,
                                runSpacing: 6,
                                children: [
                                  Text(
                                    'Saarthi AI School App',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: _ink,
                                    ),
                                  ),
                                  Text(
                                    'Secure access for authorized users',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF647593),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _orb(double size, Color color) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(-0.35, -0.45),
            colors: [Colors.white, color],
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1B4779C4),
              blurRadius: 32,
              offset: Offset(0, 16),
            ),
          ],
        ),
      );

  Widget _brand({bool prominent = false}) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: prominent ? 66 : 48,
            height: prominent ? 66 : 48,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF13C4EF), _blue],
              ),
              borderRadius: BorderRadius.circular(17),
              boxShadow: const [
                BoxShadow(color: Color(0x3351A7F8), blurRadius: 22),
              ],
            ),
            child: Icon(
              Icons.school_rounded,
              size: prominent ? 36 : 27,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Saarthi AI',
                style: TextStyle(
                  color: _ink,
                  fontWeight: FontWeight.w900,
                  fontSize: prominent ? 25 : 23,
                  height: 1.05,
                ),
              ),
              const Text(
                'School App',
                style: TextStyle(
                  color: Color(0xFF647593),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ],
      );

  Widget _header() => LayoutBuilder(
        builder: (context, size) => Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 20,
          runSpacing: 12,
          children: [
            _brand(),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.66),
                borderRadius: BorderRadius.circular(50),
                border: Border.all(color: const Color(0xFFDBE6F7)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 17, color: _blue),
                  SizedBox(width: 8),
                  Text(
                    'Secure Developer Login',
                    style: TextStyle(
                      color: _ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _loginCard() => Container(
        padding: const EdgeInsets.fromLTRB(32, 34, 32, 38),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.76),
          borderRadius: BorderRadius.circular(36),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x224D84C7),
              blurRadius: 48,
              offset: Offset(0, 22),
            ),
            BoxShadow(
              color: Color(0x446BDFF4),
              blurRadius: 14,
              spreadRadius: -10,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 92,
                height: 92,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x35518EE4),
                      blurRadius: 27,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.school_rounded,
                  color: _blue,
                  size: 48,
                ),
              ),
            ),
            const SizedBox(height: 22),
            widget.form,
          ],
        ),
      );

  Widget _features() => Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        runSpacing: 12,
        children: [
          _feature(Icons.school_outlined, 'Smart School Management'),
          _feature(Icons.insights_outlined, 'Real-time Insights'),
          _feature(Icons.verified_user_outlined, 'Secure & Reliable'),
        ],
      );

  Widget _feature(IconData icon, String text) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 19, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.76),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.white),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _blue, size: 23),
            const SizedBox(width: 11),
            Text(
              text,
              style: const TextStyle(
                color: _ink,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}

class _DownloadSection extends StatelessWidget {
  const _DownloadSection();

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(
                Icons.file_download_outlined,
                size: 37,
                color: Color(0xFF1268F3),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Get Saarthi AI Apps',
                  style: TextStyle(
                    color: Color(0xFF162A55),
                    fontSize: 29,
                    height: 1.15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.only(left: 49),
            child: Text(
              'Download the school apps for your preferred device.',
              style: TextStyle(
                color: Color(0xFF647593),
                fontSize: 15,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 26),
          const AppDownloadButtons(),
        ],
      );
}
