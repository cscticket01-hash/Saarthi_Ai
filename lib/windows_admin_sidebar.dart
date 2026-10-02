import 'package:flutter/material.dart';
import 'windows_ui_localization.dart' as ui;

enum WindowsAdminPage {
  dashboard, students, fees, exams, teachers, salary, support,
  expenses, attendance, templates,
}

/// Both the dashboard drawer and analytics rail use this exact navigation.
class WindowsAdminSidebar extends StatelessWidget {
  const WindowsAdminSidebar({super.key, required this.header,
    required this.onSelected, required this.onLogout});
  static const double width = 320;
  final Widget header;
  final ValueChanged<WindowsAdminPage> onSelected;
  final VoidCallback onLogout;
  static const entries = <(WindowsAdminPage, String, String, IconData, Color)>[
    (WindowsAdminPage.dashboard, 'Dashboard', 'School overview & notices', Icons.dashboard_rounded, Color(0xFF00D9A5)),
    (WindowsAdminPage.students, 'Student Records', 'Students, profiles & ID cards', Icons.people_alt_rounded, Color(0xFF00A884)),
    (WindowsAdminPage.fees, 'Fees Collection', 'Collect fees, receipts & dues', Icons.payments_rounded, Colors.greenAccent),
    (WindowsAdminPage.exams, 'Exam Center', 'Marks, results & report cards', Icons.fact_check_rounded, Colors.orangeAccent),
    (WindowsAdminPage.teachers, 'Teachers', 'Directory, profiles & schedules', Icons.school_rounded, Colors.purpleAccent),
    (WindowsAdminPage.salary, 'Teacher salary', 'Salary section', Icons.account_balance_wallet_rounded, Colors.purpleAccent),
    (WindowsAdminPage.support, 'App support', 'Report a Windows app problem', Icons.support_agent_rounded, Color(0xFF00D9A5)),
    (WindowsAdminPage.expenses, 'School Expenses', 'Expense entry, ledger & reports', Icons.account_balance_wallet_rounded, Colors.amberAccent),
    (WindowsAdminPage.attendance, 'Attendance', 'Student / teacher records & calendar', Icons.fact_check_rounded, Color(0xFF69C2FF)),
    (WindowsAdminPage.templates, 'Templates', 'ID cards, report cards & receipts', Icons.dashboard_customize_rounded, Color(0xFFCE93D8)),
  ];
  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: ColoredBox(color: const Color(0xFF06131A), child: SafeArea(
      child: Column(children: [
        Expanded(child: ListView(padding: EdgeInsets.zero, children: [header,
          for (final entry in entries) Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Material(color: entry.$5.withValues(alpha: .07),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: entry.$5.withValues(alpha: .18))),
              child: ListTile(key: ValueKey('admin-nav-${entry.$1.name}'),
                leading: Icon(entry.$4, color: entry.$5),
                title: ui.Text(entry.$2, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
                subtitle: ui.Text(entry.$3, maxLines: 2, style: const TextStyle(fontSize: 10, color: Colors.white54)),
                trailing: Icon(Icons.chevron_right_rounded, color: entry.$5),
                onTap: () => onSelected(entry.$1)),
            ),
          ),
        ])),
        const Divider(height: 1),
        const Padding(padding: EdgeInsets.only(top: 8),
          child: ui.Text('Vidya Saarthi • School Management', style: TextStyle(color: Colors.white38, fontSize: 10))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          child: SizedBox(width: double.infinity, child: TextButton.icon(
            key: const ValueKey('admin-logout'), onPressed: onLogout,
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            icon: const Icon(Icons.logout_rounded), label: const ui.Text('Logout')))),
      ]),
    )),
  );
}
