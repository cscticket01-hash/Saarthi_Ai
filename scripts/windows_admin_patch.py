from pathlib import Path
import re

src = Path('lib/main_dashboard_screen.dart')
out = Path('lib/main_dashboard_screen_windows.dart')

if not src.exists():
    raise SystemExit(
        'lib/main_dashboard_screen.dart not found'
    )

text = src.read_text(
    encoding='utf-8'
)

# ============================================================
# WINDOWS LOCAL-FIRST IMPORTS
# Website source is never overwritten.
# ============================================================

required_imports = {
    "import 'dart:html' as html;":
        "import 'windows_html_shim.dart' as html;",
    "import 'package:mobile_scanner/mobile_scanner.dart';":
        "import 'windows_mobile_scanner_shim.dart';",
    "import 'package:cloud_firestore/cloud_firestore.dart';":
        "import 'windows_local_firestore.dart';",
    "import 'package:firebase_auth/firebase_auth.dart';":
        "import 'windows_local_auth.dart';",
}

for old, new in required_imports.items():
    if old not in text:
        raise SystemExit(
            'Expected source import missing: ' + old
        )
    text = text.replace(old, new, 1)

settings_import = (
    "import 'windows_settings_panel.dart';\n"
)

if settings_import not in text:
    first_import_end = text.find('\n') + 1
    text = (
        text[:first_import_end] +
        settings_import +
        text[first_import_end:]
    )

# Browser-only Image.network option is not valid/needed on Windows.
text = re.sub(
    r'\s*webHtmlElementStrategy:\s*'
    r'WebHtmlElementStrategy\s*\.prefer,\s*',
    '\n',
    text,
)

# Windows Admin build should not expose Student/Admin role switching.
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
    text = text.replace(
        old_switch,
        new_switch,
        1,
    )

# Main Windows app opens the Admin dashboard directly.
# Keep the website inactivity code unchanged in source, but do not start the
# auto-logout timer in the generated Windows copy.
timer_call = '    _startPortalInactivityTimer();'

if timer_call in text:
    text = text.replace(
        timer_call,
        '    // Windows local-first build: no forced dashboard auto-logout.',
        1,
    )

# ============================================================
# WINDOWS-ONLY SETTINGS PANEL
# Existing Google Drive card remains.
# Add Local Settings Lock + Firebase + Google Cloud below it.
# ============================================================

settings_anchor = '''                      const SizedBox(height: 14),
                      const _AdvancedStudentUidSettingsPanel(),
'''

settings_add = '''                      const SizedBox(height: 14),
                      const WindowsSettingsPanel(),
                      const SizedBox(height: 14),
                      const _AdvancedStudentUidSettingsPanel(),
'''

if settings_anchor not in text:
    raise SystemExit(
        'Advanced Settings insertion point not found. '
        'Website dashboard structure changed.'
    )

text = text.replace(
    settings_anchor,
    settings_add,
    1,
)

# ============================================================
# SAFETY VALIDATION
# ============================================================

checks = {
    'browser html removed':
        "import 'dart:html' as html;" not in text,

    'Windows html shim active':
        "import 'windows_html_shim.dart' as html;" in text,

    'mobile scanner shim active':
        "windows_mobile_scanner_shim.dart" in text,

    'Firebase Firestore removed from generated Windows source':
        "package:cloud_firestore/cloud_firestore.dart" not in text,

    'Local database active':
        "import 'windows_local_firestore.dart';" in text,

    'Firebase Auth removed from generated Windows source':
        "package:firebase_auth/firebase_auth.dart" not in text,

    'Local settings auth active':
        "import 'windows_local_auth.dart';" in text,

    'Windows settings panel active':
        'const WindowsSettingsPanel()' in text,

    'Admin dashboard retained':
        'class AdminDashboardScreen' in text,

    'Student management retained':
        'students_directory' in text,

    'Teachers retained':
        'class TeachersDirectoryScreen' in text,

    'Fees retained':
        'class FeesCollectionScreen' in text,

    'Exam Center retained':
        'class ExamCenterScreen' in text,

    'Website source not overwritten':
        out != src,
}

failed = [
    name
    for name, ok in checks.items()
    if not ok
]

if failed:
    raise SystemExit(
        'Windows local-first patch validation failed: ' +
        ', '.join(failed)
    )

out.write_text(
    text,
    encoding='utf-8',
)

print(
    'Generated Windows local-first dashboard:',
    out,
)

for name in checks:
    print(name + ': OK')
