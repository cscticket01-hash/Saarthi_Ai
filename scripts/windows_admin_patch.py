from pathlib import Path
import re

src = Path('lib/main_dashboard_screen.dart')
out = Path('lib/main_dashboard_screen_windows.dart')

if not src.exists():
    raise SystemExit('lib/main_dashboard_screen.dart not found')

text = src.read_text(encoding='utf-8')

# ============================================================
# WINDOWS COMPATIBILITY PATCH
# ============================================================

html_import = "import 'dart:html' as html;"
scanner_import = "import 'package:mobile_scanner/mobile_scanner.dart';"

if html_import not in text:
    raise SystemExit(
        'Expected dart:html import not found. '
        'Source changed; patch stopped safely.'
    )

text = text.replace(
    html_import,
    "import 'windows_html_shim.dart' as html;",
    1,
)

if scanner_import in text:
    text = text.replace(
        scanner_import,
        "import 'windows_mobile_scanner_shim.dart';",
        1,
    )

text = re.sub(
    r'\s*webHtmlElementStrategy:\s*WebHtmlElementStrategy\s*\.prefer,\s*',
    '\n',
    text,
)

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

# ============================================================
# WINDOWS-ONLY ADVANCED SETTINGS CONNECTION BOXES
# ============================================================

# Never apply generic initState/input anchors outside this state class.
try:
    start = text.index('class _AdvancedSettingsScreenState')
    end = text.index('class _AdvancedStudentUidSettingsPanel', start)
except ValueError:
    raise SystemExit('Dashboard does not match the current SETTINGS_FAST_FINAL handoff. No source was changed; use the current dashboard version.')
prefix, suffix = text[:start], text[end:]
text = text[start:end]

state_anchor = '''class _AdvancedSettingsScreenState extends State<AdvancedSettingsScreen> {
  final _gmail = TextEditingController();
  final _script = TextEditingController();
  String? _linkedGmail;
  String? _linkedScript;
  bool _loading = true;
  bool _saving = false;
'''

state_add = '''class _AdvancedSettingsScreenState extends State<AdvancedSettingsScreen> {
  final _gmail = TextEditingController();
  final _script = TextEditingController();
  String? _linkedGmail;
  String? _linkedScript;
  bool _loading = true;
  bool _saving = false;

  // WINDOWS ONLY - external connection links
  final _firebaseConnectionLink = TextEditingController();
  final _googleCloudConsoleLink = TextEditingController();

  String? _linkedFirebaseConnectionLink;
  String? _linkedGoogleCloudConsoleLink;

  bool _editingFirebaseConnectionLink = false;
  bool _editingGoogleCloudConsoleLink = false;
  bool _savingWindowsConnectionLink = false;
'''

if state_anchor not in text:
    raise SystemExit(
        'Windows connection UI patch point missing: '
        'Advanced Settings state fields changed.'
    )

text = text.replace(
    state_anchor,
    state_add,
    1,
)

init_anchor = '''  void initState() {
    super.initState();
    _load();
  }
'''

init_add = '''  void initState() {
    super.initState();
    _load();
    _loadWindowsExternalConnectionLinks();
  }
'''

if init_anchor not in text:
    raise SystemExit(
        'Windows connection UI patch point missing: '
        'Advanced Settings initState changed.'
    )

text = text.replace(
    init_anchor,
    init_add,
    1,
)

dispose_anchor = '''  void dispose() {
    _gmail.dispose();
    _script.dispose();
    super.dispose();
  }
'''

dispose_add = '''  void dispose() {
    _gmail.dispose();
    _script.dispose();
    _firebaseConnectionLink.dispose();
    _googleCloudConsoleLink.dispose();
    super.dispose();
  }
'''

if dispose_anchor not in text:
    raise SystemExit(
        'Windows connection UI patch point missing: '
        'Advanced Settings dispose changed.'
    )

text = text.replace(
    dispose_anchor,
    dispose_add,
    1,
)

methods_anchor = '''  InputDecoration _input(String text, IconData icon) => InputDecoration(
'''

methods_add = r'''  Future<void> _loadWindowsExternalConnectionLinks() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('school_config')
          .doc('windows_external_connections')
          .get();

      final data = doc.data() ?? <String, dynamic>{};

      if (!mounted) return;

      final firebaseLink =
          data['firebaseLink']?.toString().trim() ?? '';

      final googleCloudLink =
          data['googleCloudConsoleLink']?.toString().trim() ?? '';

      setState(() {
        _linkedFirebaseConnectionLink =
            firebaseLink.isEmpty ? null : firebaseLink;

        _linkedGoogleCloudConsoleLink =
            googleCloudLink.isEmpty ? null : googleCloudLink;

        _firebaseConnectionLink.text =
            _linkedFirebaseConnectionLink ?? '';

        _googleCloudConsoleLink.text =
            _linkedGoogleCloudConsoleLink ?? '';
      });
    } catch (e) {
      debugPrint(
        'Windows external connection links load error: $e',
      );
    }
  }

  bool _validFirebaseConnectionLink(String value) {
    final link = value.trim();

    if (!link.startsWith(
      'vidyasaarthi://firebase?config=',
    )) {
      return false;
    }

    final uri = Uri.tryParse(link);
    final config =
        uri?.queryParameters['config']?.trim() ?? '';

    return config.length >= 20;
  }

  bool _validGoogleCloudConsoleLink(String value) {
    final uri = Uri.tryParse(value.trim());

    if (uri == null || uri.scheme != 'https') {
      return false;
    }

    return uri.host.toLowerCase() ==
        'console.cloud.google.com';
  }

  Future<void> _saveWindowsExternalConnectionLink(
    String type,
  ) async {
    if (_savingWindowsConnectionLink) return;

    final isFirebase = type == 'firebase';

    final controller = isFirebase
        ? _firebaseConnectionLink
        : _googleCloudConsoleLink;

    final value = controller.text.trim();

    if (isFirebase) {
      if (!_validFirebaseConnectionLink(value)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(
              'Valid Vidya Saarthi Firebase Link daalein.',
            ),
          ),
        );
        return;
      }
    } else {
      if (!_validGoogleCloudConsoleLink(value)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(
              'Valid Google Cloud Console link daalein.',
            ),
          ),
        );
        return;
      }
    }

    setState(() {
      _savingWindowsConnectionLink = true;
    });

    try {
      final field = isFirebase
          ? 'firebaseLink'
          : 'googleCloudConsoleLink';

      final updatedField = isFirebase
          ? 'firebaseLinkUpdatedAt'
          : 'googleCloudConsoleLinkUpdatedAt';

      await FirebaseFirestore.instance
          .collection('school_config')
          .doc('windows_external_connections')
          .set(
        {
          field: value,
          updatedField: FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      if (!mounted) return;

      setState(() {
        if (isFirebase) {
          _linkedFirebaseConnectionLink = value;
          _editingFirebaseConnectionLink = false;
        } else {
          _linkedGoogleCloudConsoleLink = value;
          _editingGoogleCloudConsoleLink = false;
        }

        _savingWindowsConnectionLink = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text(
            isFirebase
                ? 'Firebase Link save ho gaya.'
                : 'Google Cloud Console Link save ho gaya.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _savingWindowsConnectionLink = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            'Connection link save error: $e',
          ),
        ),
      );
    }
  }

  Future<void> _startProtectedWindowsConnectionEdit(
    String type,
  ) async {
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DriveUnlinkSecurityDialog(),
    );

    if (verified != true || !mounted) return;

    final isFirebase = type == 'firebase';

    setState(() {
      if (isFirebase) {
        _editingFirebaseConnectionLink = true;
        _firebaseConnectionLink.text =
            _linkedFirebaseConnectionLink ?? '';
      } else {
        _editingGoogleCloudConsoleLink = true;
        _googleCloudConsoleLink.text =
            _linkedGoogleCloudConsoleLink ?? '';
      }
    });
  }

  Future<void> _removeWindowsExternalConnectionLink(
    String type,
  ) async {
    if (_savingWindowsConnectionLink) return;

    final isFirebase = type == 'firebase';

    setState(() {
      _savingWindowsConnectionLink = true;
    });

    try {
      final field = isFirebase
          ? 'firebaseLink'
          : 'googleCloudConsoleLink';

      final updatedField = isFirebase
          ? 'firebaseLinkUpdatedAt'
          : 'googleCloudConsoleLinkUpdatedAt';

      await FirebaseFirestore.instance
          .collection('school_config')
          .doc('windows_external_connections')
          .set(
        {
          field: FieldValue.delete(),
          updatedField: FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      if (!mounted) return;

      setState(() {
        if (isFirebase) {
          _linkedFirebaseConnectionLink = null;
          _firebaseConnectionLink.clear();
          _editingFirebaseConnectionLink = false;
        } else {
          _linkedGoogleCloudConsoleLink = null;
          _googleCloudConsoleLink.clear();
          _editingGoogleCloudConsoleLink = false;
        }

        _savingWindowsConnectionLink = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text(
            isFirebase
                ? 'Firebase Link remove ho gaya.'
                : 'Google Cloud Console Link remove ho gaya.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _savingWindowsConnectionLink = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            'Connection link remove error: $e',
          ),
        ),
      );
    }
  }

  Widget _windowsExternalConnectionCard({
    required String type,
    required String title,
    required String description,
    required IconData icon,
    required Color accent,
    required TextEditingController controller,
    required String? linkedValue,
    required bool editing,
    required String hint,
  }) {
    final configured =
        linkedValue?.trim().isNotEmpty ?? false;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: accent.withOpacity(0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                configured ? 'CONFIGURED' : 'NOT CONFIGURED',
                style: TextStyle(
                  color: configured
                      ? const Color(0xFF00D9A5)
                      : Colors.orangeAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),

          if (configured && !editing) ...[
            _info(
              type == 'firebase'
                  ? 'Firebase Link'
                  : 'Google Cloud Console Link',
              linkedValue ?? '',
              Icons.link_rounded,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _savingWindowsConnectionLink
                    ? null
                    : () =>
                        _startProtectedWindowsConnectionEdit(
                          type,
                        ),
                icon: const Icon(
                  Icons.sync_alt_rounded,
                ),
                label: Text(
                  type == 'firebase'
                      ? 'Change / Remove Firebase Link'
                      : 'Change / Remove Google Cloud Link',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orangeAccent,
                  side: BorderSide(
                    color: Colors.orangeAccent
                        .withOpacity(0.5),
                  ),
                ),
              ),
            ),
          ] else ...[
            TextField(
              controller: controller,
              enabled: !_savingWindowsConnectionLink,
              style: const TextStyle(
                color: Colors.white,
              ),
              decoration: _input(
                hint,
                Icons.link_rounded,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (editing) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _savingWindowsConnectionLink
                          ? null
                          : () {
                              setState(() {
                                if (type == 'firebase') {
                                  _editingFirebaseConnectionLink =
                                      false;
                                  _firebaseConnectionLink.text =
                                      _linkedFirebaseConnectionLink ??
                                          '';
                                } else {
                                  _editingGoogleCloudConsoleLink =
                                      false;
                                  _googleCloudConsoleLink.text =
                                      _linkedGoogleCloudConsoleLink ??
                                          '';
                                }
                              });
                            },
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _savingWindowsConnectionLink
                          ? null
                          : () =>
                              _removeWindowsExternalConnectionLink(
                                type,
                              ),
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                      ),
                      label: const Text('Remove'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  flex: editing ? 2 : 1,
                  child: ElevatedButton.icon(
                    onPressed: _savingWindowsConnectionLink
                        ? null
                        : () =>
                            _saveWindowsExternalConnectionLink(
                              type,
                            ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          const Color(0xFF00A884),
                    ),
                    icon: _savingWindowsConnectionLink
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(
                            Icons.save_rounded,
                            color: Colors.white,
                          ),
                    label: Text(
                      _savingWindowsConnectionLink
                          ? 'Saving...'
                          : editing
                              ? 'Save Changes'
                              : 'Save Link',
                      style: const TextStyle(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  InputDecoration _input(String text, IconData icon) => InputDecoration(
'''

if methods_anchor not in text:
    raise SystemExit(
        'Windows connection UI patch point missing: '
        'Advanced Settings input helper changed.'
    )

text = text.replace(
    methods_anchor,
    methods_add,
    1,
)

text = text.replace(
    'Protected settings: Google Drive unlink/change ke liye '
    '30-second wait + current Admin password verification mandatory hai.',
    'Protected settings: Google Drive, Firebase aur Google Cloud '
    'connection change/remove ke liye 30-second wait + current '
    'Admin password verification mandatory hai.',
    1,
)

ui_anchor = '''                      const SizedBox(height: 14),
                      const _AdvancedStudentUidSettingsPanel(),
'''

ui_add = '''                      const SizedBox(height: 14),

                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.local_fire_department_rounded, color: Colors.orangeAccent),
                          title: const Text('Firebase Connection'),
                          subtitle: Text('Active project: ${WindowsFirebaseConnection.projectId}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => const WindowsFirebaseSetupScreen(protectCurrent: true),
                          )),
                        ),
                      ),
                      const SizedBox(height: 14),

                      _windowsExternalConnectionCard(
                        type: 'google_cloud',
                        title: 'Google Cloud Console',
                        description:
                            'Windows app ke liye Google Cloud Console project link save karein.',
                        icon: Icons.cloud_queue_rounded,
                        accent: const Color(0xFF4DA3FF),
                        controller: _googleCloudConsoleLink,
                        linkedValue: _linkedGoogleCloudConsoleLink,
                        editing: _editingGoogleCloudConsoleLink,
                        hint: 'https://console.cloud.google.com/...',
                      ),

                      const SizedBox(height: 14),
                      const _AdvancedStudentUidSettingsPanel(),
'''

if ui_anchor not in text:
    raise SystemExit(
        'Windows connection UI patch point missing: '
        'Advanced Settings UID panel anchor changed.'
    )

text = text.replace(
    ui_anchor,
    ui_add,
    1,
)

text = "import 'windows_firebase_connection.dart';\n" + prefix + text + suffix
# Check declarations and connection methods are inside the same state, before writing.
state = text[text.index('class _AdvancedSettingsScreenState'):text.index('class _AdvancedStudentUidSettingsPanel')]
for marker in ['final _firebaseConnectionLink', 'final _googleCloudConsoleLink',
               'Future<void> _loadWindowsExternalConnectionLinks', 'WindowsFirebaseSetupScreen(protectCurrent: true)']:
    if marker not in state:
        raise SystemExit('Windows settings patch incomplete: ' + marker)
if "import 'dart:html' as html;" in text:
    raise SystemExit('Browser import remains')
# Enforce the same admin claim at legacy dashboard login entry points too.
text = re.sub(r'FirebaseAuth\.instance\s*\.signInWithEmailAndPassword',
              'WindowsFirebaseConnection.signInAdmin', text)
out.write_text(text, encoding='utf-8')
print('Generated Windows-only dashboard; website source unchanged:', out)
