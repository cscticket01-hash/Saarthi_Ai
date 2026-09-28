from pathlib import Path
import re

src = Path('lib/main_dashboard_screen.dart')
out = Path('lib/main_dashboard_screen_windows.dart')

if not src.exists():
    raise SystemExit('lib/main_dashboard_screen.dart not found')

text = src.read_text(encoding='utf-8')

html_import = "import 'dart:html' as html;"
scanner_import = "import 'package:mobile_scanner/mobile_scanner.dart';"

if html_import not in text:
    raise SystemExit('Expected dart:html import not found. Source changed; patch stopped safely.')

text = text.replace(
    html_import,
    "import 'windows_html_shim.dart' as html;",
    1,
)

if "import 'windows_update_manager.dart';" not in text:
    text = text.replace(
        "import 'windows_html_shim.dart' as html;\n",
        "import 'windows_html_shim.dart' as html;\n"
        "import 'windows_update_manager.dart';\n",
        1,
    )

if scanner_import in text:
    text = text.replace(
        scanner_import,
        "import 'windows_mobile_scanner_shim.dart';",
        1,
    )

# Browser-only Image.network rendering hint is unnecessary on Windows.
text = re.sub(
    r'\s*webHtmlElementStrategy:\s*WebHtmlElementStrategy\s*\.prefer,\s*',
    '\n',
    text,
)

# Desktop build must never accidentally expose the Student/Admin role switch
# as its startup entry. main_windows.dart uses its own Admin-only login.
# These guards also stop accidental switching if the old login is ever opened.
text = text.replace(
    'bool _isAdminMode = false;',
    'bool _isAdminMode = true;',
    1,
)

old_switch = '''  void _switchRole(bool isAdmin) {
    setState(() {
      _isAdminMode = isAdmin;'''
new_switch = '''  void _switchRole(bool isAdmin) {
    setState(() {
      _isAdminMode = true;'''
if old_switch in text:
    text = text.replace(old_switch, new_switch, 1)


# Add Windows Update card to the normal Settings page.
settings_anchor = """                const SizedBox(height: 16),

                // =====================================================
                // ADVANCED SETTINGS
"""
settings_replacement = """                const SizedBox(height: 16),

                // =====================================================
                // WINDOWS APP UPDATE
                // =====================================================
                const WindowsUpdateSettingsCard(),

                const SizedBox(height: 16),

                // =====================================================
                // ADVANCED SETTINGS
"""

if settings_anchor not in text:
    raise SystemExit(
        'Windows Settings update-card anchor not found. Source changed; '
        'patch stopped safely.'
    )

text = text.replace(
    settings_anchor,
    settings_replacement,
    1,
)

out.write_text(text, encoding='utf-8')

checks = {
    'dart:html removed': "import 'dart:html' as html;" not in text,
    'Windows html shim active': "import 'windows_html_shim.dart' as html;" in text,
    'mobile scanner shim active': "windows_mobile_scanner_shim.dart" in text,
    'Admin default forced': 'bool _isAdminMode = true;' in text,
    'Admin dashboard retained': 'class AdminDashboardScreen' in text,
    'Windows update import active': "import 'windows_update_manager.dart';" in text,
    'Windows update Settings card active': 'WindowsUpdateSettingsCard' in text,
    'Exam Center retained': 'class ExamCenterScreen' in text,
    'Student management retained': 'students_directory' in text,
}

failed = [name for name, ok in checks.items() if not ok]
if failed:
    raise SystemExit('Windows patch validation failed: ' + ', '.join(failed))

print('Generated:', out)
for name in checks:
    print(name + ': OK')
