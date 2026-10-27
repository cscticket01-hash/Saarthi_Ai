import 'windows_appearance.dart';
import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'windows_ui_localization.dart';

/// Presentation only. Account, navigation and persistence stay with the owner.
class WindowsAdminSettingsLayout extends StatelessWidget {
  const WindowsAdminSettingsLayout({super.key, required this.email,
    required this.name, required this.avatar, required this.authenticated,
    required this.year, required this.month, required this.loadingYear,
    required this.onMonthChanged, required this.onDevices,
    required this.onSchool, required this.onPasswords, required this.onAdvanced});
  final String email, name, year;
  final Widget avatar;
  final bool authenticated, loadingYear;
  final int month;
  final ValueChanged<int> onMonthChanged;
  final VoidCallback onDevices, onSchool, onPasswords, onAdvanced;
  static const blue = Color(0xFF73ADFF), teal = Color(0xFF00DBC0);
  static const amber = Color(0xFFFFB536), muted = Color(0xFFAABDD7);

  @override
  Widget build(BuildContext context) { WindowsAppearance.watch(context); return  Scaffold(
    backgroundColor: WindowsAppearance.background(const Color(0xFF09172B)),
    body: Container(
      decoration:  BoxDecoration(gradient: LinearGradient(
        begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [WindowsAppearance.resolve(Color(0xFF0B1B32)), WindowsAppearance.resolve(Color(0xFF071323))])),
      child: LayoutBuilder(builder: (context, viewport) { WindowsAppearance.watch(context); return  SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(viewport.maxWidth < 600 ? 16 : 32, 24,
          viewport.maxWidth < 600 ? 16 : 32, 28),
        child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
               BackButton(color: WindowsAppearance.foreground(Color(0xFFC2D8FA))),
              const SizedBox(width: 12),
               Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Settings', style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.white), fontSize: 26, fontWeight: FontWeight.w700)),
                SizedBox(height: 4),
                Text('Manage your school preferences', style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.resolve(muted), fontSize: 14)),
              ])),
            ]),
            const SizedBox(height: 28),
            _deviceTile(),
            const SizedBox(height: 18),
            _panel(icon: Icons.person_rounded, color: blue, title: 'Admin Profile',
              subtitle: 'Signed-in administrator account', child: _profile(context)),
            const SizedBox(height: 18),
            _panel(icon: Icons.calendar_month_rounded, color: blue, title: 'Academic Year',
              subtitle: 'Choose January or April as the session change month',
              child: _academic(context)),
            const SizedBox(height: 18),
            LayoutBuilder(builder: (context, size) {WindowsAppearance.watch(context);
              final passwords = _panel(icon: Icons.lock_outline_rounded, color: amber,
                title: 'Password Management', subtitle: 'Manage section locks and passwords',
                child: _action('Open Password Management', Icons.lock_outline_rounded, onPasswords));
              final advanced = _panel(icon: Icons.shield_outlined, color: amber,
                title: 'Advanced Settings', subtitle: 'Protected integrations and system controls',
                child: _action('Open Advanced Settings', Icons.shield_outlined, onAdvanced));
              if (size.maxWidth / MediaQuery.textScalerOf(context).scale(1) < 760) {
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [passwords, const SizedBox(height: 18), advanced]);
              }
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: passwords), const SizedBox(width: 18), Expanded(child: advanced),
              ]);
            }),
          ]),
        )),
      ); }),
    ),
  ); }

  Widget _deviceTile() => Material(color: WindowsAppearance.foreground(Colors.transparent), child: Ink(
    decoration: _decoration(),
    child: InkWell(borderRadius: BorderRadius.circular(16), onTap: onDevices,
      child: Padding(padding: const EdgeInsets.all(22), child: Row(children: [
        _icon(Icons.desktop_windows_outlined, blue), const SizedBox(width: 20),
         Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Device Management', style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.white), fontSize: 18, fontWeight: FontWeight.w700)),
          SizedBox(height: 5), Text('Manage your devices and access', style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.resolve(muted), fontSize: 14)),
        ])),
        const SizedBox(width: 8), const Icon(Icons.chevron_right_rounded, color: blue),
      ])),
    ),
  ));

  Widget _profile(BuildContext context) => LayoutBuilder(builder: (context, size) {WindowsAppearance.watch(context);
    final displayName = name.trim();
    final showName = displayName.isNotEmpty && displayName != 'School Administrator' &&
        displayName.toLowerCase() != email.trim().toLowerCase();
    final info = Row(children: [
      Container(width: 68, height: 68, clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(
          colors: WindowsAppearance.gradientColors([Color(0xFF00A990), Color(0xFF008C7A)]))), child: Center(child: avatar)),
      const SizedBox(width: 18),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (showName) ...[
          Text(displayName, style:  TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.white), fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
        ],
        Text(email, style:  TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.white), fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 9),
        if (authenticated) Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: teal.withValues(alpha: .08),
            border: Border.all(color: teal.withValues(alpha: .35)), borderRadius: BorderRadius.circular(12)),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.verified_user_rounded, color: teal, size: 15), SizedBox(width: 6),
            Flexible(child: Text('Authenticated', style: TextStyle(fontFamily: 'Segoe UI', color: teal, fontSize: 12, fontWeight: FontWeight.w600))),
          ])),
      ])),
    ]);
    final button = OutlinedButton.icon(onPressed: onSchool,
      icon: const Icon(Icons.school_rounded, size: 20), label: const Text('School Settings'),
      style: OutlinedButton.styleFrom(foregroundColor: teal,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 17),
        side: const BorderSide(color: teal), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
    if (size.maxWidth / MediaQuery.textScalerOf(context).scale(1) < 620) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [info, const SizedBox(height: 18), button]);
    }
    return Row(children: [Expanded(child: info), const SizedBox(width: 24), button]);
  });

  Widget _academic(BuildContext context) {
    final label = Row(children: [
      const Icon(Icons.event_repeat_rounded, color: blue, size: 26), const SizedBox(width: 14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
         Text('Session Change Month', style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.white), fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 5), Text('Current: $year', style:  TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.resolve(muted), fontSize: 13)),
      ])),
    ]);
    final dropdown = DropdownButtonHideUnderline(child: DropdownButton<int>(
      value: month, isExpanded: true, dropdownColor: WindowsAppearance.resolve(const Color(0xFF11253C)),
      borderRadius: BorderRadius.circular(12),
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: WindowsAppearance.foreground(Colors.white), fontSize: 15),
      icon: loadingYear ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          :  Icon(Icons.keyboard_arrow_down_rounded, color: WindowsAppearance.foreground(Color(0xFFC2D8FA))),
      items: const [DropdownMenuItem(value: 1, child: Text('January')), DropdownMenuItem(value: 4, child: Text('April'))],
      onChanged: loadingYear ? null : (value) { if (value != null) onMonthChanged(value); },
    ));
    final field = Container(padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: _decoration(inset: true), child: dropdown);
    return Container(padding: const EdgeInsets.all(16), decoration: _decoration(inset: true),
      child: LayoutBuilder(builder: (context, size) {WindowsAppearance.watch(context);
        if (size.maxWidth / MediaQuery.textScalerOf(context).scale(1) < 480) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [label, const SizedBox(height: 14), field]);
        }
        return Row(children: [Expanded(child: label), const SizedBox(width: 18), SizedBox(width: 160, child: field)]);
      }));
  }

  Widget _panel({required IconData icon, required Color color, required String title,
      required String subtitle, required Widget child}) => Container(
    padding: const EdgeInsets.all(22), decoration: _decoration(),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [_icon(icon, color, small: true), const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style:  TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.white), fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5), Text(subtitle, style:  TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.resolve(muted), fontSize: 13, height: 1.35)),
        ])),
      ]),
      const SizedBox(height: 16),
      if (title == 'Admin Profile') ...[ Divider(color: WindowsAppearance.foreground(Color(0xFF24405A)), height: 1), const SizedBox(height: 18)],
      child,
    ]),
  );
  Widget _action(String text, IconData icon, VoidCallback onTap) => OutlinedButton(
    onPressed: onTap, style: OutlinedButton.styleFrom(
      foregroundColor: amber, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      side: BorderSide(color: amber.withValues(alpha: .35)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      backgroundColor: WindowsAppearance.primary),
    child: Row(children: [Icon(icon, size: 22), const SizedBox(width: 14),
      Expanded(child: Text(text, style:  TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.white), fontSize: 14, fontWeight: FontWeight.w600))),
      const SizedBox(width: 8), const Icon(Icons.arrow_forward_rounded, size: 22),
    ]));
  Widget _icon(IconData icon, Color color, {bool small = false}) => Container(
    width: small ? 44 : 56, height: small ? 44 : 56,
    decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(13)),
    child: Icon(icon, color: color, size: small ? 26 : 30));
  BoxDecoration _decoration({bool inset = false}) => BoxDecoration(
    borderRadius: BorderRadius.circular(inset ? 12 : 16),
    border: Border.all(color: WindowsAppearance.outline(const Color(0xFF294969))),
    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
      colors: inset ?  [WindowsAppearance.resolve(Color(0xFF0B1C30)), WindowsAppearance.resolve(Color(0xFF0B1A2B))]
          :  [WindowsAppearance.resolve(Color(0xFF10263F)), WindowsAppearance.resolve(Color(0xFF0C1D30))]));
}
