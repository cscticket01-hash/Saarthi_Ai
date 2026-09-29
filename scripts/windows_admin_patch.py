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
import 'windows_service_status.dart';
import 'windows_backend_bridge.dart';
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
# FIX WINDOWS DRAWER / GREY LEFT OVERLAY BEHAVIOUR
# ============================================================
replace_once(
    """      drawer: _buildAdminDrawer(),
      appBar: AppBar(""",
    """      drawer: _buildAdminDrawer(),
      drawerEnableOpenDragGesture: false,
      drawerScrimColor: Colors.black.withOpacity(0.62),
      appBar: AppBar(""",
    'Admin drawer scaffold',
)

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
# VALIDATION
# ============================================================
checks = {
    'website source not overwritten': out != src,
    'Windows html shim': "import 'windows_html_shim.dart' as html;" in text,
    'Windows local Firestore': "import 'windows_local_firestore.dart';" in text,
    'Windows local Auth': "import 'windows_local_auth.dart';" in text,
    'Windows backend bridge': "import 'windows_backend_bridge.dart';" in text,
    'all Google POST calls bridged': 'http.post(' not in text and re.search(r'http\s*\.\s*post\s*\(', text) is None,
    'local logout route': "'/local-login'" in text,
    'local storage card': 'const WindowsLocalStorageCard()' in text,
    'app update card': 'const WindowsAppUpdateCard()' in text,
    'Firebase settings panel': 'const WindowsSettingsPanel()' in text,
    'Google Drive live LED': 'WindowsServiceType.googleDrive' in text,
    'Google Cloud box absent in generated injection': 'Google Cloud Console' not in text,
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
