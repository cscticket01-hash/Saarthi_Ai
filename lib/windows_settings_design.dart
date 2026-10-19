import 'windows_appearance.dart';

import 'package:flutter/material.dart' hide Text, InputDecoration;

import 'windows_ui_localization.dart';

/// Settings-only decoration. No timers, services or network image dependencies.
class WindowsSettingsBody extends StatelessWidget {
  const WindowsSettingsBody({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            WindowsAppearance.resolve(Color(0xFF0B141A)),
            WindowsAppearance.resolve(Color(0xFF10191F)),
            WindowsAppearance.resolve(Color(0xFF0B141A)),
          ],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inset = constraints.maxWidth < 700
              ? 16.0
              : constraints.maxWidth * .067;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(inset, 20, inset, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class WindowsSettingsCard extends StatelessWidget {
  const WindowsSettingsCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.sync,
    required this.success,
    required this.content,
    required this.actions,
  });
  final String title, subtitle;
  final IconData icon;
  final bool sync, success;
  final Widget content, actions;

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: WindowsAppearance.resolve(const Color(0xFF34434C)),
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            WindowsAppearance.resolve(Color(0xFF1F2C34)),
            WindowsAppearance.resolve(Color(0xFF172229)),
            WindowsAppearance.resolve(Color(0xFF1A252D)),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: WindowsAppearance.resolve(Color(0x30000000)),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 480;
          final accent = sync
              ? const Color(0xFF57E6C4)
              : const Color(0xFF7DABFF);
          final heading = Text(
            title,
            style: TextStyle(
              color: WindowsAppearance.resolve(Colors.white),
              fontSize: compact ? 18 : 20,
              fontWeight: FontWeight.w700,
            ),
          );
          final description = Text(
            subtitle,
            style: TextStyle(
              color: WindowsAppearance.resolve(Color(0xFFB7C3DA)),
              fontSize: 15,
              height: 1.4,
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: compact ? 40 : 48,
                    height: compact ? 40 : 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(compact ? 14 : 18),
                      border: Border.all(color: accent.withValues(alpha: .55)),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: sync
                            ? [const Color(0xFF087B83), const Color(0xFF084452)]
                            : [
                                const Color(0xFF294FAD),
                                const Color(0xFF102653),
                              ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: .08),
                          blurRadius: 24,
                        ),
                      ],
                    ),
                    child: Icon(icon, color: accent, size: compact ? 22 : 26),
                  ),
                  SizedBox(width: compact ? 12 : 20),
                  Expanded(
                    child: compact
                        ? heading
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              heading,
                              const SizedBox(height: 8),
                              description,
                              const SizedBox(height: 12),
                              content,
                            ],
                          ),
                  ),
                ],
              ),
              if (compact) ...[
                const SizedBox(height: 12),
                description,
                const SizedBox(height: 12),
                content,
              ],
              const SizedBox(height: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class WindowsSettingsButton extends StatelessWidget {
  const WindowsSettingsButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.purple = false,
  });
  final VoidCallback? onPressed;
  final Widget icon;
  final String label;
  final bool purple;

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: LinearGradient(
          colors: onPressed == null
              ? [
                  WindowsAppearance.resolve(const Color(0xFF273750)),
                  WindowsAppearance.resolve(const Color(0xFF29314B)),
                ]
              : purple
              ? [
                  WindowsAppearance.resolve(const Color(0xFF1A2853)),
                  WindowsAppearance.resolve(const Color(0xFF27224E)),
                  const Color(0xFF223565),
                ]
              : [
                  const Color(0xFF17366B),
                  const Color(0xFF292F7C),
                  const Color(0xFF193C91),
                ],
        ),
      ),
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: WindowsAppearance.resolve(Colors.white),
          disabledForegroundColor: WindowsAppearance.resolve(
            const Color(0xFFADBBD4),
          ),
          minimumSize: const Size(double.infinity, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          side: BorderSide(
            color: purple ? const Color(0xFF6B5FC1) : const Color(0xFF5B91EF),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
