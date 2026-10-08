from pathlib import Path
import re

src = Path('lib/main_dashboard_screen.dart')
out = Path('lib/main_dashboard_screen_windows.dart')

if not src.exists():
    raise SystemExit('lib/main_dashboard_screen.dart not found')

text = src.read_text(encoding='utf-8')

def replace_once(old: str, new: str, label: str):
    global text
    if old not in text:
        raise SystemExit(f'Windows patch point missing: {label}')
    text = text.replace(old, new, 1)

# ============================================================
# WINDOWS-ONLY IMPORTS. Website source stays unchanged.
# ============================================================
replace_once(
    "import 'dart:html' as html;",
    "import 'windows_html_shim.dart' as html;",
    'dart:html import',
)
replace_once(
    "import 'package:mobile_scanner/mobile_scanner.dart';",
    "import 'windows_mobile_scanner_shim.dart';",
    'mobile scanner import',
)
replace_once(
    "import 'package:cloud_firestore/cloud_firestore.dart';",
    "import 'windows_local_firestore.dart';",
    'Firestore import',
)
replace_once(
    "import 'package:firebase_auth/firebase_auth.dart';",
    "import 'windows_local_auth.dart';",
    'Firebase Auth import',
)

extra_imports = """import 'windows_settings_panel.dart';
import 'windows_local_session.dart';
import 'windows_local_settings.dart';
import 'windows_service_status.dart';
import 'windows_backend_bridge.dart';
import 'windows_sync_engine.dart';
"""
first_import_end = text.find('\n') + 1
text = text[:first_import_end] + extra_imports + text[first_import_end:]

# Browser-only Image.network option is not valid/needed on Windows.
text = re.sub(
    r'\s*webHtmlElementStrategy:\s*WebHtmlElementStrategy\s*\.prefer,\s*',
    '\n',
    text,
)

# Every Google Apps Script call goes through one Windows bridge. It first
# tries the real backend and updates the Drive LED; on network/404 it keeps
# the local-first app working with a local fallback.
text, post_count = re.subn(
    r'http\s*\.\s*post\s*\(',
    'WindowsBackendBridge.post(',
    text,
)
if post_count < 10:
    raise SystemExit(f'Expected Google POST calls not patched. Count={post_count}')

# Windows admin starts in admin mode only.
text = text.replace('bool _isAdminMode = false;', 'bool _isAdminMode = true;', 1)
old_switch = """  void _switchRole(bool isAdmin) {
    setState(() {
      _isAdminMode = isAdmin;"""
new_switch = """  void _switchRole(bool isAdmin) {
    setState(() {
      _isAdminMode = true;"""
if old_switch in text:
    text = text.replace(old_switch, new_switch, 1)

# No browser-style inactivity logout in the local Windows dashboard.
timer_call = '    _startPortalInactivityTimer();'
if timer_call in text:
    text = text.replace(
        timer_call,
        '    // Windows local-first: browser inactivity auto-logout disabled.',
        1,
    )

# ============================================================
# WINDOWS ADMIN NAVIGATION
#
# Do NOT use Flutter Scaffold.drawer on Windows.
# On some Windows runs the Drawer route can appear as a blank grey panel.
# Website source is untouched; only generated Windows source changes.
# ============================================================
replace_once(
    """      drawer: _buildAdminDrawer(),
      appBar: AppBar(""",
    """      appBar: AppBar(""",
    'Remove native Windows Scaffold drawer',
)

replace_once(
    """                onTap: () => _adminScaffoldKey.currentState?.openDrawer(),""",
    """                onTap: () {
                  showGeneralDialog<void>(
                    context: context,
                    barrierDismissible: true,
                    barrierLabel: 'Admin navigation',
                    barrierColor: Colors.black.withOpacity(0.62),
                    transitionDuration: const Duration(milliseconds: 140),
                    pageBuilder: (
                      dialogContext,
                      animation,
                      secondaryAnimation,
                    ) {
                      return SafeArea(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _buildAdminDrawer(),
                        ),
                      );
                    },
                    transitionBuilder: (
                      dialogContext,
                      animation,
                      secondaryAnimation,
                      child,
                    ) {
                      return FadeTransition(
                        opacity: CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOut,
                        ),
                        child: child,
                      );
                    },
                  );
                },""",
    'Windows admin navigation modal',
)

# ============================================================
# WINDOWS-ONLY EXTRA DRAWER MODULES
# ============================================================
drawer_start = text.find('  Widget _buildAdminDrawer() {')
drawer_end = text.find('  @override\n  Widget build(BuildContext context) {', drawer_start)
if drawer_start == -1 or drawer_end == -1:
    raise SystemExit('Windows drawer boundaries missing')

drawer_section = text[drawer_start:drawer_end]

drawer_old = """            _adminDrawerItem(
              icon: Icons.school_rounded,
              title: 'Teachers',
              subtitle: 'Directory, profiles & schedules',
              color: Colors.purpleAccent,
              onTap: () => _openAdminDrawerPage(const TeachersDirectoryScreen()),
            ),
            const Spacer(),
"""

drawer_new = """            _adminDrawerItem(
              icon: Icons.school_rounded,
              title: 'Teachers',
              subtitle: 'Directory, profiles & schedules',
              color: Colors.purpleAccent,
              onTap: () => _openAdminDrawerPage(const TeachersDirectoryScreen()),
            ),
            _adminDrawerItem(
              icon: Icons.account_balance_wallet_rounded,
              title: 'School Expenses',
              subtitle: 'Expense entry & reports • Live tomorrow',
              color: Colors.amberAccent,
              onTap: () => _openAdminDrawerPage(
                const WindowsSchoolExpensesScreen(),
              ),
            ),
            _adminDrawerItem(
              icon: Icons.fact_check_rounded,
              title: 'Attendance',
              subtitle: 'Student & teacher attendance • Live tomorrow',
              color: const Color(0xFF69C2FF),
              onTap: () => _openAdminDrawerPage(
                const WindowsAttendanceScreen(),
              ),
            ),
            _adminDrawerItem(
              icon: Icons.dashboard_customize_rounded,
              title: 'Templates',
              subtitle: 'ID cards, report cards & receipts',
              color: const Color(0xFFCE93D8),
              onTap: () => _openAdminDrawerPage(
                const WindowsTemplatesScreen(),
              ),
            ),
            const SizedBox(height: 16),
"""
if drawer_old not in drawer_section:
    raise SystemExit('Windows extra drawer items anchor missing')
drawer_section = drawer_section.replace(drawer_old, drawer_new, 1)

old_column = """      child: SafeArea(
        child: Column(
          children: ["""
new_list = """      child: SafeArea(
        child: ListView(
          children: ["""
if old_column not in drawer_section:
    raise SystemExit('Windows drawer scroll anchor missing')
drawer_section = drawer_section.replace(old_column, new_list, 1)
text = text[:drawer_start] + drawer_section + text[drawer_end:]

# ============================================================
# LOCAL LOGOUT - Firebase connection is NOT removed.
# ============================================================
logout_start = text.find('  Future<void> _confirmLogout() async {')
profile_start = text.find('  String _profileInitial(User? user) {', logout_start)
if logout_start == -1 or profile_start == -1:
    raise SystemExit('Windows local logout patch point missing')

local_logout = r'''  Future<void> _confirmLogout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF172229),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        title: const Row(
          children: [
            Icon(Icons.logout_rounded, color: Colors.redAccent),
            SizedBox(width: 10),
            Text(
              'Local Logout?',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
          ],
        ),
        content: const Text(
          'Is Windows app ka local session lock hoga. Firebase/Google Drive connection remove nahi hoga.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Local Logout'),
          ),
        ],
      ),
    );

    if (shouldLogout != true) return;

    _clearPortalSession();

    try {
      await WindowsLocalSession.logout();
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/local-login',
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Local logout error: $e'),
        ),
      );
    }
  }

'''
text = text[:logout_start] + local_logout + text[profile_start:]

# Change Settings button label only in the Admin Profile section.
settings_section_start = text.find('class _SettingsScreenState')
advanced_class_start = text.find('class AdvancedSettingsScreen', settings_section_start)
if settings_section_start == -1 or advanced_class_start == -1:
    raise SystemExit('Settings section boundaries missing')
settings_section = text[settings_section_start:advanced_class_start]
settings_section = settings_section.replace(
    """label: const Text(
                          'Logout',""",
    """label: const Text(
                          'Local Logout',""",
    1,
)

# The normal Settings page and Advanced Settings must use the SAME global
# Windows connection selector. Direct local-Firestore connection writes would
# otherwise write a new Drive URL into the previous school's local profile.
settings_fetch_old = """      final doc = await FirebaseFirestore.instance
          .collection('school_config')
          .doc('google_drive_account')
          .get();

      if (!mounted) return;

      if (doc.exists) {
        final data = doc.data() ?? {};
        setState(() {
          _linkedGmail = data['email']?.toString();
          _linkedScriptUrl = data['scriptUrl']?.toString();
          _gmailController.text = _linkedGmail ?? '';
          _scriptUrlController.text = _linkedScriptUrl ?? '';
        });
      }"""
settings_fetch_new = """      final data = await WindowsExternalConnections.load();

      if (!mounted) return;

      setState(() {
        _linkedGmail = data['googleEmail']?.toString();
        _linkedScriptUrl = data['googleScriptUrl']?.toString();
        _gmailController.text = _linkedGmail ?? '';
        _scriptUrlController.text = _linkedScriptUrl ?? '';
      });"""
if settings_fetch_old not in settings_section:
    raise SystemExit('Windows Settings Google load patch point missing')
settings_section = settings_section.replace(
    settings_fetch_old,
    settings_fetch_new,
    1,
)

settings_save_old = """      await FirebaseFirestore.instance
          .collection('school_config')
          .doc('google_drive_account')
          .set({
        'email': email,
        'scriptUrl': scriptUrl,
        'status': 'connected',
        'linkedAt': DateTime.now().millisecondsSinceEpoch,
      });"""
settings_save_new = """      await WindowsSyncEngine.instance.changeGoogleConnection(
        email: email,
        scriptUrl: scriptUrl,
      );"""
if settings_save_old not in settings_section:
    raise SystemExit('Windows Settings Google save patch point missing')
settings_section = settings_section.replace(
    settings_save_old,
    settings_save_new,
    1,
)

settings_unlink_old = """      await FirebaseFirestore.instance
          .collection('school_config')
          .doc('google_drive_account')
          .delete();"""
settings_unlink_new = """      await WindowsSyncEngine.instance.disconnectGoogle();"""
if settings_unlink_old not in settings_section:
    raise SystemExit('Windows Settings Google unlink patch point missing')
settings_section = settings_section.replace(
    settings_unlink_old,
    settings_unlink_new,
    1,
)

text = text[:settings_section_start] + settings_section + text[advanced_class_start:]

# App Update + Local Storage cards directly below Admin Profile / Local Logout.
settings_cards_anchor = """                const SizedBox(height: 16),

                // =====================================================
                // ADVANCED SETTINGS
"""
settings_cards_add = """                const SizedBox(height: 16),
                const WindowsAppUpdateCard(),
                const SizedBox(height: 16),
                const WindowsLocalStorageCard(),
                const SizedBox(height: 16),

                // =====================================================
                // ADVANCED SETTINGS
"""
replace_once(settings_cards_anchor, settings_cards_add, 'Settings update/storage cards')

# ============================================================
# SCHOOL-ISOLATED GOOGLE CONNECTION (ADVANCED SETTINGS)
# ============================================================
advanced_state_start = text.find('class _AdvancedSettingsScreenState')
drive_dialog_start = text.find('class _DriveUnlinkSecurityDialog', advanced_state_start)
if advanced_state_start == -1 or drive_dialog_start == -1:
    raise SystemExit('Advanced Settings Google boundaries missing')
advanced_section = text[advanced_state_start:drive_dialog_start]

advanced_load_old = """      final doc = await FirebaseFirestore.instance
          .collection('school_config')
          .doc('google_drive_account')
          .get();
      final data = doc.data() ?? <String, dynamic>{};"""
advanced_load_new = """      final data = await WindowsExternalConnections.load();"""
if advanced_load_old not in advanced_section:
    raise SystemExit('Advanced Google load patch point missing')
advanced_section = advanced_section.replace(
    advanced_load_old,
    advanced_load_new,
    1,
)
advanced_section = advanced_section.replace(
    "_linkedGmail = data['email']?.toString().trim();",
    "_linkedGmail = data['googleEmail']?.toString().trim();",
    1,
)
advanced_section = advanced_section.replace(
    "_linkedScript = data['scriptUrl']?.toString().trim();",
    "_linkedScript = data['googleScriptUrl']?.toString().trim();",
    1,
)

advanced_save_old = """      await FirebaseFirestore.instance
          .collection('school_config')
          .doc('google_drive_account')
          .set({
        'email': email,
        'scriptUrl': url,
        'status': 'connected',
        'linkedAt': DateTime.now().millisecondsSinceEpoch,
      });"""
advanced_save_new = """      await WindowsSyncEngine.instance.changeGoogleConnection(
        email: email,
        scriptUrl: url,
      );"""
if advanced_save_old not in advanced_section:
    raise SystemExit('Advanced Google save patch point missing')
advanced_section = advanced_section.replace(
    advanced_save_old,
    advanced_save_new,
    1,
)

advanced_unlink_old = """      await FirebaseFirestore.instance
          .collection('school_config')
          .doc('google_drive_account')
          .delete();"""
advanced_unlink_new = """      await WindowsSyncEngine.instance.disconnectGoogle();"""
if advanced_unlink_old not in advanced_section:
    raise SystemExit('Advanced Google unlink patch point missing')
advanced_section = advanced_section.replace(
    advanced_unlink_old,
    advanced_unlink_new,
    1,
)

text = text[:advanced_state_start] + advanced_section + text[drive_dialog_start:]

# ============================================================
# GOOGLE DRIVE UNLINK PASSWORD RELIABILITY (WINDOWS ONLY)
# Use secure Local Admin password directly instead of a stale currentUser.
# ============================================================
drive_security_start = text.find('class _DriveUnlinkSecurityDialogState')
drive_security_end = text.find('\nclass ', drive_security_start + 10)
if drive_security_start == -1:
    raise SystemExit('Drive unlink security dialog missing')
if drive_security_end == -1:
    drive_security_end = len(text)

drive_security = text[drive_security_start:drive_security_end]
old_drive_verify = """      final user = FirebaseAuth.instance.currentUser;
      final email = user?.email?.trim() ?? '';
      if (user == null || email.isEmpty) {
        throw Exception('Admin unavailable');
      }
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: pass),
      );"""
new_drive_verify = """      await WindowsLocalSecurity.initialize();
      if (!WindowsLocalSecurity.verifyPassword(pass)) {
        throw Exception('Invalid Local Admin password');
      }"""
if old_drive_verify not in drive_security:
    raise SystemExit('Drive unlink password verify anchor missing')
drive_security = drive_security.replace(old_drive_verify, new_drive_verify, 1)
text = text[:drive_security_start] + drive_security + text[drive_security_end:]

# ============================================================
# ADVANCED SETTINGS
# Existing Google Drive stays. Add live LED and Windows Local/Firebase panel.
# Google Cloud separate box is intentionally absent.
# ============================================================
drive_status_old = """                                Text(
                                  _linked ? 'CONNECTED' : 'NOT CONNECTED',
                                  style: TextStyle(
                                    color: _linked
                                        ? const Color(0xFF00D9A5)
                                        : Colors.orangeAccent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),"""
drive_status_new = """                                const WindowsStatusLed(
                                  service: WindowsServiceType.googleDrive,
                                ),"""
replace_once(drive_status_old, drive_status_new, 'Google Drive live LED')

# Test the real Apps Script immediately when an existing link is loaded.
drive_load_anchor = """        _script.text = _linkedScript ?? '';
        _loading = false;
      });
    } catch (e) {"""
drive_load_add = """        _script.text = _linkedScript ?? '';
        _loading = false;
      });

      final loadedUrl = _linkedScript?.trim() ?? '';
      if (loadedUrl.isNotEmpty) {
        unawaited(
          WindowsBackendBridge.testRemote(Uri.parse(loadedUrl)),
        );
      } else {
        WindowsServiceStatus.instance.unhealthy(
          WindowsServiceType.googleDrive,
          'Google Drive / Apps Script connected nahi hai.',
        );
      }
    } catch (e) {"""
replace_once(drive_load_anchor, drive_load_add, 'Google Drive load health test')

# After save, verify actual remote backend; saved URL alone never makes LED green.
drive_save_anchor = """        _linkedScript = url;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar("""
drive_save_add = """        _linkedScript = url;
        _saving = false;
      });
      unawaited(
        WindowsBackendBridge.testRemote(Uri.parse(url)),
      );
      ScaffoldMessenger.of(context).showSnackBar("""
replace_once(drive_save_anchor, drive_save_add, 'Google Drive save health test')

# Unlink -> LED red.
drive_unlink_anchor = """        _script.clear();
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar("""
drive_unlink_add = """        _script.clear();
        _saving = false;
      });
      WindowsServiceStatus.instance.unhealthy(
        WindowsServiceType.googleDrive,
        'Google Drive / Apps Script disconnected.',
      );
      ScaffoldMessenger.of(context).showSnackBar("""
replace_once(drive_unlink_anchor, drive_unlink_add, 'Google Drive unlink health')

# Add Local Settings Lock + Firebase hand-drawn style panel before UID test panel.
windows_panel_anchor = """                      const SizedBox(height: 14),
                      const _AdvancedStudentUidSettingsPanel(),
"""
windows_panel_add = """                      const SizedBox(height: 14),
                      const WindowsSettingsPanel(),
                      const SizedBox(height: 14),
                      const _AdvancedStudentUidSettingsPanel(),
"""
replace_once(windows_panel_anchor, windows_panel_add, 'Windows Settings panel insertion')

# Update protected-settings explanation: Firebase/local lock now exist here too.
text = text.replace(
    'Protected settings: Google Drive unlink/change ke liye 30-second wait + current Admin password verification mandatory hai.',
    'Protected settings: Google Drive, Firebase aur Local Settings Lock changes password-protected hain.',
    1,
)

# ============================================================
# WINDOWS-ONLY FUTURE MODULES
# Keep these screens inside generated main_dashboard_screen_windows.dart
# so no separate windows_future_modules.dart is needed.
# ============================================================
future_modules_code = r"""
class WindowsSchoolExpensesScreen extends StatelessWidget {
  const WindowsSchoolExpensesScreen({super.key});

  @override
  Widget build(BuildContext context) => const _ComingSoonModule(
        title: 'School Expenses',
        subtitle: 'Daily expenses, categories, vouchers and reports',
        icon: Icons.account_balance_wallet_rounded,
        accent: Color(0xFFFFB74D),
        cards: <_ModuleCardData>[
          _ModuleCardData(Icons.add_card_rounded, 'Add Expense', 'Date, category, amount, paid-to and notes'),
          _ModuleCardData(Icons.category_rounded, 'Expense Categories', 'Electricity, salary, transport, maintenance and more'),
          _ModuleCardData(Icons.receipt_long_rounded, 'Voucher & Attachment', 'Keep expense proof with each entry'),
          _ModuleCardData(Icons.analytics_rounded, 'Expense Reports', 'Daily, monthly and category-wise totals'),
        ],
      );
}

class WindowsAttendanceScreen extends StatelessWidget {
  const WindowsAttendanceScreen({super.key});

  @override
  Widget build(BuildContext context) => const _ComingSoonModule(
        title: 'Attendance',
        subtitle: 'Student and teacher attendance centre',
        icon: Icons.fact_check_rounded,
        accent: Color(0xFF69C2FF),
        cards: <_ModuleCardData>[
          _ModuleCardData(Icons.groups_rounded, 'Student Attendance', 'Class-wise present, absent and late records'),
          _ModuleCardData(Icons.badge_rounded, 'Teacher Attendance', 'Teacher entry, exit and attendance history'),
          _ModuleCardData(Icons.qr_code_scanner_rounded, 'Quick Scan', 'Future QR / UID attendance workflow'),
          _ModuleCardData(Icons.insights_rounded, 'Attendance Reports', 'Daily, monthly and individual reports'),
        ],
      );
}

class _ModuleCardData {
  const _ModuleCardData(this.icon, this.title, this.subtitle);
  final IconData icon;
  final String title;
  final String subtitle;
}

class _ComingSoonModule extends StatelessWidget {
  const _ComingSoonModule({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.cards,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final List<_ModuleCardData> cards;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(title: Text(title), backgroundColor: const Color(0xFF111B21)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: const Color(0xFF172229),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: accent.withOpacity(.28)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          color: accent.withOpacity(.12),
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: Icon(icon, color: accent, size: 28),
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
                            const SizedBox(height: 4),
                            Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
                          ],
                        ),
                      ),
                      const _LiveTomorrowBadge(),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints.maxWidth >= 760 ? (constraints.maxWidth - 14) / 2 : constraints.maxWidth;
                    return Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: cards
                          .map((item) => SizedBox(
                                width: w,
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF111B21),
                                    borderRadius: BorderRadius.circular(17),
                                    border: Border.all(color: Colors.white.withOpacity(.06)),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(item.icon, color: accent, size: 25),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(item.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
                                            const SizedBox(height: 3),
                                            Text(item.subtitle, style: const TextStyle(color: Colors.white38, fontSize: 10.5, height: 1.35)),
                                          ],
                                        ),
                                      ),
                                      const Icon(Icons.lock_clock_rounded, color: Colors.white24),
                                    ],
                                  ),
                                ),
                              ))
                          .toList(),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveTomorrowBadge extends StatelessWidget {
  const _LiveTomorrowBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.orangeAccent.withOpacity(.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.orangeAccent.withOpacity(.28)),
        ),
        child: const Text('LIVE TOMORROW', style: TextStyle(color: Colors.orangeAccent, fontSize: 9.5, fontWeight: FontWeight.w900)),
      );
}

enum _CardOrientation { portrait, landscape }

class _TemplateSpec {
  const _TemplateSpec(this.code, this.name, this.orientation, this.primary, this.accent, this.variant);
  final String code;
  final String name;
  final _CardOrientation orientation;
  final Color primary;
  final Color accent;
  final int variant;
}

class WindowsTemplatesScreen extends StatefulWidget {
  const WindowsTemplatesScreen({super.key});

  @override
  State<WindowsTemplatesScreen> createState() => _WindowsTemplatesScreenState();
}

class _WindowsTemplatesScreenState extends State<WindowsTemplatesScreen> {
  int section = 0;

  static const templates = <_TemplateSpec>[
    _TemplateSpec('P1', 'Emerald Scholar', _CardOrientation.portrait, Color(0xFF075E54), Color(0xFF00D9A5), 0),
    _TemplateSpec('P2', 'Royal Academy', _CardOrientation.portrait, Color(0xFF172554), Color(0xFFFFC857), 1),
    _TemplateSpec('P3', 'Fresh Campus', _CardOrientation.portrait, Color(0xFF176B3A), Color(0xFF7CFF9D), 2),
    _TemplateSpec('P4', 'Classic Maroon', _CardOrientation.portrait, Color(0xFF6B1D2B), Color(0xFFFFD7A8), 3),
    _TemplateSpec('L1', 'Teal Horizon', _CardOrientation.landscape, Color(0xFF004D4D), Color(0xFF00D9A5), 4),
    _TemplateSpec('L2', 'Midnight Tech', _CardOrientation.landscape, Color(0xFF111A3A), Color(0xFF5DE1FF), 5),
    _TemplateSpec('L3', 'Purple Motion', _CardOrientation.landscape, Color(0xFF4B286D), Color(0xFFCE93D8), 6),
    _TemplateSpec('L4', 'Orange Slate', _CardOrientation.landscape, Color(0xFF2B2F33), Color(0xFFFF9E40), 7),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(title: const Text('Templates'), backgroundColor: const Color(0xFF111B21)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1380),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(),
                const SizedBox(height: 18),
                _categories(),
                const SizedBox(height: 22),
                if (section == 0) _idCards() else _futureSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF123D38), Color(0xFF172229)]),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFF00D9A5).withOpacity(.20)),
        ),
        child: const Row(
          children: [
            Icon(Icons.dashboard_customize_rounded, color: Color(0xFF00D9A5), size: 34),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('School Print Templates', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
                  SizedBox(height: 4),
                  Text('ID cards, report cards and receipts in one library.', style: TextStyle(color: Colors.white54, fontSize: 11.5)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _categories() {
    const data = [
      (Icons.badge_rounded, 'ID Card Templates', '8 templates ready now'),
      (Icons.description_rounded, 'Report Card Templates', 'Live tomorrow'),
      (Icons.receipt_long_rounded, 'Receipt Templates', 'Live tomorrow'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth >= 900 ? (constraints.maxWidth - 24) / 3 : constraints.maxWidth;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: List.generate(data.length, (i) {
            final item = data[i];
            final selected = section == i;
            return SizedBox(
              width: w,
              child: InkWell(
                borderRadius: BorderRadius.circular(17),
                onTap: () => setState(() => section = i),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xFF15322F) : const Color(0xFF111B21),
                    borderRadius: BorderRadius.circular(17),
                    border: Border.all(color: selected ? const Color(0xFF00D9A5).withOpacity(.35) : Colors.white.withOpacity(.06)),
                  ),
                  child: Row(
                    children: [
                      Icon(item.$1, color: selected ? const Color(0xFF00D9A5) : Colors.white38),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.$2, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5)),
                            Text(item.$3, style: const TextStyle(color: Colors.white38, fontSize: 9.5)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _idCards() {
    final portraits = templates.where((e) => e.orientation == _CardOrientation.portrait).toList();
    final landscapes = templates.where((e) => e.orientation == _CardOrientation.landscape).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title('Portrait ID Cards', '4 vertical templates'),
        const SizedBox(height: 12),
        _templateWrap(portraits, portrait: true),
        const SizedBox(height: 28),
        _title('Landscape ID Cards', '4 horizontal templates'),
        const SizedBox(height: 12),
        _templateWrap(landscapes, portrait: false),
      ],
    );
  }

  Widget _title(String title, String subtitle) => Row(
        children: [
          const Icon(Icons.auto_awesome_rounded, color: Color(0xFF00D9A5), size: 19),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16)),
          const SizedBox(width: 8),
          Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ],
      );

  Widget _templateWrap(List<_TemplateSpec> list, {required bool portrait}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = portrait
            ? (constraints.maxWidth >= 1180 ? (constraints.maxWidth - 42) / 4 : constraints.maxWidth >= 620 ? (constraints.maxWidth - 14) / 2 : constraints.maxWidth)
            : (constraints.maxWidth >= 900 ? (constraints.maxWidth - 14) / 2 : constraints.maxWidth);
        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: list.map((spec) => SizedBox(width: w, child: _TemplateTile(spec: spec, onPreview: () => _preview(spec)))).toList(),
        );
      },
    );
  }

  Widget _futureSection() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xFF111B21),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(.06)),
        ),
        child: Column(
          children: [
            Icon(section == 1 ? Icons.description_rounded : Icons.receipt_long_rounded, color: Colors.orangeAccent, size: 46),
            const SizedBox(height: 10),
            Text(section == 1 ? 'Report Card Templates' : 'Receipt Templates', style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            const Text('Section ready hai. Designs next live update me add honge.', style: TextStyle(color: Colors.white54, fontSize: 11)),
            const SizedBox(height: 12),
            const _LiveTomorrowBadge(),
          ],
        ),
      );

  Future<void> _preview(_TemplateSpec spec) => showDialog<void>(
        context: context,
        builder: (ctx) {
          final portrait = spec.orientation == _CardOrientation.portrait;
          return Dialog(
            backgroundColor: const Color(0xFF0B141A),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('${spec.code} • ${spec.name}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 17))),
                      IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close_rounded, color: Colors.white54)),
                    ],
                  ),
                  SizedBox(
                    width: portrait ? 350 : 620,
                    child: AspectRatio(aspectRatio: portrait ? .63 : 1.58, child: _IdCard(spec: spec, large: true)),
                  ),
                ],
              ),
            ),
          );
        },
      );
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({required this.spec, required this.onPreview});
  final _TemplateSpec spec;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final portrait = spec.orientation == _CardOrientation.portrait;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFF111B21),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(spec.code, style: TextStyle(color: spec.accent, fontWeight: FontWeight.w900)),
              const SizedBox(width: 8),
              Expanded(child: Text(spec.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
              Text(portrait ? 'PORTRAIT' : 'LANDSCAPE', style: const TextStyle(color: Colors.white30, fontSize: 8, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 11),
          Center(
            child: SizedBox(
              width: portrait ? 180 : double.infinity,
              child: AspectRatio(aspectRatio: portrait ? .63 : 1.58, child: _IdCard(spec: spec)),
            ),
          ),
          const SizedBox(height: 11),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onPreview,
              icon: const Icon(Icons.visibility_rounded, size: 17),
              label: const Text('Preview'),
              style: OutlinedButton.styleFrom(foregroundColor: spec.accent, side: BorderSide(color: spec.accent.withOpacity(.35))),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdCard extends StatelessWidget {
  const _IdCard({required this.spec, this.large = false});
  final _TemplateSpec spec;
  final bool large;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(large ? 20 : 13),
        child: Container(
          color: Colors.white,
          child: spec.orientation == _CardOrientation.portrait ? _portrait() : _landscape(),
        ),
      );

  Widget _header() => Container(
        padding: EdgeInsets.symmetric(horizontal: large ? 14 : 8, vertical: large ? 10 : 5),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: spec.variant.isEven ? [spec.primary, spec.accent] : [spec.accent, spec.primary],
          ),
        ),
        child: Row(
          children: [
            Container(
              width: large ? 34 : 21,
              height: large ? 34 : 21,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(7)),
              child: Icon(Icons.school_rounded, color: spec.primary, size: large ? 22 : 14),
            ),
            SizedBox(width: large ? 9 : 5),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SARASWATI VIDYA NIKETAN', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: large ? 12 : 6.8, fontWeight: FontWeight.w900)),
                  Text('STUDENT IDENTITY CARD • 2026-27', style: TextStyle(color: Colors.white.withOpacity(.82), fontSize: large ? 7.5 : 4.4, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _portrait() => Column(
        children: [
          _header(),
          SizedBox(height: large ? 12 : 6),
          Container(
            width: large ? 88 : 50,
            height: large ? 102 : 58,
            decoration: BoxDecoration(
              color: spec.primary.withOpacity(.08),
              borderRadius: BorderRadius.circular(large ? 14 : 8),
              border: Border.all(color: spec.primary.withOpacity(.24)),
            ),
            child: Icon(Icons.person_rounded, color: spec.primary.withOpacity(.65), size: large ? 58 : 34),
          ),
          SizedBox(height: large ? 8 : 4),
          Text('ANANYA DAS', style: TextStyle(color: spec.primary, fontSize: large ? 15 : 8.2, fontWeight: FontWeight.w900)),
          Text('Class 8 • Roll 012', style: TextStyle(color: Colors.black54, fontSize: large ? 9 : 5.3, fontWeight: FontWeight.w700)),
          SizedBox(height: large ? 9 : 4),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: large ? 16 : 8),
            child: Column(children: [_row('ID No.', 'SVN-8-012'), _row('DOB', '18/08/2013'), _row('Contact', '98XXXXXX12')]),
          ),
          const Spacer(),
          Padding(
            padding: EdgeInsets.all(large ? 12 : 6),
            child: Row(
              children: [
                _MiniQr(size: large ? 43 : 25, color: spec.primary),
                SizedBox(width: large ? 8 : 4),
                Expanded(child: Text('Principal Signature', style: TextStyle(color: Colors.black38, fontSize: large ? 7 : 4.2))),
              ],
            ),
          ),
        ],
      );

  Widget _landscape() => Column(
        children: [
          _header(),
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(large ? 13 : 7),
              child: Row(
                children: [
                  Container(
                    width: large ? 116 : 62,
                    decoration: BoxDecoration(
                      color: spec.primary.withOpacity(.07),
                      borderRadius: BorderRadius.circular(large ? 14 : 8),
                      border: Border.all(color: spec.primary.withOpacity(.20)),
                    ),
                    child: Icon(Icons.person_rounded, color: spec.primary.withOpacity(.65), size: large ? 72 : 38),
                  ),
                  SizedBox(width: large ? 14 : 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ANANYA DAS', style: TextStyle(color: spec.primary, fontSize: large ? 18 : 9.5, fontWeight: FontWeight.w900)),
                        SizedBox(height: large ? 8 : 3),
                        _row('Class', '8 • Section A'),
                        _row('Roll', '012'),
                        _row('Student ID', 'SVN-8-012'),
                        _row('DOB', '18/08/2013'),
                      ],
                    ),
                  ),
                  _MiniQr(size: large ? 58 : 32, color: spec.primary),
                ],
              ),
            ),
          ),
          Container(height: large ? 8 : 4, color: spec.accent),
        ],
      );

  Widget _row(String label, String value) => Padding(
        padding: EdgeInsets.only(bottom: large ? 4 : 1.5),
        child: Row(
          children: [
            SizedBox(width: large ? 62 : 34, child: Text(label, style: TextStyle(color: Colors.black45, fontSize: large ? 8 : 4.4, fontWeight: FontWeight.w700))),
            Expanded(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.black87, fontSize: large ? 8.5 : 4.8, fontWeight: FontWeight.w800))),
          ],
        ),
      );
}

class _MiniQr extends StatelessWidget {
  const _MiniQr({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(width: size, height: size, child: CustomPaint(painter: _MiniQrPainter(color)));
}

class _MiniQrPainter extends CustomPainter {
  const _MiniQrPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const cells = 9;
    final cell = size.width / cells;
    final paint = Paint()..color = color;
    for (var y = 0; y < cells; y++) {
      for (var x = 0; x < cells; x++) {
        final finder = (x < 3 && y < 3) || (x >= 6 && y < 3) || (x < 3 && y >= 6);
        final pattern = ((x * 7 + y * 11 + x * y) % 5) < 2;
        if (finder || pattern) {
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell * .86, cell * .86), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MiniQrPainter oldDelegate) => oldDelegate.color != color;
}
"""

if 'class WindowsSchoolExpensesScreen' not in text:
    text += "\n\n" + future_modules_code + "\n"

# ============================================================
# VALIDATION
# ============================================================
checks = {
    'website source not overwritten': out != src,
    'Windows html shim': "import 'windows_html_shim.dart' as html;" in text,
    'Windows local Firestore': "import 'windows_local_firestore.dart';" in text,
    'Windows local Auth': "import 'windows_local_auth.dart';" in text,
    'Windows backend bridge': "import 'windows_backend_bridge.dart';" in text,
    'Windows master sync engine': "import 'windows_sync_engine.dart';" in text,
    'Windows external connections': "import 'windows_local_settings.dart';" in text,
    'all Google POST calls bridged': 'http.post(' not in text and re.search(r'http\s*\.\s*post\s*\(', text) is None,
    'local logout route': "'/local-login'" in text,
    'local storage card': 'const WindowsLocalStorageCard()' in text,
    'app update card': 'const WindowsAppUpdateCard()' in text,
    'Firebase settings panel': 'const WindowsSettingsPanel()' in text,
    'Google Drive live LED': 'WindowsServiceType.googleDrive' in text,
    'Google save uses isolated engine': 'WindowsSyncEngine.instance.changeGoogleConnection' in text,
    'Google unlink uses isolated engine': 'WindowsSyncEngine.instance.disconnectGoogle' in text,
    'Google unlink Local Admin verification': 'WindowsLocalSecurity.verifyPassword(pass)' in text,
    'School Expenses drawer': 'const WindowsSchoolExpensesScreen()' in text,
    'Attendance drawer': 'const WindowsAttendanceScreen()' in text,
    'Templates drawer': 'const WindowsTemplatesScreen()' in text,
    'Future modules embedded': 'class WindowsTemplatesScreen' in text,
    'native Windows Scaffold drawer removed': 'drawer: _buildAdminDrawer()' not in text,
    'Windows admin navigation modal': "barrierLabel: 'Admin navigation'" in text,
    'old openDrawer call removed': 'currentState?.openDrawer()' not in text,
    'Google Cloud box absent in generated injection': 'Google Cloud Console' not in text,
    'School Expenses screen embedded': 'class WindowsSchoolExpensesScreen' in text,
    'Attendance screen embedded': 'class WindowsAttendanceScreen' in text,
    'Templates screen embedded': 'class WindowsTemplatesScreen' in text,
    '8 ID templates embedded': all(code in text for code in ["'P1'", "'P2'", "'P3'", "'P4'", "'L1'", "'L2'", "'L3'", "'L4'"]),
    'Admin dashboard retained': 'class AdminDashboardScreen' in text,
    'School Settings retained': 'class SchoolSettingsScreen' in text,
    'Exam Center retained': 'class ExamCenterScreen' in text,
    'Transaction History retained': 'class FeeTransactionHistoryScreen' in text,
}
failed = [name for name, ok in checks.items() if not ok]
if failed:
    raise SystemExit('Windows final patch validation failed: ' + ', '.join(failed))

out.write_text(text, encoding='utf-8')
print('Generated:', out)
print('Google POST calls routed through bridge:', post_count)
for name in checks:
    print(name + ': OK')
