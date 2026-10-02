import 'dart:async';
import 'windows_admin_sidebar.dart';
import 'windows_monthly_attendance.dart';
import 'windows_exam_service.dart';
import 'windows_ui_localization.dart';
import 'windows_preferences_reset.dart';
import 'windows_school_operations.dart';
import 'windows_staff_payroll.dart';
import 'windows_school_identity.dart';
import 'windows_document_templates.dart';
import 'windows_platform_client.dart';
import 'dart:io';
import 'dart:math';
import 'windows_settings_panel.dart';
import 'windows_local_session.dart';
import 'windows_local_settings.dart';
import 'windows_connection_center.dart';
import 'windows_service_status.dart';
import 'windows_backend_bridge.dart';
import 'windows_sync_engine.dart';
import 'windows_app_restart.dart';
import 'dart:convert';
import 'windows_html_shim.dart' as html;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'windows_local_firestore.dart';
import 'windows_local_auth.dart';
import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'windows_mobile_scanner_shim.dart';



// ============================================================
// WINDOWS LANGUAGE / SCHOOL IDENTITY / QR HELPERS
// ============================================================

/// Single source of truth for the Google Apps Script connection on Windows.
/// Advanced Settings saves Google connection in WindowsExternalConnections,
/// so Windows feature screens must NOT read the old Firestore
/// school_config/google_drive_account document.
Future<String> _windowsGoogleScriptUrl({bool required = true}) {
  return WindowsConnectionCenter.googleScriptUrl(required: required);
}

String _windowsLanguage() => WindowsUiLanguage.current;
void _setWindowsLanguage(String value) => WindowsUiLanguage.change(value);
String windowsTr(String key) => WindowsUiLanguage.translate(const {
  'dashboard': 'Dashboard', 'students': 'Student Records', 'fees': 'Fees Collection',
  'exam': 'Exam Center', 'teachers': 'Teachers', 'expenses': 'School Expenses',
  'attendance': 'Attendance', 'templates': 'Templates', 'settings': 'Settings',
  'schoolSettings': 'School Settings', 'entry': 'Entry', 'exit': 'Exit',
}[key] ?? key);

String _windowsStableHash(String input) {
  var hash = 0xcbf29ce484222325;
  for (final unit in utf8.encode(input)) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

Future<String> _windowsActiveSchoolProfileId() async {
  final active = FirebaseFirestore.instance.activeProfileId.trim();
  if (active.isNotEmpty && active != 'unbound') {
    return active;
  }

  final snapshot = await WindowsConnectionCenter.reload();
  return 'VS-${_windowsStableHash('${snapshot.firebaseProjectId}|${snapshot.googleScriptUrl}')}';
}

Future<Map<String, dynamic>> _windowsSchoolLocationData() async {
  try {
    final doc = await FirebaseFirestore.instance
        .collection('school_settings')
        .doc('school_location')
        .get();
    return doc.data() ?? <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

Future<String> _windowsEnsurePersonLinkToken({
  required String collection,
  required String documentId,
  required Map<String, dynamic> data,
}) async {
  final person = await SchoolPersonIdentity.ensure(collection,documentId);
  if(data['name']!=null && data['name']!=person['name'])throw StateError('School record changed. Refresh the directory.');
  return person['mobileLinkToken'].toString();
}

Future<String> _windowsBuildPersonQrPayload({
  required String type,
  required String collection,
  required String documentId,
  required Map<String, dynamic> person,
}) async {
  final connections = await WindowsConnectionCenter.reload();
  final firebaseLink = connections.firebaseLink;
  final googleScriptUrl = connections.googleScriptUrl;
  final profileId = await _windowsActiveSchoolProfileId();
  final location = await _windowsSchoolLocationData();
  final token = await _windowsEnsurePersonLinkToken(
    collection: collection,
    documentId: documentId,
    data: person,
  );
  final payload = <String, dynamic>{
    'app': 'VIDYA_SAARTHI',
    'v': 2,
    'type': type,
    'schoolProfileId': profileId,
    'firebaseProjectId': connections.firebaseProjectId,
    'firebaseLink': firebaseLink,
    'googleScriptUrl': googleScriptUrl,
    'personId': documentId,
    'linkToken': token,
    'name': person['name']?.toString() ?? '',
    'class': person['class']?.toString() ?? '',
    'rollNo': person['rollNo']?.toString() ?? '',
    'teacherId': person['teacherId']?.toString() ?? '',
    'studentUid': person[_testStudentUidField]?.toString() ?? '',
    'schoolLat': location['latitude'],
    'schoolLng': location['longitude'],
    'attendanceRadiusMeters': location['radiusMeters'] ?? 200,
  };
  return jsonEncode(payload);
}

Map<String, dynamic>? _windowsParsePersonQr(String raw) {
  final clean = raw.trim();
  if (clean.isEmpty) return null;
  try {
    final decoded = jsonDecode(clean);
    if (decoded is Map && decoded['app'] == 'VIDYA_SAARTHI') {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {}

  // Legacy Student ID card fallback.
  if (clean.contains('SVN_STUDENT_CARD') ||
      clean.contains('VIDYA_SAARTHI_STUDENT_CARD')) {
    final out = <String, dynamic>{
      'app': 'VIDYA_SAARTHI',
      'v': 1,
      'type': 'student',
    };
    for (final line in clean.split(RegExp(r'\r?\n'))) {
      final value = line.trim();
      if (value.toLowerCase().startsWith('record id:')) {
        out['personId'] = value.substring('record id:'.length).trim();
      }
      if (value.toLowerCase().startsWith('student uid:')) {
        out['studentUid'] = value.substring('student uid:'.length).trim();
      }
    }
    return out['personId']?.toString().isNotEmpty == true ? out : null;
  }
  return null;
}

Future<({double latitude, double longitude})> _windowsCurrentPosition() async {
  const script = r'''$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Devices.Geolocation.Geolocator,Windows.Devices.Geolocation,ContentType=WindowsRuntime] | Out-Null
$locator = New-Object Windows.Devices.Geolocation.Geolocator
$locator.DesiredAccuracyInMeters = 20
$op = $locator.GetGeopositionAsync()
$asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object {
    $_.Name -eq 'AsTask' -and
    $_.IsGenericMethodDefinition -and
    $_.GetGenericArguments().Count -eq 1 -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  } |
  Select-Object -First 1
if ($null -eq $asTaskMethod) {
  throw 'Windows Runtime AsTask method unavailable.'
}
$task = $asTaskMethod.MakeGenericMethod([Windows.Devices.Geolocation.Geoposition]).Invoke($null, [object[]]@($op))
$pos = $task.GetAwaiter().GetResult().Coordinate.Point.Position
Write-Output ($pos.Latitude.ToString([System.Globalization.CultureInfo]::InvariantCulture) + "," + $pos.Longitude.ToString([System.Globalization.CultureInfo]::InvariantCulture))''';
  final result = await Process.run(
    'powershell.exe',
    const ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
  ).timeout(const Duration(seconds: 20));
  if (result.exitCode != 0) {
    throw StateError('Windows Location access fail: ${result.stderr}');
  }
  final parts = result.stdout.toString().trim().split(',');
  if (parts.length != 2) throw StateError('Windows GPS response invalid hai.');
  final lat = double.tryParse(parts[0]);
  final lng = double.tryParse(parts[1]);
  if (lat == null || lng == null) throw StateError('Windows GPS coordinates invalid hain.');
  return (latitude: lat, longitude: lng);
}

({double latitude, double longitude})? _windowsParseCoordinates(String raw) {
  final values = RegExp(r'[-+]?(?:\d+(?:\.\d+)?|\.\d+)')
      .allMatches(raw)
      .map((match) => double.tryParse(match.group(0)!))
      .whereType<double>()
      .toList();

  for (var index = 0; index + 1 < values.length; index++) {
    final latitude = values[index];
    final longitude = values[index + 1];
    if (latitude >= -90 && latitude <= 90 &&
        longitude >= -180 && longitude <= 180) {
      return (latitude: latitude, longitude: longitude);
    }
  }

  return null;
}

Future<void> _openGoogleMapsForSchoolLocation(String query) async {
  final cleanQuery = query.trim().isEmpty ? 'school' : query.trim();
  final uri = Uri.https(
    'www.google.com',
    '/maps/search/',
    <String, String>{
      'api': '1',
      'query': cleanQuery,
    },
  );

  await Process.start('explorer.exe', <String>[uri.toString()]);
}

double _windowsDistanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const earth = 6371000.0;
  double rad(double value) => value * pi / 180.0;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  return earth * 2 * atan2(sqrt(a), sqrt(1 - a));
}

// ============================================================
// WINDOWS SECTION PASSWORD LOCKS
// These passwords are independent from the Firebase app-login password and
// from the existing Local Settings Lock.
// ============================================================

const String _windowsAdminSectionLock = 'admin_section';
const String _windowsStudentRecordsLock = 'student_records';
const String _windowsFeesCollectionLock = 'fees_collection';
const String _windowsSchoolExpensesLock = 'school_expenses';
const String _windowsAttendanceLock = 'attendance';

class _WindowsSectionLockDefinition {
  const _WindowsSectionLockDefinition({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final String key;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
}

const List<_WindowsSectionLockDefinition> _windowsSectionLockDefinitions = [
  _WindowsSectionLockDefinition(
    key: _windowsAdminSectionLock,
    title: 'Admin Section',
    subtitle: 'App open hone ke baad full management panel unlock karein.',
    icon: Icons.admin_panel_settings_rounded,
    color: Color(0xFF00D9A5),
  ),
  _WindowsSectionLockDefinition(
    key: _windowsStudentRecordsLock,
    title: 'Student Records',
    subtitle: 'Students, profiles aur ID cards ko protect karein.',
    icon: Icons.people_alt_rounded,
    color: Color(0xFF00A884),
  ),
  _WindowsSectionLockDefinition(
    key: _windowsFeesCollectionLock,
    title: 'Fees Collection',
    subtitle: 'Fee collection, receipts aur dues ko protect karein.',
    icon: Icons.payments_rounded,
    color: Colors.greenAccent,
  ),
  _WindowsSectionLockDefinition(
    key: _windowsSchoolExpensesLock,
    title: 'School Expenses',
    subtitle: 'Expense entry, ledger aur reports ko protect karein.',
    icon: Icons.account_balance_wallet_rounded,
    color: Colors.amberAccent,
  ),
  _WindowsSectionLockDefinition(
    key: _windowsAttendanceLock,
    title: 'Attendance',
    subtitle: 'Student/Teacher QR attendance ko protect karein.',
    icon: Icons.fact_check_rounded,
    color: Color(0xFF69C2FF),
  ),
];

class WindowsSectionLocks {
  WindowsSectionLocks._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static String _passwordKey(String sectionKey) {
    return 'vidya_saarthi_windows_section_password_v1_$sectionKey';
  }

  static String _enabledKey(String sectionKey) {
    return 'vidya_saarthi_windows_section_password_enabled_v1_$sectionKey';
  }

  static Future<bool> configured(String sectionKey) async {
    final value = await _secure.read(key: _passwordKey(sectionKey));
    return value?.trim().isNotEmpty ?? false;
  }

  static Future<bool> enabled(String sectionKey) async {
    if (!await configured(sectionKey)) return false;

    final value = await _secure.read(key: _enabledKey(sectionKey));
    // A configured lock without an old enabled flag remains protected.
    return value == null || value == 'true';
  }

  static Future<bool> verify({
    required String sectionKey,
    required String password,
  }) async {
    final stored = await _secure.read(key: _passwordKey(sectionKey));
    return stored != null && stored.isNotEmpty && stored == password;
  }

  static Future<void> addPassword({
    required String sectionKey,
    required String password,
  }) async {
    _validatePassword(password);

    await _secure.write(
      key: _passwordKey(sectionKey),
      value: password,
    );
    // Adding a password turns that section lock ON by default.
    await _secure.write(
      key: _enabledKey(sectionKey),
      value: 'true',
    );
  }

  static Future<void> changePassword({
    required String sectionKey,
    required String currentPassword,
    required String newPassword,
  }) async {
    final storedPassword = await _secure.read(
      key: _passwordKey(sectionKey),
    );

    if (storedPassword == null || storedPassword.isEmpty) {
      throw StateError('Pehle section password add karein.');
    }

    if (storedPassword != currentPassword) {
      throw StateError('Current section password galat hai.');
    }

    _validatePassword(newPassword);
    await _secure.write(
      key: _passwordKey(sectionKey),
      value: newPassword,
    );
    await _secure.write(
      key: _enabledKey(sectionKey),
      value: 'true',
    );
  }

  static Future<void> setEnabled({
    required String sectionKey,
    required bool value,
  }) async {
    if (value && !(await configured(sectionKey))) {
      throw StateError('Pehle section password add karein.');
    }

    await _secure.write(
      key: _enabledKey(sectionKey),
      value: value ? 'true' : 'false',
    );
  }

  static void _validatePassword(String password) {
    if (password.trim().length < 6) {
      throw const FormatException(
        'Section password kam se kam 6 characters ka hona chahiye.',
      );
    }
  }
}

const String _windowsAcademicYearRolloverMonthKey =
    'vidya_saarthi_windows_academic_year_rollover_month_v1';

class WindowsAcademicYearSettings {
  WindowsAcademicYearSettings._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static int _normalizeMonth(int month) => month == 4 ? 4 : 1;

  static Future<int> load() async {
    try {
      final raw = await _secure.read(
        key: _windowsAcademicYearRolloverMonthKey,
      );
      return _normalizeMonth(int.tryParse(raw ?? '') ?? 1);
    } catch (_) {
      return 1;
    }
  }

  static Future<void> save(int month) async {
    await _secure.write(
      key: _windowsAcademicYearRolloverMonthKey,
      value: _normalizeMonth(month).toString(),
    );
  }

  static int startYear(DateTime date, int rolloverMonth) {
    return date.month >= _normalizeMonth(rolloverMonth)
        ? date.year
        : date.year - 1;
  }

  static String format(DateTime date, int rolloverMonth) {
    final start = startYear(date, rolloverMonth);
    final next = ((start + 1) % 100).toString().padLeft(2, '0');
    return '$start-$next';
  }
}

const String _windowsLicenseKeyStorageKey =
    'vidya_saarthi_windows_license_key_v1';
const String _windowsLicenseStatusStorageKey =
    'vidya_saarthi_windows_license_status_v1';
const String _windowsLicenseSavedAtStorageKey =
    'vidya_saarthi_windows_license_saved_at_v1';

/// Local license-key store for the Windows-only licensing module.
///
/// The key is kept in secure storage. Live central-Firebase/website
/// verification is intentionally a separate next step so a school Firebase
/// connection is never treated as the product-license server.
class WindowsLicenseStore {
  WindowsLicenseStore._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static Future<Map<String, String>> load() async {
    try {
      return <String, String>{
        'key': (await _secure.read(key: _windowsLicenseKeyStorageKey) ?? '')
            .trim(),
        'status':
            (await _secure.read(key: _windowsLicenseStatusStorageKey) ?? '')
                .trim(),
        'savedAt':
            (await _secure.read(key: _windowsLicenseSavedAtStorageKey) ?? '')
                .trim(),
      };
    } catch (_) {
      return const <String, String>{};
    }
  }

  static Future<void> save(String key) async {
    final normalized = key.trim();
    await WindowsPlatformClient.instance.refresh();
    await WindowsPlatformClient.instance.activate(normalized);
    await _secure.write(key: _windowsLicenseKeyStorageKey, value: normalized);
    await _secure.write(
      key: _windowsLicenseStatusStorageKey,
      value: 'active',
    );
    await _secure.write(
      key: _windowsLicenseSavedAtStorageKey,
      value: DateTime.now().toIso8601String(),
    );
  }

  static Future<void> clear() async {
    await _secure.delete(key: _windowsLicenseKeyStorageKey);
    await _secure.delete(key: _windowsLicenseStatusStorageKey);
    await _secure.delete(key: _windowsLicenseSavedAtStorageKey);
  }
}

class WindowsLicenseSettingsPanel extends StatefulWidget {
  const WindowsLicenseSettingsPanel({super.key});

  @override
  State<WindowsLicenseSettingsPanel> createState() =>
      _WindowsLicenseSettingsPanelState();
}

class _WindowsLicenseSettingsPanelState
    extends State<WindowsLicenseSettingsPanel> {
  final _licenseKey = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String _savedKey = '';
  String _status = '';
  String _savedAt = '';

  @override
  void initState() {
    super.initState();
    WindowsPlatformClient.instance.state.addListener(_licenseChanged);
    _load();
  }

  void _licenseChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WindowsPlatformClient.instance.state.removeListener(_licenseChanged);
    _licenseKey.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final data = await WindowsLicenseStore.load();
    if (!mounted) return;
    setState(() {
      _savedKey = data['key'] ?? '';
      _status = data['status'] ?? '';
      _savedAt = data['savedAt'] ?? '';
      _loading = false;
    });
  }

  String _maskedKey(String key) {
    if (key.length <= 8) return key;
    return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
  }

  String _statusText() {
    if (_savedKey.isEmpty) return 'License Key not added';
    final state = WindowsPlatformClient.instance.state.value;
    if (state.allowed && state.status == 'licensed') return 'License Active';
    if (!state.allowed) return 'License Expired';
    return 'Key saved — online verification pending';
  }

  Color _statusColor() {
    if (_savedKey.isEmpty) return Colors.white54;
    final state = WindowsPlatformClient.instance.state.value;
    if (state.allowed && state.status == 'licensed') return const Color(0xFF00D9A5);
    if (!state.allowed) return Colors.redAccent;
    return Colors.orangeAccent;
  }

  Future<void> _save() async {
    if (_saving) return;
    final key = _licenseKey.text.trim();
    if (key.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Valid Licensing Key daalein.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await WindowsLicenseStore.save(key);
      if (!mounted) return;
      setState(() {
        _savedKey = key;
        _status = 'active';
        _savedAt = DateTime.now().toIso8601String();
        _saving = false;
        _licenseKey.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF00A884),
          content: Text('Licensing Key secure storage me save ho gayi.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Licensing Key save error: $e'),
        ),
      );
    }
  }

  Future<void> _clear() async {
    if (_saving || _savedKey.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF172229),
        title: const Text('Remove Licensing Key'),
        content: const Text(
          'Saved key is device se remove ho jayegi. Website verification record delete nahi hoga.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await WindowsLicenseStore.clear();
    if (!mounted) return;
    setState(() {
      _savedKey = '';
      _status = '';
      _savedAt = '';
    });
  }

  String _savedAtText() {
    final date = DateTime.tryParse(_savedAt);
    if (date == null) return 'Not saved yet';
    return date.toLocal().toString().split('.').first;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(22),
          child: CircularProgressIndicator(color: Color(0xFF00A884)),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.vpn_key_rounded, color: Colors.orangeAccent),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Licensing Key',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                _statusText(),
                style: TextStyle(
                  color: _statusColor(),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Adobe-style activation ke liye key yahan add hogi. School Firebase aur Google Drive connection isse alag rahega.',
            style: TextStyle(color: Colors.white60, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 14),
          if (_savedKey.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F191F),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_rounded,
                      color: Color(0xFF00D9A5), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Saved Key',
                            style:
                                TextStyle(color: Colors.white38, fontSize: 10)),
                        const SizedBox(height: 3),
                        SelectableText(
                          _maskedKey(_savedKey),
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Saved: ${_savedAtText()}',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: WindowsUiLanguage.translate('Remove key'),
                    onPressed: _saving ? null : _clear,
                    icon: const Icon(Icons.delete_outline_rounded,
                        color: Colors.orangeAccent),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _licenseKey,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: _savedKey.isEmpty
                  ? 'Enter Licensing Key'
                  : 'Replace Licensing Key',
              prefixIcon: const Icon(Icons.key_rounded),
              filled: true,
              fillColor: const Color(0xFF0F191F),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00A884),
                foregroundColor: Colors.white,
              ),
              icon: _saving
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.verified_user_rounded),
              label: Text(_saving ? 'Saving...' : 'Save Licensing Key'),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Keys are verified by the developer platform and bound to this school.',
            style: TextStyle(color: Colors.orangeAccent, fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

Future<bool> _requireWindowsSectionPassword(
  BuildContext context,
  String sectionKey,
  String sectionTitle,
) async {
  if (!await WindowsSectionLocks.enabled(sectionKey)) return true;
  if (!context.mounted) return false;

  final controller = TextEditingController();
  String? error;
  bool verifying = false;

  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> verifyPassword() async {
            if (verifying) return;

            final password = controller.text;
            if (password.isEmpty) {
              setDialogState(() => error = 'Password required hai.');
              return;
            }

            setDialogState(() {
              verifying = true;
              error = null;
            });

            final valid = await WindowsSectionLocks.verify(
              sectionKey: sectionKey,
              password: password,
            );

            if (!dialogContext.mounted) return;
            if (valid) {
              Navigator.of(dialogContext).pop(true);
              return;
            }

            setDialogState(() {
              verifying = false;
              error = 'Galat $sectionTitle password.';
            });
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF172229),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: Row(
              children: [
                const Icon(
                  Icons.lock_rounded,
                  color: Color(0xFF00D9A5),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$sectionTitle Password',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                enabled: !verifying,
                onSubmitted: (_) => verifyPassword(),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Enter $sectionTitle Password',
                  labelStyle: const TextStyle(color: Colors.white54),
                  errorText: error,
                  prefixIcon: const Icon(
                    Icons.password_rounded,
                    color: Color(0xFF00A884),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF0F191F),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: verifying
                    ? null
                    : () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: verifying ? null : verifyPassword,
                icon: verifying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.lock_open_rounded, size: 17),
                label: const Text('Unlock'),
              ),
            ],
          );
        },
      );
    },
  );

  controller.dispose();
  return result == true;
}


// ============================================================
// VIDYA SAARTHI WEB BOOTSTRAP BACKGROUND
// ============================================================
final bool _vidyaWebBootstrapBackgroundApplied = (() {
  try {
    html.document.documentElement?.style.backgroundColor = '#06171D';
    html.document.body?.style.backgroundColor = '#06171D';
  } catch (_) {}
  return true;
})();


// ============================================================
// PORTAL SESSION + 30 MINUTE INACTIVITY
// Keeps login across browser reload. Any click/tap refreshes 30 minutes.
// ============================================================
const Duration _portalInactivityLimit = Duration(minutes: 30);
const String _portalSessionRoleKey = 'saarthi_portal_role_v1';
const String _portalSessionStudentIdKey = 'saarthi_portal_student_id_v1';
const String _portalSessionStudentClassKey = 'saarthi_portal_student_class_v1';
const String _portalSessionExpiryKey = 'saarthi_portal_expiry_v1';

void _savePortalSession({
  required String role,
  String? studentId,
  String? studentClass,
}) {
  try {
    final storage = html.window.localStorage;
    storage[_portalSessionRoleKey] = role;

    if (role == 'student') {
      storage[_portalSessionStudentIdKey] = studentId?.trim() ?? '';
      storage[_portalSessionStudentClassKey] = studentClass?.trim() ?? '';
    } else {
      storage.remove(_portalSessionStudentIdKey);
      storage.remove(_portalSessionStudentClassKey);
    }

    storage[_portalSessionExpiryKey] =
        DateTime.now().add(_portalInactivityLimit).millisecondsSinceEpoch.toString();
  } catch (e) {
    debugPrint('Portal session save error: $e');
  }
}

void _touchPortalSession() {
  try {
    final storage = html.window.localStorage;
    final role = storage[_portalSessionRoleKey]?.trim() ?? '';
    if (role.isEmpty) return;

    storage[_portalSessionExpiryKey] =
        DateTime.now().add(_portalInactivityLimit).millisecondsSinceEpoch.toString();
  } catch (e) {
    debugPrint('Portal session refresh error: $e');
  }
}

void _clearPortalSession() {
  try {
    final storage = html.window.localStorage;
    storage.remove(_portalSessionRoleKey);
    storage.remove(_portalSessionStudentIdKey);
    storage.remove(_portalSessionStudentClassKey);
    storage.remove(_portalSessionExpiryKey);
  } catch (e) {
    debugPrint('Portal session clear error: $e');
  }
}

String _savedPortalRole() {
  try {
    return html.window.localStorage[_portalSessionRoleKey]?.trim() ?? '';
  } catch (_) {
    return '';
  }
}

String _savedPortalStudentId() {
  try {
    return html.window.localStorage[_portalSessionStudentIdKey]?.trim() ?? '';
  } catch (_) {
    return '';
  }
}

String _savedPortalStudentClass() {
  try {
    return html.window.localStorage[_portalSessionStudentClassKey]?.trim() ?? '';
  } catch (_) {
    return '';
  }
}

int _portalSessionRemainingSeconds() {
  try {
    final raw = html.window.localStorage[_portalSessionExpiryKey]?.trim() ?? '';
    final expiryMs = int.tryParse(raw);
    if (expiryMs == null) return 0;

    final remainingMs =
        expiryMs - DateTime.now().millisecondsSinceEpoch;
    if (remainingMs <= 0) return 0;

    final seconds = (remainingMs / 1000).ceil();
    return seconds.clamp(0, _portalInactivityLimit.inSeconds).toInt();
  } catch (_) {
    return 0;
  }
}

String _formatPortalTimer(int totalSeconds) {
  final safe = totalSeconds.clamp(0, _portalInactivityLimit.inSeconds).toInt();
  final minutes = safe ~/ 60;
  final seconds = safe % 60;
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

Widget _buildPortalSessionTimer(ValueNotifier<int> secondsListenable) {
  return Tooltip(
    message: 'Auto logout after 30 minutes of inactivity',
    child: ValueListenableBuilder<int>(
      valueListenable: secondsListenable,
      builder: (context, seconds, _) {
        final isLow = seconds <= 300;
        final color = isLow ? Colors.orangeAccent : const Color(0xFF00D9A5);

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          decoration: BoxDecoration(
            color: color.withOpacity(0.10),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: color.withOpacity(0.24)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.timer_outlined, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                _formatPortalTimer(seconds),
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}


// ============================================================
// STUDENT NOTICE NOTIFICATION (WEB / PWA)
// Student portal requires notification permission before access.
// New Firestore notices show as browser/device notifications while
// the site/PWA session is available. Existing notices are not re-spammed.
// ============================================================
bool _browserNotificationSupported() {
  try {
    return html.Notification.supported;
  } catch (_) {
    return false;
  }
}

bool _browserNotificationGranted() {
  try {
    return html.Notification.supported &&
        html.Notification.permission == 'granted';
  } catch (_) {
    return false;
  }
}

Future<bool> _requestBrowserNotificationPermission() async {
  try {
    if (!html.Notification.supported) return false;

    final current = html.Notification.permission ?? 'default';
    if (current == 'granted') return true;
    if (current == 'denied') return false;

    final result = await html.Notification.requestPermission();
    return result == 'granted';
  } catch (e) {
    debugPrint('Notification permission error: $e');
    return false;
  }
}

String _studentNoticeStorageKey(String studentClass, String studentId) {
  final raw = '${studentClass}_$studentId'
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  return 'vidya_saarthi_notice_last_$raw';
}

int _readLastStudentNoticeTimestamp(String studentClass, String studentId) {
  try {
    final raw = html.window.localStorage[
          _studentNoticeStorageKey(studentClass, studentId)
        ] ??
        '';
    return int.tryParse(raw) ?? 0;
  } catch (_) {
    return 0;
  }
}

void _writeLastStudentNoticeTimestamp(
  String studentClass,
  String studentId,
  int timestamp,
) {
  try {
    html.window.localStorage[
      _studentNoticeStorageKey(studentClass, studentId)
    ] = timestamp.toString();
  } catch (e) {
    debugPrint('Notice timestamp save error: $e');
  }
}

void _showStudentBrowserNotification({
  required String noticeId,
  required String title,
  required String description,
  required String category,
}) {
  try {
    if (!_browserNotificationGranted()) return;

    final body = description.trim().isEmpty
        ? 'School notice open karke details dekhein.'
        : description.trim();

    final notification = html.Notification(
      'Vidya Saarthi • ${category.trim().isEmpty ? 'Notice' : category.trim()}',
      body: '$title\n$body',
      tag: 'vidya_saarthi_notice_$noticeId',
    );

    notification.onClick.listen((_) {
      notification.close();
    });
  } catch (e) {
    debugPrint('Browser notification show error: $e');
  }
}


// ============================================================
// TEST STUDENT UID HELPERS
// Test-only fields/config. Final production UID can be promoted later.
// ============================================================
const String _testStudentUidField = 'studentUidTest';
const String _testStudentUidConfigDocId = 'student_uid_test_config';

DocumentReference<Map<String, dynamic>> _testStudentUidConfigRef() {
  return FirebaseFirestore.instance
      .collection('fee_settings')
      .doc(_testStudentUidConfigDocId);
}

String _normalizeIdentityPart(dynamic value) {
  return (value?.toString() ?? '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ');
}

Map<String, dynamic> _parseTestUidPattern(String input) {
  final value = input.trim();
  final match = RegExp(r'^(.*?)(\d+)$').firstMatch(value);

  if (match == null) {
    throw const FormatException(
      'UID format ke end me number hona chahiye. Example: TEST-000001',
    );
  }

  final prefix = match.group(1) ?? '';
  final numberText = match.group(2) ?? '';

  if (prefix.trim().isEmpty || numberText.isEmpty) {
    throw const FormatException(
      'UID format sahi nahi hai. Example: TEST-000001',
    );
  }

  final startNumber = int.tryParse(numberText);
  if (startNumber == null || startNumber < 0) {
    throw const FormatException('UID starting number invalid hai.');
  }

  return {
    'prefix': prefix,
    'padding': numberText.length,
    'startNumber': startNumber,
  };
}

String _formatTestStudentUid(String prefix, int padding, int number) {
  return '$prefix${number.toString().padLeft(padding, '0')}';
}

Future<Map<String, dynamic>> _loadTestStudentUidConfig() async {
  final doc = await _testStudentUidConfigRef().get();
  return doc.data() ?? <String, dynamic>{};
}

Future<String?> _ensureTestStudentUid(
  DocumentReference<Map<String, dynamic>> studentRef,
) async {
  return FirebaseFirestore.instance.runTransaction<String?>((transaction) async {
    final configRef = _testStudentUidConfigRef();
    final configSnap = await transaction.get(configRef);
    final config = configSnap.data() ?? <String, dynamic>{};

    if (config['masterEnabled'] != true) return null;

    final studentSnap = await transaction.get(studentRef);
    if (!studentSnap.exists) return null;

    final student = studentSnap.data() ?? <String, dynamic>{};
    final existing = student[_testStudentUidField]?.toString().trim() ?? '';
    if (existing.isNotEmpty) return existing;

    final prefix = config['prefix']?.toString() ?? 'TEST-';
    final padding = (config['padding'] as num?)?.toInt() ?? 6;
    final nextNumber = (config['nextNumber'] as num?)?.toInt() ?? 1;
    final uid = _formatTestStudentUid(prefix, padding, nextNumber);

    transaction.update(studentRef, {
      _testStudentUidField: uid,
      'studentUidTestAssignedAt': FieldValue.serverTimestamp(),
    });

    transaction.set(
      configRef,
      {
        'nextNumber': nextNumber + 1,
        'lastIssuedUid': uid,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    return uid;
  });
}

String _compositeStudentFeeIdentity(Map<String, dynamic> student) {
  final raw = [
    _normalizeIdentityPart(student['name']),
    _normalizeIdentityPart(student['parentName']),
    _normalizeIdentityPart(student['dateOfBirth']),
    _normalizeIdentityPart(student['rollNo']),
    _normalizeIdentityPart(student['parentContact']),
  ].join('|');

  final encoded = base64UrlEncode(utf8.encode(raw)).replaceAll('=', '');
  return 'CMP-$encoded';
}

String _feeIdentityForStudent(
  Map<String, dynamic> student,
  Map<String, dynamic> uidConfig,
) {
  final uid = student[_testStudentUidField]?.toString().trim() ?? '';
  final useUid = uidConfig['masterEnabled'] == true &&
      uidConfig['feesEnabled'] == true &&
      uid.isNotEmpty;

  if (useUid) return 'UID-$uid';
  return _compositeStudentFeeIdentity(student);
}

// ============================================================
// SCHOOL PROFILE / BRANDING CACHE
// Master copy is saved in Google Drive through Apps Script.
// Firestore keeps a fast admin-side cache so dashboard/PDF UI is instant.
// ============================================================

const String _schoolProfileCacheDocId = 'school_profile_cache';

// Memory cache keeps School Settings / branding instant inside the current session.
Map<String, dynamic>? _schoolProfileMemoryCache;
String? _schoolProfileScriptUrlMemoryCache;

Map<String, dynamic> _defaultSchoolProfile() => <String, dynamic>{
      // Fresh installations must start unbound. The school identity is filled
      // only after the administrator saves the selected school's profile.
      'schoolName': '',
      'principalName': '',
      'schoolContactNo': '',
      'logoUrl': '',
      'logoFileId': '',
      'sealUrl': '',
      'sealFileId': '',
      'principalSignatureUrl': '',
      'principalSignatureFileId': '',
    };

DocumentReference<Map<String, dynamic>> _schoolProfileCacheRef() {
  return FirebaseFirestore.instance
      .collection('school_config')
      .doc(_schoolProfileCacheDocId);
}

Map<String, dynamic> _mergeSchoolProfile(Map<String, dynamic>? raw) {
  return <String, dynamic>{
    ..._defaultSchoolProfile(),
    ...?raw,
  };
}

Future<String> _schoolProfileScriptUrl() async {
  final cachedUrl = _schoolProfileScriptUrlMemoryCache?.trim() ?? '';
  if (cachedUrl.isNotEmpty) return cachedUrl;

  final url = await _windowsGoogleScriptUrl();

  _schoolProfileScriptUrlMemoryCache = url;
  return url;
}

Future<Map<String, dynamic>> _schoolProfileBackendPost(
  Map<String, dynamic> body,
) async {
  final response = await WindowsBackendBridge.post(
    Uri.parse(await _schoolProfileScriptUrl()),
    headers: const {'Content-Type': 'text/plain;charset=utf-8'},
    body: jsonEncode(body),
  );

  if (response.statusCode != 200) {
    throw Exception('Google backend error: ${response.statusCode}');
  }

  final decoded = jsonDecode(response.body);
  if (decoded is! Map) {
    throw Exception('Google backend response invalid hai.');
  }

  final result = Map<String, dynamic>.from(decoded);
  if (result['success'] != true) {
    throw Exception(result['message'] ?? 'Google backend operation failed');
  }

  return result;
}

Future<Map<String, dynamic>> _loadSchoolProfileCache() async {
  if (_schoolProfileMemoryCache != null) {
    return _mergeSchoolProfile(_schoolProfileMemoryCache);
  }

  try {
    final doc = await _schoolProfileCacheRef().get();
    final profile = _mergeSchoolProfile(doc.data());
    _schoolProfileMemoryCache = Map<String, dynamic>.from(profile);
    return profile;
  } catch (_) {
    final profile = _defaultSchoolProfile();
    _schoolProfileMemoryCache = Map<String, dynamic>.from(profile);
    return profile;
  }
}

Future<Map<String, dynamic>> _refreshSchoolProfileFromDrive() async {
  final result = await _schoolProfileBackendPost(
    const {'action': 'get_school_profile'},
  );

  final raw = result['profile'];
  final profile = raw is Map
      ? _mergeSchoolProfile(Map<String, dynamic>.from(raw))
      : _defaultSchoolProfile();

  _schoolProfileMemoryCache = Map<String, dynamic>.from(profile);

  await _schoolProfileCacheRef().set(
    {
      ...profile,
      'cachedAt': FieldValue.serverTimestamp(),
    },
    SetOptions(merge: true),
  );

  return profile;
}

Future<Map<String, dynamic>> _loadSchoolProfile({
  bool refreshFromDrive = false,
}) async {
  if (refreshFromDrive) {
    try {
      return await _refreshSchoolProfileFromDrive();
    } catch (e) {
      debugPrint('School profile Drive refresh warning: $e');
    }
  }
  return _loadSchoolProfileCache();
}

String _schoolName(Map<String, dynamic> profile) {
  final value = profile['schoolName']?.toString().trim() ?? '';
  return value;
}

String _principalName(Map<String, dynamic> profile) {
  final value = profile['principalName']?.toString().trim() ?? '';
  return value;
}

Future<Uint8List?> _downloadImageBytes(String url) async {
  final clean = url.trim();
  if (clean.isEmpty) return null;

  try {
    if (clean.startsWith('data:image/')) {
      return Uint8List.fromList(UriData.parse(clean).contentAsBytes());
    }
    final response = await http.get(Uri.parse(clean));
    if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
      return response.bodyBytes;
    }
  } catch (e) {
    debugPrint('Image download warning: $e');
  }
  return null;
}


Widget _windowsSchoolProfileImage(String source, {BoxFit fit = BoxFit.contain, required Widget fallback}) {
  if (source.startsWith('data:image/')) {
    try {
      return Image.memory(Uint8List.fromList(UriData.parse(source).contentAsBytes()),
          fit: fit, errorBuilder: (_, __, ___) => fallback);
    } catch (_) { return fallback; }
  }
  return Image.network(source, fit: fit, errorBuilder: (_, __, ___) => fallback);
}

// ============================================================
// EXAM CENTER MEMORY CACHE / PREFETCH
// Opens the page immediately while refreshing in background.
// ============================================================

Widget _windowsAdminModule(WindowsAdminPage page) => switch (page) {
  WindowsAdminPage.students => const AllStudentsListScreen(),
  WindowsAdminPage.fees => const FeesCollectionScreen(),
  WindowsAdminPage.exams => const ExamCenterScreen(),
  WindowsAdminPage.teachers => const TeachersDirectoryScreen(),
  WindowsAdminPage.salary => const StaffSalaryScreen(),
  WindowsAdminPage.support => const WindowsSupportScreen(),
  WindowsAdminPage.expenses => const WindowsSchoolExpensesScreen(),
  WindowsAdminPage.attendance => const SchoolAttendanceOverview(),
  WindowsAdminPage.templates => const SchoolDocumentTemplatesScreen(),
  WindowsAdminPage.dashboard => const AdminDashboardScreen(),
};
String? _windowsAdminModuleLock(WindowsAdminPage page) => switch (page) {
  WindowsAdminPage.students => _windowsStudentRecordsLock,
  WindowsAdminPage.fees => _windowsFeesCollectionLock,
  WindowsAdminPage.expenses => _windowsSchoolExpensesLock,
  WindowsAdminPage.attendance => _windowsAttendanceLock,
  _ => null,
};
String _windowsAdminModuleTitle(WindowsAdminPage page) => WindowsAdminSidebar.entries.firstWhere((e) => e.$1 == page).$2;
Widget _windowsSharedAdminSidebar(BuildContext context, {required ValueChanged<WindowsAdminPage> onSelected,
  required VoidCallback onLogout, VoidCallback? onAnalytics}) => WindowsAdminSidebar(
    onSelected: onSelected, onLogout: onLogout,
    header: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _schoolProfileCacheRef().snapshots(), builder: (ctx, snapshot) {
        final profile = _mergeSchoolProfile(snapshot.data?.data());
        final logo = profile['logoUrl']?.toString() ?? '';
        return Padding(padding: const EdgeInsets.all(12), child: Material(
          color: const Color(0xFF123D38), borderRadius: BorderRadius.circular(18),
          child: ListTile(onTap: onAnalytics,
            leading: SizedBox(width: 50, height: 50, child: logo.isEmpty
              ? const Icon(Icons.school_rounded, color: Color(0xFF00D9A5), size: 34)
              : _windowsSchoolProfileImage(logo, fallback: const Icon(Icons.school_rounded))),
            title: Text(_schoolName(profile), translate: false, maxLines: 2),
            subtitle: const Text('ADMIN NAVIGATION', style: TextStyle(color: Color(0xFF00D9A5), fontSize: 10)),
          )));
      }));
Future<void> _windowsConfirmLogout(BuildContext context) async {
  final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
    title: const Text('Logout Admin?'), content: const Text('Logout karne ke baad School Login screen dikhegi.'),
    actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Logout'))]));
  if (confirmed != true) return;
  _clearPortalSession();
  await WindowsLocalSession.logout();
  await FirebaseAuth.instance.signOut();
  if (context.mounted) Navigator.of(context).pushNamedAndRemoveUntil('/local-login', (_) => false);
}

class _ExamCenterSnapshot {
  const _ExamCenterSnapshot({
    required this.exams,
    required this.results,
    required this.studentCounts,
    required this.loadedAt,
  });

  final List<Map<String, dynamic>> exams;
  final List<Map<String, dynamic>> results;
  final Map<String, int> studentCounts;
  final DateTime loadedAt;
}

class _ExamCenterDataCache {
  static _ExamCenterSnapshot? snapshot;
  static Future<_ExamCenterSnapshot>? _inFlight;
  static String _profile = '';

  static Future<_ExamCenterSnapshot> refresh({bool force = false}) async {
    final profile = FirebaseFirestore.instance.activeProfileId;
    if (_profile != profile) { snapshot = null; _inFlight = null; _profile = profile; }
    final cached = snapshot;
    if (!force && cached != null) {
      final age = DateTime.now().difference(cached.loadedAt);
      if (age < const Duration(seconds: 45)) {
        return cached;
      }
    }

    if (_inFlight != null) return _inFlight!;

    final future = _fetch();
    _inFlight = future;

    try {
      final value = await future;
      if (_profile != profile) throw StateError('School changed. Refresh the exam screen.');
      snapshot = value;
      return value;
    } finally {
      if (_profile == profile) _inFlight = null;
    }
  }

  static Future<_ExamCenterSnapshot> _fetch() async {
    final result = await WindowsExamService.request({'action': 'list_exam_center'});
    if (result['success'] != true) {
      throw Exception(result['message'] ?? 'Exam Center load failed');
    }

    List<Map<String, dynamic>> convert(dynamic raw) => raw is List
        ? raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];

    final exams = convert(result['exams']);
    final results = convert(result['results']);

    final classes = exams
        .map((e) => e['studentClass']?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();

    final countEntries = await Future.wait<MapEntry<String, int>>(
      classes.map((className) async {
        try {
          final snapshot = await FirebaseFirestore.instance
              .collection('students_directory')
              .where('class', isEqualTo: className)
              .get();
          return MapEntry(className, snapshot.docs.length);
        } catch (_) {
          return MapEntry(className, 0);
        }
      }),
    );

    return _ExamCenterSnapshot(
      exams: exams,
      results: results,
      studentCounts: Map<String, int>.fromEntries(countEntries),
      loadedAt: DateTime.now(),
    );
  }
}


// ============================================================
// MAIN DASHBOARD
// Opens directly to School Portal.
// AI Chat / Chat history / AI navigation removed completely.
// ============================================================
class MainDashboardScreen extends StatelessWidget {
  const MainDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SchoolAdminLoginScreen();
  }
}

// ============================================================
// SCHOOL ADMIN / STUDENT LOGIN
// ============================================================
class SchoolAdminLoginScreen extends StatefulWidget {
  const SchoolAdminLoginScreen({super.key});

  @override
  State<SchoolAdminLoginScreen> createState() => _SchoolAdminLoginScreenState();
}

class _SchoolAdminLoginScreenState extends State<SchoolAdminLoginScreen> {
  bool _isAdminMode = true;
  bool _isRestoringSession = true;
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoggingIn = false;

  // QR scanner state - Student mode only.
  bool _showInlineScanner = false;
  bool _scanHandled = false;
  bool _isQrVerifying = false;
  String? _scanError;
  Map<String, dynamic>? _scannedStudentData;

  String _selectedClass = 'Class 1';

  final List<String> _classList =
      List.generate(12, (index) => 'Class ${index + 1}');

  @override
  void initState() {
    super.initState();
    _restoreSavedPortalSession();
  }

  Future<void> _restoreSavedPortalSession() async {
    final role = _savedPortalRole();
    final remaining = _portalSessionRemainingSeconds();

    if (role.isEmpty || remaining <= 0) {
      _clearPortalSession();
      if (mounted) {
        setState(() => _isRestoringSession = false);
      }
      return;
    }

    if (role == 'admin') {
      User? user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        try {
          user = await FirebaseAuth.instance
              .authStateChanges()
              .firstWhere((value) => value != null)
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          user = FirebaseAuth.instance.currentUser;
        }
      }

      if (user == null) {
        _clearPortalSession();
        if (mounted) {
          setState(() => _isRestoringSession = false);
        }
        return;
      }

      if (!mounted) return;

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;

        final adminSectionUnlocked = await _requireWindowsSectionPassword(
          context,
          _windowsAdminSectionLock,
          'Admin Section',
        );
        if (!adminSectionUnlocked) {
          _clearPortalSession();
          await FirebaseAuth.instance.signOut();
          if (mounted) {
            setState(() => _isRestoringSession = false);
          }
          return;
        }

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const AdminDashboardScreen(),
          ),
        );

        if (mounted) {
          setState(() => _isRestoringSession = false);
        }
      });
      return;
    }

    if (role == 'student') {
      final studentId = _savedPortalStudentId();
      final studentClass = _savedPortalStudentClass();

      if (studentId.isEmpty || studentClass.isEmpty) {
        _clearPortalSession();
        if (mounted) {
          setState(() => _isRestoringSession = false);
        }
        return;
      }

      if (!mounted) return;

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => StudentPortalScreen(
              studentId: studentId,
              studentClass: studentClass,
            ),
          ),
        );

        if (mounted) {
          setState(() => _isRestoringSession = false);
        }
      });
      return;
    }

    _clearPortalSession();
    if (mounted) {
      setState(() => _isRestoringSession = false);
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _switchRole(bool isAdmin) {
    setState(() {
      _isAdminMode = true;
      _usernameController.clear();
      _passwordController.clear();

      // Scanner should never remain active when changing role.
      _showInlineScanner = false;
      _scanHandled = false;
      _isQrVerifying = false;
      _scanError = null;
      _scannedStudentData = null;
    });
  }

  String _normalizeDob(String value) {
    final cleaned = value
        .trim()
        .replaceAll('-', '/')
        .replaceAll('.', '/')
        .replaceAll(RegExp(r'\s+'), '');
    final parts = cleaned.split('/');
    if (parts.length != 3) return '';
    final day = parts[0].padLeft(2, '0');
    final month = parts[1].padLeft(2, '0');
    final year = parts[2];
    if (year.length != 4) return '';
    return '$day/$month/$year';
  }

  // ============================================================
  // MOBILE-ONLY INLINE STUDENT ID SCANNER
  // Scanner stays on THIS login page. Desktop is hidden.
  // ============================================================

  bool _isMobileScannerDevice() {
    final userAgent = html.window.navigator.userAgent.toLowerCase();

    return userAgent.contains('android') ||
        userAgent.contains('iphone') ||
        userAgent.contains('ipad') ||
        userAgent.contains('ipod') ||
        userAgent.contains('mobile');
  }

void _startInlineScanner() {
  if (_isAdminMode) return;

  setState(() {
    _showInlineScanner = true;
    _scanHandled = false;
    _isQrVerifying = false;
    _scanError = null;
    _scannedStudentData = null;
    _passwordController.clear();
  });
}

  void _closeInlineScanner() {
    setState(() {
      _showInlineScanner = false;
      _scanHandled = false;
      _isQrVerifying = false;
      _scanError = null;
    });
  }

  void _clearScannedStudent() {
    setState(() {
      _showInlineScanner = false;
      _scanHandled = false;
      _isQrVerifying = false;
      _scanError = null;
      _scannedStudentData = null;
      _usernameController.clear();
      _passwordController.clear();
    });
  }

  String? _extractRecordIdFromQr(String qrValue) {
    final value = qrValue.trim();

    // New secure card format.
    final isNewCard = value.contains('VIDYA_SAARTHI_STUDENT_CARD') ||
        value.contains('SVN_STUDENT_CARD');

    // Temporary support for previously printed cards.
    final isOldCard = value.contains('STUDENT VERIFICATION') &&
        value.contains('SARASWATI VIDYA NIKETAN');

    if (!isNewCard && !isOldCard) return null;

    final lines = value.split(RegExp(r'\r?\n'));

    for (final line in lines) {
      final cleaned = line.trim();

      if (cleaned.toLowerCase().startsWith('record id:')) {
        final recordId =
            cleaned.substring('record id:'.length).trim();

        if (recordId.isNotEmpty) return recordId;
      }
    }

    return null;
  }

  void _onInlineQrDetected(BarcodeCapture capture) {
    if (_scanHandled ||
        _isQrVerifying ||
        capture.barcodes.isEmpty) {
      return;
    }

    final rawValue = capture.barcodes.first.rawValue?.trim();

    if (rawValue == null || rawValue.isEmpty) return;

    _scanHandled = true;
    _verifyScannedStudent(rawValue);
  }

  Future<void> _verifyScannedStudent(String qrValue) async {
    final recordId = _extractRecordIdFromQr(qrValue);

    if (recordId == null || recordId.isEmpty) {
      if (!mounted) return;

      setState(() {
        _scanHandled = false;
        _scanError =
            'Invalid School ID Card QR. Sahi student card scan karein.';
      });
      return;
    }

    if (mounted) {
      setState(() {
        _isQrVerifying = true;
        _scanError = null;
      });
    }

    try {
      final studentDoc = await FirebaseFirestore.instance
          .collection('students_directory')
          .doc(recordId)
          .get();

      if (!studentDoc.exists) {
        if (!mounted) return;

        setState(() {
          _isQrVerifying = false;
          _scanHandled = false;
          _scanError =
              'Is ID Card ka student record database me nahi mila.';
        });
        return;
      }

      final data = studentDoc.data() as Map<String, dynamic>;
      final studentClass = data['class']?.toString().trim() ?? '';
      final roll = data['rollNo']?.toString().trim() ?? '';
      final status = data['status']?.toString().trim().toLowerCase();

      if (status != null &&
          status.isNotEmpty &&
          status != 'active') {
        if (!mounted) return;

        setState(() {
          _isQrVerifying = false;
          _scanHandled = false;
          _scanError = 'Yeh Student ID Card Active nahi hai.';
        });
        return;
      }

      if (studentClass.isEmpty || roll.isEmpty) {
        if (!mounted) return;

        setState(() {
          _isQrVerifying = false;
          _scanHandled = false;
          _scanError =
              'Student ke Class / Roll details database me missing hain.';
        });
        return;
      }

      if (!mounted) return;

      setState(() {
        _selectedClass = studentClass;
        _usernameController.text = roll;
        _passwordController.clear();

        _scannedStudentData = data;
        _showInlineScanner = false;
        _scanHandled = false;
        _isQrVerifying = false;
        _scanError = null;
      });
    } catch (e) {
      debugPrint('Student QR verification error: $e');

      if (!mounted) return;

      setState(() {
        _isQrVerifying = false;
        _scanHandled = false;
        _scanError = 'QR verify nahi ho paya. Dobara try karein.';
      });
    }
  }

  Widget _buildInlineScannerPanel() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0C171D),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF00A884).withOpacity(0.45),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00A884).withOpacity(0.08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00A884).withOpacity(0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Icon(
                    Icons.qr_code_scanner_rounded,
                    color: Color(0xFF00D9A5),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SCAN STUDENT ID CARD',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'ID card ka QR frame ke andar rakhein',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: WindowsUiLanguage.translate('Close scanner'),
                  onPressed: _closeInlineScanner,
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white60,
                  ),
                ),
              ],
            ),
          ),
          AspectRatio(
            aspectRatio: 1.15,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  fit: BoxFit.cover,
                  onDetect: _onInlineQrDetected,
                ),

                // Dark focus overlay.
                Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 0.78,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.42),
                      ],
                      stops: const [0.56, 1],
                    ),
                  ),
                ),

                Center(
                  child: Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFF00E8B5),
                        width: 2.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00E8B5)
                              .withOpacity(0.18),
                          blurRadius: 18,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Stack(
                      children: [
                        Center(
                          child: Container(
                            margin:
                                const EdgeInsets.symmetric(horizontal: 16),
                            height: 2,
                            decoration: BoxDecoration(
                              color: const Color(0xFF00E8B5),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF00E8B5)
                                      .withOpacity(0.7),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (_isQrVerifying)
                  Container(
                    color: Colors.black.withOpacity(0.55),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: Color(0xFF00E8B5),
                            strokeWidth: 3,
                          ),
                          SizedBox(height: 12),
                          Text(
                            'Student verify ho raha hai...',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_scanError != null)
            Container(
              width: double.infinity,
              color: Colors.redAccent.withOpacity(0.12),
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Colors.redAccent,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _scanError!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScanLaunchCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: _startInlineScanner,
      child: Ink(
        width: double.infinity,
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [
              Color(0xFF153A3A),
              Color(0xFF12313A),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: const Color(0xFF00A884).withOpacity(0.42),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFF00A884).withOpacity(0.14),
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(
                Icons.qr_code_scanner_rounded,
                color: Color(0xFF00E8B5),
                size: 29,
              ),
            ),
            const SizedBox(width: 13),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Scan Student ID Card',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Camera se ID card ka QR scan karein',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              color: Color(0xFF00D9A5),
              size: 17,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerifiedStudentCard() {
    final data = _scannedStudentData ?? {};
    final name = data['name']?.toString().trim() ?? 'Student';
    final studentClass = data['class']?.toString().trim() ?? _selectedClass;
    final roll = data['rollNo']?.toString().trim() ??
        _usernameController.text.trim();
    final photoUrl = data['photoUrl']?.toString().trim() ?? '';
    final parentName =
        data['parentName']?.toString().trim() ?? 'N/A';

    final initial = name.isEmpty
        ? 'S'
        : name.substring(0, 1).toUpperCase();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF143A35),
            Color(0xFF162A30),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF00A884).withOpacity(0.46),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 68,
            height: 76,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: const Color(0xFF00D9A5),
                width: 1.6,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: photoUrl.isNotEmpty
                  ? Image.network(
                      photoUrl,
                      fit: BoxFit.cover,
errorBuilder: (context, error, stackTrace) {
                        return _scannerPhotoFallback(initial);
                      },
                    )
                  : _scannerPhotoFallback(initial),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.verified_rounded,
                      color: Color(0xFF00D9A5),
                      size: 16,
                    ),
                    SizedBox(width: 5),
                    Text(
                      'STUDENT VERIFIED',
                      style: TextStyle(
                        color: Color(0xFF00D9A5),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$studentClass  •  Roll $roll',
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Guardian: $parentName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: WindowsUiLanguage.translate('Scan another card'),
            onPressed: _clearScannedStudent,
            icon: const Icon(
              Icons.refresh_rounded,
              color: Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  Widget _scannerPhotoFallback(String initial) {
    return Container(
      color: const Color(0xFF0E171C),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            color: Color(0xFF00A884),
            fontSize: 28,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _buildManualLoginDivider() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 1,
            color: Colors.white12,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'OR LOGIN MANUALLY',
            style: TextStyle(
              color: Colors.white30,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 1,
            color: Colors.white12,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // EXISTING LOGIN LOGIC - KEPT INTACT
  // ============================================================

  Future<void> _handleLogin() async {
    final idText = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (idText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            _isAdminMode
                ? 'Admin Email bharein.'
                : 'Student Roll No bharein.',
          ),
        ),
      );
      return;
    }

    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            'Password / Date of Birth bharein.',
          ),
        ),
      );
      return;
    }

    if (!_isAdminMode) {
      final notificationAllowed =
          await _requestBrowserNotificationPermission();

      if (!notificationAllowed) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 5),
            backgroundColor: Colors.orangeAccent,
            content: Text(
              'Student Portal use karne ke liye Notifications Allow karna zaroori hai. Browser/site settings me Notifications Allow karke dobara Login karein.',
            ),
          ),
        );
        return;
      }
    }

    setState(() => _isLoggingIn = true);

    try {
      if (_isAdminMode) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: idText,
          password: password,
        );

        final adminSectionUnlocked = await _requireWindowsSectionPassword(
          context,
          _windowsAdminSectionLock,
          'Admin Section',
        );
        if (!adminSectionUnlocked) {
          _clearPortalSession();
          await FirebaseAuth.instance.signOut();
          return;
        }

        _savePortalSession(role: 'admin');

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF00A884),
            content: Text('Admin Login Safal hua!'),
          ),
        );

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                const AdminDashboardScreen(),
          ),
        );
        return;
      }

      final studentRoll = idText;
      final docId =
          '${_selectedClass}_Roll_$studentRoll';

      final studentDoc =
          await FirebaseFirestore.instance
              .collection('students_directory')
              .doc(docId)
              .get();

      if (!studentDoc.exists) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(
              'Student record nahi mila! Class aur Roll No check karein.',
            ),
          ),
        );
        return;
      }

      final studentData =
          studentDoc.data() as Map<String, dynamic>;

      final storedDob =
          studentData['dateOfBirth']
                  ?.toString()
                  .trim() ??
              '';

      if (storedDob.isEmpty) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.orangeAccent,
            content: Text(
              'Is student ka Date of Birth database mein set nahi hai.',
            ),
          ),
        );
        return;
      }

      final enteredPassword =
          password.replaceAll(RegExp(r'[\s-]'), '/');

      final normalizedStoredDob =
          _normalizeDob(storedDob);

      final normalizedEnteredDob =
          _normalizeDob(enteredPassword);

      final passwordMatched =
          normalizedStoredDob.isNotEmpty &&
              normalizedEnteredDob.isNotEmpty &&
              normalizedStoredDob ==
                  normalizedEnteredDob;

if (!passwordMatched) {
  if (!mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      backgroundColor: Colors.redAccent,
      content: Text(
        'Galat Password! Apna Date of Birth sahi format mein enter karein.',
      ),
    ),
  );
  return;
}

      _savePortalSession(
        role: 'student',
        studentId: studentRoll,
        studentClass: _selectedClass,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF00A884),
          content: Text('Student Login Safal hua!'),
        ),
      );

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => StudentPortalScreen(
            studentId: studentRoll,
            studentClass: _selectedClass,
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      String errorMessage = 'Login details galat hain.';

      switch (e.code) {
        case 'user-not-found':
          errorMessage =
              'Yeh Admin account registered nahi hai.';
          break;
        case 'wrong-password':
        case 'invalid-credential':
          errorMessage =
              'Galat Admin Email ya Password.';
          break;
        case 'invalid-email':
          errorMessage = 'Invalid Admin Email.';
          break;
        case 'user-disabled':
          errorMessage =
              'Admin account disabled hai.';
          break;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(errorMessage),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Login error: $e'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoggingIn = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isRestoringSession) {
      return Scaffold(
        backgroundColor: const Color(0xFF06171D),
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.25),
              radius: 1.15,
              colors: [
                Color(0xFF0B3B3A),
                Color(0xFF08262D),
                Color(0xFF06171D),
                Color(0xFF041116),
              ],
              stops: [0.0, 0.34, 0.72, 1.0],
            ),
          ),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_stories_rounded,
                    color: Color(0xFF00E8D0), size: 54),
                SizedBox(height: 14),
                Text(
                  'Vidya Saarthi',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 5),
                Text(
                  'SMART SCHOOL MANAGEMENT SUITE',
                  style: TextStyle(
                    color: Color(0xFFBCE8E5),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.7,
                  ),
                ),
                SizedBox(height: 20),
                SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    color: Color(0xFF00D9A5),
                    strokeWidth: 2.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final media = MediaQuery.of(context);
    final screenWidth = media.size.width;
    final screenHeight = media.size.height;
    final isCompact = screenWidth < 700;
    final showMobileScanner = !_isAdminMode && screenWidth <= 700;

    Widget decorationIcon(
      IconData icon, {
      double size = 120,
      double opacity = 0.16,
    }) {
      return Icon(
        icon,
        size: size,
        color: const Color(0xFF00E8D0).withOpacity(opacity),
      );
    }

    Widget brandHeader() {
      final logo = Container(
        width: isCompact ? 68 : 82,
        height: isCompact ? 68 : 82,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [
              Color(0xFF33E9D0),
              Color(0xFF00A8FF),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00E8D0).withOpacity(0.25),
              blurRadius: 28,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.auto_stories_rounded,
              color: Colors.white,
              size: isCompact ? 38 : 46,
            ),
            Positioned(
              top: 5,
              right: 7,
              child: Icon(
                Icons.star_rounded,
                color: Colors.amberAccent,
                size: isCompact ? 16 : 19,
              ),
            ),
          ],
        ),
      );

      final title = Column(
        crossAxisAlignment:
            isCompact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          RichText(
            textAlign: isCompact ? TextAlign.center : TextAlign.left,
            text: TextSpan(
              children: [
                TextSpan(
                  text: 'Vidya ',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isCompact ? 36 : 52,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.0,
                  ),
                ),
                TextSpan(
                  text: 'Saarthi',
                  style: TextStyle(
                    color: const Color(0xFF00E8D0),
                    fontSize: isCompact ? 36 : 52,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.0,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'SMART SCHOOL MANAGEMENT SUITE',
            textAlign: isCompact ? TextAlign.center : TextAlign.left,
            style: TextStyle(
              color: const Color(0xFFBCE8E5).withOpacity(0.82),
              fontSize: isCompact ? 10.5 : 13,
              fontWeight: FontWeight.w700,
              letterSpacing: isCompact ? 2.0 : 3.2,
            ),
          ),
        ],
      );

      return Column(
        children: [
          if (isCompact)
            Column(
              children: [
                logo,
                const SizedBox(height: 14),
                title,
              ],
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                logo,
                const SizedBox(width: 22),
                title,
              ],
            ),
          SizedBox(height: isCompact ? 14 : 18),
          Container(
            width: isCompact ? 300 : 560,
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  const Color(0xFF00E8D0).withOpacity(0.95),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isCompact
                ? 'EMPOWERING SCHOOLS  •  ENABLING EDUCATION'
                : 'EMPOWERING SCHOOLS   •   ENABLING EDUCATION   •   BUILDING BRIGHTER TOMORROWS',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withOpacity(0.64),
              fontSize: isCompact ? 8.5 : 10,
              fontWeight: FontWeight.w700,
              letterSpacing: isCompact ? 1.0 : 2.3,
            ),
          ),
        ],
      );
    }

    Widget loginPanel() {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(isCompact ? 18 : 28),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF0C2A30).withOpacity(0.97),
              const Color(0xFF0A1E26).withOpacity(0.98),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: const Color(0xFF00E8D0).withOpacity(0.72),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00D7C0).withOpacity(0.14),
              blurRadius: 35,
              spreadRadius: 2,
            ),
            BoxShadow(
              color: Colors.black.withOpacity(0.40),
              blurRadius: 35,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFF00A884).withOpacity(0.13),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF00E8D0).withOpacity(0.25),
                ),
              ),
              child: Icon(
                _isAdminMode
                    ? Icons.admin_panel_settings_rounded
                    : Icons.school_rounded,
                size: 35,
                color: const Color(0xFF00D9A5),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _isAdminMode ? 'ADMIN LOGIN' : 'STUDENT LOGIN',
              style: TextStyle(
                color: Colors.white,
                fontSize: isCompact ? 21 : 24,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              _isAdminMode
                  ? 'Access your school management dashboard'
                  : 'Access your student portal securely',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11.5,
              ),
            ),
            const SizedBox(height: 20),

            // Existing Admin / Student switching behaviour kept intact.
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFF142832),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _switchRole(true),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        decoration: BoxDecoration(
                          gradient: _isAdminMode
                              ? const LinearGradient(
                                  colors: [
                                    Color(0xFF00A884),
                                    Color(0xFF00D9A5),
                                  ],
                                )
                              : null,
                          color: _isAdminMode ? null : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.security, size: 16, color: Colors.white),
                            SizedBox(width: 6),
                            Text(
                              'Admin',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _switchRole(false),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        decoration: BoxDecoration(
                          gradient: !_isAdminMode
                              ? const LinearGradient(
                                  colors: [
                                    Color(0xFF00A884),
                                    Color(0xFF00D9A5),
                                  ],
                                )
                              : null,
                          color: !_isAdminMode ? null : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.person, size: 16, color: Colors.white),
                            SizedBox(width: 6),
                            Text(
                              'Student',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),

            // Existing mobile student QR flow kept intact.
            if (showMobileScanner) ...[
              if (_showInlineScanner)
                _buildInlineScannerPanel()
              else if (_scannedStudentData != null)
                _buildVerifiedStudentCard()
              else
                _buildScanLaunchCard(),
              const SizedBox(height: 16),
              if (_scannedStudentData == null) ...[
                _buildManualLoginDivider(),
                const SizedBox(height: 16),
              ],
            ],

            // Existing manual student class selector kept intact.
            if (!_isAdminMode && _scannedStudentData == null) ...[
              DropdownButtonFormField<String>(
                value: _selectedClass,
                dropdownColor: const Color(0xFF162A32),
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Class'),
                items: _classList
                    .map(
                      (value) => DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedClass = value);
                  }
                },
              ),
              const SizedBox(height: 16),
            ],

            if (_isAdminMode || _scannedStudentData == null)
              TextField(
                controller: _usernameController,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration(
                  _isAdminMode ? 'Admin Email' : 'Student ID / Roll No',
                  icon: _isAdminMode
                      ? Icons.person_outline
                      : Icons.badge_outlined,
                ),
              ),

            if (_isAdminMode || _scannedStudentData == null)
              const SizedBox(height: 16),

            TextField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration(
                _isAdminMode
                    ? 'Password'
                    : _scannedStudentData != null
                        ? 'Confirm Date of Birth (DD/MM/YYYY)'
                        : 'Date of Birth (DD/MM/YYYY)',
                icon: Icons.lock_outline,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                    color: Colors.grey,
                  ),
                  onPressed: () => setState(
                    () => _obscurePassword = !_obscurePassword,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 22),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00B894),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shadowColor: const Color(0xFF00D9A5).withOpacity(0.35),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                onPressed: _isLoggingIn ? null : _handleLogin,
                child: _isLoggingIn
                    ? const SizedBox(
                        width: 21,
                        height: 21,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _isAdminMode
                                ? 'LOGIN AS ADMIN'
                                : _scannedStudentData != null
                                    ? 'VERIFY DOB & ENTER PORTAL'
                                    : 'LOGIN AS STUDENT',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.arrow_forward_rounded, size: 20),
                        ],
                      ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF06171D),
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.35),
                  radius: 1.25,
                  colors: [
                    Color(0xFF0B3B3A),
                    Color(0xFF08262D),
                    Color(0xFF06171D),
                    Color(0xFF041116),
                  ],
                  stops: [0.0, 0.34, 0.72, 1.0],
                ),
              ),
            ),
          ),

          // Decorative school visuals. They never receive clicks.
          Positioned.fill(
            child: IgnorePointer(
              child: Stack(
                children: [
                  if (!isCompact) ...[
                    Positioned(
                      left: -8,
                      top: screenHeight * 0.18,
                      child: decorationIcon(
                        Icons.account_balance_rounded,
                        size: 190,
                        opacity: 0.14,
                      ),
                    ),
                    Positioned(
                      right: 38,
                      top: screenHeight * 0.13,
                      child: decorationIcon(
                        Icons.school_rounded,
                        size: 145,
                        opacity: 0.16,
                      ),
                    ),
                    Positioned(
                      right: -16,
                      top: screenHeight * 0.35,
                      child: decorationIcon(
                        Icons.public_rounded,
                        size: 185,
                        opacity: 0.12,
                      ),
                    ),
                    Positioned(
                      right: 170,
                      top: screenHeight * 0.38,
                      child: decorationIcon(
                        Icons.menu_book_rounded,
                        size: 105,
                        opacity: 0.10,
                      ),
                    ),
                  ],
                  Positioned(
                    left: -screenWidth * 0.12,
                    bottom: screenHeight * 0.11,
                    child: Transform.rotate(
                      angle: -0.08,
                      child: Container(
                        width: screenWidth * 0.72,
                        height: 2,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              const Color(0xFF00E8D0).withOpacity(0.62),
                              Colors.transparent,
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF00E8D0).withOpacity(0.28),
                              blurRadius: 16,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: -screenWidth * 0.13,
                    bottom: screenHeight * 0.22,
                    child: Transform.rotate(
                      angle: 0.07,
                      child: Container(
                        width: screenWidth * 0.68,
                        height: 2,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              const Color(0xFF00B6FF).withOpacity(0.56),
                              Colors.transparent,
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF00B6FF).withOpacity(0.22),
                              blurRadius: 14,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          Positioned.fill(
            child: SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isCompact ? 14 : 28,
                  vertical: isCompact ? 22 : 34,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: screenHeight - (isCompact ? 44 : 68),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1180),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          brandHeader(),
                          SizedBox(height: isCompact ? 24 : 34),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 530),
                            child: loginPanel(),
                          ),
                          SizedBox(height: isCompact ? 18 : 28),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(
    String hint, {
    IconData? icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        color: Colors.grey,
        fontSize: 13,
      ),
      prefixIcon: icon == null
          ? null
          : Icon(
              icon,
              color: const Color(0xFF00A884),
            ),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: const Color(0xFF1F2C34),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }
}

// ============================================================
// STUDENT PORTAL SCREEN
// ============================================================
class StudentPortalScreen extends StatefulWidget {
  final String studentId;
  final String studentClass;

  const StudentPortalScreen({
    super.key,
    required this.studentId,
    required this.studentClass,
  });

  @override
  State<StudentPortalScreen> createState() => _StudentPortalScreenState();
}

class _StudentPortalScreenState extends State<StudentPortalScreen> {
  int _loginBackPressCount = 0;
int _loginBackResetToken = 0;

  Timer? _sessionTimer;
  StreamSubscription<html.MouseEvent>? _sessionClickSubscription;
  final ValueNotifier<int> _sessionSecondsRemaining =
      ValueNotifier<int>(_portalInactivityLimit.inSeconds);
  bool _autoLogoutInProgress = false;

  bool _notificationPermissionGranted = false;
  bool _requestingNotificationPermission = false;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _noticeNotificationSubscription;

void _handleLoginBack(bool didPop) {
  if (didPop) {
    _loginBackPressCount = 0;
    _loginBackResetToken++;
    _clearPortalSession();
    return;
  }

  setState(() {
    _loginBackPressCount++;
  });

  final remaining = 3 - _loginBackPressCount;

  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        backgroundColor: const Color(0xFF1F2C34),
        content: Text(
          remaining == 1
              ? 'Login page par jaane ke liye Back 1 baar aur dabayein.'
              : 'Login page par jaane ke liye Back $remaining baar aur dabayein.',
        ),
      ),
    );

  final token = ++_loginBackResetToken;

  Future<void>.delayed(const Duration(seconds: 4), () {
    if (!mounted || token != _loginBackResetToken) return;

    if (_loginBackPressCount != 0) {
      setState(() {
        _loginBackPressCount = 0;
      });
    }
  });
}

  void _startPortalInactivityTimer() {
    final initialRemaining = _portalSessionRemainingSeconds();
    _sessionSecondsRemaining.value = initialRemaining;

    _sessionClickSubscription = html.document.onClick.listen((_) {
      if (!mounted || _autoLogoutInProgress) return;
      _touchPortalSession();
      _sessionSecondsRemaining.value = _portalInactivityLimit.inSeconds;
    });

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _autoLogoutInProgress) return;

      final remaining = _portalSessionRemainingSeconds();
      _sessionSecondsRemaining.value = remaining;

      if (remaining <= 0) {
        _autoLogoutStudent();
      }
    });

    if (initialRemaining <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoLogoutStudent();
      });
    }
  }

  Future<void> _autoLogoutStudent() async {
    if (_autoLogoutInProgress) return;
    _autoLogoutInProgress = true;
    _clearPortalSession();

    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _logoutStudent() {
    _clearPortalSession();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _initializeStudentNotifications() {
    _notificationPermissionGranted = _browserNotificationGranted();

    if (_notificationPermissionGranted) {
      _startStudentNoticeNotifications();
    }
  }

  Future<void> _requestNotificationFromGate() async {
    if (_requestingNotificationPermission) return;

    setState(() => _requestingNotificationPermission = true);

    final granted = await _requestBrowserNotificationPermission();

    if (!mounted) return;

    setState(() {
      _requestingNotificationPermission = false;
      _notificationPermissionGranted = granted;
    });

    if (granted) {
      _startStudentNoticeNotifications();
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 5),
        backgroundColor: Colors.orangeAccent,
        content: Text(
          'Notification permission blocked hai. Browser ke Site Settings / App Settings me Notifications Allow karein.',
        ),
      ),
    );
  }

  void _startStudentNoticeNotifications() {
    _noticeNotificationSubscription?.cancel();

    final storageTimestamp = _readLastStudentNoticeTimestamp(
      widget.studentClass,
      widget.studentId,
    );

    var lastTimestamp = storageTimestamp;
    var firstSnapshot = true;

    _noticeNotificationSubscription = FirebaseFirestore.instance
        .collection('school_notices')
        .orderBy('timestamp', descending: true)
        .limit(25)
        .snapshots()
        .listen(
      (snapshot) {
        if (!mounted || !_notificationPermissionGranted) return;

        final docs = snapshot.docs.toList()
          ..sort((a, b) {
            final at = (a.data()['timestamp'] as num?)?.toInt() ?? 0;
            final bt = (b.data()['timestamp'] as num?)?.toInt() ?? 0;
            return at.compareTo(bt);
          });

        if (docs.isEmpty) {
          firstSnapshot = false;
          return;
        }

        final newestTimestamp = docs.fold<int>(0, (current, doc) {
          final ts = (doc.data()['timestamp'] as num?)?.toInt() ?? 0;
          return ts > current ? ts : current;
        });

        // First ever notification setup: old notices ko spam nahi karna.
        if (firstSnapshot && lastTimestamp <= 0) {
          firstSnapshot = false;
          lastTimestamp = newestTimestamp;
          if (newestTimestamp > 0) {
            _writeLastStudentNoticeTimestamp(
              widget.studentClass,
              widget.studentId,
              newestTimestamp,
            );
          }
          return;
        }

        firstSnapshot = false;

        for (final doc in docs) {
          final data = doc.data();
          final ts = (data['timestamp'] as num?)?.toInt() ?? 0;

          if (ts <= lastTimestamp) continue;

          _showStudentBrowserNotification(
            noticeId: doc.id,
            title: data['title']?.toString().trim().isNotEmpty == true
                ? data['title'].toString().trim()
                : 'New School Notice',
            description: data['description']?.toString() ?? '',
            category: data['category']?.toString() ?? 'Notice',
          );
        }

        if (newestTimestamp > lastTimestamp) {
          lastTimestamp = newestTimestamp;
          _writeLastStudentNoticeTimestamp(
            widget.studentClass,
            widget.studentId,
            newestTimestamp,
          );
        }
      },
      onError: (error) {
        debugPrint('Student notice notification stream error: $error');
      },
    );
  }

  Widget _buildNotificationPermissionGate() {
    final supported = _browserNotificationSupported();
    final denied = supported && html.Notification.permission == 'denied';

    return Scaffold(
      backgroundColor: const Color(0xFF0F171D),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 470),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF172229),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: const Color(0xFF00A884).withOpacity(0.28),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: const Color(0xFF00A884).withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.notifications_active_rounded,
                      color: Color(0xFF00D9A5),
                      size: 31,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Notifications Required',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    !supported
                        ? 'Is browser/device me web notifications supported nahi hain. Student Portal ke liye notification-supported browser use karein.'
                        : denied
                            ? 'Notifications browser/site settings se blocked hain. Pehle Site Settings me Notifications ko Allow karein, phir neeche button dabayein.'
                            : 'School ke notices mobile/browser par paane ke liye Notifications Allow karna zaroori hai. Permission ke bina Student Portal open nahi hoga.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12.5,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00A884),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: !supported || _requestingNotificationPermission
                          ? null
                          : _requestNotificationFromGate,
                      icon: _requestingNotificationPermission
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.notifications_rounded,
                              color: Colors.white,
                              size: 19,
                            ),
                      label: Text(
                        _requestingNotificationPermission
                            ? 'Checking...'
                            : denied
                                ? 'I Enabled It — Check Again'
                                : 'Allow Notifications',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: _logoutStudent,
                    icon: const Icon(
                      Icons.logout_rounded,
                      color: Colors.redAccent,
                      size: 17,
                    ),
                    label: const Text(
                      'Logout',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Map<String, dynamic>? studentData;
  bool isLoadingProfile = true;
  String? profileError;

  @override
  void initState() {
    super.initState();
    _initializeStudentNotifications();
    _fetchStudentProfile();
    // Windows local-first: browser inactivity auto-logout disabled.
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    _sessionClickSubscription?.cancel();
    _noticeNotificationSubscription?.cancel();
    _sessionSecondsRemaining.dispose();
    super.dispose();
  }

  Future<void> _fetchStudentProfile() async {
    try {
      final docId = '${widget.studentClass}_Roll_${widget.studentId}';
      final doc = await FirebaseFirestore.instance.collection('students_directory').doc(docId).get();
      if (!mounted) return;
      if (doc.exists) {
        setState(() {
          studentData = doc.data();
          isLoadingProfile = false;
          profileError = null;
        });
      } else {
        setState(() {
          studentData = null;
          isLoadingProfile = false;
          profileError = 'Student profile nahi mila.';
        });
      }
    } catch (e) {
      debugPrint('Profile load error: $e');
      if (!mounted) return;
      setState(() {
        isLoadingProfile = false;
        profileError = 'Profile load nahi ho paya.';
      });
    }
  }

  Color _categoryColor(String category) {
    switch (category.toLowerCase()) {
      case 'holiday': return Colors.orangeAccent;
      case 'exam': return Colors.redAccent;
      case 'event': return Colors.blueAccent;
      case 'general':
      default: return const Color(0xFF00A884);
    }
  }

  IconData _categoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'holiday': return Icons.beach_access_rounded;
      case 'exam': return Icons.menu_book_rounded;
      case 'event': return Icons.event_rounded;
      case 'general':
      default: return Icons.campaign_rounded;
    }
  }

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp is Timestamp) {
      final date = timestamp.toDate();
      final day = date.day.toString().padLeft(2, '0');
      final month = date.month.toString().padLeft(2, '0');
      final year = date.year.toString();
      return '$day/$month/$year';
    }
    return '';
  }

  String _studentInitial(String? value) {
    if (value == null || value.trim().isEmpty) return 'S';
    return value.trim().substring(0, 1).toUpperCase();
  }

  Future<void> _updateMobileNumber(String newMobile) async {
    final mobile = newMobile.trim();
    if (mobile.isEmpty) throw Exception('Mobile number bharna zaroori hai.');
    if (!RegExp(r'^[0-9]{10}$').hasMatch(mobile)) throw Exception('10 digit mobile number daalein.');

    final docId = '${widget.studentClass}_Roll_${widget.studentId}';
    await FirebaseFirestore.instance.collection('students_directory').doc(docId).update({
      'parentContact': mobile,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  void _showMobileUpdateDialog() {
    final mobileController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool isSaving = false;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F2C34),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.phone_android_rounded, color: Color(0xFF00A884)),
                  SizedBox(width: 10),
                  Text('Update Mobile Number', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                ],
              ),
              content: TextField(
                controller: mobileController,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Enter 10 digit mobile number',
                  hintStyle: const TextStyle(color: Colors.grey),
                  prefixIcon: const Icon(Icons.phone_outlined, color: Color(0xFF00A884)),
                  filled: true,
                  fillColor: const Color(0xFF121B22),
                  counterStyle: const TextStyle(color: Colors.grey),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(ctx),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
                  onPressed: isSaving
                      ? null
                      : () async {
                          setDialogState(() => isSaving = true);
                          try {
                            await _updateMobileNumber(mobileController.text);
                            if (!mounted) return;
                            Navigator.pop(ctx);
                            _fetchStudentProfile();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Mobile number successfully update ho gaya!')),
                            );
                          } catch (e) {
                            setDialogState(() => isSaving = false);
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Update error: $e')));
                          }
                        },
                  child: isSaving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildProfileTop() {
    final photoUrl = studentData?['photoUrl']?.toString().trim() ?? '';
    final studentName = studentData?['name']?.toString().trim().isNotEmpty == true ? studentData!['name'].toString().trim() : 'Student Profile';
    final studentInitial = _studentInitial(studentName);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF193A38), Color(0xFF172229)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              Container(
                width: 108,
                height: 108,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF00A884), width: 2),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFF00A884).withOpacity(0.18), blurRadius: 22, spreadRadius: 2),
                  ],
                ),
                child: ClipOval(
                  child: isLoadingProfile
                      ? const ColoredBox(
                          color: Color(0xFF0F171D),
                          child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF00A884)))),
                        )
                      : photoUrl.isNotEmpty
                          ? Image.network(
                              photoUrl,
                              fit: BoxFit.cover,
errorBuilder: (context, error, stackTrace) {
                                return ColoredBox(
                                  color: const Color(0xFF0F171D),
                                  child: Center(child: Text(studentInitial, style: const TextStyle(color: Color(0xFF00A884), fontSize: 38, fontWeight: FontWeight.bold))),
                                );
                              },
                            )
                          : ColoredBox(
                              color: const Color(0xFF0F171D),
                              child: Center(child: Text(studentInitial, style: const TextStyle(color: Color(0xFF00A884), fontSize: 38, fontWeight: FontWeight.bold))),
                            ),
                ),
              ),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(color: const Color(0xFF00A884), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF172229), width: 3)),
                child: const Icon(Icons.check_rounded, size: 15, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(studentName, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          const Text('Vidya Saarthi Student Portal', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 13),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF00A884).withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF00A884).withOpacity(0.28)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified_rounded, color: Color(0xFF00A884), size: 15),
                SizedBox(width: 6),
                Text('Active / Enrolled', style: TextStyle(color: Color(0xFF00A884), fontSize: 11, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileDetails() {
    if (isLoadingProfile) {
      return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: Color(0xFF00A884))));
    }
    if (studentData == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.person_off_outlined, color: Colors.white38, size: 38),
            const SizedBox(height: 10),
            Text(profileError ?? 'Profile unavailable', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _fetchStudentProfile,
              style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF00A884), side: const BorderSide(color: Color(0xFF00A884))),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final parentName = studentData?['parentName']?.toString().trim() ?? 'N/A';
    final dob = studentData?['dateOfBirth']?.toString().trim() ?? 'N/A';
    final contact = studentData?['parentContact']?.toString().trim() ?? 'N/A';
    final address = studentData?['address']?.toString().trim() ?? '';
    final district = studentData?['district']?.toString().trim() ?? '';
    final state = studentData?['state']?.toString().trim() ?? '';
    final pinCode = studentData?['pinCode']?.toString().trim() ?? '';
    final hostel = studentData?['hostelFacility']?.toString().trim() ?? 'No';

    String fullAddress = [address, district, state].where((e) => e.isNotEmpty).join(', ');
    if (pinCode.isNotEmpty) fullAddress = fullAddress.isEmpty ? pinCode : '$fullAddress - $pinCode';
    if (fullAddress.isEmpty) fullAddress = 'Not Available';

    return Column(
      children: [
        _profileInfoTile(icon: Icons.badge_outlined, label: 'Student ID / Roll', value: widget.studentId),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.school_outlined, label: 'Assigned Class', value: widget.studentClass),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.person_outline_rounded, label: "Father's / Guardian Name", value: parentName.isEmpty ? 'N/A' : parentName),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.cake_outlined, label: 'Date of Birth', value: dob.isEmpty ? 'N/A' : dob),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.phone_outlined, label: 'Contact Number', value: contact.isEmpty ? 'N/A' : contact),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.home_outlined, label: 'Address', value: fullAddress),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.hotel_outlined, label: 'Hostel Facility', value: hostel.isEmpty ? 'No' : hostel),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.verified_user_outlined, label: 'Status', value: 'Active', valueColor: const Color(0xFF00A884)),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _showMobileUpdateDialog,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF00A884)),
              foregroundColor: const Color(0xFF00A884),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.phone_android_rounded, size: 18),
            label: const Text('Update Mobile Number', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(color: const Color(0xFF0F171D), borderRadius: BorderRadius.circular(13), border: Border.all(color: Colors.white.withOpacity(0.05))),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline_rounded, color: Colors.white38, size: 17),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Profile details school database se linked hain. Student sirf apna mobile number update kar sakta hai.',
                  style: TextStyle(color: Colors.white54, fontSize: 11.5, height: 1.45),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _profileInfoTile({required IconData icon, required String label, required String value, Color valueColor = Colors.white}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1D2A31),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.035)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 35,
            height: 35,
            decoration: BoxDecoration(color: const Color(0xFF0F171D), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: const Color(0xFF00A884), size: 18),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: Colors.white38, fontSize: 9.5)),
                const SizedBox(height: 3),
                Text(value, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: valueColor, fontSize: 12.5, fontWeight: FontWeight.w700, height: 1.25)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeBoard(BuildContext context, {double? height}) {
    return Container(
      width: double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 25, offset: const Offset(0, 10))],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('school_notices').snapshots(),
              builder: (context, snapshot) {
                final count = snapshot.hasData ? snapshot.data!.docs.length : 0;
                return Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(color: const Color(0xFF00A884).withOpacity(0.13), borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.campaign_rounded, color: Color(0xFF00A884), size: 21),
                    ),
                    const SizedBox(width: 11),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('School Notice Board', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                          SizedBox(height: 2),
                          Text('Latest announcements & updates', style: TextStyle(color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F171D),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withOpacity(0.05)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.notifications_none_rounded, color: Colors.white54, size: 15),
                          const SizedBox(width: 5),
                          Text('$count', style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 15),
            Container(height: 1, color: Colors.white.withOpacity(0.06)),
            const SizedBox(height: 14),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('school_notices').orderBy('timestamp', descending: true).snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: Color(0xFF00A884), strokeWidth: 2.5));
                  if (snapshot.hasError) return Center(child: _emptyNoticeState(icon: Icons.error_outline_rounded, title: 'Notice load nahi ho paya', subtitle: 'Internet ya Firebase check karein.'));
                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return Center(child: _emptyNoticeState(icon: Icons.notifications_none_rounded, title: 'Abhi koi notice nahi hai', subtitle: 'School jab notice publish karega, yahan dikhega.'));
                  final docs = snapshot.data!.docs;
                  return ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final notice = docs[index].data() as Map<String, dynamic>;
                      return _buildNoticeCard(
                        title: notice['title']?.toString() ?? 'Notice',
                        description: notice['description']?.toString() ?? '',
                        category: notice['category']?.toString() ?? 'General',
                        date: _formatTimestamp(notice['timestamp']),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoticeCard({required String title, required String description, required String category, required String date}) {
    final accent = _categoryColor(category);
    final categoryIcon = _categoryIcon(category);
    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFF10181E), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white.withOpacity(0.055))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: accent.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
            child: Icon(categoryIcon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 7,
                  runSpacing: 5,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: accent.withOpacity(0.11), borderRadius: BorderRadius.circular(20)),
                      child: Text(category, style: TextStyle(color: accent, fontSize: 9.5, fontWeight: FontWeight.w800)),
                    ),
                    if (date.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.calendar_today_rounded, size: 11, color: Colors.white30),
                          const SizedBox(width: 4),
                          Text(date, style: const TextStyle(color: Colors.white30, fontSize: 9.5)),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700, height: 1.25)),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(description, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 11.5, height: 1.45)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyNoticeState({required IconData icon, required String title, required String subtitle}) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(color: const Color(0xFF00A884).withOpacity(0.08), shape: BoxShape.circle),
            child: Icon(icon, color: const Color(0xFF00A884), size: 30),
          ),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white30, fontSize: 11, height: 1.4)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_notificationPermissionGranted) {
      return _buildNotificationPermissionGate();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F171D),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF172229),
        titleSpacing: 18,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFF00A884).withOpacity(0.15),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: const Color(0xFF00A884).withOpacity(0.35)),
              ),
              child: const Icon(Icons.school_rounded, color: Color(0xFF00A884), size: 21),
            ),
            const SizedBox(width: 11),
            const Expanded(
              child: Text('Student Portal', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
            ),
          ],
        ),
        actions: [
          _buildPortalSessionTimer(_sessionSecondsRemaining),
          const SizedBox(width: 7),
          IconButton(
            tooltip: WindowsUiLanguage.translate('Logout'),
            icon: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.10), borderRadius: BorderRadius.circular(11)),
              child: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 19),
            ),
            onPressed: _logoutStudent,
          ),
          const SizedBox(width: 8),
        ],
      ),
body: PopScope(
  canPop: _loginBackPressCount >= 2,
  onPopInvokedWithResult: (didPop, result) {
    _handleLoginBack(didPop);
  },
  child: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 800;
          if (isMobile) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
              child: Column(
                children: [
                  _buildMobileProfileCard(),
                  const SizedBox(height: 14),
                  _buildNoticeBoard(context, height: null),
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 330, child: SingleChildScrollView(child: _buildDesktopProfileCard())),
                const SizedBox(width: 18),
                Expanded(child: _buildNoticeBoard(context, height: constraints.maxHeight - 36)),
              ],
            ),
          );
        },
      ),
    ),
  );
}

  Widget _buildDesktopProfileCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.20), blurRadius: 25, offset: const Offset(0, 10))],
      ),
      child: Column(
        children: [
          _buildProfileTop(),
          Padding(padding: const EdgeInsets.all(18), child: _buildProfileDetails()),
        ],
      ),
    );
  }

  Widget _buildMobileProfileCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 22, offset: const Offset(0, 9))],
      ),
      child: Column(
        children: [
          _buildProfileTop(),
          Padding(padding: const EdgeInsets.all(16), child: _buildProfileDetails()),
        ],
      ),
    );
  }
}


// ============================================================
// VIDYA SAARTHI BRAND HEADER BACKGROUND
// Decorative only. No existing dashboard logic depends on this painter.
// ============================================================
class _VidyaSaarthiWavePainter extends CustomPainter {
  const _VidyaSaarthiWavePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final teal = const Color(0xFF00E6C0);
    final cyan = const Color(0xFF39D7FF);

    final softGlow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.15
      ..color = teal.withOpacity(0.20);

    final brightGlow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.8
      ..color = cyan.withOpacity(0.30);

    final wave1 = Path()
      ..moveTo(-30, size.height * 0.70)
      ..cubicTo(
        size.width * 0.14,
        size.height * 0.48,
        size.width * 0.25,
        size.height * 0.92,
        size.width * 0.40,
        size.height * 0.72,
      )
      ..cubicTo(
        size.width * 0.55,
        size.height * 0.52,
        size.width * 0.69,
        size.height * 0.88,
        size.width * 0.82,
        size.height * 0.64,
      )
      ..cubicTo(
        size.width * 0.90,
        size.height * 0.50,
        size.width * 0.97,
        size.height * 0.72,
        size.width + 30,
        size.height * 0.58,
      );

    final wave2 = Path()
      ..moveTo(-20, size.height * 0.82)
      ..cubicTo(
        size.width * 0.18,
        size.height * 0.62,
        size.width * 0.30,
        size.height * 1.02,
        size.width * 0.47,
        size.height * 0.74,
      )
      ..cubicTo(
        size.width * 0.61,
        size.height * 0.52,
        size.width * 0.76,
        size.height * 0.92,
        size.width + 20,
        size.height * 0.69,
      );

    final wave3 = Path()
      ..moveTo(size.width * 0.58, size.height * 0.18)
      ..cubicTo(
        size.width * 0.69,
        size.height * 0.02,
        size.width * 0.79,
        size.height * 0.30,
        size.width * 0.88,
        size.height * 0.17,
      )
      ..cubicTo(
        size.width * 0.93,
        size.height * 0.09,
        size.width * 0.97,
        size.height * 0.26,
        size.width + 10,
        size.height * 0.13,
      );

    canvas.drawPath(wave1, brightGlow);
    canvas.drawPath(wave2, softGlow);
    canvas.drawPath(wave3, softGlow);

    // Extra faint wave layers make the header feel deeper without using images.
    for (var i = 0; i < 4; i++) {
      final yShift = i * 6.0;
      final p = Path()
        ..moveTo(-20, size.height * 0.73 + yShift)
        ..cubicTo(
          size.width * 0.20,
          size.height * 0.55 + yShift,
          size.width * 0.33,
          size.height * 0.88 + yShift,
          size.width * 0.50,
          size.height * 0.70 + yShift,
        )
        ..cubicTo(
          size.width * 0.67,
          size.height * 0.53 + yShift,
          size.width * 0.81,
          size.height * 0.82 + yShift,
          size.width + 20,
          size.height * 0.62 + yShift,
        );

      canvas.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.7
          ..color = teal.withOpacity(0.08),
      );
    }

    final particlePaint = Paint()..color = const Color(0xFF7DF9E7).withOpacity(0.60);
    const particles = <Offset>[
      Offset(0.08, 0.39),
      Offset(0.13, 0.24),
      Offset(0.19, 0.48),
      Offset(0.29, 0.30),
      Offset(0.36, 0.18),
      Offset(0.43, 0.40),
      Offset(0.53, 0.20),
      Offset(0.64, 0.32),
      Offset(0.72, 0.17),
      Offset(0.82, 0.37),
      Offset(0.90, 0.23),
      Offset(0.96, 0.45),
    ];

    for (var i = 0; i < particles.length; i++) {
      final p = particles[i];
      canvas.drawCircle(
        Offset(size.width * p.dx, size.height * p.dy),
        i % 3 == 0 ? 1.8 : 1.1,
        particlePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VidyaSaarthiWavePainter oldDelegate) => false;
}

// ============================================================
// ADMIN DASHBOARD
// ============================================================
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final GlobalKey<ScaffoldState> _adminScaffoldKey = GlobalKey<ScaffoldState>();

int _loginBackPressCount = 0;
int _loginBackResetToken = 0;

void _handleLoginBack(bool didPop) {
  if (didPop) {
    _loginBackPressCount = 0;
    _loginBackResetToken++;

    _clearPortalSession();
    FirebaseAuth.instance.signOut();
    return;
  }

  setState(() {
    _loginBackPressCount++;
  });

  final remaining = 3 - _loginBackPressCount;

  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        backgroundColor: const Color(0xFF1F2C34),
        content: Text(
          remaining == 1
              ? 'Login page par jaane ke liye Back 1 baar aur dabayein.'
              : 'Login page par jaane ke liye Back $remaining baar aur dabayein.',
        ),
      ),
    );

  final token = ++_loginBackResetToken;

  Future<void>.delayed(const Duration(seconds: 4), () {
    if (!mounted || token != _loginBackResetToken) return;

    if (_loginBackPressCount != 0) {
      setState(() {
        _loginBackPressCount = 0;
      });
    }
  });
}

  Timer? _sessionTimer;
  StreamSubscription<html.MouseEvent>? _sessionClickSubscription;
  final ValueNotifier<int> _sessionSecondsRemaining =
      ValueNotifier<int>(_portalInactivityLimit.inSeconds);
  bool _autoLogoutInProgress = false;

  void _startPortalInactivityTimer() {
    final initialRemaining = _portalSessionRemainingSeconds();
    _sessionSecondsRemaining.value = initialRemaining;

    _sessionClickSubscription = html.document.onClick.listen((_) {
      if (!mounted || _autoLogoutInProgress) return;
      _touchPortalSession();
      _sessionSecondsRemaining.value = _portalInactivityLimit.inSeconds;
    });

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _autoLogoutInProgress) return;

      final remaining = _portalSessionRemainingSeconds();
      _sessionSecondsRemaining.value = remaining;

      if (remaining <= 0) {
        _autoLogoutAdmin();
      }
    });

    if (initialRemaining <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoLogoutAdmin();
      });
    }
  }

  Future<void> _autoLogoutAdmin() async {
    if (_autoLogoutInProgress) return;
    _autoLogoutInProgress = true;
    _sessionTimer?.cancel();
    await _sessionClickSubscription?.cancel();
    _clearPortalSession();

    try {
      await WindowsLocalSession.logout();
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint('Auto logout sign-out error: $e');
    }

    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/local-login',
      (route) => false,
    );
  }

  final TextEditingController _noticeTitleController = TextEditingController();
  final TextEditingController _noticeDescController = TextEditingController();
  String _noticeCategory = 'Holiday';
  final List<String> _noticeCategories = ['Holiday', 'Exam', 'Event', 'General'];
  String? _editingNoticeId;
  bool _isSavingNotice = false;

  String _directoryClass = 'Class 1';
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _rollController = TextEditingController();
  final TextEditingController _parentContactController = TextEditingController();
  String? _studentPhotoUrl;
  bool _isSearchingStudent = false;

  final List<String> _classList = List.generate(12, (index) => 'Class ${index + 1}');

  final List<Map<String, String>> _teachersList = [
    {'name': 'Ramesh Sharma', 'subject': 'Mathematics', 'phone': '+91 9876543210'},
    {'name': 'Priya Sen', 'subject': 'Bengali & English', 'phone': '+91 9876543211'},
    {'name': 'Amit Paul', 'subject': 'Science', 'phone': '+91 9876543212'},
  ];

  @override
  void initState() {
    super.initState();
    _startPortalInactivityTimer();

    // Preload heavy/remote Admin data while dashboard is already visible.
    // Exam Center then opens immediately with warm data.
    Future<void>.microtask(() async {
      try {
        await Future.wait([
          _ExamCenterDataCache.refresh(force: true),
          _refreshSchoolProfileFromDrive(),
        ]);
        if (mounted) setState(() {});
      } catch (e) {
        debugPrint('Admin background preload warning: $e');
      }
    });
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    _sessionClickSubscription?.cancel();
    _sessionSecondsRemaining.dispose();
    _noticeTitleController.dispose();
    _noticeDescController.dispose();
    _nameController.dispose();
    _rollController.dispose();
    _parentContactController.dispose();
    super.dispose();
  }

  void _openAddStudentDialog() {
    final nameCtrl = TextEditingController();
    final parentCtrl = TextEditingController();
    final rollCtrl = TextEditingController();
    final contactCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    final stateCtrl = TextEditingController();
    final districtCtrl = TextEditingController();
    final admissionDateCtrl = TextEditingController(text: '${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}');
    final dobCtrl = TextEditingController();
    String selectedClass = _directoryClass;
    String hostelFacility = 'No';
    List<int>? selectedPhotoBytes;
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: !isSaving,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDlgState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F2C34),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              title: const Row(
                children: [
                  Icon(Icons.person_add_alt_1, color: Color(0xFF00A884), size: 22),
                  SizedBox(width: 10),
                  Text('Add New Student', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                ],
              ),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: selectedClass,
                              dropdownColor: const Color(0xFF1F2C34),
                              style: const TextStyle(color: Colors.white),
                              decoration: _inputDecoration('Class'),
                              items: _classList.map((value) => DropdownMenuItem<String>(value: value, child: Text(value))).toList(),
                              onChanged: (value) {
                                if (value != null) setDlgState(() => selectedClass = value);
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: rollCtrl,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white),
                              decoration: _inputDecoration('Roll No *'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(controller: nameCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('Student Full Name *')),
                      const SizedBox(height: 10),
                      TextField(controller: parentCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration("Parent's / Guardian Name *")),
                      const SizedBox(height: 10),
                      TextField(controller: contactCtrl, keyboardType: TextInputType.phone, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('Contact No *')),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        value: hostelFacility,
                        dropdownColor: const Color(0xFF1F2C34),
                        style: const TextStyle(color: Colors.white),
                        decoration: _inputDecoration('Hostel Facility'),
                        items: const [
                          DropdownMenuItem(value: 'No', child: Text('Hostel Facility: No')),
                          DropdownMenuItem(value: 'Yes', child: Text('Hostel Facility: Yes')),
                        ],
                        onChanged: (value) {
                          if (value != null) setDlgState(() => hostelFacility = value);
                        },
                      ),
                      const SizedBox(height: 10),
                      TextField(controller: addressCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('Address')),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: TextField(controller: districtCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('District'))),
                          const SizedBox(width: 10),
                          Expanded(child: TextField(controller: stateCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('State'))),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: TextField(controller: pinCtrl, keyboardType: TextInputType.number, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('PIN Code'))),
                          const SizedBox(width: 10),
                          Expanded(child: TextField(controller: admissionDateCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('Admission Date'))),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(controller: dobCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('Date of Birth (DD/MM/YYYY)')),
                    ],
                  ),
                ),
              ),
              actions: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(side: BorderSide(color: selectedPhotoBytes != null ? const Color(0xFF00A884) : Colors.grey)),
                  onPressed: isSaving ? null : () async {
                    final picker = ImagePicker();
                    final image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
                    if (image == null) return;
                    final bytes = await image.readAsBytes();
                    setDlgState(() => selectedPhotoBytes = bytes);
                  },
                  icon: Icon(selectedPhotoBytes != null ? Icons.check_circle : Icons.add_a_photo_outlined, color: selectedPhotoBytes != null ? const Color(0xFF00A884) : Colors.white70),
                  label: Text(selectedPhotoBytes != null ? 'Photo Ready' : 'Upload Photo', style: TextStyle(color: selectedPhotoBytes != null ? const Color(0xFF00A884) : Colors.white70)),
                ),
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                  ),
                  onPressed: isSaving
                      ? null
                      : () async {
                          final name = nameCtrl.text.trim();
                          final parent = parentCtrl.text.trim();
                          final roll = rollCtrl.text.trim();
                          final contact = contactCtrl.text.trim();

                          if (name.isEmpty || roll.isEmpty || contact.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                backgroundColor: Colors.redAccent,
                                content: Text(
                                  'Name, Roll No aur Contact bharna zaroori hai!',
                                ),
                              ),
                            );
                            return;
                          }

                          String normalizeRoll(String value) {
                            final cleaned = value.trim();
                            final number = int.tryParse(cleaned);

                            if (number != null) {
                              return number.toString();
                            }

                            return cleaned.toLowerCase();
                          }

                          setDlgState(() => isSaving = true);

                          // One permanent student identity:
                          // Class 1 + Roll 1/01/001 all use the SAME document ID.
                          final normalizedNewRoll = normalizeRoll(roll);
                          final docId = '${selectedClass}_Roll_$normalizedNewRoll';
                          String finalPhotoUrl = '';
                          bool driveSaved = false;

                          try {
                            // Duplicate protection:
                            // 1, 01, 001, 0001 ko same roll maana jayega.

                            final existingStudents =
                                await FirebaseFirestore.instance
                                    .collection('students_directory')
                                    .where('class', isEqualTo: selectedClass)
                                    .get();

                            final alreadyExists =
                                existingStudents.docs.any((doc) {
                              final data = doc.data();
                              final existingRoll =
                                  data['rollNo']?.toString() ?? '';

                              return normalizeRoll(existingRoll) ==
                                  normalizedNewRoll;
                            });

                            if (alreadyExists) {
                              setDlgState(() => isSaving = false);

                              if (!mounted) return;

                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: Colors.orangeAccent,
                                  content: Text(
                                    '$selectedClass me Roll $roll already exist karta hai!',
                                  ),
                                ),
                              );
                              return;
                            }

                            final scriptUrl =
                                await _windowsGoogleScriptUrl(required: false);

                            if (scriptUrl.isNotEmpty) {
                              final base64Image =
                                  selectedPhotoBytes != null
                                      ? base64Encode(selectedPhotoBytes!)
                                      : '';

                              final response = await WindowsBackendBridge.post(
                                Uri.parse(scriptUrl),
                                headers: {
                                  'Content-Type':
                                      'text/plain;charset=utf-8',
                                },
                                body: jsonEncode({
                                  'action': 'add_student',
                                  'name': name,
                                  'parentName': parent,
                                  'studentClass': selectedClass,
                                  'roll': normalizedNewRoll,
                                  'contact': contact,
                                  'photoBase64': base64Image,
                                  'hostelFacility': hostelFacility,
                                  'address': addressCtrl.text.trim(),
                                  'district': districtCtrl.text.trim(),
                                  'state': stateCtrl.text.trim(),
                                  'pinCode': pinCtrl.text.trim(),
                                  'joiningDate':
                                      admissionDateCtrl.text.trim(),
                                  'dateOfBirth': dobCtrl.text.trim(),
                                }),
                              );

                              if (response.statusCode != 200) {
                                throw Exception(
                                  'Google save failed: ${response.statusCode}',
                                );
                              }

                              final responseJson =
                                  Map<String, dynamic>.from(
                                jsonDecode(response.body),
                              );

                              if (responseJson['success'] != true) {
                                throw Exception(
                                  responseJson['message'] ??
                                      'Student save failed',
                                );
                              }

                              driveSaved = true;

                              if (responseJson['photoUrl'] != null) {
                                finalPhotoUrl =
                                    responseJson['photoUrl'].toString();
                              }
                            }

                            final studentRef = FirebaseFirestore.instance
                                .collection('students_directory')
                                .doc(docId);

                            await studentRef.set({
                              'name': name,
                              'parentName': parent,
                              'class': selectedClass,
                              'rollNo': normalizedNewRoll,
                              'parentContact': contact,
                              'photoUrl': finalPhotoUrl,
                              'hostelFacility': hostelFacility,
                              'address': addressCtrl.text.trim(),
                              'pinCode': pinCtrl.text.trim(),
                              'district': districtCtrl.text.trim(),
                              'state': stateCtrl.text.trim(),
                              'joiningDate':
                                  admissionDateCtrl.text.trim(),
                              'dateOfBirth': dobCtrl.text.trim(),
                              'createdAt': FieldValue.serverTimestamp(),
                              'updatedAt': FieldValue.serverTimestamp(),
                            });

                            final assignedTestUid =
                                await _ensureTestStudentUid(studentRef);

                            if (!mounted) return;

                            Navigator.pop(dialogContext);

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                backgroundColor: driveSaved
                                    ? const Color(0xFF00A884)
                                    : Colors.orangeAccent,
                                content: Text(
                                  (driveSaved
                                          ? 'Student Google Sheet, Drive aur Firestore me save ho gaya.'
                                          : 'Student Firestore me save hua.') +
                                      (assignedTestUid != null
                                          ? ' Test UID: $assignedTestUid'
                                          : ''),
                                ),
                              ),
                            );
                          } catch (e) {
                            setDlgState(() => isSaving = false);

                            if (!mounted) return;

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                backgroundColor: Colors.redAccent,
                                content: Text(
                                  'Student save error: $e',
                                ),
                              ),
                            );
                          }
                        },
                  child: Text(
                    isSaving ? 'Saving...' : 'Save Student',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _saveNotice() async {
    final title = _noticeTitleController.text.trim();
    final description = _noticeDescController.text.trim();
    if (title.isEmpty || description.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Title aur details bharna zaroori hai.')));
      return;
    }
    setState(() => _isSavingNotice = true);
    try {
      final connection = await WindowsConnectionCenter.reload();
      if (!connection.remoteReady) throw StateError('Notice not sent. Connect and verify this school Firebase and Google Script first.');
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = 'NOTICE-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
      // An edited announcement is a new notification, avoiding old FCM-job dedupe.
      final result = await WindowsPlatformClient.instance.publishNotice(id, {
        'title': title, 'description': description, 'category': _noticeCategory,
        'timestamp': now, 'lastEdited': now,
      });
      if (_editingNoticeId != null) await FirebaseFirestore.instance.collection('school_notices').doc(_editingNoticeId).delete();
      if (!mounted) return;
      _cancelNoticeEdit();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: result.notificationSent ? const Color(0xFF00A884) : Colors.orange,
        content: Text(result.notificationSent
          ? 'Published to the school student app. Notification accepted for ${result.recipients} registered students.'
          : 'Published to the school portal. Notification pending: ${result.error}')));
    } catch (e) {
      if (mounted) {
        setState(() => _isSavingNotice = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Notice save error: $e')));
      }
    }
  }

  void _startEditNotice(String id, Map<String, dynamic> data) {
    setState(() {
      _editingNoticeId = id;
      _noticeTitleController.text = data['title']?.toString() ?? '';
      _noticeDescController.text = data['description']?.toString() ?? '';
      final category = data['category']?.toString();
      _noticeCategory = _noticeCategories.contains(category) ? category! : 'General';
    });
  }

  void _cancelNoticeEdit() {
    setState(() {
      _editingNoticeId = null;
      _noticeTitleController.clear();
      _noticeDescController.clear();
      _noticeCategory = 'Holiday';
      _isSavingNotice = false;
    });
  }

  Future<void> _deleteNotice(String id) async {
    try {
      await FirebaseFirestore.instance.collection('school_notices').doc(id).delete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Notice delete ho gaya!')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Delete error: $e')));
    }
  }

  String _normalizeDirectoryRoll(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return '';

    if (RegExp(r'^\d+$').hasMatch(raw)) {
      final normalized = raw.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      return normalized.isEmpty ? '0' : normalized;
    }

    return raw.toLowerCase();
  }

  Future<void> _searchStudent() async {
    final enteredRoll = _rollController.text.trim();
    final requestedRoll = _normalizeDirectoryRoll(enteredRoll);

    if (requestedRoll.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kripya Roll Number bharein')),
      );
      return;
    }

    setState(() => _isSearchingStudent = true);

    try {
      Map<String, dynamic>? studentData;

      // Fast exact lookup first for the most common stored document IDs.
      final candidateIds = <String>{
        '${_directoryClass}_Roll_$enteredRoll',
        '${_directoryClass}_Roll_$requestedRoll',
      };

      for (final docId in candidateIds) {
        final doc = await FirebaseFirestore.instance
            .collection('students_directory')
            .doc(docId)
            .get();
        if (doc.exists) {
          final data = doc.data();
          if (data != null &&
              _normalizeDirectoryRoll(data['rollNo']?.toString() ?? '') ==
                  requestedRoll) {
            studentData = data;
            break;
          }
        }
      }

      // Fallback handles legacy IDs like Roll_01 / Roll_001 / Roll_0001.
      if (studentData == null) {
        final classSnapshot = await FirebaseFirestore.instance
            .collection('students_directory')
            .where('class', isEqualTo: _directoryClass)
            .get();

        for (final doc in classSnapshot.docs) {
          final data = doc.data();
          final storedRoll =
              _normalizeDirectoryRoll(data['rollNo']?.toString() ?? '');
          if (storedRoll == requestedRoll) {
            studentData = data;
            break;
          }
        }
      }

      if (studentData != null) {
        _nameController.text = studentData['name']?.toString() ?? '';
        _parentContactController.text =
            studentData['parentContact']?.toString() ?? '';
        _studentPhotoUrl = studentData['photoUrl']?.toString();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Color(0xFF00A884),
              content: Text('Student mil gaya!'),
            ),
          );
        }
      } else {
        _nameController.clear();
        _parentContactController.clear();
        _studentPhotoUrl = null;

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.redAccent,
              content: Text('Is Roll No ka koi student nahi mila!'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('Search error: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSearchingStudent = false);
    }
  }

  void _openAddTeacherDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Add Teacher', style: TextStyle(color: Colors.white)),
        content: const Text('Teacher database fields baad mein connect kiye ja sakte hain.', style: TextStyle(color: Colors.grey)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close', style: TextStyle(color: Color(0xFF00A884)))),
        ],
      ),
    );
  }

  void _showProfileDialog() {
    final user = FirebaseAuth.instance.currentUser;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Admin Profile', style: TextStyle(color: Colors.white)),
        content: Text(user?.email ?? 'Admin', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close', style: TextStyle(color: Color(0xFF00A884)))),
        ],
      ),
    );
  }

// ============================================================
// MODERN STUDENT ID CARD - FRONT SIDE
// Preview + QR + Print + PDF Download
// ============================================================

Future<Map<String, dynamic>> _getIdCardStudentData() async {
  final name = _nameController.text.trim().isEmpty
      ? 'Student Name'
      : _nameController.text.trim();

  final roll = _rollController.text.trim().isEmpty
      ? '01'
      : _rollController.text.trim();

  final contact = _parentContactController.text.trim().isEmpty
      ? 'Not Available'
      : _parentContactController.text.trim();

  String parentName = 'N/A';
  String address = 'N/A';
  String district = '';
  String state = '';
  String pinCode = '';
  String admissionDate = 'N/A';
  String dob = 'N/A';
  String studentUid = '';
  bool showStudentUid = false;
  String? photoUrl = _studentPhotoUrl;

  try {
    final docId = '${_directoryClass}_Roll_$roll';

    final doc = await FirebaseFirestore.instance
        .collection('students_directory')
        .doc(docId)
        .get();

    if (doc.exists) {
      final data = doc.data()!;

      parentName =
          data['parentName']?.toString().trim() ?? 'N/A';

      address =
          data['address']?.toString().trim() ?? 'N/A';

      district =
          data['district']?.toString().trim() ?? '';

      state =
          data['state']?.toString().trim() ?? '';

      pinCode =
          data['pinCode']?.toString().trim() ?? '';

      admissionDate =
          data['joiningDate']?.toString().trim() ?? 'N/A';

      dob =
          data['dateOfBirth']?.toString().trim() ?? 'N/A';

      final dbPhoto =
          data['photoUrl']?.toString().trim();

      if (dbPhoto != null && dbPhoto.isNotEmpty) {
        photoUrl = dbPhoto;
      }

      final uidConfig = await _loadTestStudentUidConfig();
      showStudentUid = uidConfig['masterEnabled'] == true &&
          uidConfig['idCardEnabled'] == true;

      if (showStudentUid) {
        studentUid = data[_testStudentUidField]?.toString().trim() ?? '';

        if (studentUid.isEmpty) {
          studentUid = await _ensureTestStudentUid(doc.reference) ?? '';
        }
      }
    }
  } catch (e) {
    debugPrint('ID card data fetch error: $e');
  }

  String fullAddress = [
    address,
    district,
    state,
  ].where((e) {
    final value = e.trim();
    return value.isNotEmpty &&
        value.toLowerCase() != 'n/a';
  }).join(', ');

  if (pinCode.isNotEmpty &&
      pinCode.toLowerCase() != 'n/a') {
    fullAddress = fullAddress.isEmpty
        ? pinCode
        : '$fullAddress - $pinCode';
  }

  if (fullAddress.isEmpty) {
    fullAddress = 'Not Available';
  }

  final classNumber = _directoryClass
      .replaceAll(RegExp(r'[^0-9]'), '');

  final numericRoll = int.tryParse(roll);

  final displayRoll = numericRoll != null
      ? numericRoll.toString().padLeft(3, '0')
      : roll.toUpperCase();

  final studentId =
      'VS-${classNumber.isEmpty ? 'X' : classNumber}-$displayRoll';

  final docId = '${_directoryClass}_Roll_$roll';

  final existingStudentDoc = await FirebaseFirestore.instance
      .collection('students_directory')
      .doc(docId)
      .get();

  final qrData = await _windowsBuildPersonQrPayload(
    type: 'student',
    collection: 'students_directory',
    documentId: docId,
    person: <String, dynamic>{
      ...?existingStudentDoc.data(),
      'name': name,
      'class': _directoryClass,
      'rollNo': roll,
      _testStudentUidField: studentUid,
      'studentCardId': studentId,
    },
  );

  final schoolProfile = await _loadSchoolProfile();

  return {
    'name': name,
    'roll': roll,
    'displayRoll': displayRoll,
    'contact': contact,
    'parentName': parentName,
    'address': fullAddress,
    'admissionDate': admissionDate,
    'dob': dob,
    'photoUrl': photoUrl,
    'studentId': studentId,
    'studentUid': studentUid,
    'showStudentUid': showStudentUid,
    'qrData': qrData,
    'class': _directoryClass,
    'schoolName': _schoolName(schoolProfile),
    'principalName': _principalName(schoolProfile),
    'schoolLogoUrl': schoolProfile['logoUrl']?.toString() ?? '',
    'schoolSealUrl': schoolProfile['sealUrl']?.toString() ?? '',
    'principalSignatureUrl':
        schoolProfile['principalSignatureUrl']?.toString() ?? '',
  };
}

// ============================================================
// ID CARD PREVIEW
// ============================================================

Future<void> _showIdCardPreview() async {
  final data = await _getIdCardStudentData();
  final custom = await WindowsDocumentTemplates.selected('studentId', data, qr:data['qrData'].toString());
  if(custom != null){if(mounted)await WindowsDocumentTemplates.preview(context,custom,title:'Student ID card');return;}

  if (!mounted) return;

  final name = data['name'].toString();
  final roll = data['roll'].toString();
  final parentName = data['parentName'].toString();
  final contact = data['contact'].toString();
  final dob = data['dob'].toString();
  final address = data['address'].toString();
  final studentId = data['studentId'].toString();
  final studentUid = data['studentUid']?.toString() ?? '';
  final showStudentUid = data['showStudentUid'] == true;
  final qrData = data['qrData'].toString();
  final photoUrl = data['photoUrl']?.toString() ?? '';
  final schoolName = data['schoolName']?.toString().trim().isNotEmpty == true
      ? data['schoolName'].toString().trim()
      : '';
  final principalName =
      data['principalName']?.toString().trim().isNotEmpty == true
          ? data['principalName'].toString().trim()
          : '';
  final schoolLogoUrl = data['schoolLogoUrl']?.toString().trim() ?? '';
  final schoolSealUrl = data['schoolSealUrl']?.toString().trim() ?? '';
  final principalSignatureUrl =
      data['principalSignatureUrl']?.toString().trim() ?? '';

  showDialog(
    context: context,
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 610,
                constraints: const BoxConstraints(
                  maxWidth: 610,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF3F5),
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.30),
                      blurRadius: 30,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(18),
                child: AspectRatio(
                  aspectRatio: 85.60 / 53.98,
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0xFF0E7C67),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              const Color(0xFF0B3558)
                                  .withOpacity(0.12),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Stack(
                      children: [
                        // BACKGROUND DECORATION
                        Positioned(
                          right: -65,
                          top: -75,
                          child: Container(
                            width: 230,
                            height: 230,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF00A884)
                                  .withOpacity(0.07),
                            ),
                          ),
                        ),

                        Positioned(
                          left: -55,
                          bottom: -85,
                          child: Container(
                            width: 230,
                            height: 180,
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(100),
                              color: const Color(0xFF0B3558)
                                  .withOpacity(0.04),
                            ),
                          ),
                        ),

                        Column(
                          children: [
                            // =================================
                            // HEADER
                            // =================================
                            Container(
                              height: 82,
                              width: double.infinity,
                              padding:
                                  const EdgeInsets.symmetric(
                                horizontal: 17,
                                vertical: 10,
                              ),
                              decoration:
                                  const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0xFF0B3558),
                                    Color(0xFF07566A),
                                    Color(0xFF008B75),
                                  ],
                                  begin: Alignment.topLeft,
                                  end:
                                      Alignment.bottomRight,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 58,
                                    height: 58,
                                    padding:
                                        const EdgeInsets.all(3),
                                    decoration:
                                        BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                    ),
                                    child: ClipOval(
                                      child: schoolLogoUrl.isNotEmpty
                                          ? Image.network(
                                              schoolLogoUrl,
                                              fit: BoxFit.contain,
errorBuilder: (_, __, ___) =>
                                                  const Icon(
                                                Icons.school_rounded,
                                                color: Color(0xFF0B3558),
                                                size: 32,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.school_rounded,
                                              color: Color(0xFF0B3558),
                                              size: 32,
                                            ),
                                    ),
                                  ),

                                  const SizedBox(width: 12),

                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          schoolName.toUpperCase(),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: .3,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        const Text(
                                          'STUDENT IDENTITY CARD',
                                          style: TextStyle(
                                            color: Color(0xFF98F3D6),
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 1.3,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  Container(
                                    padding:
                                        const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration:
                                        BoxDecoration(
                                      color: Colors.white
                                          .withOpacity(.13),
                                      borderRadius:
                                          BorderRadius.circular(
                                              20),
                                      border: Border.all(
                                        color: Colors.white
                                            .withOpacity(.20),
                                      ),
                                    ),
                                    child: const Text(
                                      'STUDENT',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 8,
                                        fontWeight:
                                            FontWeight.w800,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // GREEN ACCENT BAR
                            Container(
                              height: 5,
                              decoration:
                                  const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0xFF00A884),
                                    Color(0xFF00D9A5),
                                  ],
                                ),
                              ),
                            ),

                            // =================================
                            // BODY
                            // =================================
                            Expanded(
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(
                                  16,
                                  10,
                                  15,
                                  8,
                                ),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    // LEFT INFORMATION
                                    Expanded(
                                      flex: 7,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment
                                                .start,
                                        children: [
                                          Row(
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                  horizontal: 10,
                                                  vertical: 4,
                                                ),
                                                decoration:
                                                    BoxDecoration(
                                                  color:
                                                      const Color(
                                                          0xFF00A884),
                                                  borderRadius:
                                                      BorderRadius
                                                          .circular(
                                                              5),
                                                ),
                                                child:
                                                    const Text(
                                                  'STUDENT ID CARD',
                                                  style:
                                                      TextStyle(
                                                    color:
                                                        Colors.white,
                                                    fontSize: 8.5,
                                                    fontWeight:
                                                        FontWeight
                                                            .w800,
                                                    letterSpacing:
                                                        .6,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(
                                                  width: 8),
                                              Expanded(
                                                child:
                                                    Container(
                                                  height: 1,
                                                  color:
                                                      const Color(
                                                              0xFF00A884)
                                                          .withOpacity(
                                                              .25),
                                                ),
                                              ),
                                            ],
                                          ),

                                          const SizedBox(
                                              height: 7),

                                          _modernIdField(
                                            'Name',
                                            name,
                                            important: true,
                                          ),
                                          _modernIdField(
                                            'Father / Guardian',
                                            parentName,
                                          ),
                                          _modernIdField(
                                            'Class',
                                            _directoryClass,
                                          ),
                                          _modernIdField(
                                            'Roll No.',
                                            roll,
                                          ),
                                          _modernIdField(
                                            'Student ID',
                                            studentId,
                                          ),
                                          _modernIdField(
                                            'Date of Birth',
                                            dob,
                                          ),
                                          _modernIdField(
                                            'Contact',
                                            contact,
                                          ),
                                          _modernIdField(
                                            'Address',
                                            address,
                                            maxLines: 2,
                                          ),

                                          const Spacer(),

                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment
                                                    .end,
                                            children: [
                                              // QR
                                              Container(
                                                width: 58,
                                                height: 58,
                                                padding:
                                                    const EdgeInsets
                                                        .all(3),
                                                decoration:
                                                    BoxDecoration(
                                                  color:
                                                      Colors.white,
                                                  borderRadius:
                                                      BorderRadius
                                                          .circular(
                                                              6),
                                                  border:
                                                      Border.all(
                                                    color:
                                                        const Color(
                                                                0xFF0B3558)
                                                            .withOpacity(
                                                                .18),
                                                  ),
                                                ),
                                                child:
                                                    QrImageView(
                                                  data: qrData,
                                                  version:
                                                      QrVersions
                                                          .auto,
                                                  padding:
                                                      EdgeInsets
                                                          .zero,
                                                  backgroundColor:
                                                      Colors.white,
                                                  eyeStyle:
                                                      const QrEyeStyle(
                                                    eyeShape:
                                                        QrEyeShape
                                                            .square,
                                                    color: Color(
                                                        0xFF0B3558),
                                                  ),
                                                  dataModuleStyle:
                                                      const QrDataModuleStyle(
                                                    dataModuleShape:
                                                        QrDataModuleShape
                                                            .square,
                                                    color: Color(
                                                        0xFF0B3558),
                                                  ),
                                                ),
                                              ),

                                              const SizedBox(
                                                  width: 8),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.only(
                                                        bottom: 3),
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    const Text(
                                                      'SCAN FOR\nSTUDENT\nVERIFICATION',
                                                      style: TextStyle(
                                                        color: Color(0xFF0B3558),
                                                        fontSize: 6.4,
                                                        fontWeight: FontWeight.w800,
                                                        height: 1.25,
                                                        letterSpacing: .3,
                                                      ),
                                                    ),
                                                    if (showStudentUid &&
                                                        studentUid.isNotEmpty) ...[
                                                      const SizedBox(height: 4),
                                                      Container(
                                                        padding: const EdgeInsets.symmetric(
                                                          horizontal: 5,
                                                          vertical: 2,
                                                        ),
                                                        decoration: BoxDecoration(
                                                          color: const Color(0xFF00A884)
                                                              .withOpacity(0.10),
                                                          borderRadius:
                                                              BorderRadius.circular(5),
                                                        ),
                                                        child: Text(
                                                          'UID: $studentUid',
                                                          style: const TextStyle(
                                                            color: Color(0xFF0B6A5B),
                                                            fontSize: 6.2,
                                                            fontWeight: FontWeight.w900,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),

                                    const SizedBox(width: 13),

                                    // RIGHT PHOTO + SIGNATURE
                                    SizedBox(
                                      width: 132,
                                      child: Column(
                                        children: [
                                          Container(
                                            width: 105,
                                            height: 123,
                                            padding:
                                                const EdgeInsets
                                                    .all(3),
                                            decoration:
                                                BoxDecoration(
                                              color:
                                                  Colors.white,
                                              borderRadius:
                                                  BorderRadius
                                                      .circular(12),
                                              border:
                                                  Border.all(
                                                color:
                                                    const Color(
                                                        0xFF00A884),
                                                width: 2,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: const Color(
                                                          0xFF00A884)
                                                      .withOpacity(
                                                          .12),
                                                  blurRadius: 8,
                                                ),
                                              ],
                                            ),
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius
                                                      .circular(8),
                                              child: photoUrl
                                                      .isNotEmpty
                                                  ? Image.network(
                                                      photoUrl,
                                                      fit: BoxFit
                                                          .cover,
errorBuilder:
                                                          (
                                                        context,
                                                        error,
                                                        stackTrace,
                                                      ) =>
                                                              _studentPhotoFallback(
                                                        name,
                                                      ),
                                                    )
                                                  : _studentPhotoFallback(
                                                      name,
                                                    ),
                                            ),
                                          ),

                                          const SizedBox(
                                              height: 5),

                                          Container(
                                            padding:
                                                const EdgeInsets
                                                    .symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration:
                                                BoxDecoration(
                                              color:
                                                  const Color(
                                                      0xFFE6F8F2),
                                              borderRadius:
                                                  BorderRadius
                                                      .circular(20),
                                              border:
                                                  Border.all(
                                                color:
                                                    const Color(
                                                            0xFF00A884)
                                                        .withOpacity(
                                                            .25),
                                              ),
                                            ),
                                            child: const Row(
                                              mainAxisSize:
                                                  MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons
                                                      .verified_rounded,
                                                  color: Color(
                                                      0xFF00A884),
                                                  size: 11,
                                                ),
                                                SizedBox(width: 3),
                                                Text(
                                                  'ACTIVE',
                                                  style:
                                                      TextStyle(
                                                    color: Color(
                                                        0xFF00866C),
                                                    fontWeight:
                                                        FontWeight
                                                            .w800,
                                                    fontSize: 7,
                                                    letterSpacing:
                                                        .5,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),

                                          const Spacer(),

                                          SizedBox(
                                            height: 43,
                                            width: 105,
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                if (schoolSealUrl.isNotEmpty)
                                                  SizedBox(
                                                    width: 34,
                                                    height: 34,
                                                    child: Image.network(
                                                      schoolSealUrl,
                                                      fit: BoxFit.contain,
errorBuilder:
                                                          (_, __, ___) =>
                                                              const SizedBox
                                                                  .shrink(),
                                                    ),
                                                  ),
                                                Expanded(
                                                  child: principalSignatureUrl
                                                          .isNotEmpty
                                                      ? Image.network(
                                                          principalSignatureUrl,
                                                          fit: BoxFit.contain,
errorBuilder:
                                                              (_, __, ___) =>
                                                                  const SizedBox
                                                                      .shrink(),
                                                        )
                                                      : const SizedBox.shrink(),
                                                ),
                                              ],
                                            ),
                                          ),

                                          Container(
                                            width: 100,
                                            height: 1,
                                            color: const Color(0xFF0B3558),
                                          ),

                                          const SizedBox(height: 2),

                                          Text(
                                            principalName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Color(0xFF0B3558),
                                              fontSize: 6.2,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                          const Text(
                                            'PRINCIPAL',
                                            style: TextStyle(
                                              color: Color(0xFF0B3558),
                                              fontSize: 5.6,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: .7,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // =================================
                            // BOTTOM STRIP
                            // =================================
                            Container(
                              height: 24,
                              width: double.infinity,
                              padding:
                                  const EdgeInsets.symmetric(
                                horizontal: 15,
                              ),
                              decoration:
                                  const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0xFF0B3558),
                                    Color(0xFF086A70),
                                  ],
                                ),
                              ),
                              child: const Row(
                                children: [
                                  Icon(
                                    Icons.school_rounded,
                                    color: Color(0xFF6DE3BE),
                                    size: 11,
                                  ),
                                  SizedBox(width: 5),
                                  Text(
                                    'Education for a Better Tomorrow',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 7,
                                      fontWeight:
                                          FontWeight.w600,
                                      fontStyle:
                                          FontStyle.italic,
                                    ),
                                  ),
                                  Spacer(),
                                  Text(
                                    'LEARN • GROW • SUCCEED',
                                    style: TextStyle(
                                      color: Color(0xFF9EECD3),
                                      fontSize: 6.5,
                                      fontWeight:
                                          FontWeight.w700,
                                      letterSpacing: .7,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 14),

              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: () =>
                        Navigator.pop(dialogContext),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(
                        color: Colors.white38,
                      ),
                    ),
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 18,
                    ),
                    label: const Text('Close'),
                  ),

                  ElevatedButton.icon(
                    onPressed: _printIdCard,
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          const Color(0xFF0B3558),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(
                      Icons.print_rounded,
                      size: 18,
                    ),
                    label: const Text('Print ID Card'),
                  ),

                  ElevatedButton.icon(
                    onPressed: _downloadIdCard,
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          const Color(0xFF00A884),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(
                      Icons.download_rounded,
                      size: 18,
                    ),
                    label:
                        const Text('Download PDF'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

// ============================================================
// STUDENT PHOTO FALLBACK
// ============================================================

Widget _studentPhotoFallback(String name) {
  String initial = 'S';

  if (name.trim().isNotEmpty) {
    initial =
        name.trim().substring(0, 1).toUpperCase();
  }

  return Container(
    color: const Color(0xFFE9EFF2),
    child: Center(
      child: Text(
        initial,
        style: const TextStyle(
          color: Color(0xFF0B3558),
          fontSize: 42,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}

// ============================================================
// PREVIEW FIELD
// ============================================================

Widget _modernIdField(
  String label,
  String value, {
  bool important = false,
  int maxLines = 1,
}) {
  final displayValue =
      value.trim().isEmpty ? 'N/A' : value.trim();

  return Padding(
    padding: const EdgeInsets.only(bottom: 3.2),
    child: Row(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF47707D),
              fontSize: 7.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),

        const Text(
          ': ',
          style: TextStyle(
            color: Color(0xFF47707D),
            fontSize: 7.5,
            fontWeight: FontWeight.w700,
          ),
        ),

        Expanded(
          child: Text(
            displayValue,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: const Color(0xFF102A36),
              fontSize: important ? 9.5 : 7.7,
              fontWeight: important
                  ? FontWeight.w800
                  : FontWeight.w600,
              height: 1.15,
            ),
          ),
        ),
      ],
    ),
  );
}

// ============================================================
// BUILD ACTUAL ID CARD PDF
// Standard CR80 Card: 85.60mm x 53.98mm
// ============================================================

Future<Uint8List> _buildIdCardPdf() async {
  final data = await _getIdCardStudentData();
  final custom = await WindowsDocumentTemplates.selected('studentId', data, qr:data['qrData'].toString());
  if(custom != null) return custom;

  final name = data['name'].toString();
  final roll = data['roll'].toString();
  final parentName =
      data['parentName'].toString();
  final contact = data['contact'].toString();
  final dob = data['dob'].toString();
  final address = data['address'].toString();
  final studentId =
      data['studentId'].toString();
  final studentUid =
      data['studentUid']?.toString() ?? '';
  final showStudentUid =
      data['showStudentUid'] == true;
  final qrData = data['qrData'].toString();
  final photoUrl =
      data['photoUrl']?.toString() ?? '';
  final schoolName = data['schoolName']?.toString().trim().isNotEmpty == true
      ? data['schoolName'].toString().trim()
      : '';
  final principalName =
      data['principalName']?.toString().trim().isNotEmpty == true
          ? data['principalName'].toString().trim()
          : '';
  final schoolLogoUrl = data['schoolLogoUrl']?.toString().trim() ?? '';
  final schoolSealUrl = data['schoolSealUrl']?.toString().trim() ?? '';
  final principalSignatureUrl =
      data['principalSignatureUrl']?.toString().trim() ?? '';

  final logoNetworkBytes = await _downloadImageBytes(schoolLogoUrl);
  final signNetworkBytes =
      await _downloadImageBytes(principalSignatureUrl);
  final sealNetworkBytes = await _downloadImageBytes(schoolSealUrl);

  final fallbackLogoBytes = await rootBundle.load('assets/school_logo.png');
  final fallbackSignBytes =
      await rootBundle.load('assets/principal_sign.png');

  final logoImage = pw.MemoryImage(
    logoNetworkBytes ??
        fallbackLogoBytes.buffer.asUint8List(
          fallbackLogoBytes.offsetInBytes,
          fallbackLogoBytes.lengthInBytes,
        ),
  );

  final signImage = pw.MemoryImage(
    signNetworkBytes ??
        fallbackSignBytes.buffer.asUint8List(
          fallbackSignBytes.offsetInBytes,
          fallbackSignBytes.lengthInBytes,
        ),
  );

  final pw.MemoryImage? sealImage =
      sealNetworkBytes == null ? null : pw.MemoryImage(sealNetworkBytes);

  // ==========================================
  // LOAD STUDENT PHOTO
  // ==========================================

  pw.MemoryImage? studentPhoto;

  if (photoUrl.isNotEmpty) {
    try {
      final response =
          await http.get(Uri.parse(photoUrl));

      if (response.statusCode == 200 &&
          response.bodyBytes.isNotEmpty) {
        studentPhoto =
            pw.MemoryImage(response.bodyBytes);
      }
    } catch (e) {
      debugPrint(
          'PDF student photo load error: $e');
    }
  }

  const navy =
      PdfColor(0.043, 0.208, 0.345);

  const teal =
      PdfColor(0.000, 0.659, 0.518);

  const darkText =
      PdfColor(0.063, 0.165, 0.212);

  const muted =
      PdfColor(0.278, 0.439, 0.490);

  const paleGreen =
      PdfColor(0.902, 0.973, 0.949);

  final pdf = pw.Document();

  pdf.addPage(
    pw.Page(
      pageFormat:
          const PdfPageFormat(
        243,
        153,
        marginAll: 0,
      ),
      build: (pw.Context context) {
        return pw.Container(
          width: 243,
          height: 153,
          decoration: pw.BoxDecoration(
            color: PdfColors.white,
            border: pw.Border.all(
              color: teal,
              width: 0.8,
            ),
            borderRadius:
                pw.BorderRadius.circular(5),
          ),
          child: pw.Column(
            children: [
              // ==================================
              // PDF HEADER
              // ==================================
              pw.Container(
                height: 38,
                width: double.infinity,
                padding:
                    const pw.EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 4,
                ),
                decoration:
                    const pw.BoxDecoration(
                  color: navy,
                  borderRadius:
                      pw.BorderRadius.only(
                    topLeft:
                        pw.Radius.circular(4),
                    topRight:
                        pw.Radius.circular(4),
                  ),
                ),
                child: pw.Row(
                  children: [
                    pw.Container(
                      width: 29,
                      height: 29,
                      padding:
                          const pw.EdgeInsets.all(1),
                      decoration:
                          const pw.BoxDecoration(
                        color: PdfColors.white,
                        shape: pw.BoxShape.circle,
                      ),
                      child: pw.ClipOval(
                        child: pw.Image(
                          logoImage,
                          fit: pw.BoxFit.contain,
                        ),
                      ),
                    ),

                    pw.SizedBox(width: 6),

                    pw.Expanded(
                      child: pw.Column(
                        mainAxisAlignment:
                            pw.MainAxisAlignment
                                .center,
                        crossAxisAlignment:
                            pw.CrossAxisAlignment
                                .start,
                        children: [
                          pw.Text(
                            schoolName.toUpperCase(),
                            maxLines: 2,
                            style: pw.TextStyle(
                              color:
                                  PdfColors.white,
                              fontSize: 8.5,
                              fontWeight:
                                  pw.FontWeight.bold,
                            ),
                          ),

                          pw.SizedBox(height: 1),

                          pw.Text(
                            'STUDENT IDENTITY CARD',
                            style: pw.TextStyle(
                              color: teal,
                              fontSize: 5.4,
                              fontWeight: pw.FontWeight.bold,
                              letterSpacing: .8,
                            ),
                          ),

                          pw.SizedBox(height: 1),

                          pw.Text(
                            'DISCIPLINE • KNOWLEDGE • VALUES',
                            style:
                                const pw.TextStyle(
                              color:
                                  PdfColors.grey300,
                              fontSize: 3.8,
                              letterSpacing: .25,
                            ),
                          ),
                        ],
                      ),
                    ),

                    pw.Container(
                      padding:
                          const pw.EdgeInsets
                              .symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration:
                          pw.BoxDecoration(
                        color: paleGreen,
                        borderRadius:
                            pw.BorderRadius
                                .circular(8),
                      ),
                      child: pw.Text(
                        'STUDENT',
                        style: pw.TextStyle(
                          color: teal,
                          fontSize: 5.2,
                          fontWeight:
                              pw.FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              pw.Container(
                height: 2.5,
                color: teal,
              ),

              // ==================================
              // PDF BODY
              // ==================================
              pw.Expanded(
                child: pw.Padding(
                  padding:
                      const pw.EdgeInsets.fromLTRB(
                    7,
                    4,
                    7,
                    3,
                  ),
                  child: pw.Row(
                    crossAxisAlignment:
                        pw.CrossAxisAlignment.start,
                    children: [
                      // LEFT DETAILS
                      pw.Expanded(
                        flex: 7,
                        child: pw.Column(
                          crossAxisAlignment:
                              pw.CrossAxisAlignment
                                  .start,
                          children: [
                            pw.Row(
                              children: [
                                pw.Container(
                                  padding:
                                      const pw.EdgeInsets
                                          .symmetric(
                                    horizontal: 5,
                                    vertical: 1.5,
                                  ),
                                  decoration:
                                      pw.BoxDecoration(
                                    color: teal,
                                    borderRadius:
                                        pw.BorderRadius
                                            .circular(2),
                                  ),
                                  child: pw.Text(
                                    'STUDENT ID CARD',
                                    style:
                                        pw.TextStyle(
                                      color:
                                          PdfColors.white,
                                      fontSize: 4.7,
                                      fontWeight:
                                          pw.FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            pw.SizedBox(height: 3),

                            _pdfModernField(
                              'Name',
                              name,
                              darkText,
                              muted,
                              important: true,
                            ),

                            _pdfModernField(
                              'Father / Guardian',
                              parentName,
                              darkText,
                              muted,
                            ),

                            _pdfModernField(
                              'Class',
                              _directoryClass,
                              darkText,
                              muted,
                            ),

                            _pdfModernField(
                              'Roll No.',
                              roll,
                              darkText,
                              muted,
                            ),

                            _pdfModernField(
                              'Student ID',
                              studentId,
                              darkText,
                              muted,
                            ),

                            _pdfModernField(
                              'DOB',
                              dob,
                              darkText,
                              muted,
                            ),

                            _pdfModernField(
                              'Contact',
                              contact,
                              darkText,
                              muted,
                            ),

                            _pdfModernField(
                              'Address',
                              address,
                              darkText,
                              muted,
                              maxLines: 2,
                            ),

                            pw.Spacer(),

                            pw.Row(
                              crossAxisAlignment:
                                  pw.CrossAxisAlignment
                                      .end,
                              children: [
                                pw.Container(
                                  width: 30,
                                  height: 30,
                                  padding:
                                      const pw.EdgeInsets
                                          .all(1),
                                  decoration:
                                      pw.BoxDecoration(
                                    border: pw.Border.all(
                                      color:
                                          PdfColors.grey400,
                                      width: .3,
                                    ),
                                  ),
                                  child:
                                      pw.BarcodeWidget(
                                    barcode:
                                        pw.Barcode
                                            .qrCode(),
                                    data: qrData,
                                    drawText: false,
                                  ),
                                ),

                                pw.SizedBox(width: 4),

                                pw.Column(
                                  crossAxisAlignment:
                                      pw.CrossAxisAlignment.start,
                                  children: [
                                    pw.Text(
                                      'SCAN FOR\nSTUDENT\nVERIFICATION',
                                      style: pw.TextStyle(
                                        color: navy,
                                        fontSize: 3.3,
                                        fontWeight:
                                            pw.FontWeight.bold,
                                        lineSpacing: 1,
                                      ),
                                    ),
                                    if (showStudentUid &&
                                        studentUid.isNotEmpty) ...[
                                      pw.SizedBox(height: 2),
                                      pw.Container(
                                        padding: const pw.EdgeInsets.symmetric(
                                          horizontal: 2.5,
                                          vertical: 1,
                                        ),
                                        decoration: pw.BoxDecoration(
                                          color: paleGreen,
                                          borderRadius:
                                              pw.BorderRadius.circular(2),
                                        ),
                                        child: pw.Text(
                                          'UID: $studentUid',
                                          style: pw.TextStyle(
                                            color: teal,
                                            fontSize: 3.1,
                                            fontWeight: pw.FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      pw.SizedBox(width: 6),

                      // RIGHT PHOTO/SIGN
                      pw.SizedBox(
                        width: 58,
                        child: pw.Column(
                          children: [
                            pw.Container(
                              width: 47,
                              height: 57,
                              padding:
                                  const pw.EdgeInsets
                                      .all(1.2),
                              decoration:
                                  pw.BoxDecoration(
                                color:
                                    PdfColors.white,
                                border:
                                    pw.Border.all(
                                  color: teal,
                                  width: 1,
                                ),
                                borderRadius:
                                    pw.BorderRadius
                                        .circular(4),
                              ),
                              child:
                                  studentPhoto != null
                                      ? pw.ClipRRect(
                                          horizontalRadius:
                                              3,
                                          verticalRadius:
                                              3,
                                          child: pw.Image(
                                            studentPhoto,
                                            fit: pw
                                                .BoxFit.cover,
                                          ),
                                        )
                                      : pw.Container(
                                          color:
                                              PdfColors
                                                  .grey200,
                                          child:
                                              pw.Center(
                                            child:
                                                pw.Text(
                                              name
                                                      .trim()
                                                      .isNotEmpty
                                                  ? name
                                                      .trim()[0]
                                                      .toUpperCase()
                                                  : 'S',
                                              style:
                                                  pw.TextStyle(
                                                color:
                                                    navy,
                                                fontSize:
                                                    20,
                                                fontWeight:
                                                    pw.FontWeight
                                                        .bold,
                                              ),
                                            ),
                                          ),
                                        ),
                            ),

                            pw.SizedBox(height: 2),

                            pw.Container(
                              padding:
                                  const pw.EdgeInsets
                                      .symmetric(
                                horizontal: 5,
                                vertical: 1.5,
                              ),
                              decoration:
                                  pw.BoxDecoration(
                                color: paleGreen,
                                borderRadius:
                                    pw.BorderRadius
                                        .circular(8),
                              ),
                              child: pw.Text(
                                'ACTIVE',
                                style: pw.TextStyle(
                                  color: teal,
                                  fontSize: 3.7,
                                  fontWeight:
                                      pw.FontWeight.bold,
                                ),
                              ),
                            ),

                            pw.Spacer(),

                            pw.SizedBox(
                              width: 52,
                              height: 21,
                              child: pw.Row(
                                mainAxisAlignment:
                                    pw.MainAxisAlignment.center,
                                children: [
                                  if (sealImage != null)
                                    pw.SizedBox(
                                      width: 17,
                                      height: 17,
                                      child: pw.Image(
                                        sealImage,
                                        fit: pw.BoxFit.contain,
                                      ),
                                    ),
                                  pw.Expanded(
                                    child: pw.Image(
                                      signImage,
                                      fit: pw.BoxFit.contain,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            pw.Container(
                              width: 48,
                              height: .5,
                              color: navy,
                            ),

                            pw.SizedBox(height: 1),

                            pw.Text(
                              principalName,
                              maxLines: 1,
                              style: pw.TextStyle(
                                color: navy,
                                fontSize: 3.2,
                                fontWeight: pw.FontWeight.bold,
                              ),
                            ),
                            pw.Text(
                              'PRINCIPAL',
                              style: pw.TextStyle(
                                color: navy,
                                fontSize: 3.0,
                                fontWeight: pw.FontWeight.bold,
                                letterSpacing: .4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ==================================
              // PDF BOTTOM
              // ==================================
              pw.Container(
                height: 12,
                width: double.infinity,
                padding:
                    const pw.EdgeInsets.symmetric(
                  horizontal: 7,
                ),
                color: navy,
                child: pw.Row(
                  children: [
                    pw.Text(
                      'Education for a Better Tomorrow',
                      style:
                          const pw.TextStyle(
                        color: PdfColors.white,
                        fontSize: 3.8,
                      ),
                    ),

                    pw.Spacer(),

                    pw.Text(
                      'LEARN • GROW • SUCCEED',
                      style: pw.TextStyle(
                        color: teal,
                        fontSize: 3.4,
                        fontWeight:
                            pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  return pdf.save();
}

// ============================================================
// PDF FIELD
// ============================================================

pw.Widget _pdfModernField(
  String label,
  String value,
  PdfColor darkText,
  PdfColor muted, {
  bool important = false,
  int maxLines = 1,
}) {
  final displayValue =
      value.trim().isEmpty ? 'N/A' : value.trim();

  return pw.Padding(
    padding:
        const pw.EdgeInsets.only(bottom: 1.1),
    child: pw.Row(
      crossAxisAlignment:
          pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 43,
          child: pw.Text(
            label,
            style: pw.TextStyle(
              color: muted,
              fontSize: 3.8,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ),

        pw.Text(
          ': ',
          style: pw.TextStyle(
            color: muted,
            fontSize: 3.8,
          ),
        ),

        pw.Expanded(
          child: pw.Text(
            displayValue,
            maxLines: maxLines,
            style: pw.TextStyle(
              color: darkText,
              fontSize: important ? 4.8 : 4,
              fontWeight: important
                  ? pw.FontWeight.bold
                  : pw.FontWeight.normal,
              lineSpacing: .5,
            ),
          ),
        ),
      ],
    ),
  );
}

// ============================================================
// DOWNLOAD PDF
// ============================================================

Future<void> _downloadIdCard() async {
  try {
    final data =
        await _getIdCardStudentData();

    final pdfBytes =
        await _buildIdCardPdf();

    final name =
        data['name'].toString();

    final roll =
        data['roll'].toString();

    final safeName = name
        .replaceAll(
          RegExp(r'[\\/:*?"<>|]'),
          '_',
        )
        .replaceAll(
          RegExp(r'\s+'),
          '_',
        );

    final blob = html.Blob(
      [pdfBytes],
      'application/pdf',
    );

    final url =
        html.Url.createObjectUrlFromBlob(blob);

    final anchor =
        html.AnchorElement(href: url)
          ..setAttribute(
            'download',
            'Vidya_Saarthi_ID_Card_${safeName}_Roll_$roll.pdf',
          )
          ..style.display = 'none';

    html.document.body?.children.add(anchor);

    anchor.click();
    anchor.remove();

    html.Url.revokeObjectUrl(url);

    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(
      const SnackBar(
        backgroundColor:
            Color(0xFF00A884),
        content: Text(
          'Student ID Card PDF download ho gaya.',
        ),
      ),
    );
  } catch (e) {
    debugPrint(
        'ID Card download error: $e');

    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        backgroundColor:
            Colors.redAccent,
        content: Text(
          'ID Card download error: $e',
        ),
      ),
    );
  }
}

// ============================================================
// PRINT ID CARD
// ============================================================

Future<void> _printIdCard() async {
  try {
    final pdfBytes =
        await _buildIdCardPdf();

    await Printing.layoutPdf(
      name: 'Vidya Saarthi Student ID Card',
      format: const PdfPageFormat(
        243,
        153,
        marginAll: 0,
      ),
      onLayout:
          (PdfPageFormat format) async {
        return pdfBytes;
      },
    );
  } catch (e) {
    debugPrint(
        'ID Card print error: $e');

    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        backgroundColor:
            Colors.redAccent,
        content: Text(
          'ID Card print error: $e',
        ),
      ),
    );
  }
}

  Future<void> _confirmAdminLogoutFromHeader() async {
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
              'Logout Admin?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        content: const Text(
          'Logout karne ke baad School Login screen dikhegi.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Logout'),
          ),
        ],
      ),
    );

    if (shouldLogout != true) return;

    _clearPortalSession();
    try {
      await WindowsLocalSession.logout();
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint('Admin header logout sign-out warning: $e');
    }

    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/local-login',
      (route) => false,
    );
  }

  /// Opens the protected Analytics page only after the currently signed-in
  /// Firebase Admin re-authenticates successfully. No password is stored.
  Future<void> _openAdminAnalyticsGate() async {
    final user = FirebaseAuth.instance.currentUser;
    final email = user?.email?.trim() ?? '';

    if (user == null || email.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Admin login session nahi mila.'),
        ),
      );
      return;
    }

    final passwordController = TextEditingController();
    var obscurePassword = true;
    var verifying = false;
    String? errorMessage;

    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> verifyPassword() async {
              final password = passwordController.text;
              if (password.isEmpty || verifying) {
                if (password.isEmpty) {
                  setDialogState(() {
                    errorMessage = 'Admin Password required hai.';
                  });
                }
                return;
              }

              setDialogState(() {
                verifying = true;
                errorMessage = null;
              });

              try {
                final credential = EmailAuthProvider.credential(
                  email: email,
                  password: password,
                );
                await user.reauthenticateWithCredential(credential);

                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(true);
                }
              } on FirebaseAuthException catch (e) {
                if (!dialogContext.mounted) return;
                setDialogState(() {
                  verifying = false;
                  errorMessage =
                      e.code == 'too-many-requests'
                          ? 'Bahut attempts ho gaye. Thodi der baad try karein.'
                          : 'Galat Admin Password.';
                });
              } catch (_) {
                if (!dialogContext.mounted) return;
                setDialogState(() {
                  verifying = false;
                  errorMessage = 'Admin Password verify nahi hua.';
                });
              }
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF172229),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Row(
                children: [
                  Icon(
                    Icons.analytics_rounded,
                    color: Color(0xFF00D9A5),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Admin Password',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'School Analytics kholne ke liye Admin Password enter karein.',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 15),
                    TextField(
                      controller: passwordController,
                      autofocus: true,
                      obscureText: obscurePassword,
                      enabled: !verifying,
                      onSubmitted: (_) => verifyPassword(),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Admin Password',
                        labelStyle: const TextStyle(color: Colors.white54),
                        prefixIcon: const Icon(
                          Icons.lock_outline_rounded,
                          color: Color(0xFF00D9A5),
                        ),
                        suffixIcon: IconButton(
                          onPressed: verifying
                              ? null
                              : () => setDialogState(
                                    () => obscurePassword = !obscurePassword,
                                  ),
                          icon: Icon(
                            obscurePassword
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            color: Colors.white54,
                          ),
                        ),
                        filled: true,
                        fillColor: const Color(0xFF0F191F),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: errorMessage == null
                                ? Colors.white10
                                : Colors.redAccent,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Color(0xFF00D9A5),
                          ),
                        ),
                      ),
                    ),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        errorMessage!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: verifying
                      ? null
                      : () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: verifying ? null : verifyPassword,
                  icon: verifying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.lock_open_rounded, size: 18),
                  label: Text(verifying ? 'Verifying...' : 'Continue'),
                ),
              ],
            );
          },
        );
      },
    );

    passwordController.dispose();

    if (verified != true || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AdminAnalyticsScreen(),
      ),
    );
  }

  void _openAdminDrawerPage(
    Widget page, {
    String? sectionKey,
    String? sectionTitle,
  }) {
    Navigator.of(context).pop();
    Future<void>.delayed(Duration.zero, () async {
      if (!mounted) return;

      if (sectionKey != null) {
        final unlocked = await _requireWindowsSectionPassword(
          context,
          sectionKey,
          sectionTitle ?? 'Protected Section',
        );
        if (!unlocked || !mounted) return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => page),
      );
    });
  }

  Future<void> _openAdminModule(
    Widget page, {
    required String sectionKey,
    required String sectionTitle,
  }) async {
    final unlocked = await _requireWindowsSectionPassword(
      context,
      sectionKey,
      sectionTitle,
    );
    if (!unlocked || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  Widget _buildAdminDrawer() => Drawer(width: WindowsAdminSidebar.width,
    child: _windowsSharedAdminSidebar(context,
      onAnalytics: () { Navigator.of(context).pop(); _openAdminAnalyticsGate(); },
      onLogout: () { Navigator.of(context).pop(); _confirmAdminLogoutFromHeader(); },
      onSelected: (page) {
        if (page == WindowsAdminPage.dashboard) { Navigator.of(context).pop(); return; }
        final module = _windowsAdminModule(page);
        final lock = _windowsAdminModuleLock(page);
        _openAdminDrawerPage(module, sectionKey: lock, sectionTitle: _windowsAdminModuleTitle(page));
      }));

  @override
  Widget build(BuildContext context) {
    final adminEmail = FirebaseAuth.instance.currentUser?.email ?? 'School Administrator';

    return Scaffold(
      key: _adminScaffoldKey,
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 72,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: const Color(0xFF111B21),
        surfaceTintColor: Colors.transparent,
        titleSpacing: 18,
        title: Row(
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(13),
                onTap: () {
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
                },
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF00A884), Color(0xFF00C896)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(13),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00A884).withOpacity(0.22),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.menu_rounded,
                    color: Colors.white,
                    size: 25,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'School Admin Console',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.1,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Vidya Saarthi • School Management',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          _buildPortalSessionTimer(_sessionSecondsRemaining),
          const SizedBox(width: 8),

          // Settings icon opens the Settings screen directly.
          IconButton(
            tooltip: WindowsUiLanguage.translate('Settings'),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const SettingsScreen(),
                ),
              );
              if (mounted) setState(() {});
            },
            icon: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF00A884).withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF00A884).withOpacity(0.28),
                ),
              ),
              child: const Icon(
                Icons.settings_rounded,
                color: Color(0xFF00A884),
                size: 21,
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop || !mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                duration: Duration(seconds: 2),
                backgroundColor: Color(0xFF1F2C34),
                content: Text(
                  'Login screen par jaane ke liye Settings se Logout karein.',
                ),
              ),
            );
        },
        child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 1080;

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              constraints.maxWidth < 600 ? 12 : 18,
              18,
              constraints.maxWidth < 600 ? 12 : 18,
              28,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1450),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildVidyaSaarthiBrandHeader(),
                    const SizedBox(height: 16),
                    _buildAdminHero(adminEmail),
                    const SizedBox(height: 22),
                    if (isWide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 11,
                            child: _buildLeftColumn(),
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            flex: 9,
                            child: _buildRightColumn(),
                          ),
                        ],
                      )
                    else
                      Column(
                        children: [
                          _buildLeftColumn(),
                          const SizedBox(height: 20),
                          _buildRightColumn(),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}


  Widget _buildVidyaSaarthiBrandHeader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isPhone = width < 600;
        final isTablet = width >= 600 && width < 900;

        final headerHeight = isPhone ? 148.0 : (isTablet ? 165.0 : 178.0);
        final panelWidth = isPhone
            ? width * 0.92
            : (isTablet ? width * 0.72 : 560.0);

        final brandFontSize = isPhone ? 25.0 : (isTablet ? 31.0 : 39.0);
        final subtitleFontSize = isPhone ? 8.5 : (isTablet ? 10.0 : 11.5);
        final logoSize = isPhone ? 54.0 : (isTablet ? 66.0 : 76.0);

        return Container(
          width: double.infinity,
          height: headerHeight,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [
                Color(0xFF071820),
                Color(0xFF08262B),
                Color(0xFF07171E),
              ],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: const Color(0xFF00A884).withOpacity(0.16),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.22),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const CustomPaint(
                painter: _VidyaSaarthiWavePainter(),
              ),

              // Very subtle center glow behind the floating brand card.
              Center(
                child: Container(
                  width: isPhone ? width * 0.72 : 500,
                  height: headerHeight * 0.86,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFF00D9A5).withOpacity(0.13),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),

              Center(
                child: Container(
                  width: panelWidth,
                  padding: EdgeInsets.symmetric(
                    horizontal: isPhone ? 15 : 24,
                    vertical: isPhone ? 13 : 17,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFF123D3A).withOpacity(0.88),
                        const Color(0xFF123238).withOpacity(0.82),
                        const Color(0xFF0E242C).withOpacity(0.88),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(21),
                    border: Border.all(
                      color: const Color(0xFF23E4BD).withOpacity(0.66),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00D9A5).withOpacity(0.16),
                        blurRadius: 28,
                        spreadRadius: 1,
                      ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildVidyaSaarthiBrandMark(size: logoSize),
                      SizedBox(width: isPhone ? 12 : 18),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: RichText(
                                text: TextSpan(
                                  style: TextStyle(
                                    fontSize: brandFontSize,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.8,
                                    height: 1,
                                  ),
                                  children: const [
                                    TextSpan(
                                      text: 'Vidya ',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                    TextSpan(
                                      text: 'Saarthi',
                                      style: TextStyle(
                                        color: Color(0xFF17DFC0),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(height: isPhone ? 6 : 8),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'D I G I T A L   S C H O O L   C O N T R O L   H U B',
                                maxLines: 1,
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: subtitleFontSize,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: isPhone ? 0.6 : 1.25,
                                ),
                              ),
                            ),
                            SizedBox(height: isPhone ? 9 : 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Container(
                                    height: 1.2,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      gradient: LinearGradient(
                                        colors: [
                                          const Color(0xFF3EA6FF).withOpacity(0.85),
                                          const Color(0xFF00E6B8).withOpacity(0.15),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 11),
                                  child: Icon(
                                    Icons.school_rounded,
                                    size: 17,
                                    color: Color(0xFF00E6B8),
                                  ),
                                ),
                                Expanded(
                                  child: Container(
                                    height: 1.2,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      gradient: LinearGradient(
                                        colors: [
                                          const Color(0xFF00E6B8).withOpacity(0.15),
                                          const Color(0xFF00E6B8).withOpacity(0.85),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildVidyaSaarthiBrandMark({required double size}) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(0xFF00D9A5).withOpacity(0.22),
                  const Color(0xFF00A884).withOpacity(0.07),
                  Colors.transparent,
                ],
              ),
              border: Border.all(
                color: const Color(0xFF00E6C0).withOpacity(0.35),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(0, size * 0.08),
            child: Icon(
              Icons.auto_stories_rounded,
              size: size * 0.66,
              color: const Color(0xFF2BDCC1),
            ),
          ),
          Positioned(
            top: size * 0.08,
            child: Container(
              width: size * 0.18,
              height: size * 0.18,
              decoration: const BoxDecoration(
                color: Color(0xFFFFC857),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: size * 0.17,
            child: Container(
              width: size * 0.34,
              height: size * 0.34,
              decoration: BoxDecoration(
                color: const Color(0xFF0A2429),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF00E6C0).withOpacity(0.60),
                ),
              ),
              child: Icon(
                Icons.school_rounded,
                size: size * 0.20,
                color: const Color(0xFF00E6C0),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdminHero(String adminEmail) {
    final now = DateTime.now();
    final months = const [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final dateText = '${now.day} ${months[now.month - 1]} ${now.year}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF173A36),
            Color(0xFF13262A),
            Color(0xFF111B21),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: const Color(0xFF00A884).withOpacity(0.16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.22),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF00A884).withOpacity(0.13),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFF00A884).withOpacity(0.20),
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.verified_user_rounded,
                  color: Color(0xFF00D9A5),
                  size: 14,
                ),
                SizedBox(width: 6),
                Text(
                  'ADMIN ACCESS',
                  style: TextStyle(
                    color: Color(0xFF00D9A5),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.7,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _schoolProfileCacheRef().snapshots(),
            builder: (context, snapshot) {
              final profile = _mergeSchoolProfile(snapshot.data?.data());
              final schoolName = _schoolName(profile);
              return Text(
                schoolName.isEmpty ? 'Welcome' : 'Welcome to $schoolName',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              );
            },
          ),
          const SizedBox(height: 7),
          Text(
            adminEmail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            dateText,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

Widget _buildOverviewCards() {
  return LayoutBuilder(
    builder: (context, constraints) {
      final maxWidth = constraints.maxWidth;
      final columns = maxWidth >= 1000 ? 4 : (maxWidth >= 620 ? 2 : 1);
      final spacing = 12.0;

      final itemWidth = columns == 1
          ? maxWidth
          : (maxWidth - (spacing * (columns - 1))) / columns;

      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('students_directory')
                .snapshots(),
            builder: (context, snapshot) {
              final count = snapshot.data?.docs.length;

              return _overviewCard(
                width: itemWidth,
                icon: Icons.people_alt_rounded,
                title: count == null
                    ? 'Student Records'
                    : 'Student Records • $count',
                subtitle: count == null
                    ? 'Loading student count...'
                    : 'Total Students: $count',
                accent: const Color(0xFF00A884),
                onTap: () => _openAdminModule(
                  const AllStudentsListScreen(),
                  sectionKey: _windowsStudentRecordsLock,
                  sectionTitle: 'Student Records',
                ),
              );
            },
          ),

          _overviewCard(
            width: itemWidth,
            icon: Icons.payments_rounded,
            title: windowsTr('fees'),
            subtitle: 'Collect fees, receipts & dues',
            accent: Colors.greenAccent,
            onTap: () => _openAdminModule(
              const FeesCollectionScreen(),
              sectionKey: _windowsFeesCollectionLock,
              sectionTitle: 'Fees Collection',
            ),
          ),
              
          _overviewCard(
            width: itemWidth,
            icon: Icons.fact_check_rounded,
            title: windowsTr('exam'),
            subtitle: 'Marks, results & report cards',
            accent: Colors.orangeAccent,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ExamCenterScreen(),
                ),
              );
            },
          ),

          _overviewCard(
            width: itemWidth,
            icon: Icons.school_rounded,
            title: windowsTr('teachers'),
            subtitle: 'Directory, profiles & schedules',
            accent: Colors.purpleAccent,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const TeachersDirectoryScreen(),
                ),
              );
            },
          ),
        ],
      );
    },
  );
}

  Widget _overviewCard({
    required double width,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
    VoidCallback? onTap,
  }) {
    final card = Container(
      width: width,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF111B21),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: onTap != null
              ? accent.withOpacity(0.28)
              : Colors.white.withOpacity(0.055),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 43,
            height: 43,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.11),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: accent.withOpacity(0.18)),
            ),
            child: Icon(icon, color: accent, size: 21),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 9.8,
                  ),
                ),
              ],
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.arrow_forward_ios_rounded,
              color: accent.withOpacity(0.85),
              size: 14,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return card;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: card,
      ),
    );
  }

  Widget _buildLeftColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _adminPanel(
          icon: Icons.campaign_rounded,
          title: 'Digital Notice Board',
          subtitle: _editingNoticeId == null
              ? 'Create and publish a new school announcement'
              : 'Editing an existing school announcement',
          accent: Colors.orangeAccent,
          trailing: _editingNoticeId == null
              ? null
              : TextButton.icon(
                  onPressed: _cancelNoticeEdit,
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Cancel Edit'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 560;

                  final category = DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: _noticeCategory,
                    dropdownColor: const Color(0xFF1B2A32),
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Notice Type').copyWith(
                      prefixIcon: const Icon(
                        Icons.category_outlined,
                        color: Color(0xFF00A884),
                        size: 19,
                      ),
                    ),
                    items: _noticeCategories
                        .map(
                          (value) => DropdownMenuItem<String>(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _noticeCategory = value);
                      }
                    },
                  );

                  final title = TextField(
                    controller: _noticeTitleController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Notice Title').copyWith(
                      prefixIcon: const Icon(
                        Icons.title_rounded,
                        color: Color(0xFF00A884),
                        size: 19,
                      ),
                    ),
                  );

                  if (compact) {
                    return Column(
                      children: [
                        category,
                        const SizedBox(height: 10),
                        title,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      SizedBox(width: 180, child: category),
                      const SizedBox(width: 10),
                      Expanded(child: title),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _noticeDescController,
                minLines: 3,
                maxLines: 5,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Details / Instructions').copyWith(
                  alignLabelWithHint: true,
                  prefixIcon: const Padding(
                    padding: EdgeInsets.only(bottom: 54),
                    child: Icon(
                      Icons.notes_rounded,
                      color: Color(0xFF00A884),
                      size: 19,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 13),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                    disabledBackgroundColor: const Color(0xFF00A884).withOpacity(0.35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _isSavingNotice ? null : _saveNotice,
                  icon: _isSavingNotice
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          _editingNoticeId == null
                              ? Icons.send_rounded
                              : Icons.check_circle_outline_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                  label: Text(
                    _isSavingNotice
                        ? 'Saving...'
                        : (_editingNoticeId == null
                            ? 'Publish Notice'
                            : 'Update Notice'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _adminPanel(
          icon: Icons.badge_rounded,
          title: 'Student Directory & ID Cards',
          subtitle: 'Search student records and manage digital ID cards',
          accent: const Color(0xFF00A884),
          trailing: TextButton.icon(
            onPressed: _openAddStudentDialog,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF00D9A5),
              backgroundColor: const Color(0xFF00A884).withOpacity(0.09),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
            label: const Text(
              'Add Student',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
          child: Column(
            children: [
              if (_studentPhotoUrl != null && _studentPhotoUrl!.trim().isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D171C),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF00A884).withOpacity(0.12),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFF00A884),
                            width: 1.5,
                          ),
                        ),
                        child: ClipOval(
                          child: Image.network(
                            _studentPhotoUrl!,
                            fit: BoxFit.cover,
errorBuilder: (_, __, ___) => const ColoredBox(
                              color: Color(0xFF162229),
                              child: Icon(
                                Icons.person_rounded,
                                color: Color(0xFF00A884),
                                size: 27,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _nameController.text.trim().isEmpty
                                  ? 'Student Found'
                                  : _nameController.text.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$_directoryClass • Roll ${_rollController.text.trim()}',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 10.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.verified_rounded,
                        color: Color(0xFF00A884),
                        size: 19,
                      ),
                    ],
                  ),
                ),
              ],
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 520;

                  final classField = DropdownButtonFormField<String>(
                    value: _directoryClass,
                    dropdownColor: const Color(0xFF1B2A32),
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Class').copyWith(
                      prefixIcon: const Icon(
                        Icons.school_outlined,
                        color: Color(0xFF00A884),
                        size: 19,
                      ),
                    ),
                    items: _classList
                        .map(
                          (value) => DropdownMenuItem<String>(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _directoryClass = value;
                          _nameController.clear();
                          _parentContactController.clear();
                          _studentPhotoUrl = null;
                        });
                      }
                    },
                  );

                  final rollField = TextField(
                    controller: _rollController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (_) {
                      if (_studentPhotoUrl != null ||
                          _nameController.text.isNotEmpty ||
                          _parentContactController.text.isNotEmpty) {
                        setState(() {
                          _studentPhotoUrl = null;
                          _nameController.clear();
                          _parentContactController.clear();
                        });
                      }
                    },
                    decoration: _inputDecoration('Roll No').copyWith(
                      prefixIcon: const Icon(
                        Icons.numbers_rounded,
                        color: Color(0xFF00A884),
                        size: 19,
                      ),
                    ),
                  );

                  if (compact) {
                    return Column(
                      children: [
                        classField,
                        const SizedBox(height: 10),
                        rollField,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: classField),
                      const SizedBox(width: 10),
                      Expanded(child: rollField),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameController,
                readOnly: true,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Student Full Name').copyWith(
                  prefixIcon: const Icon(
                    Icons.person_outline_rounded,
                    color: Colors.white38,
                    size: 19,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _parentContactController,
                readOnly: true,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Parent Contact No').copyWith(
                  prefixIcon: const Icon(
                    Icons.phone_outlined,
                    color: Colors.white38,
                    size: 19,
                  ),
                ),
              ),
              const SizedBox(height: 13),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 520;

                  final searchButton = _dashboardActionButton(
                    icon: Icons.search_rounded,
                    label: _isSearchingStudent ? 'Searching...' : 'Search Record',
                    onPressed: _isSearchingStudent ? null : _searchStudent,
                    primary: true,
                  );

                  final idButton = _dashboardActionButton(
                    icon: Icons.badge_outlined,
                    label: 'View ID Card',
                    onPressed: _showIdCardPreview,
                  );

                  if (compact) {
                    return Column(
                      children: [
                        SizedBox(width: double.infinity, child: searchButton),
                        const SizedBox(height: 9),
                        SizedBox(width: double.infinity, child: idButton),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: searchButton),
                      const SizedBox(width: 9),
                      Expanded(child: idButton),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRightColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _adminPanel(
          icon: Icons.notifications_active_outlined,
          title: 'Published Notices',
          subtitle: 'Preview, edit or remove live announcements',
          accent: Colors.blueAccent,
          child: SizedBox(
            height: 430,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('school_notices')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF00A884),
                      strokeWidth: 2.4,
                    ),
                  );
                }

                if (snapshot.hasError) {
                  return _adminEmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: 'Notice load nahi ho paya',
                    subtitle: 'Internet ya Firebase connection check karein.',
                  );
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return _adminEmptyState(
                    icon: Icons.notifications_none_rounded,
                    title: 'Abhi koi notice published nahi hai',
                    subtitle: 'Left panel se pehla notice publish karein.',
                  );
                }

                final docs = snapshot.data!.docs;

                return ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 9),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final category = data['category']?.toString() ?? 'General';
                    final accent = _adminCategoryColor(category);

                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _showNoticeDetailDialog(data),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D171C),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.045),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: accent.withOpacity(0.11),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Icon(
                                  _adminCategoryIcon(category),
                                  color: accent,
                                  size: 19,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      spacing: 7,
                                      runSpacing: 5,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: accent.withOpacity(0.10),
                                            borderRadius: BorderRadius.circular(20),
                                          ),
                                          child: Text(
                                            category,
                                            style: TextStyle(
                                              color: accent,
                                              fontSize: 9,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          'Notice ${index + 1}',
                                          style: const TextStyle(
                                            color: Colors.white24,
                                            fontSize: 8.8,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(data['title']?.toString() ?? 'Untitled Notice', translate: false,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w800,
                                        height: 1.25,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(data['description']?.toString() ?? '', translate: false,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 10.2,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                tooltip: WindowsUiLanguage.translate('Notice Actions'),
                                color: const Color(0xFF1B2A32),
                                icon: const Icon(
                                  Icons.more_vert_rounded,
                                  color: Colors.white38,
                                  size: 20,
                                ),
                                onSelected: (value) {
                                  if (value == 'preview') {
                                    _showNoticeDetailDialog(data);
                                  } else if (value == 'edit') {
                                    _startEditNotice(doc.id, data);
                                  } else if (value == 'delete') {
                                    _deleteNotice(doc.id);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'preview',
                                    child: Row(
                                      children: [
                                        Icon(Icons.visibility_outlined, color: Color(0xFF00A884), size: 18),
                                        SizedBox(width: 9),
                                        Text('Preview', style: TextStyle(color: Colors.white)),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Row(
                                      children: [
                                        Icon(Icons.edit_outlined, color: Colors.blueAccent, size: 18),
                                        SizedBox(width: 9),
                                        Text('Edit', style: TextStyle(color: Colors.white)),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                                        SizedBox(width: 9),
                                        Text('Delete', style: TextStyle(color: Colors.redAccent)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _adminPanel({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111B21),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: Colors.white.withOpacity(0.055)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.14),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.11),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withOpacity(0.15)),
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 9.8,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing,
              ],
            ],
          ),
          const SizedBox(height: 15),
          Container(
            height: 1,
            color: Colors.white.withOpacity(0.045),
          ),
          const SizedBox(height: 15),
          child,
        ],
      ),
    );
  }

  Widget _dashboardActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool primary = false,
    bool soft = false,
  }) {
    if (primary) {
      return ElevatedButton.icon(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00A884),
          disabledBackgroundColor: const Color(0xFF00A884).withOpacity(0.30),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
        ),
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    if (soft) {
      return TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF00D9A5),
          backgroundColor: const Color(0xFF00A884).withOpacity(0.075),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
            side: BorderSide(
              color: const Color(0xFF00A884).withOpacity(0.14),
            ),
          ),
        ),
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF00D9A5),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
        side: BorderSide(
          color: const Color(0xFF00A884).withOpacity(0.38),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
        ),
      ),
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _adminEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: const Color(0xFF00A884).withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: const Color(0xFF00A884),
                size: 27,
              ),
            ),
            const SizedBox(height: 13),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white30,
                fontSize: 10,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _adminCategoryColor(String category) {
    switch (category.toLowerCase()) {
      case 'holiday':
        return Colors.orangeAccent;
      case 'exam':
        return Colors.redAccent;
      case 'event':
        return Colors.blueAccent;
      case 'general':
      default:
        return const Color(0xFF00A884);
    }
  }

  IconData _adminCategoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'holiday':
        return Icons.beach_access_rounded;
      case 'exam':
        return Icons.menu_book_rounded;
      case 'event':
        return Icons.event_rounded;
      case 'general':
      default:
        return Icons.campaign_rounded;
    }
  }

  void _showNoticeDetailDialog(Map<String, dynamic> data) {
    final category = data['category']?.toString() ?? 'General';
    final accent = _adminCategoryColor(category);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111B21),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.11),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _adminCategoryIcon(category),
                color: accent,
                size: 20,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      category,
                      style: TextStyle(
                        color: accent,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(data['title']?.toString() ?? 'Notice', translate: false,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(data['description']?.toString() ?? '', translate: false,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Close',
              style: TextStyle(
                color: Color(0xFF00A884),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        color: Colors.white30,
        fontSize: 11.5,
      ),
      filled: true,
      fillColor: const Color(0xFF0D171C),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 13,
        vertical: 13,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: BorderSide(
          color: Colors.white.withOpacity(0.055),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(
          color: Color(0xFF00A884),
          width: 1.15,
        ),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: BorderSide.none,
      ),
    );
  }

}

// ============================================================
// PROTECTED ADMIN ANALYTICS
// ============================================================

class _AdminAnalyticsPair {
  const _AdminAnalyticsPair({this.pass = 0, this.fail = 0});

  final double pass;
  final double fail;
}

class _AdminAnalyticsData {
  const _AdminAnalyticsData({
    required this.totalStudents,
    required this.totalTeachers,
    required this.totalFees,
    required this.totalExpenses,
    required this.passStudents,
    required this.failStudents,
    required this.studentAttendance,
    required this.teacherAttendance,
    required this.attendanceTrend,
    required this.feesByMonth,
    required this.expensesByMonth,
    required this.passFailByMonth,
    required this.admissionsByMonth,
  });

  final int totalStudents;
  final int totalTeachers;
  final double totalFees;
  final double totalExpenses;
  final int passStudents;
  final int failStudents;
  final double studentAttendance;
  final double teacherAttendance;
  final List<double> attendanceTrend;
  final List<double> feesByMonth;
  final List<double> expensesByMonth;
  final List<_AdminAnalyticsPair> passFailByMonth;
  final List<double> admissionsByMonth;
}

class AdminAnalyticsScreen extends StatefulWidget {
  const AdminAnalyticsScreen({super.key});

  @override
  State<AdminAnalyticsScreen> createState() => _AdminAnalyticsScreenState();
}

class _AdminAnalyticsScreenState extends State<AdminAnalyticsScreen> {
  static const List<String> _monthLabels = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  // The rollover month is selected in Admin Settings.
  final List<int> _availableYears = <int>[
    DateTime.now().year,
    DateTime.now().year - 1,
    DateTime.now().year - 2,
  ];

  final Map<String, int> _chartMonths = {};
  late int _selectedYear;
  int _academicYearRolloverMonth = 1;
  bool _loading = true;
  String? _error;
  _AdminAnalyticsData? _data;

  @override
  void initState() {
    super.initState();
    _selectedYear = _availableYears.first;
    _loadAcademicYearSettingsAndAnalytics();
  }

  Future<void> _loadAcademicYearSettingsAndAnalytics() async {
    final month = await WindowsAcademicYearSettings.load();
    if (!mounted) return;
    setState(() {
      _academicYearRolloverMonth = month;
      _selectedYear = WindowsAcademicYearSettings.startYear(
        DateTime.now(),
        month,
      );
    });
    await _loadAnalytics();
  }

  Future<QuerySnapshot<Map<String, dynamic>>?> _analyticsGet(
    String collection,
  ) async {
    try {
      return await FirebaseFirestore.instance.collection(collection).get();
    } catch (e) {
      debugPrint('Analytics $collection read skipped: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _analyticsLoadExpenses() async {
    try {
      final connection = await WindowsConnectionCenter.reload();
      if (!connection.remoteReady) return <Map<String, dynamic>>[];
      final url = connection.googleScriptUrl;
      final response = await WindowsBackendBridge.post(
        Uri.parse(url),
        headers: const {'Content-Type': 'text/plain;charset=utf-8'},
        body: jsonEncode(const {'action': 'list_school_expenses'}),
      );

      if (response.statusCode != 200) return <Map<String, dynamic>>[];
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['expenses'] is! List) {
        return <Map<String, dynamic>>[];
      }

      return (decoded['expenses'] as List)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (e) {
      debugPrint('Analytics expenses read skipped: $e');
      return <Map<String, dynamic>>[];
    }
  }

  double _analyticsNumber(dynamic value) {
    if (value is num) return value.toDouble();
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return 0;
    return double.tryParse(
          text.replaceAll(',', '').replaceAll('₹', '').replaceAll('%', ''),
        ) ??
        0;
  }

  double _analyticsAmount(
    Map<String, dynamic> data,
    List<String> keys,
  ) {
    for (final key in keys) {
      if (data.containsKey(key)) {
        final value = _analyticsNumber(data[key]);
        if (value != 0) return value;
      }
    }
    return 0;
  }

  DateTime? _analyticsDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;

    if (value is num) {
      final number = value.toInt();
      if (number > 100000000000) {
        return DateTime.fromMillisecondsSinceEpoch(number);
      }
      if (number > 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch(number * 1000);
      }
    }

    if (value is Map) {
      final seconds = value['seconds'] ?? value['_seconds'];
      if (seconds is num) {
        return DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);
      }
    }

    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;

    final parsed = DateTime.tryParse(text);
    if (parsed != null) return parsed;

    final dmy = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$')
        .firstMatch(text);
    if (dmy != null) {
      return DateTime(
        int.parse(dmy.group(3)!),
        int.parse(dmy.group(2)!),
        int.parse(dmy.group(1)!),
      );
    }

    return null;
  }

  int? _analyticsMonthToken(String token) {
    final text = token.trim();
    if (text.isEmpty) return null;

    final yearMonth = RegExp(r'^(\d{4})[-/](\d{1,2})').firstMatch(text);
    if (yearMonth != null) {
      final year = int.tryParse(yearMonth.group(1) ?? '');
      final month = int.tryParse(yearMonth.group(2) ?? '');
      if (year == _selectedYear && month != null && month >= 1 && month <= 12) {
        return month - 1;
      }
      return null;
    }

    final numeric = int.tryParse(text);
    if (numeric != null && numeric >= 1 && numeric <= 12) return numeric - 1;

    final lower = text.toLowerCase();
    for (var index = 0; index < _monthLabels.length; index++) {
      if (lower.startsWith(_monthLabels[index].toLowerCase())) return index;
    }
    return null;
  }

  int? _analyticsMonth(
    Map<String, dynamic> data, {
    List<String>? keys,
  }) {
    final candidates = keys ?? const <String>[
      'month',
      'timestamp',
      'createdAt',
      'updatedAt',
      'date',
      'dateText',
      'paymentDate',
      'paidAt',
      'admissionDate',
    ];

    for (final key in candidates.where((k) => k != 'month')) {
      final date = _analyticsDate(data[key]);
      if (date == null) continue;
      return WindowsAcademicYearSettings.startYear(date, _academicYearRolloverMonth) == _selectedYear ? date.month - 1 : null;
    }
    for (final key in candidates) {
      final value = data[key];
      if (value == null) continue;

      final tokenMonth = _analyticsMonthToken(value.toString());
      if (tokenMonth != null && value is String && value.length <= 7) {
        return tokenMonth;
      }
      if (tokenMonth != null && value is num && value >= 1 && value <= 12) {
        return tokenMonth;
      }

      final date = _analyticsDate(value);
      if (date != null && WindowsAcademicYearSettings.startYear(date, _academicYearRolloverMonth) == _selectedYear) return date.month - 1;
    }
    return null;
  }

  double? _analyticsAttendance(
    Map<String, dynamic> data,
    List<String> directKeys,
  ) {
    for (final key in directKeys) {
      if (!data.containsKey(key)) continue;
      var value = _analyticsNumber(data[key]);
      if (value > 0 && value <= 1) value *= 100;
      if (value >= 0 && value <= 100) return value;
    }

    final present = _analyticsAmount(
      data,
      const ['presentDays', 'daysPresent', 'present', 'attendancePresent'],
    );
    final total = _analyticsAmount(
      data,
      const ['totalDays', 'workingDays', 'attendanceDays', 'daysTotal'],
    );
    if (total > 0) return (present / total * 100).clamp(0, 100).toDouble();
    return null;
  }

  List<double> _analyticsAttendanceTrend(
    List<Map<String, dynamic>> records,
    double average,
    List<String> historyKeys,
  ) {
    final values = List<double>.filled(12, 0);
    final counts = List<int>.filled(12, 0);

    for (final record in records) {
      dynamic history;
      for (final key in historyKeys) {
        if (record[key] is Map) {
          history = record[key];
          break;
        }
      }
      if (history is! Map) continue;

      for (final entry in history.entries) {
        final month = _analyticsMonthToken(entry.key.toString());
        final value = _analyticsNumber(entry.value);
        if (month == null || value <= 0) continue;
        values[month] += value <= 1 ? value * 100 : value;
        counts[month]++;
      }
    }

    for (var index = 0; index < values.length; index++) {
      if (counts[index] > 0) {
        values[index] /= counts[index];
      }
    }
    return values;
  }

  String _analyticsStatus(Map<String, dynamic> data) {
    for (final key in const [
      'result',
      'status',
      'lastExamResult',
      'lastResult',
    ]) {
      final value = data[key]?.toString().trim().toUpperCase() ?? '';
      if (value == 'PASS' || value == 'FAIL') return value;
    }
    return '';
  }

  String _analyticsStudentIdentity(Map<String, dynamic> data) {
    String valueFor(List<String> keys) {
      for (final key in keys) {
        final value = _normalizeIdentityPart(data[key]);
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    final profileParts = <String>[
      valueFor(const ['name', 'studentName']),
      valueFor(const ['parentName', 'fatherName', 'guardianName']),
      valueFor(const ['dateOfBirth', 'dob']),
      valueFor(const ['class', 'studentClass']),
      valueFor(const ['rollNo', 'roll', 'rollNumber']),
      valueFor(const ['parentContact', 'fatherContact', 'guardianContact']),
    ];
    final meaningfulParts = profileParts.where((value) => value.isNotEmpty);

    // Student records can be duplicated with different Firestore document IDs.
    // Prefer the stable profile fingerprint so one real student is counted once.
    if (meaningfulParts.length >= 2) {
      return 'profile:${profileParts.join('|')}';
    }

    final uid = valueFor(const [
      'uniqueStudentId',
      'studentUid',
      'studentUidTest',
      'studentId',
      'admissionNo',
      'admissionNumber',
    ]);
    if (uid.isNotEmpty) return 'uid:$uid';

    final documentId = valueFor(const ['_analyticsDocId']);
    return documentId.isEmpty ? 'record:${data.hashCode}' : 'doc:$documentId';
  }

  List<Map<String, dynamic>> _analyticsUniqueStudents(
    List<Map<String, dynamic>> records,
  ) {
    final unique = <String, Map<String, dynamic>>{};
    for (final record in records) {
      unique.putIfAbsent(_analyticsStudentIdentity(record), () => record);
    }
    return unique.values.toList();
  }

  Future<void> _loadAnalytics() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final snapshots =
          await Future.wait<QuerySnapshot<Map<String, dynamic>>?>([
        _analyticsGet('students_directory'),
        _analyticsGet('teachers_directory'),
        _analyticsGet('fee_payments'),
        _analyticsGet('fee_ledger'),
        _analyticsGet('attendance_records'),
        _analyticsGet('school_calendar'),
      ]);

      final rawStudents = snapshots[0]?.docs
              .map((doc) => <String, dynamic>{
                    ...doc.data(),
                    '_analyticsDocId': doc.id,
                  })
              .toList() ??
          <Map<String, dynamic>>[];
      final students = _analyticsUniqueStudents(rawStudents);
      final teachers = snapshots[1]?.docs
              .map((doc) => doc.data())
              .toList() ??
          <Map<String, dynamic>>[];
      var feeRecords = snapshots[2]?.docs
              .map((doc) => doc.data())
              .toList() ??
          <Map<String, dynamic>>[];
      if (feeRecords.isEmpty) {
        feeRecords = snapshots[3]?.docs
                .map((doc) => doc.data())
                .toList() ??
            <Map<String, dynamic>>[];
      }

      final expenses = await _analyticsLoadExpenses();

      _ExamCenterSnapshot? examSnapshot;
      try {
        examSnapshot = await _ExamCenterDataCache.refresh(force: true);
      } catch (e) {
        debugPrint('Analytics exam data skipped: $e');
      }

      final feesByMonth = List<double>.filled(12, 0);
      var totalFees = 0.0;
      for (final record in feeRecords) {
        final amount = _analyticsAmount(
          record,
          const [
            'installmentAmount',
            'amount',
            'paidAmount',
            'totalPaid',
            'paid',
          ],
        );
        totalFees += amount;
        final month = _analyticsMonth(record);
        if (month != null) feesByMonth[month] += amount;
      }

      final expensesByMonth = List<double>.filled(12, 0);
      var totalExpenses = 0.0;
      for (final record in expenses) {
        final amount = _analyticsAmount(record, const ['amount', 'value']);
        totalExpenses += amount;
        final month = _analyticsMonth(record);
        if (month != null) expensesByMonth[month] += amount;
      }

      var passStudents = 0;
      var failStudents = 0;
      final passFailByMonth = List<_AdminAnalyticsPair>.generate(
        12,
        (_) => const _AdminAnalyticsPair(),
      );

      final examResults = examSnapshot?.results ?? <Map<String, dynamic>>[];
      for (final result in examResults) {
        final status = _analyticsStatus(result);
        final passed = status == 'PASS';
        final failed = status == 'FAIL';
        if (passed) passStudents++;
        if (failed) failStudents++;
        final month = _analyticsMonth(result);
        if (month != null) {
          final old = passFailByMonth[month];
          passFailByMonth[month] = _AdminAnalyticsPair(
            pass: old.pass + (passed ? 1 : 0),
            fail: old.fail + (failed ? 1 : 0),
          );
        }
      }

      // If Exam Center has not produced results yet, use the latest result
      // fields already mirrored in the student records when available.
      if (passStudents == 0 && failStudents == 0) {
        for (final student in students) {
          final status = _analyticsStatus(student);
          if (status == 'PASS') passStudents++;
          if (status == 'FAIL') failStudents++;
        }
      }

      final studentAttendanceValues = students
          .map(
            (item) => _analyticsAttendance(
              item,
              const [
                'attendancePercentage',
                'attendancePercent',
                'attendanceRate',
                'studentAttendance',
              ],
            ),
          )
          .whereType<double>()
          .toList();
      final teacherAttendanceValues = teachers
          .map(
            (item) => _analyticsAttendance(
              item,
              const [
                'attendancePercentage',
                'attendancePercent',
                'attendanceRate',
                'teacherAttendance',
              ],
            ),
          )
          .whereType<double>()
          .toList();

      double average(List<double> values) => values.isEmpty
          ? 0
          : values.reduce((a, b) => a + b) / values.length;

      final studentAttendance = average(studentAttendanceValues);
      final teacherAttendance = average(teacherAttendanceValues);

      final admissionsByMonth = List<double>.filled(12, 0);
      for (final student in students) {
        final month = _analyticsMonth(
          student,
          keys: const [
            'admissionDate',
            'admissionDateText',
            'createdAt',
            'timestamp',
          ],
        );
        if (month != null) admissionsByMonth[month]++;
      }

      final attendanceRecords = snapshots[4]?.docs.map((d) => d.data()).toList() ?? <Map<String, dynamic>>[];
      final calendar = snapshots[5]?.docs.map((d) => {'date': d.id, ...d.data()}).toList() ?? <Map<String, dynamic>>[];
      final monthlyAttendance = windowsMonthlyAttendance(records: attendanceRecords, calendar: calendar,
        role: 'student', people: students.length, startYear: _selectedYear,
        rolloverMonth: _academicYearRolloverMonth, today: DateTime.now());

      final result = _AdminAnalyticsData(
        totalStudents: students.length,
        totalTeachers: teachers.length,
        totalFees: totalFees,
        totalExpenses: totalExpenses,
        passStudents: passStudents,
        failStudents: failStudents,
        studentAttendance: studentAttendance,
        teacherAttendance: teacherAttendance,
        attendanceTrend: attendanceRecords.isNotEmpty ? monthlyAttendance : _analyticsAttendanceTrend(
          students, studentAttendance, const ['attendanceHistory', 'monthlyAttendance', 'attendanceByMonth']),
        feesByMonth: feesByMonth,
        expensesByMonth: expensesByMonth,
        passFailByMonth: passFailByMonth,
        admissionsByMonth: admissionsByMonth,
      );

      if (!mounted) return;
      setState(() {
        _data = result;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Admin Analytics load error: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Analytics data load nahi ho paaya: $e';
      });
    }
  }

  String _money(double value) {
    if (value >= 10000000) return '₹${(value / 10000000).toStringAsFixed(2)}Cr';
    if (value >= 100000) return '₹${(value / 100000).toStringAsFixed(2)}L';
    if (value >= 1000) return '₹${(value / 1000).toStringAsFixed(1)}K';
    return '₹${value.toStringAsFixed(0)}';
  }

  String _academicYear(int year) {
    final next = ((year + 1) % 100).toString().padLeft(2, '0');
    return '$year-$next';
  }

  String _trend(List<double> values, {bool percentage = false}) {
    final nonZero = values.where((value) => value > 0).toList();
    if (nonZero.length < 2) return '—';
    final first = nonZero.first;
    final last = nonZero.last;
    if (first == 0) return '—';
    final change = ((last - first) / first) * 100;
    final prefix = change >= 0 ? '▲ +' : '▼ ';
    return '$prefix${change.abs().toStringAsFixed(1)}%';
  }

  Color _trendColor(String value) => value.startsWith('▼')
      ? Colors.redAccent
      : const Color(0xFF00D9A5);

  Widget _metricCard({
    required double width,
    required String title,
    required String value,
    required String subtitle,
    required String trend,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      width: width,
      constraints: const BoxConstraints(minHeight: 100),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0D2027),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(.25)),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(.05),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 43,
            height: 43,
            decoration: BoxDecoration(
              color: color.withOpacity(.13),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white30,
                          fontSize: 8.5,
                        ),
                      ),
                    ),
                    if (trend != '—')
                      Text(
                        trend,
                        style: TextStyle(
                          color: _trendColor(trend),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chartCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required String trend,
    required Widget chart,
    Widget? footer,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0D2027),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: color.withOpacity(.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withOpacity(.13),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
              ),
              if (trend != '—')
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _trendColor(trend).withOpacity(.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _trendColor(trend).withOpacity(.25),
                    ),
                  ),
                  child: Text(
                    trend,
                    style: TextStyle(
                      color: _trendColor(trend),
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              const SizedBox(width: 7),
              _analyticsDropdownPill(title),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(height: 190, child: chart),
          if ((_chartMonths[title] ?? -1) >= 0 && _data != null)
            Text(_chartMonthSummary(title, _chartMonths[title]!), key: ValueKey('monthly-value-$title'),
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
          if (footer != null) ...[
            const SizedBox(height: 2),
            footer,
          ],
        ],
      ),
    );
  }

  String _chartMonthSummary(String title, int month) {
    final data = _data!;
    final label = WindowsUiLanguage.translate(_monthLabels[month]);
    final value = switch (title) {
      'Student Attendance Trend' => '${data.attendanceTrend[month].toStringAsFixed(1)}%',
      'Monthly Fees Collection' => _money(data.feesByMonth[month]),
      'Monthly School Expenses' => _money(data.expensesByMonth[month]),
      'Pass vs Fail Trend' => '${WindowsUiLanguage.translate('Pass Students')}: ${data.passFailByMonth[month].pass.toInt()} / ${WindowsUiLanguage.translate('Fail Students')}: ${data.passFailByMonth[month].fail.toInt()}',
      _ => '${data.admissionsByMonth[month].toInt()}',
    };
    return '$label: $value';
  }

  Widget _analyticsDropdownPill(String chart) => PopupMenuButton<int>(
    tooltip: WindowsUiLanguage.translate('Select month'),
    initialValue: _chartMonths[chart] ?? -1,
    onSelected: (month) => setState(() => _chartMonths[chart] = month),
    itemBuilder: (_) => [
      const PopupMenuItem(value: -1, child: Text('All months')),
      for (var i = 0; i < 12; i++) PopupMenuItem(value: i, child: Text('${WindowsUiLanguage.translate(_monthLabels[i])} ${i + 1 < _academicYearRolloverMonth ? _selectedYear + 1 : _selectedYear}', translate: false)),
    ],
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(color: const Color(0xFF12313A), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text((_chartMonths[chart] ?? -1) == -1 ? 'Monthly' : _monthLabels[_chartMonths[chart]!], style: const TextStyle(color: Colors.white70, fontSize: 10)),
        const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
      ])));
  List<T> _chartValues<T>(String chart, List<T> values) {
    final month = _chartMonths[chart] ?? -1;
    return month == -1 ? values : [values[month]];
  }
  List<String> _chartLabels(String chart) => _chartValues(chart, _monthLabels);

  Widget _legend(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 9),
        ),
      ],
    );
  }

  Widget _analyticsSidebar() => _windowsSharedAdminSidebar(context,
    onAnalytics: null,
    onLogout: () => _windowsConfirmLogout(context),
    onSelected: (page) {
      if (page == WindowsAdminPage.dashboard) { Navigator.of(context).pop(); return; }
      final module = _windowsAdminModule(page);
      final lock = _windowsAdminModuleLock(page);
      if (lock != null) {
        _openAnalyticsModule(module, sectionKey: lock, sectionTitle: _windowsAdminModuleTitle(page));
      } else {
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => module));
      }
    });

  Future<void> _openAnalyticsSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AdminSettingsScreen(),
      ),
    );

    if (!mounted) return;
    await _loadAcademicYearSettingsAndAnalytics();
    setState(() {});
  }

  Future<void> _openAnalyticsModule(
    Widget page, {
    required String sectionKey,
    required String sectionTitle,
  }) async {
    final unlocked = await _requireWindowsSectionPassword(
      context,
      sectionKey,
      sectionTitle,
    );
    if (!unlocked || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;

    return Scaffold(
      backgroundColor: const Color(0xFF06151B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF071A21),
        elevation: 0,
        title: const Text(
          'Admin Analytics',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: WindowsUiLanguage.translate('Refresh analytics'),
            onPressed: _loading ? null : _loadAnalytics,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal = constraints.maxWidth < 700 ? 12.0 : 22.0;
          final content = SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(horizontal, 18, horizontal, 30),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1450),
                child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: _schoolProfileCacheRef().snapshots(),
                  builder: (context, profileSnapshot) {
                    final profile = _mergeSchoolProfile(
                      profileSnapshot.data?.data(),
                    );
                    final schoolName = _schoolName(profile);

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFF0A2830),
                                Color(0xFF07181F),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(21),
                            border: Border.all(
                              color: const Color(0xFF00D9A5).withOpacity(.22),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 54,
                                height: 54,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00A884).withOpacity(.14),
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: const Icon(
                                  Icons.analytics_rounded,
                                  color: Color(0xFF00D9A5),
                                  size: 29,
                                ),
                              ),
                              const SizedBox(width: 13),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'School Analytics',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 24,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      schoolName.toUpperCase(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 10,
                                        letterSpacing: 1.3,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  value: _selectedYear,
                                  dropdownColor: const Color(0xFF12272F),
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Color(0xFF00D9A5),
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  items: _availableYears
                                      .map(
                                        (year) => DropdownMenuItem<int>(
                                          value: year,
                                          child: Text(_academicYear(year)),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (value) {
                                    if (value == null || value == _selectedYear) {
                                      return;
                                    }
                                    setState(() => _selectedYear = value);
                                    _loadAnalytics();
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: WindowsUiLanguage.translate('Admin Settings'),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 42,
                                  height: 42,
                                ),
                                splashRadius: 21,
                                onPressed: () async {
                                  await _openAnalyticsSettings();
                                },
                                icon: Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00A884).withOpacity(.12),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: const Color(0xFF00A884).withOpacity(.25),
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.settings_rounded,
                                    color: Color(0xFF00D9A5),
                                    size: 20,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_loading)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 100),
                            child: Center(
                              child: CircularProgressIndicator(
                                color: Color(0xFF00D9A5),
                              ),
                            ),
                          )
                        else if (data == null)
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.all(40),
                              child: Text(
                                _error ?? 'Analytics data available nahi hai.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white54),
                              ),
                            ),
                          )
                        else ...[
                          _buildMetrics(data, constraints.maxWidth),
                          const SizedBox(height: 16),
                          _buildCharts(data, constraints.maxWidth),
                        ],
                        if (_error != null && !_loading)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 10,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          );

          if (constraints.maxWidth >= 1000) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _analyticsSidebar(),
                Expanded(child: content),
              ],
            );
          }

          return content;
        },
      ),
    );
  }

  Widget _buildMetrics(_AdminAnalyticsData data, double maxWidth) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1200
            ? 4
            : (constraints.maxWidth >= 700 ? 2 : 1);
        final gap = 12.0;
        final width = columns == 1
            ? constraints.maxWidth
            : (constraints.maxWidth - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            _metricCard(
              width: width,
              title: 'Total Students',
              value: '${data.totalStudents}',
              subtitle: 'Live student records',
              trend: _trend(data.admissionsByMonth),
              icon: Icons.groups_rounded,
              color: const Color(0xFF00D9D0),
            ),
            _metricCard(
              width: width,
              title: 'Total Teachers',
              value: '${data.totalTeachers}',
              subtitle: 'Teacher directory',
              trend: '—',
              icon: Icons.person_rounded,
              color: Colors.purpleAccent,
            ),
            _metricCard(
              width: width,
              title: 'Total Student Fees Collection',
              value: _money(data.totalFees),
              subtitle: 'Fee payments recorded',
              trend: _trend(data.feesByMonth),
              icon: Icons.account_balance_wallet_rounded,
              color: Colors.greenAccent,
            ),
            _metricCard(
              width: width,
              title: 'Total School Expenses',
              value: _money(data.totalExpenses),
              subtitle: 'Expense entries recorded',
              trend: _trend(data.expensesByMonth),
              icon: Icons.monetization_on_rounded,
              color: Colors.amberAccent,
            ),
            _metricCard(
              width: width,
              title: 'Total Students Pass',
              value: '${data.passStudents}',
              subtitle: 'Exam results',
              trend: _trend(data.passFailByMonth.map((e) => e.pass).toList()),
              icon: Icons.school_rounded,
              color: const Color(0xFF00D9A5),
            ),
            _metricCard(
              width: width,
              title: 'Total Students Fail',
              value: '${data.failStudents}',
              subtitle: 'Exam results',
              trend: _trend(data.passFailByMonth.map((e) => e.fail).toList()),
              icon: Icons.school_outlined,
              color: Colors.redAccent,
            ),
            _metricCard(
              width: width,
              title: 'Total Student Attendance',
              value: '${data.studentAttendance.toStringAsFixed(1)}%',
              subtitle: 'Attendance records',
              trend: _trend(data.attendanceTrend),
              icon: Icons.person_pin_circle_rounded,
              color: const Color(0xFF69C2FF),
            ),
            _metricCard(
              width: width,
              title: 'Total Teacher Attendance',
              value: '${data.teacherAttendance.toStringAsFixed(1)}%',
              subtitle: 'Attendance records',
              trend: '—',
              icon: Icons.groups_rounded,
              color: const Color(0xFF4D86FF),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCharts(_AdminAnalyticsData data, double maxWidth) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = 14.0;
        final columns = constraints.maxWidth >= 1100 ? 2 : 1;
        final width = columns == 1
            ? constraints.maxWidth
            : (constraints.maxWidth - gap) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            SizedBox(
              width: width,
              child: _chartCard(
                title: 'Student Attendance Trend',
                subtitle: 'Monthly student attendance',
                icon: Icons.groups_rounded,
                color: const Color(0xFF00D9D0),
                trend: _trend(data.attendanceTrend),
                chart: _AnalyticsLineChart(
                  values: _chartValues('Student Attendance Trend', data.attendanceTrend),
                  labels: _chartLabels('Student Attendance Trend'),
                  color: const Color(0xFF16D8E4),
                  percent: true,
                ),
              ),
            ),
            SizedBox(
              width: width,
              child: _chartCard(
                title: 'Monthly Fees Collection',
                subtitle: 'Student fee payments',
                icon: Icons.account_balance_wallet_rounded,
                color: Colors.greenAccent,
                trend: _trend(data.feesByMonth),
                chart: _AnalyticsBarChart(
                  values: _chartValues('Monthly Fees Collection', data.feesByMonth),
                  labels: _chartLabels('Monthly Fees Collection'),
                  color: const Color(0xFF24D5BE),
                  money: true,
                ),
              ),
            ),
            SizedBox(
              width: width,
              child: _chartCard(
                title: 'Monthly School Expenses',
                subtitle: 'Google Drive expense entries',
                icon: Icons.monetization_on_rounded,
                color: Colors.amberAccent,
                trend: _trend(data.expensesByMonth),
                chart: _AnalyticsBarChart(
                  values: _chartValues('Monthly School Expenses', data.expensesByMonth),
                  labels: _chartLabels('Monthly School Expenses'),
                  color: Colors.orangeAccent,
                  money: true,
                ),
              ),
            ),
            SizedBox(
              width: width,
              child: _chartCard(
                title: 'Pass vs Fail Trend',
                subtitle: 'Monthly exam results',
                icon: Icons.bar_chart_rounded,
                color: Colors.orangeAccent,
                trend: _trend(
                  data.passFailByMonth.map((e) => e.pass).toList(),
                ),
                chart: _AnalyticsPassFailChart(
                  values: _chartValues('Pass vs Fail Trend', data.passFailByMonth),
                  labels: _chartLabels('Pass vs Fail Trend'),
                ),
                footer: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _legend('Pass Students', const Color(0xFF53E6A6)),
                    const SizedBox(width: 18),
                    _legend('Fail Students', Colors.redAccent),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: width,
              child: _chartCard(
                title: 'New Admissions',
                subtitle: 'Monthly admission records',
                icon: Icons.person_add_alt_1_rounded,
                color: const Color(0xFF00B7FF),
                trend: _trend(data.admissionsByMonth),
                chart: _AnalyticsLineChart(
                  values: _chartValues('New Admissions', data.admissionsByMonth),
                  labels: _chartLabels('New Admissions'),
                  color: const Color(0xFF28A9F0),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AnalyticsLineChart extends StatelessWidget {
  const _AnalyticsLineChart({
    required this.values,
    required this.labels,
    required this.color,
    this.percent = false,
  });

  final List<double> values;
  final List<String> labels;
  final Color color;
  final bool percent;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AnalyticsLinePainter(
        values: values,
        labels: labels,
        color: color,
        percent: percent,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _AnalyticsBarChart extends StatelessWidget {
  const _AnalyticsBarChart({
    required this.values,
    required this.labels,
    required this.color,
    this.money = false,
  });

  final List<double> values;
  final List<String> labels;
  final Color color;
  final bool money;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AnalyticsBarPainter(
        values: values,
        labels: labels,
        color: color,
        money: money,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _AnalyticsPassFailChart extends StatelessWidget {
  const _AnalyticsPassFailChart({
    required this.values,
    required this.labels,
  });

  final List<_AdminAnalyticsPair> values;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AnalyticsPassFailPainter(values: values, labels: labels),
      child: const SizedBox.expand(),
    );
  }
}

abstract class _AnalyticsPainterBase extends CustomPainter {
  static const Color gridColor = Color(0x263A7B86);
  static const TextStyle axisStyle = TextStyle(
    color: Colors.white54,
    fontSize: 8,
  );

  void drawText(Canvas canvas, String text, Offset offset, {TextStyle? style}) {
    final painter = TextPainter(
      text: TextSpan(text: WindowsUiLanguage.translate(text), style: style ?? axisStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  void drawGrid(Canvas canvas, Size size, Rect chart) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = chart.top + chart.height * i / 4;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), paint);
    }
    for (var i = 0; i < 12; i++) {
      final x = chart.left + chart.width * i / 11;
      canvas.drawLine(Offset(x, chart.top), Offset(x, chart.bottom), paint);
    }
  }

  Rect chartRect(Size size) => Rect.fromLTRB(
        35,
        10,
        size.width - 8,
        size.height - 25,
      );
}

class _AnalyticsLinePainter extends _AnalyticsPainterBase {
  _AnalyticsLinePainter({
    required this.values,
    required this.labels,
    required this.color,
    required this.percent,
  });

  final List<double> values;
  final List<String> labels;
  final Color color;
  final bool percent;

  @override
  void paint(Canvas canvas, Size size) {
    final chart = chartRect(size);
    drawGrid(canvas, size, chart);
    final maxValue = percent
        ? 100.0
        : ((values.fold<double>(0, (a, b) => a > b ? a : b) * 1.18) <= 1
            ? 1.0
            : values.fold<double>(0, (a, b) => a > b ? a : b) * 1.18);
    final safeMax = maxValue <= 0 ? 1.0 : maxValue;

    final path = Path();
    final fill = Path();
    for (var i = 0; i < values.length; i++) {
      final x = values.length <= 1
          ? chart.left
          : chart.left + chart.width * i / (values.length - 1);
      final y = chart.bottom -
          (values[i].clamp(0, safeMax).toDouble() / safeMax) * chart.height;
      if (i == 0) {
        path.moveTo(x, y);
        fill.moveTo(x, chart.bottom);
        fill.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fill.lineTo(x, y);
      }
      canvas.drawCircle(Offset(x, y), 3.1, Paint()..color = color);
    }
    fill.lineTo(chart.right, chart.bottom);
    fill.close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          colors: [color.withOpacity(.30), color.withOpacity(.01)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(chart),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.1
        ..strokeJoin = StrokeJoin.round,
    );

    for (var i = 0; i < labels.length; i++) {
      final x = chart.left + chart.width * i / max(1, labels.length - 1);
      drawText(canvas, labels[i], Offset(x - 8, chart.bottom + 7));
    }
    if (percent) {
      drawText(canvas, '100%', const Offset(2, 7));
      drawText(canvas, '50%', Offset(7, chart.top + chart.height / 2 - 5));
      drawText(canvas, '0%', Offset(13, chart.bottom - 5));
    }
  }

  @override
  bool shouldRepaint(covariant _AnalyticsLinePainter oldDelegate) => true;
}

class _AnalyticsBarPainter extends _AnalyticsPainterBase {
  _AnalyticsBarPainter({
    required this.values,
    required this.labels,
    required this.color,
    required this.money,
  });

  final List<double> values;
  final List<String> labels;
  final Color color;
  final bool money;

  @override
  void paint(Canvas canvas, Size size) {
    final chart = chartRect(size);
    drawGrid(canvas, size, chart);
    final highest = values.fold<double>(0, (a, b) => a > b ? a : b);
    final maxValue = highest <= 0 ? 1.0 : highest * 1.2;
    final slot = chart.width / values.length;
    final barWidth = slot * .56;

    for (var i = 0; i < values.length; i++) {
      final height =
          (values[i].clamp(0, maxValue).toDouble() / maxValue) * chart.height;
      final left = chart.left + slot * i + (slot - barWidth) / 2;
      final rect = Rect.fromLTRB(
        left,
        chart.bottom - height,
        left + barWidth,
        chart.bottom,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()
          ..shader = LinearGradient(
            colors: [color, color.withOpacity(.55)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ).createShader(rect),
      );
      drawText(canvas, labels[i], Offset(left + barWidth / 2 - 8, chart.bottom + 7));
    }

    final suffix = money ? '₹' : '';
    drawText(canvas, '$suffix${_compactChartNumber(maxValue)}', const Offset(2, 7));
    drawText(canvas, '$suffix${_compactChartNumber(maxValue / 2)}', Offset(2, chart.top + chart.height / 2 - 5));
    drawText(canvas, '${suffix}0', Offset(13, chart.bottom - 5));
  }

  String _compactChartNumber(double value) {
    if (value >= 100000) return '${(value / 100000).toStringAsFixed(1)}L';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return value.toStringAsFixed(0);
  }

  @override
  bool shouldRepaint(covariant _AnalyticsBarPainter oldDelegate) => true;
}

class _AnalyticsPassFailPainter extends _AnalyticsPainterBase {
  _AnalyticsPassFailPainter({required this.values, required this.labels});

  final List<_AdminAnalyticsPair> values;
  final List<String> labels;

  @override
  void paint(Canvas canvas, Size size) {
    final chart = chartRect(size);
    drawGrid(canvas, size, chart);
    final highest = values.fold<double>(0, (best, item) {
      final value = item.pass > item.fail ? item.pass : item.fail;
      return value > best ? value : best;
    });
    final maxValue = highest <= 0 ? 1.0 : highest * 1.2;
    final slot = chart.width / values.length;
    final barWidth = slot * .23;

    for (var i = 0; i < values.length; i++) {
      final left = chart.left + slot * i + slot * .22;
      final passHeight = (values[i].pass / maxValue) * chart.height;
      final failHeight = (values[i].fail / maxValue) * chart.height;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(left, chart.bottom - passHeight, left + barWidth, chart.bottom),
          const Radius.circular(2),
        ),
        Paint()..color = const Color(0xFF53E6A6),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(left + barWidth + 2, chart.bottom - failHeight, left + barWidth * 2 + 2, chart.bottom),
          const Radius.circular(2),
        ),
        Paint()..color = Colors.redAccent,
      );
      drawText(canvas, labels[i], Offset(left - 2, chart.bottom + 7));
    }

    drawText(canvas, _compactChartNumber(maxValue), const Offset(2, 7));
    drawText(canvas, _compactChartNumber(maxValue / 2), Offset(2, chart.top + chart.height / 2 - 5));
    drawText(canvas, '0', Offset(20, chart.bottom - 5));
  }

  String _compactChartNumber(double value) {
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return value.toStringAsFixed(0);
  }

  @override
  bool shouldRepaint(covariant _AnalyticsPassFailPainter oldDelegate) => true;
}

// ============================================================
// SETTINGS SCREEN
// ============================================================
// ============================================================
// SCHOOL SETTINGS
// Text + Logo + Seal + Principal Signature are stored in Google Drive.
// Firestore keeps only a fast cache of the Drive-backed profile.
// ============================================================

class SchoolSettingsScreen extends StatefulWidget {
  const SchoolSettingsScreen({super.key});

  @override
  State<SchoolSettingsScreen> createState() => _SchoolSettingsScreenState();
}

class _SchoolSettingsScreenState extends State<SchoolSettingsScreen> {
  final TextEditingController _schoolNameController = TextEditingController();
  final TextEditingController _principalNameController = TextEditingController();
  final TextEditingController _schoolContactController = TextEditingController();
  final TextEditingController _schoolLatitudeController = TextEditingController();
  final TextEditingController _schoolLongitudeController = TextEditingController();
  final TextEditingController _attendanceRadiusController = TextEditingController(text: '200');
  String _selectedWindowsLanguage = _windowsLanguage();

  bool _loading = false;
  bool _saving = false;
  String? _error;

  String _logoUrl = '';
  String _sealUrl = '';
  String _signatureUrl = '';

  Uint8List? _logoBytes;
  Uint8List? _sealBytes;
  Uint8List? _signatureBytes;

  String _logoFileName = 'school_logo.png';
  String _sealFileName = 'school_seal.png';
  String _signatureFileName = 'principal_signature.png';

  String _logoMimeType = 'image/png';
  String _sealMimeType = 'image/png';
  String _signatureMimeType = 'image/png';

  @override
  void initState() {
    super.initState();

    // Paint immediately from memory/defaults; refresh cache/Drive in background.
    _applyProfile(
      _schoolProfileMemoryCache ?? _defaultSchoolProfile(),
    );
    _load();
  }

  @override
  void dispose() {
    _schoolNameController.dispose();
    _principalNameController.dispose();
    _schoolContactController.dispose();
    _schoolLatitudeController.dispose();
    _schoolLongitudeController.dispose();
    _attendanceRadiusController.dispose();
    super.dispose();
  }

  String _mimeFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  void _applyProfile(Map<String, dynamic> profile) {
    _schoolNameController.text = _schoolName(profile);
    _principalNameController.text = _principalName(profile);
    _schoolContactController.text =
        profile['schoolContactNo']?.toString().trim() ?? '';
    _logoUrl = profile['logoUrl']?.toString().trim() ?? '';
    _sealUrl = profile['sealUrl']?.toString().trim() ?? '';
    _signatureUrl =
        profile['principalSignatureUrl']?.toString().trim() ?? '';
    _schoolLatitudeController.text = profile['latitude']?.toString() ?? '';
    _schoolLongitudeController.text = profile['longitude']?.toString() ?? '';
    _attendanceRadiusController.text =
        profile['attendanceRadiusMeters']?.toString() ?? '200';
  }

  Future<void> _pasteGoogleMapsCoordinates() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = clipboard?.text?.trim() ?? '';
    final coordinates = _windowsParseCoordinates(raw);

    if (coordinates == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text(
            'Google Maps se latitude, longitude copy karke paste karein.',
          ),
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _schoolLatitudeController.text = coordinates.latitude.toStringAsFixed(7);
      _schoolLongitudeController.text = coordinates.longitude.toStringAsFixed(7);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: Color(0xFF00A884),
        content: Text('Google Maps coordinates fill ho gaye. Ab Save karein.'),
      ),
    );
  }

  Future<void> _load() async {
    // Never block the screen with a full-page loader.
    try {
      final cached = await _loadSchoolProfileCache();
      if (mounted) {
        setState(() {
          _applyProfile(cached);
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      debugPrint('School profile cache load warning: $e');
    }

    // Google Drive is source-of-truth, but refresh does not block opening.
    Future<void>(() async {
      try {
        final fresh = await _refreshSchoolProfileFromDrive();
        if (!mounted) return;
        setState(() {
          _applyProfile(fresh);
          _error = null;
        });
      } catch (e) {
        debugPrint('School profile background refresh warning: $e');
      }
    });
  }

  Future<bool> _confirmAdminPasswordBeforeSave() async {
    final user = FirebaseAuth.instance.currentUser;
    final email = user?.email?.trim() ?? '';

    if (user == null || email.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('Admin login session nahi mila.'),
          ),
        );
      }
      return false;
    }

    final passwordController = TextEditingController();
    bool obscure = true;
    bool verifying = false;
    String? errorMessage;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF172229),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              title: const Row(
                children: [
                  Icon(
                    Icons.lock_rounded,
                    color: Color(0xFF00D9A5),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Confirm Admin Password',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'School Settings save karne se pehle Admin Password verify karein.',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: passwordController,
                      obscureText: obscure,
                      autofocus: true,
                      onSubmitted: verifying
                          ? null
                          : (_) async {
                              final password = passwordController.text;
                              if (password.isEmpty) {
                                setDialogState(() {
                                  errorMessage = 'Admin Password required hai.';
                                });
                                return;
                              }
                              setDialogState(() {
                                verifying = true;
                                errorMessage = null;
                              });
                              try {
                                final credential = EmailAuthProvider.credential(
                                  email: email,
                                  password: password,
                                );
                                await user.reauthenticateWithCredential(credential);
                                if (dialogContext.mounted) {
                                  Navigator.pop(dialogContext, true);
                                }
                              } catch (_) {
                                setDialogState(() {
                                  verifying = false;
                                  errorMessage = 'Galat Admin Password.';
                                });
                              }
                            },
                      style: const TextStyle(color: Colors.white),
                      decoration: _field(
                        'Admin Password',
                        Icons.password_rounded,
                      ).copyWith(
                        suffixIcon: IconButton(
                          onPressed: verifying
                              ? null
                              : () => setDialogState(() => obscure = !obscure),
                          icon: Icon(
                            obscure
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        errorMessage!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: verifying
                      ? null
                      : () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: verifying
                      ? null
                      : () async {
                          final password = passwordController.text;
                          if (password.isEmpty) {
                            setDialogState(() {
                              errorMessage = 'Admin Password required hai.';
                            });
                            return;
                          }
                          setDialogState(() {
                            verifying = true;
                            errorMessage = null;
                          });
                          try {
                            final credential = EmailAuthProvider.credential(
                              email: email,
                              password: password,
                            );
                            await user.reauthenticateWithCredential(credential);
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext, true);
                            }
                          } catch (_) {
                            setDialogState(() {
                              verifying = false;
                              errorMessage = 'Galat Admin Password.';
                            });
                          }
                        },
                  icon: verifying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.verified_user_rounded, size: 18),
                  label: Text(verifying ? 'Verifying...' : 'Verify & Save'),
                ),
              ],
            );
          },
        );
      },
    );

    passwordController.dispose();
    return confirmed == true;
  }

  Future<void> _pickAsset(String type) async {
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1600,
    );
    if (image == null) return;

    final bytes = await image.readAsBytes();
    if (!mounted) return;

    final mime = _mimeFromName(image.name);

    setState(() {
      if (type == 'logo') {
        _logoBytes = bytes;
        _logoFileName = image.name;
        _logoMimeType = mime;
      } else if (type == 'seal') {
        _sealBytes = bytes;
        _sealFileName = image.name;
        _sealMimeType = mime;
      } else {
        _signatureBytes = bytes;
        _signatureFileName = image.name;
        _signatureMimeType = mime;
      }
    });
  }

  String _dataUri(Uint8List bytes, String mime) {
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  Future<void> _save() async {
    if (_saving) return;

    final schoolName = _schoolNameController.text.trim();
    final principalName = _principalNameController.text.trim();
    final schoolContactNo = _schoolContactController.text.trim();
    final schoolLatitude = double.tryParse(_schoolLatitudeController.text.trim());
    final schoolLongitude = double.tryParse(_schoolLongitudeController.text.trim());
    final attendanceRadius =
        double.tryParse(_attendanceRadiusController.text.trim()) ?? 200.0;

    if (schoolLatitude == null || schoolLongitude == null ||
        schoolLatitude < -90 || schoolLatitude > 90 ||
        schoolLongitude < -180 || schoolLongitude > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text('Valid School Latitude aur Longitude required hai.'),
        ),
      );
      return;
    }

    if (attendanceRadius < 50 || attendanceRadius > 2000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text('Attendance radius 50 se 2000 meter ke beech rakhein.'),
        ),
      );
      return;
    }

    if (schoolName.isEmpty || principalName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text('School Name aur Principal Name required hai.'),
        ),
      );
      return;
    }

    final passwordConfirmed = await _confirmAdminPasswordBeforeSave();
    if (!passwordConfirmed || !mounted) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final payload = <String, dynamic>{
        'action': 'save_school_profile',
        'schoolName': schoolName,
        'principalName': principalName,
        'schoolContactNo': schoolContactNo,
        'latitude': schoolLatitude,
        'longitude': schoolLongitude,
        'attendanceRadiusMeters': attendanceRadius,
        'updatedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
      };

      if (_logoBytes != null) {
        payload.addAll({
          'logoBase64': _dataUri(_logoBytes!, _logoMimeType),
          'logoMimeType': _logoMimeType,
          'logoFileName': _logoFileName,
        });
      }

      if (_sealBytes != null) {
        payload.addAll({
          'sealBase64': _dataUri(_sealBytes!, _sealMimeType),
          'sealMimeType': _sealMimeType,
          'sealFileName': _sealFileName,
        });
      }

      if (_signatureBytes != null) {
        payload.addAll({
          'principalSignatureBase64':
              _dataUri(_signatureBytes!, _signatureMimeType),
          'principalSignatureMimeType': _signatureMimeType,
          'principalSignatureFileName': _signatureFileName,
        });
      }

      final result = await _schoolProfileBackendPost(payload);
      final raw = result['profile'];
      if (raw is! Map) {
        throw Exception('School profile response invalid hai.');
      }

      final profile = _mergeSchoolProfile(Map<String, dynamic>.from(raw));
      _schoolProfileMemoryCache = Map<String, dynamic>.from(profile);

      await FirebaseFirestore.instance
          .collection('school_settings')
          .doc('school_location')
          .set({
            'latitude': schoolLatitude,
            'longitude': schoolLongitude,
            'radiusMeters': attendanceRadius,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      // Drive save is already complete. Firestore is only the fast cache,
      // so do not keep the Save button waiting for a second network round-trip.
      unawaited(
        _schoolProfileCacheRef()
            .set(
              {
                ...profile,
                'cachedAt': FieldValue.serverTimestamp(),
              },
              SetOptions(merge: true),
            )
            .catchError((e) {
              debugPrint('School profile Firestore cache warning: $e');
            }),
      );

      if (!mounted) return;
      setState(() {
        _applyProfile(profile);
        _logoBytes = null;
        _sealBytes = null;
        _signatureBytes = null;
        _saving = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF00A884),
          content: Text(
            'School Settings Google Drive me save ho gaya.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('School Settings save error: $e'),
        ),
      );
    }
  }

  Widget _assetCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Uint8List? selectedBytes,
    required String currentUrl,
    required VoidCallback onPick,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF111B21),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            width: 74,
            height: 74,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: selectedBytes != null
                  ? Image.memory(selectedBytes, fit: BoxFit.contain)
                  : currentUrl.isNotEmpty
                      ? _windowsSchoolProfileImage(
                          currentUrl,
                          fallback: Icon(
                            icon,
                            color: const Color(0xFF00A884),
                            size: 34,
                          ),
                        )
                      : Icon(
                          icon,
                          color: const Color(0xFF00A884),
                          size: 34,
                        ),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 9),
                OutlinedButton.icon(
                  onPressed: _saving ? null : onPick,
                  icon: const Icon(Icons.upload_rounded, size: 17),
                  label: Text(
                    selectedBytes != null || currentUrl.isNotEmpty
                        ? 'Change'
                        : 'Upload',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _field(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
      prefixIcon: Icon(icon, color: const Color(0xFF00A884)),
      filled: true,
      fillColor: const Color(0xFF0F191F),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide(color: Colors.white.withOpacity(.07)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: Color(0xFF00A884)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF172229),
        elevation: 0,
        title: const Text(
          'School Settings',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: WindowsUiLanguage.translate('Refresh from Google Drive'),
            onPressed: _loading || _saving ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00A884)),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF123D38), Color(0xFF172229)],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(0xFF00A884).withOpacity(.20),
                          ),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.school_rounded,
                              color: Color(0xFF00D9A5),
                              size: 30,
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Reusable School Identity',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'Ye details aur files Google Drive me save hongi. School change karne ke liye code edit nahi karna padega.',
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _schoolNameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: _field(
                          'School Name',
                          Icons.account_balance_rounded,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _principalNameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: _field(
                          'School Principal Name',
                          Icons.person_rounded,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _schoolContactController,
                        keyboardType: TextInputType.phone,
                        style: const TextStyle(color: Colors.white),
                        decoration: _field(
                          'School Contact No.',
                          Icons.phone_rounded,
                        ),
                      ),
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final cards = <Widget>[
                            _assetCard(
                              title: 'School Logo',
                              subtitle: 'ID Card / school branding ke liye.',
                              icon: Icons.image_rounded,
                              selectedBytes: _logoBytes,
                              currentUrl: _logoUrl,
                              onPick: () => _pickAsset('logo'),
                            ),
                            _assetCard(
                              title: 'School Seal',
                              subtitle: 'Official seal/stamp image.',
                              icon: Icons.approval_rounded,
                              selectedBytes: _sealBytes,
                              currentUrl: _sealUrl,
                              onPick: () => _pickAsset('seal'),
                            ),
                            _assetCard(
                              title: 'Principal Signature',
                              subtitle: 'ID cards / reports me principal signature.',
                              icon: Icons.draw_rounded,
                              selectedBytes: _signatureBytes,
                              currentUrl: _signatureUrl,
                              onPick: () => _pickAsset('signature'),
                            ),
                          ];

                          if (constraints.maxWidth < 700) {
                            return Column(
                              children: [
                                for (var i = 0; i < cards.length; i++) ...[
                                  cards[i],
                                  if (i != cards.length - 1)
                                    const SizedBox(height: 10),
                                ],
                              ],
                            );
                          }

                          return Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(child: cards[0]),
                                  const SizedBox(width: 10),
                                  Expanded(child: cards[1]),
                                ],
                              ),
                              const SizedBox(height: 10),
                              cards[2],
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111B21),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF69C2FF).withOpacity(.20)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.location_on_rounded, color: Color(0xFF69C2FF)),
                                SizedBox(width: 9),
                                Text('School Location & Attendance Geofence', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Student/Teacher QR attendance tabhi accept hogi jab device configured school location ke radius ke andar ho.',
                              style: TextStyle(color: Colors.white54, fontSize: 10.5, height: 1.4),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _schoolLatitudeController,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                    style: const TextStyle(color: Colors.white),
                                    decoration: _field('Latitude', Icons.my_location_rounded),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: _schoolLongitudeController,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                    style: const TextStyle(color: Colors.white),
                                    decoration: _field('Longitude', Icons.explore_rounded),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 180,
                                  child: TextField(
                                    controller: _attendanceRadiusController,
                                    keyboardType: TextInputType.number,
                                    style: const TextStyle(color: Colors.white),
                                    decoration: _field('Radius (meter)', Icons.radar_rounded),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _saving
                                      ? null
                                      : () async {
                                          try {
                                            await _openGoogleMapsForSchoolLocation(
                                              _schoolNameController.text,
                                            );
                                          } catch (e) {
                                            if (!mounted) return;
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                backgroundColor: Colors.redAccent,
                                                content: Text('Google Maps open nahi hua: $e'),
                                              ),
                                            );
                                          }
                                        },
                                  icon: const Icon(Icons.map_rounded),
                                  label: const Text('Open Google Maps'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _saving ? null : _pasteGoogleMapsCoordinates,
                                  icon: const Icon(Icons.content_paste_rounded),
                                  label: const Text('Paste Map Coordinates'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _saving
                                      ? null
                                      : () async {
                                          try {
                                            final pos = await _windowsCurrentPosition();
                                            if (!mounted) return;
                                            setState(() {
                                              _schoolLatitudeController.text = pos.latitude.toStringAsFixed(7);
                                              _schoolLongitudeController.text = pos.longitude.toStringAsFixed(7);
                                            });
                                          } catch (e) {
                                            if (!mounted) return;
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                backgroundColor: Colors.redAccent,
                                                content: Text('$e'),
                                              ),
                                            );
                                          }
                                        },
                                  icon: const Icon(Icons.gps_fixed_rounded),
                                  label: const Text('Use This Windows PC Location'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Google Maps me school point par right-click karke coordinates copy karein, phir “Paste Map Coordinates” dabayein.',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111B21),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.language_rounded, color: Color(0xFF00D9A5)),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Windows App Language', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                                  SizedBox(height: 3),
                                  Text('English • Hindi • Bengali • Assamese', style: TextStyle(color: Colors.white38, fontSize: 10)),
                                ],
                              ),
                            ),
                            DropdownButton<String>(
                              value: _selectedWindowsLanguage,
                              dropdownColor: const Color(0xFF172229),
                              items: const [
                                DropdownMenuItem(value: 'en', child: Text('English')),
                                DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
                                DropdownMenuItem(value: 'bn', child: Text('বাংলা')),
                                DropdownMenuItem(value: 'as', child: Text('অসমীয়া')),
                              ],
                              onChanged: (value) async {
                                if (value == null) return;
                                _setWindowsLanguage(value);
                                if (mounted) {
                                  setState(() => _selectedWindowsLanguage = value);
                                }

                              },
                            ),
                          ],
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00A884),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(13),
                            ),
                          ),
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.cloud_upload_rounded),
                          label: Text(
                            _saving
                                ? 'Saving to Google Drive...'
                                : 'SAVE SCHOOL SETTINGS TO GOOGLE DRIVE',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}


class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF172229),
        titleSpacing: 6,
        title: const Text(
          'Settings',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: const WindowsAppUpdateCard(),
          ),
        ),
      ),
    );
  }
}

/// Full protected settings opened from the School Analytics gear.
/// App Update intentionally lives only in the dashboard Settings screen.
class AdminSettingsScreen extends StatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  State<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends State<AdminSettingsScreen> {
  final TextEditingController _gmailController = TextEditingController();
  final TextEditingController _scriptUrlController = TextEditingController();
  final TextEditingController _uidStartController =
      TextEditingController(text: 'TEST-000001');

  String? _linkedGmail;
  String? _linkedScriptUrl;
  bool _isLoading = false;
  int _academicYearRolloverMonth = 1;
  bool _academicYearSettingsLoading = true;

  bool _uidSettingsLoading = true;
  bool _uidMasterEnabled = false;
  bool _uidFeesEnabled = false;
  bool _uidIdCardEnabled = false;
  bool _uidEverActivated = false;
  String _uidPrefix = 'TEST-';
  int _uidPadding = 6;
  int _uidNextNumber = 1;
  String _uidLastIssued = '';

  @override
  void initState() {
    super.initState();
    _fetchLinkedAccount();
    _loadAcademicYearSettings();
  }

  @override
  void dispose() {
    _gmailController.dispose();
    _scriptUrlController.dispose();
    _uidStartController.dispose();
    super.dispose();
  }

  bool get _isDriveLinked {
    return (_linkedGmail?.trim().isNotEmpty ?? false) &&
        (_linkedScriptUrl?.trim().isNotEmpty ?? false);
  }

  Future<void> _loadAcademicYearSettings() async {
    final month = await WindowsAcademicYearSettings.load();
    if (!mounted) return;
    setState(() {
      _academicYearRolloverMonth = month;
      _academicYearSettingsLoading = false;
    });
  }

  Future<void> _saveAcademicYearRolloverMonth(int month) async {
    if (_academicYearSettingsLoading) return;

    try {
      await WindowsAcademicYearSettings.save(month);
      if (!mounted) return;
      setState(() => _academicYearRolloverMonth = month);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text(
            'Academic year ab ${month == 1 ? 'January' : 'April'} se change hoga.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Academic year setting save error: $e'),
        ),
      );
    }
  }

  Future<void> _fetchLinkedAccount() async {
    try {
      final data = await WindowsExternalConnections.load();

      if (!mounted) return;

      setState(() {
        _linkedGmail = data['googleEmail']?.toString();
        _linkedScriptUrl = data['googleScriptUrl']?.toString();
        _gmailController.text = _linkedGmail ?? '';
        _scriptUrlController.text = _linkedScriptUrl ?? '';
      });
    } catch (e) {
      debugPrint('Settings load error: $e');
    }
  }

  Future<void> _linkGmail() async {
    final email = _gmailController.text.trim();
    final scriptUrl = _scriptUrlController.text.trim();

    if (email.isEmpty || !email.toLowerCase().endsWith('@gmail.com')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Kripya valid Gmail ID daalein.'),
        ),
      );
      return;
    }

    if (scriptUrl.isEmpty ||
        !scriptUrl.startsWith('https://script.google.com/')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Kripya valid Google Apps Script Web App URL daalein.'),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await WindowsSyncEngine.instance.changeGoogleConnection(
        email: email,
        scriptUrl: scriptUrl,
      );
      await WindowsAppRestart.restart(reason: 'Google Drive connection changed');

      if (!mounted) return;

      setState(() {
        _linkedGmail = email;
        _linkedScriptUrl = scriptUrl;
        _isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF00A884),
          content: Text('Google Drive configuration save ho gayi!'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Error: $e'),
        ),
      );
    }
  }

  Future<void> _unlinkGmail() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF172229),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.link_off_rounded, color: Colors.orangeAccent),
            SizedBox(width: 10),
            Text(
              'Change Drive Account?',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
          ],
        ),
        content: const Text(
          'Current Google Drive / Apps Script configuration remove ho jayegi. Student records delete nahi honge.',
          style: TextStyle(color: Colors.white70, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isLoading = true);

    try {
      await WindowsSyncEngine.instance.disconnectGoogle();

      if (!mounted) return;

      setState(() {
        _linkedGmail = null;
        _linkedScriptUrl = null;
        _gmailController.clear();
        _scriptUrlController.clear();
        _isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text('Google Drive configuration remove ho gayi.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Error: $e'),
        ),
      );
    }
  }

  Future<void> _fetchUidTestSettings() async {
    try {
      final data = await _loadTestStudentUidConfig();
      if (!mounted) return;

      final prefix = data['prefix']?.toString() ?? 'TEST-';
      final padding = (data['padding'] as num?)?.toInt() ?? 6;
      final nextNumber = (data['nextNumber'] as num?)?.toInt() ?? 1;
      final everActivated = data['everActivated'] == true;

      setState(() {
        _uidMasterEnabled = data['masterEnabled'] == true;
        _uidFeesEnabled = data['feesEnabled'] == true;
        _uidIdCardEnabled = data['idCardEnabled'] == true;
        _uidEverActivated = everActivated;
        _uidPrefix = prefix;
        _uidPadding = padding;
        _uidNextNumber = nextNumber;
        _uidLastIssued = data['lastIssuedUid']?.toString() ?? '';
        _uidSettingsLoading = false;

        if (everActivated) {
          _uidStartController.text =
              _formatTestStudentUid(prefix, padding, nextNumber);
        } else {
          _uidStartController.text =
              data['startPattern']?.toString() ?? 'TEST-000001';
        }
      });
    } catch (e) {
      debugPrint('Test UID settings load error: $e');
      if (!mounted) return;
      setState(() => _uidSettingsLoading = false);
    }
  }

  int _classSortNumber(String value) {
    return int.tryParse(value.replaceAll(RegExp(r'[^0-9]'), '')) ?? 999999;
  }

  int _rollSortNumber(String value) {
    return int.tryParse(value.trim()) ?? 999999;
  }

  Future<String?> _showUidActivationPasswordDialog() async {
    final passwordController = TextEditingController();
    int secondsLeft = 20;
    bool countdownStarted = false;

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            if (!countdownStarted) {
              countdownStarted = true;

              Future<void>(() async {
                while (secondsLeft > 0) {
                  await Future<void>.delayed(const Duration(seconds: 1));
                  if (!dialogContext.mounted) return;
                  setDialogState(() => secondsLeft--);
                }
              });
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF172229),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              title: const Row(
                children: [
                  Icon(Icons.badge_rounded, color: Color(0xFF00D9A5)),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Activate TEST Student UID?',
                      style: TextStyle(color: Colors.white, fontSize: 17),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 470,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Kya school ke sabhi existing students Student Directory me add ho chuke hain?\n\n'
                      'TEST UID activate hone par existing students ko Class 1 → Class 12 aur Roll No order me permanent TEST UID assign hoga. '
                      'Delete hone ke baad purana UID dobara issue nahi hoga. Final production UID baad me alag se activate kiya jayega.',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orangeAccent.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.orangeAccent.withOpacity(0.25),
                        ),
                      ),
                      child: Text(
                        secondsLeft > 0
                            ? 'Student Directory verify karein... Password option $secondsLeft sec baad unlock hoga.'
                            : 'Verification time complete. Ab Admin Password enter karein.',
                        style: TextStyle(
                          color: secondsLeft > 0
                              ? Colors.orangeAccent
                              : const Color(0xFF00D9A5),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: passwordController,
                      enabled: secondsLeft == 0,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Admin Password',
                        labelStyle: const TextStyle(color: Colors.white54),
                        prefixIcon: const Icon(
                          Icons.lock_outline_rounded,
                          color: Color(0xFF00A884),
                        ),
                        filled: true,
                        fillColor: const Color(0xFF0F191F),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: secondsLeft == 0 &&
                          passwordController.text.trim().isNotEmpty
                      ? () => Navigator.pop(
                            dialogContext,
                            passwordController.text,
                          )
                      : null,
                  icon: const Icon(Icons.verified_user_rounded, size: 18),
                  label: const Text('Verify & Activate'),
                ),
              ],
            );
          },
        );
      },
    );

    passwordController.dispose();
    return result;
  }

  Future<void> _verifyCurrentAdminPassword(String password) async {
    final user = FirebaseAuth.instance.currentUser;
    final email = user?.email?.trim() ?? '';

    if (user == null || email.isEmpty) {
      throw Exception('Admin login session nahi mila.');
    }

    final credential = EmailAuthProvider.credential(
      email: email,
      password: password,
    );

    await user.reauthenticateWithCredential(credential);
  }

  Future<void> _activateUidTestMode() async {
    if (_uidSettingsLoading) return;

    Map<String, dynamic>? parsedPattern;

    if (!_uidEverActivated) {
      try {
        parsedPattern = _parseTestUidPattern(_uidStartController.text);
      } on FormatException catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(e.message.toString()),
          ),
        );
        return;
      }
    }

    final password = await _showUidActivationPasswordDialog();
    if (password == null || password.isEmpty || !mounted) return;

    setState(() => _uidSettingsLoading = true);

    try {
      await _verifyCurrentAdminPassword(password);

      final freshConfig = await _loadTestStudentUidConfig();
      final everActivated = freshConfig['everActivated'] == true;

      final prefix = everActivated
          ? (freshConfig['prefix']?.toString() ?? _uidPrefix)
          : parsedPattern!['prefix'].toString();
      final padding = everActivated
          ? ((freshConfig['padding'] as num?)?.toInt() ?? _uidPadding)
          : parsedPattern!['padding'] as int;
      var nextNumber = everActivated
          ? ((freshConfig['nextNumber'] as num?)?.toInt() ?? _uidNextNumber)
          : parsedPattern!['startNumber'] as int;

      final students = await FirebaseFirestore.instance
          .collection('students_directory')
          .get();

      final docs = [...students.docs];
      docs.sort((a, b) {
        final ad = a.data();
        final bd = b.data();

        final classCompare = _classSortNumber(
          ad['class']?.toString() ?? '',
        ).compareTo(
          _classSortNumber(bd['class']?.toString() ?? ''),
        );
        if (classCompare != 0) return classCompare;

        final rollCompare = _rollSortNumber(
          ad['rollNo']?.toString() ?? '',
        ).compareTo(
          _rollSortNumber(bd['rollNo']?.toString() ?? ''),
        );
        if (rollCompare != 0) return rollCompare;

        return (ad['name']?.toString() ?? '')
            .toLowerCase()
            .compareTo((bd['name']?.toString() ?? '').toLowerCase());
      });

      final missing = docs.where((doc) {
        return (doc.data()[_testStudentUidField]?.toString().trim() ?? '')
            .isEmpty;
      }).toList();

      final assignments = <MapEntry<
          DocumentReference<Map<String, dynamic>>, String>>[];
      var reservedNextNumber = nextNumber;
      String lastIssued = freshConfig['lastIssuedUid']?.toString() ?? '';

      for (final doc in missing) {
        final uid =
            _formatTestStudentUid(prefix, padding, reservedNextNumber);
        assignments.add(MapEntry(doc.reference, uid));
        lastIssued = uid;
        reservedNextNumber++;
      }

      // Counter pehle reserve hota hai. Agar network/batch beech me fail bhi ho,
      // reserved UID dobara reuse nahi hoga; sirf gap aa sakta hai.
      await _testStudentUidConfigRef().set(
        {
          'testMode': true,
          'masterEnabled': false,
          'everActivated': true,
          'prefix': prefix,
          'padding': padding,
          'startPattern': everActivated
              ? freshConfig['startPattern']?.toString()
              : _uidStartController.text.trim(),
          'nextNumber': reservedNextNumber,
          'lastIssuedUid': lastIssued,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      for (var start = 0; start < assignments.length; start += 400) {
        final batch = FirebaseFirestore.instance.batch();
        final end = (start + 400 < assignments.length)
            ? start + 400
            : assignments.length;

        for (var i = start; i < end; i++) {
          final assignment = assignments[i];
          batch.update(assignment.key, {
            _testStudentUidField: assignment.value,
            'studentUidTestAssignedAt': FieldValue.serverTimestamp(),
          });
        }

        await batch.commit();
      }

      await _testStudentUidConfigRef().set(
        {
          'masterEnabled': true,
          'feesEnabled': freshConfig['feesEnabled'] == true,
          'idCardEnabled': freshConfig['idCardEnabled'] == true,
          'activatedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      await _fetchUidTestSettings();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text(
            missing.isEmpty
                ? 'TEST Student UID ON ho gaya. Sab existing students ke UID pehle se assigned hain.'
                : 'TEST Student UID ON. ${missing.length} existing students ko UID assign hua.',
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _uidSettingsLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            e.code == 'wrong-password' || e.code == 'invalid-credential'
                ? 'Admin Password galat hai.'
                : 'Admin verification failed: ${e.message ?? e.code}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _uidSettingsLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('TEST UID activation error: $e'),
        ),
      );
    }
  }

  Future<void> _setUidMasterEnabled(bool value) async {
    if (value) {
      await _activateUidTestMode();
      return;
    }

    setState(() => _uidSettingsLoading = true);

    try {
      await _testStudentUidConfigRef().set(
        {
          'masterEnabled': false,
          'feesEnabled': false,
          'idCardEnabled': false,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      await _fetchUidTestSettings();
    } catch (e) {
      if (!mounted) return;
      setState(() => _uidSettingsLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('TEST UID OFF error: $e'),
        ),
      );
    }
  }

  Future<void> _setUidFeatureFlag(String field, bool value) async {
    if (!_uidMasterEnabled) return;

    setState(() => _uidSettingsLoading = true);
    try {
      await _testStudentUidConfigRef().set(
        {
          field: value,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      await _fetchUidTestSettings();
    } catch (e) {
      if (!mounted) return;
      setState(() => _uidSettingsLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('TEST UID setting save error: $e'),
        ),
      );
    }
  }

  String _profileInitial(User? user) {
    final name = user?.displayName?.trim() ?? '';
    if (name.isNotEmpty) return name.substring(0, 1).toUpperCase();

    final email = user?.email?.trim() ?? '';
    if (email.isNotEmpty) return email.substring(0, 1).toUpperCase();

    return 'A';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final adminEmail = user?.email?.trim().isNotEmpty == true
        ? user!.email!.trim()
        : 'Admin account';
    final adminName = user?.displayName?.trim().isNotEmpty == true
        ? user!.displayName!.trim()
        : 'School Administrator';

    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF172229),
        titleSpacing: 6,
        title: const Text(
          'Settings',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // =====================================================
                // ADMIN PROFILE
                // =====================================================
                _settingsCard(
                  icon: Icons.admin_panel_settings_rounded,
                  iconColor: const Color(0xFF00D9A5),
                  title: 'Admin Profile',
                  subtitle: 'Signed-in administrator account',
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 600;

                      final profileInfo = Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF00A884), Color(0xFF087B68)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF00A884).withOpacity(0.22),
                                  blurRadius: 18,
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              _profileInitial(user),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 25,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 15),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  adminName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.alternate_email_rounded,
                                      color: Colors.white38,
                                      size: 14,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        adminEmail,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white60,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00A884).withOpacity(0.10),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: const Color(0xFF00A884).withOpacity(0.22),
                                    ),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.verified_user_rounded,
                                        color: Color(0xFF00D9A5),
                                        size: 13,
                                      ),
                                      SizedBox(width: 5),
                                      Text(
                                        'Authenticated',
                                        style: TextStyle(
                                          color: Color(0xFF00D9A5),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );

                      final schoolSettingsButton = OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF00D9A5),
                          side: BorderSide(
                            color: const Color(0xFF00A884).withOpacity(0.55),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 13,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SchoolSettingsScreen(),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                        icon: const Icon(Icons.school_rounded, size: 18),
                        label: const Text(
                          'School Settings',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      );

                      if (compact) {
                        return Column(
                          children: [
                            profileInfo,
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: schoolSettingsButton,
                            ),
                          ],
                        );
                      }

                      return Row(
                        children: [
                          Expanded(child: profileInfo),
                          const SizedBox(width: 18),
                          SizedBox(
                            width: 190,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                schoolSettingsButton,
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),

                const SizedBox(height: 16),

                _settingsCard(
                  icon: Icons.calendar_month_rounded,
                  iconColor: const Color(0xFF69C2FF),
                  title: 'Academic Year',
                  subtitle: 'Choose January or April as the session change month',
                  child: _academicYearSettingsLoading
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(8),
                            child: CircularProgressIndicator(
                              color: Color(0xFF69C2FF),
                            ),
                          ),
                        )
                      : Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 13,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F191F),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white10),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.event_repeat_rounded,
                                color: Color(0xFF69C2FF),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Session Change Month',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      'Current: ${WindowsAcademicYearSettings.format(DateTime.now(), _academicYearRolloverMonth)}',
                                      style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 10.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  value: _academicYearRolloverMonth,
                                  dropdownColor: const Color(0xFF12272F),
                                  style: const TextStyle(color: Colors.white),
                                  items: const [
                                    DropdownMenuItem<int>(
                                      value: 1,
                                      child: Text('January'),
                                    ),
                                    DropdownMenuItem<int>(
                                      value: 4,
                                      child: Text('April'),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    if (value != null) {
                                      _saveAcademicYearRolloverMonth(value);
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                ),

                const SizedBox(height: 16),

                _settingsCard(
                  icon: Icons.password_rounded,
                  iconColor: Colors.orangeAccent,
                  title: 'Password Management',
                  subtitle: 'Section locks aur Local Settings Lock manage karein',
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white38,
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(13),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const PasswordManagementScreen(),
                          ),
                        );
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F191F),
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: Colors.orangeAccent.withOpacity(0.16),
                          ),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.lock_person_rounded,
                              color: Colors.orangeAccent,
                              size: 21,
                            ),
                            SizedBox(width: 11),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Open Password Management',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    'Admin, Student, Fees, Expenses, Attendance aur Local Settings locks yahan manage honge.',
                                    style: TextStyle(
                                      color: Colors.white38,
                                      fontSize: 10.5,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_rounded,
                              color: Colors.orangeAccent,
                              size: 19,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // =====================================================
                // ADVANCED SETTINGS
                // Google Drive integration is intentionally kept inside
                // the protected Advanced Settings screen only.
                // =====================================================
                _settingsCard(
                  icon: Icons.admin_panel_settings_rounded,
                  iconColor: Colors.orangeAccent,
                  title: 'Advanced Settings',
                  subtitle: 'Protected integrations & system controls',
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white38,
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(13),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const AdvancedSettingsScreen(),
                          ),
                        );
                        if (mounted) {
                          _fetchLinkedAccount();
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F191F),
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: Colors.orangeAccent.withOpacity(0.16),
                          ),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.security_rounded,
                              color: Colors.orangeAccent,
                              size: 21,
                            ),
                            SizedBox(width: 11),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Open Advanced Settings',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    'Google Drive, Student UID aur protected system controls yahan manage honge.',
                                    style: TextStyle(
                                      color: Colors.white38,
                                      fontSize: 10.5,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_rounded,
                              color: Colors.orangeAccent,
                              size: 19,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),


              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _settingsCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.065)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.16),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.11),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: iconColor.withOpacity(0.18)),
                ),
                child: Icon(icon, color: iconColor, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                trailing,
              ],
            ],
          ),
          const SizedBox(height: 15),
          Container(height: 1, color: Colors.white.withOpacity(0.055)),
          const SizedBox(height: 15),
          child,
        ],
      ),
    );
  }

  Widget _uidToggleTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFF0F191F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.055)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: enabled ? Colors.white : Colors.white30,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: enabled ? Colors.white38 : Colors.white24,
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            activeColor: const Color(0xFF00D9A5),
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }

  Widget _statusPill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _connectionInfoTile({
    required IconData icon,
    required String label,
    required String value,
    bool selectable = false,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFF0F191F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFF4DA3FF).withOpacity(0.09),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: const Color(0xFF4DA3FF), size: 17),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 9.5,
                  ),
                ),
                const SizedBox(height: 4),
                selectable
                    ? SelectableText(
                        value,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      )
                    : Text(
                        value,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _modernInputDecoration(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
      prefixIcon: Icon(icon, color: const Color(0xFF00A884), size: 19),
      filled: true,
      fillColor: const Color(0xFF0F191F),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.06)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF00A884)),
      ),
    );
  }
}

// ============================================================
// FEES COLLECTION
// ============================================================

class FeesCollectionScreen extends StatefulWidget {
  const FeesCollectionScreen({super.key});

  @override
  State<FeesCollectionScreen> createState() => _FeesCollectionScreenState();
}

class _FeesCollectionScreenState extends State<FeesCollectionScreen> {
  static const List<String> _feeHeads = [
    'Tuition Fees',
    'Admission Fees',
    'Registration Fees',
    'Nobikaron Fees',
    'Bidya Bharati Sahojog Rashi',
    'Building Fees',
    'Shishu Bharati Fees',
    'Library Fees',
    'Medical Fees',
    'Game Fees',
    'Development Fees',
    'Electric Fees',
    'Cultural Fees',
    'Computer Fees',
    'Computer Lab Fees',
    'Educational Development Fees',
    'Exam Fees',
    'Miscellaneous Fees',
    'Late Fees',
    'Vehicle Fees',
  ];

  final TextEditingController _nameSearchController = TextEditingController();
  final TextEditingController _rollSearchController = TextEditingController();
  final TextEditingController _receivedAmountController = TextEditingController();

  final List<String> _classes = [
    'All Classes',
    ...List.generate(12, (index) => 'Class ${index + 1}'),
  ];

  String _selectedClass = 'All Classes';
  late String _selectedMonth;
  String? _activeStudentId;
  String _paymentMode = 'Cash';
  bool _isSavingPayment = false;
  bool _activeFeeSettingsReady = false;
  String? _activeFeeSettingsMessage;

  Map<String, double> _activeFeeAmounts = {};
  Set<String> _selectedFeeHeads = <String>{};
  Map<String, dynamic>? _activeLedger;

  Map<String, dynamic> _studentUidConfig = <String, dynamic>{};
  bool _studentUidConfigLoaded = false;

  final Map<String, Map<String, dynamic>> _feeSettingsCache = {};

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _studentsStream;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _ledgerStream;

  Stream<QuerySnapshot<Map<String, dynamic>>> _ledgerStreamForMonth(
    String month,
  ) {
    return FirebaseFirestore.instance
        .collection('fee_ledger')
        .where('month', isEqualTo: month)
        .snapshots();
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';

    _studentsStream =
        FirebaseFirestore.instance.collection('students_directory').snapshots();
    _ledgerStream = _ledgerStreamForMonth(_selectedMonth);

    _preloadFeeSettings();
    _loadStudentUidConfigForFees();
  }

  @override
  void dispose() {
    _nameSearchController.dispose();
    _rollSearchController.dispose();
    _receivedAmountController.dispose();
    super.dispose();
  }

  String _settingsDocId(String className) => className.replaceAll(' ', '_');

  Future<void> _preloadFeeSettings() async {
  try {
    await Future.wait(
      List.generate(12, (index) async {
        final className = 'Class ${index + 1}';
        final settings = await _getClassFeeSettings(className);
        _feeSettingsCache[className] = settings;
      }),
    );

    debugPrint('Fee settings cache ready');
  } catch (e) {
    debugPrint('Fee settings preload error: $e');
  }
}

  Future<void> _loadStudentUidConfigForFees() async {
    try {
      final data = await _loadTestStudentUidConfig();
      if (!mounted) return;
      setState(() {
        _studentUidConfig = data;
        _studentUidConfigLoaded = true;
      });
    } catch (e) {
      debugPrint('Fees TEST UID config load error: $e');
      if (!mounted) return;
      setState(() => _studentUidConfigLoaded = true);
    }
  }

  String _ledgerId(String feeIdentity) {
    final safe = base64UrlEncode(utf8.encode(feeIdentity)).replaceAll('=', '');
    return '${_selectedMonth}_$safe';
  }

  bool _legacyLedgerMatchesStudent(
    Map<String, dynamic> ledger,
    Map<String, dynamic> student,
  ) {
    final oldName = _normalizeIdentityPart(ledger['studentName']);
    final newName = _normalizeIdentityPart(student['name']);
    final oldRoll = _normalizeIdentityPart(ledger['rollNo']);
    final newRoll = _normalizeIdentityPart(student['rollNo']);
    final oldMobile = _normalizeIdentityPart(ledger['parentContact']);
    final newMobile = _normalizeIdentityPart(student['parentContact']);

    return oldName.isNotEmpty &&
        oldName == newName &&
        oldRoll == newRoll &&
        oldMobile == newMobile;
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  String _money(num value) {
    final d = value.toDouble();
    return '₹${d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2)}';
  }

  String _monthName(String value) {
    final parts = value.split('-');
    if (parts.length != 2) return value;
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final month = int.tryParse(parts[1]) ?? 1;
    if (month < 1 || month > 12) return value;
    return '${months[month - 1]} ${parts[0]}';
  }

  List<String> _monthList() {
    final now = DateTime.now();
    return List.generate(12, (index) {
      final d = DateTime(now.year, now.month - index, 1);
      return '${d.year}-${d.month.toString().padLeft(2, '0')}';
    });
  }

  String _feeStatus(double expected, double paid) {
    if (expected > 0 && paid >= expected) return 'PAID';
    if (paid > 0) return 'PARTIAL';
    return 'DUE';
  }

  Color _statusColor(String status) {
    if (status == 'PAID') return const Color(0xFF00A884);
    if (status == 'PARTIAL') return Colors.orangeAccent;
    return Colors.redAccent;
  }

  InputDecoration _inputDecoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
      prefixIcon: Icon(icon, color: const Color(0xFF00A884)),
      filled: true,
      fillColor: const Color(0xFF172229),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _summaryCard({
    required String title,
    required int count,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      width: 185,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.30)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 11),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$count',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                title,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

Future<Map<String, dynamic>> _getClassFeeSettings(
  String studentClass,
) async {
  final cached = _feeSettingsCache[studentClass];

  if (cached != null) {
    return cached;
  }

  final doc = await FirebaseFirestore.instance
      .collection('fee_settings')
      .doc(_settingsDocId(studentClass))
      .get();

  final data = doc.data() ?? <String, dynamic>{};
  final rawFees =
      Map<String, dynamic>.from(data['fees'] ?? {});

  final fees = <String, double>{};

  for (final head in _feeHeads) {
    fees[head] = _toDouble(rawFees[head]);
  }

  final configuredHeads = _feeHeads
      .where((head) => (fees[head] ?? 0) > 0)
      .toList();

  final result = <String, dynamic>{
    'fees': fees,
    'configured': configuredHeads.isNotEmpty,
    'configuredHeads': configuredHeads,
  };

  _feeSettingsCache[studentClass] = result;

  return result;
}

  void _resetActiveSelection() {
    _activeStudentId = null;
    _activeFeeSettingsReady = false;
    _activeFeeSettingsMessage = null;
    _activeFeeAmounts = {};
    _selectedFeeHeads = <String>{};
    _activeLedger = null;
    _receivedAmountController.clear();
    _paymentMode = 'Cash';
  }

  void _clearStudentAndSearch() {
    setState(() {
      _resetActiveSelection();
      _nameSearchController.clear();
      _rollSearchController.clear();
    });
  }

  Future<void> _openInlineCollector(
    QueryDocumentSnapshot<Map<String, dynamic>> studentDoc,
    Map<String, dynamic>? ledger,
  ) async {
    final student = studentDoc.data();
    final studentClass = student['class']?.toString().trim() ?? '';
    final studentName = student['name']?.toString().trim() ?? '';
    final roll = student['rollNo']?.toString().trim() ?? '';

    if (studentClass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Student class missing hai.'),
        ),
      );
      return;
    }

        final cachedSettings = _feeSettingsCache[studentClass];
    
        _activeStudentId = studentDoc.id;
        _selectedClass = studentClass;
        _nameSearchController.text = studentName;
        _rollSearchController.text = roll;
        _activeFeeSettingsReady = cachedSettings != null;
        _activeFeeSettingsMessage =
            cachedSettings == null ? 'Fee structure load ho raha hai...' : null;

        _activeFeeAmounts = cachedSettings != null
            ? Map<String, double>.from(cachedSettings['fees'] as Map)
            : {};
        _selectedFeeHeads = <String>{};
        _activeLedger = ledger;
        _receivedAmountController.clear();
        _paymentMode = ledger?['paymentMode']?.toString() ?? 'Cash';

    try {
      final settings = await _getClassFeeSettings(studentClass);
      final fees = Map<String, double>.from(settings['fees'] as Map);
      final configured = settings['configured'] == true;

      if (!configured) {
        if (!mounted) return;
        setState(() {
          _activeFeeSettingsReady = false;
          _activeFeeSettingsMessage =
              '$studentClass ke liye fixed fee amount Settings me save nahi hai. Pehle Payment Collection Settings complete karein.';
          _activeFeeAmounts = fees;
          _selectedFeeHeads = <String>{};
        });
        return;
      }

      final savedItems = Map<String, dynamic>.from(ledger?['feeItems'] ?? {});
      final selected = <String>{};

      // Partial/full payment ke baad wahi fee heads fixed rahenge.
      if (savedItems.isNotEmpty) {
        for (final entry in savedItems.entries) {
          if (_toDouble(entry.value) > 0) selected.add(entry.key);
        }
      }

      final expected = _toDouble(ledger?['expectedAmount']);
      final paid = _toDouble(ledger?['totalPaid']);
      final remaining = (expected - paid).clamp(0, double.infinity).toDouble();

      if (!mounted) return;
      setState(() {
        _activeStudentId = studentDoc.id;
        _activeFeeSettingsReady = true;
        _activeFeeSettingsMessage = null;
        _activeFeeAmounts = fees;
        _selectedFeeHeads = selected;
        _activeLedger = ledger;
        _paymentMode = ledger?['paymentMode']?.toString() ?? 'Cash';

        // Existing partial payment me remaining amount suggest hoga.
        // New payment me fee heads tick karne ke baad full amount auto-fill hoga,
        // admin partial payment ke liye ise kam kar sakta hai.
        _receivedAmountController.text =
            remaining > 0 ? remaining.toStringAsFixed(0) : '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _activeFeeSettingsReady = false;
        _activeFeeSettingsMessage = 'Fee settings load error: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Fee settings load error: $e'),
        ),
      );
    }
  }

  double get _selectedFeesTotal {
    return _selectedFeeHeads.fold<double>(
      0,
      (sum, head) => sum + (_activeFeeAmounts[head] ?? 0),
    );
  }

  Future<bool> _confirmPayment({
    required String studentName,
    required String studentClass,
    required String roll,
    required double amount,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Row(
          children: [
            Icon(Icons.help_outline_rounded, color: Colors.orangeAccent),
            SizedBox(width: 10),
            Text('Are you sure?', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(
          '$studentName\n$studentClass • Roll $roll\n${_monthName(_selectedMonth)}\n\nCollect ${_money(amount)} via $_paymentMode?',
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, Collect', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    return result == true;
  }

  Future<String> _getGoogleScriptUrl() async {
    return _windowsGoogleScriptUrl();
  }

  Future<Map<String, dynamic>> _saveFeeToGoogleDrive({
    required Map<String, dynamic> paymentData,
    required Uint8List pdfBytes,
  }) async {
    final scriptUrl = await _getGoogleScriptUrl();

    final response = await WindowsBackendBridge.post(
      Uri.parse(scriptUrl),
      headers: {'Content-Type': 'text/plain;charset=utf-8'},
      body: jsonEncode({
        'action': 'save_fee_payment',
        ...paymentData,
        'pdfBase64': base64Encode(pdfBytes),
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Google Drive save failed: ${response.statusCode}');
    }

    final result = Map<String, dynamic>.from(jsonDecode(response.body));
    if (result['success'] != true) {
      throw Exception(result['message'] ?? 'Google Drive fee save failed');
    }
    return result;
  }

  Future<void> _collectPayment(
    QueryDocumentSnapshot<Map<String, dynamic>> studentDoc,
    Map<String, dynamic>? ledger,
  ) async {
    if (_isSavingPayment) return;

    final student = await SchoolPersonIdentity.ensure('students_directory',studentDoc.id);
    final studentName = student['name']?.toString().trim() ?? 'Student';
    final studentClass = student['class']?.toString().trim() ?? '';
    final roll = student['rollNo']?.toString().trim() ?? '';
    final parentContact = student['parentContact']?.toString().trim() ?? '';
    final parentName = student['parentName']?.toString().trim() ?? '';
    final dateOfBirth = student['dateOfBirth']?.toString().trim() ?? '';
    final rawStudentUid =
        student[_testStudentUidField]?.toString().trim() ?? '';
    final studentUid = _studentUidConfig['masterEnabled'] == true &&
            _studentUidConfig['feesEnabled'] == true
        ? rawStudentUid
        : '';
    final feeIdentity = _feeIdentityForStudent(student, _studentUidConfig);

    final oldExpected = _toDouble(ledger?['expectedAmount']);
    final oldPaid = _toDouble(ledger?['totalPaid']);
    final expected = oldExpected > 0 ? oldExpected : _selectedFeesTotal;
    final amount = double.tryParse(_receivedAmountController.text.trim()) ?? 0.0;
    final remainingBefore = (expected - oldPaid).clamp(0, double.infinity).toDouble();

    if (_selectedFeeHeads.isEmpty || expected <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text('Kam se kam ek fee item tick karein aur fee amount set karein.'),
        ),
      );
      return;
    }

    if (amount <= 0 || amount > remainingBefore) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text('Amount 1 se ${_money(remainingBefore)} ke beech hona chahiye.'),
        ),
      );
      return;
    }

    final confirmed = await _confirmPayment(
      studentName: studentName,
      studentClass: studentClass,
      roll: roll,
      amount: amount,
    );
    if (!confirmed) return;

    setState(() => _isSavingPayment = true);

    final now = DateTime.now();
    final schoolProfile = await _loadSchoolProfile();
    final receiptNo =
        'VS-${now.year}${now.month.toString().padLeft(2, '0')}-${now.millisecondsSinceEpoch}';
    final totalPaid = oldPaid + amount;
    final balance = (expected - totalPaid).clamp(0, double.infinity).toDouble();
    final status = _feeStatus(expected, totalPaid);

    final feeItems = <String, double>{};
    if (oldExpected > 0 && ledger?['feeItems'] is Map) {
      final oldItems = Map<String, dynamic>.from(ledger!['feeItems']);
      for (final entry in oldItems.entries) {
        feeItems[entry.key] = _toDouble(entry.value);
      }
    } else {
      for (final head in _selectedFeeHeads) {
        feeItems[head] = _activeFeeAmounts[head] ?? 0.0;
      }
    }

    final paymentRef = FirebaseFirestore.instance.collection('fee_payments').doc();
    final paymentData = <String, dynamic>{
      'paymentId': paymentRef.id,
      'receiptNo': receiptNo,
      'studentId': studentDoc.id,
          'personId': student['mobileStableId'] ?? studentDoc.id,
      'feeIdentity': feeIdentity,
      'studentUid': studentUid,
      'studentName': studentName,
      'parentName': parentName,
      'dateOfBirth': dateOfBirth,
      'class': studentClass,
      'rollNo': roll,
      'parentContact': parentContact,
      'month': _selectedMonth,
      'feeItems': feeItems,
      'expectedAmount': expected,
      'installmentAmount': amount,
      'totalPaid': totalPaid,
      'balance': balance,
      'status': status,
      'paymentMode': _paymentMode,
      'schoolName': _schoolName(schoolProfile),
      'principalName': _principalName(schoolProfile),
      'schoolLogoUrl': schoolProfile['logoUrl']?.toString() ?? '',
      'schoolSealUrl': schoolProfile['sealUrl']?.toString() ?? '',
      'principalSignatureUrl':
          schoolProfile['principalSignatureUrl']?.toString() ?? '',
      'collectedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
      'dateText': '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}',
      'timeText': '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    };

    try {
      final pdfBytes = await _buildReceiptPdf(paymentData);
      final googleResult = await _saveFeeToGoogleDrive(
        paymentData: paymentData,
        pdfBytes: pdfBytes,
      );

      final driveUrl = googleResult['fileUrl']?.toString() ?? '';
      final sheetUrl = googleResult['sheetUrl']?.toString() ?? '';

      final batch = FirebaseFirestore.instance.batch();
      batch.set(paymentRef, {
        ...paymentData,
        'driveUrl': driveUrl,
        'sheetUrl': sheetUrl,
        'paidAt': FieldValue.serverTimestamp(),
      });

      final existingLedgerDocId =
          ledger?['__docId']?.toString().trim() ?? '';

      final ledgerRef = FirebaseFirestore.instance
          .collection('fee_ledger')
          .doc(existingLedgerDocId.isNotEmpty
              ? existingLedgerDocId
              : _ledgerId(feeIdentity));

      batch.set(
        ledgerRef,
        {
          'studentId': studentDoc.id,
          'personId': student['mobileStableId'] ?? studentDoc.id,
          'feeIdentity': feeIdentity,
          'studentUid': studentUid,
          'studentName': studentName,
          'parentName': parentName,
          'dateOfBirth': dateOfBirth,
          'class': studentClass,
          'rollNo': roll,
          'parentContact': parentContact,
          'month': _selectedMonth,
          'feeItems': feeItems,
          'expectedAmount': expected,
          'totalPaid': totalPaid,
          'balance': balance,
          'status': status,
          'paymentMode': _paymentMode,
          'lastPaymentId': paymentRef.id,
          'lastReceiptNo': receiptNo,
          'lastDriveUrl': driveUrl,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      await batch.commit();

      if (!mounted) return;
      setState(() {
        // Payment ke baad student selected hi rahega taaki receipt
        // print/WhatsApp aur final status isi panel me dikh sake.
        _activeStudentId = studentDoc.id;
        _activeLedger = {
          ...?ledger,
          'expectedAmount': expected,
          'totalPaid': totalPaid,
          'balance': balance,
          'status': status,
          'feeItems': feeItems,
          'feeIdentity': feeIdentity,
          'studentUid': studentUid,
          '__docId': ledgerRef.id,
          'lastPaymentId': paymentRef.id,
          'lastReceiptNo': receiptNo,
          'lastDriveUrl': driveUrl,
        };
        _receivedAmountController.text =
            balance > 0 ? balance.toStringAsFixed(0) : '';
        _isSavingPayment = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text(
            status == 'PAID'
                ? 'Payment complete. Current month Collect button lock ho gaya.'
                : 'Partial payment saved. Balance ${_money(balance)}.',
          ),
        ),
      );

      _openWhatsAppFromPayment({
        ...paymentData,
        'driveUrl': driveUrl,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSavingPayment = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Payment save error: $e'),
        ),
      );
    }
  }

  String _whatsappNumber(String raw) {
    var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('0') && digits.length > 10) {
      digits = digits.substring(1);
    }
    if (digits.length == 10) digits = '91$digits';
    return digits;
  }

  String _receiptText(Map<String, dynamic> data) {
    final items = Map<String, dynamic>.from(data['feeItems'] ?? {});
    final itemLines = items.entries
        .where((e) => _toDouble(e.value) > 0)
        .map((e) => '${e.key}: ${_money(_toDouble(e.value))}')
        .join('\n');

    final driveUrl = data['driveUrl']?.toString() ?? '';

    final schoolName = data['schoolName']?.toString().trim().isNotEmpty == true
        ? data['schoolName'].toString().trim()
        : '';

    return '$schoolName\n\n'
        'FEES RECEIPT\n'
        'Receipt No: ${data['receiptNo'] ?? ''}\n'
        'Date: ${data['dateText'] ?? ''} ${data['timeText'] ?? ''}\n'
        'Student: ${data['studentName'] ?? ''}\n'
        '${(data['studentUid']?.toString().trim().isNotEmpty ?? false) ? 'Student UID: ${data['studentUid']}\n' : ''}'
        'Class: ${data['class'] ?? ''} | Roll: ${data['rollNo'] ?? ''}\n'
        'Month: ${_monthName(data['month']?.toString() ?? _selectedMonth)}\n\n'
        '$itemLines\n\n'
        'Received: ${_money(_toDouble(data['installmentAmount']))}\n'
        'Total Paid: ${_money(_toDouble(data['totalPaid']))}\n'
        'Balance: ${_money(_toDouble(data['balance']))}\n'
        'Mode: ${data['paymentMode'] ?? ''}\n'
        '${driveUrl.isNotEmpty ? '\nPDF Receipt: $driveUrl\n' : ''}'
        '\nThank you.';
  }

  void _openWhatsAppFromPayment(Map<String, dynamic> data) {
    final contact = data['parentContact']?.toString() ?? '';
    final number = _whatsappNumber(contact);
    if (number.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Parent WhatsApp number missing hai.')),
      );
      return;
    }

    final message = Uri.encodeComponent(_receiptText(data));
    html.window.open('https://wa.me/$number?text=$message', '_blank');
  }

  Future<Uint8List> _buildReceiptPdf(Map<String, dynamic> data) async {
    final custom=await WindowsDocumentTemplates.selected('receipt',data);
    if(custom!=null)return custom;
    final pdf = pw.Document();
    final items = Map<String, dynamic>.from(data['feeItems'] ?? {});
    final itemEntries = items.entries.where((e) => _toDouble(e.value) > 0).toList();

    pw.TableRow row(String left, String right, {bool bold = false}) {
      final style = pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal);
      return pw.TableRow(
        children: [
          pw.Padding(
            padding: const pw.EdgeInsets.all(5),
            child: pw.Text(left, style: style),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.all(5),
            child: pw.Text(right, style: style, textAlign: pw.TextAlign.right),
          ),
        ],
      );
    }

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(34),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(
                data['schoolName']?.toString().trim().isNotEmpty == true
                    ? data['schoolName'].toString().trim()
                    : '',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                'VIDYA SAARTHI • FEES RECEIPT',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 14),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Receipt No: ${data['receiptNo'] ?? ''}', style: const pw.TextStyle(fontSize: 9)),
                  pw.Text('Date: ${data['dateText'] ?? ''}', style: const pw.TextStyle(fontSize: 9)),
                ],
              ),
              pw.SizedBox(height: 6),
              pw.Text('Name: ${data['studentName'] ?? ''}', style: const pw.TextStyle(fontSize: 10)),
              if (data['studentUid']?.toString().trim().isNotEmpty == true) ...[
                pw.SizedBox(height: 3),
                pw.Text(
                  'Student UID: ${data['studentUid']}',
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
              pw.SizedBox(height: 4),
              pw.Text(
                'Class: ${data['class'] ?? ''}    Roll No: ${data['rollNo'] ?? ''}    Month: ${_monthName(data['month']?.toString() ?? _selectedMonth)}',
                style: const pw.TextStyle(fontSize: 10),
              ),
              pw.SizedBox(height: 12),
              pw.Table(
                border: pw.TableBorder.all(width: 0.5),
                columnWidths: const {
                  0: pw.FlexColumnWidth(3),
                  1: pw.FlexColumnWidth(1),
                },
                children: [
                  row('Description', 'Rs.', bold: true),
                  ...itemEntries.map((e) => row(e.key, _toDouble(e.value).toStringAsFixed(0))),
                  row('Amount Received', _toDouble(data['installmentAmount']).toStringAsFixed(0), bold: true),
                  row('Total Paid', _toDouble(data['totalPaid']).toStringAsFixed(0), bold: true),
                  row('Balance Due', _toDouble(data['balance']).toStringAsFixed(0), bold: true),
                ],
              ),
              pw.SizedBox(height: 10),
              pw.Text('Payment Mode: ${data['paymentMode'] ?? ''}', style: const pw.TextStyle(fontSize: 9)),
              pw.Spacer(),
              pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Column(
                  children: [
                    pw.SizedBox(height: 25),
                    pw.Container(width: 110, height: 0.5, color: PdfColors.black),
                    pw.SizedBox(height: 4),
                    pw.Text('Signature', style: const pw.TextStyle(fontSize: 9)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  Future<Map<String, dynamic>?> _loadLastPayment(Map<String, dynamic>? ledger) async {
    final paymentId = ledger?['lastPaymentId']?.toString() ?? '';
    if (paymentId.isEmpty) return null;
    final doc = await FirebaseFirestore.instance.collection('fee_payments').doc(paymentId).get();
    return doc.data();
  }

  Future<void> _printLastReceipt(Map<String, dynamic>? ledger) async {
    try {
      final data = await _loadLastPayment(ledger);
      if (data == null) throw Exception('Receipt record nahi mila.');
      final bytes = await _buildReceiptPdf(data);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Receipt print error: $e')),
      );
    }
  }

  Future<void> _whatsappLastReceipt(Map<String, dynamic>? ledger) async {
    try {
      final data = await _loadLastPayment(ledger);
      if (data == null) throw Exception('Receipt record nahi mila.');
      _openWhatsAppFromPayment(data);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('WhatsApp receipt error: $e')),
      );
    }
  }

  Widget _amountSummaryBox({
    required String label,
    required double amount,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        decoration: BoxDecoration(
          color: const Color(0xFF14242C),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.22)),
        ),
        child: Column(
          children: [
            Text(
              _money(amount),
              style: TextStyle(
                color: color,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _feeStructurePanel({
    required bool studentSelected,
    required bool settingsReady,
    required bool alreadyPaid,
    required double oldExpected,
  }) {
    final configuredHeads = _feeHeads
        .where((head) => (_activeFeeAmounts[head] ?? 0) > 0)
        .toSet();

    final canSelectAll = studentSelected &&
        settingsReady &&
        configuredHeads.isNotEmpty &&
        !alreadyPaid &&
        oldExpected <= 0 &&
        !_isSavingPayment;

    final allSelected = configuredHeads.isNotEmpty &&
        configuredHeads.every(_selectedFeeHeads.contains);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_rounded, color: Color(0xFF38A8FF), size: 21),
              const SizedBox(width: 8),
              const Text(
                'Fee Structure',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  studentSelected
                      ? settingsReady
                          ? 'Settings me fixed amount wale fee heads. Tick karke payment select karein.'
                          : 'Is class ka fee structure Settings me configure nahi hai.'
                      : 'Student select hone tak amounts ₹0 rahenge.',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: settingsReady || !studentSelected
                        ? Colors.white38
                        : Colors.orangeAccent,
                    fontSize: 9.5,
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: Checkbox(
                      value: allSelected,
                      activeColor: const Color(0xFF00A884),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: canSelectAll
                          ? (value) {
                              setState(() {
                                if (value == true) {
                                  _selectedFeeHeads =
                                      Set<String>.from(configuredHeads);
                                } else {
                                  _selectedFeeHeads.clear();
                                }

                                final total = _selectedFeesTotal;
                                _receivedAmountController.text =
                                    total > 0 ? total.toStringAsFixed(0) : '';
                              });
                            }
                          : null,
                    ),
                  ),
                  Text(
                    'Select All',
                    style: TextStyle(
                      color: canSelectAll ? Colors.white70 : Colors.white30,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FeeCollectionSettingsScreen()),
                  );
                },
                icon: const Icon(Icons.settings_rounded, size: 16),
                label: const Text('Settings'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF172932),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                SizedBox(width: 44, child: Text('Select', style: TextStyle(color: Colors.white54, fontSize: 10))),
                Expanded(child: Text('Fee Type', style: TextStyle(color: Colors.white54, fontSize: 10))),
                SizedBox(width: 120, child: Text('Amount (₹)', style: TextStyle(color: Colors.white54, fontSize: 10))),
              ],
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 255,
            child: ListView.separated(
              itemCount: _feeHeads.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
              itemBuilder: (context, index) {
                final head = _feeHeads[index];
                final amount = studentSelected && settingsReady
                    ? (_activeFeeAmounts[head] ?? 0.0)
                    : 0.0;
                final configured = amount > 0;
                final checked = studentSelected && _selectedFeeHeads.contains(head);
                final lockedByExistingPayment = oldExpected > 0;
                final canToggle = studentSelected &&
                    settingsReady &&
                    configured &&
                    !alreadyPaid &&
                    !lockedByExistingPayment &&
                    !_isSavingPayment;

                return SizedBox(
                  height: 42,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Checkbox(
                          value: checked,
                          activeColor: const Color(0xFF00A884),
                          side: BorderSide(color: configured ? Colors.white54 : Colors.white12),
                          onChanged: canToggle
                              ? (value) {
                                  setState(() {
                                    if (value == true) {
                                      _selectedFeeHeads.add(head);
                                    } else {
                                      _selectedFeeHeads.remove(head);
                                    }
                                    final total = _selectedFeesTotal;
                                    _receivedAmountController.text =
                                        total > 0 ? total.toStringAsFixed(0) : '';
                                  });
                                }
                              : null,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          head,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: configured ? Colors.white70 : Colors.white30,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Container(
                        width: 120,
                        height: 31,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF12242D),
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Text(
                          amount > 0 ? amount.toStringAsFixed(0) : '0',
                          style: TextStyle(
                            color: amount > 0 ? const Color(0xFF00D9A5) : Colors.white30,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _paymentDetailsPanel({
    required bool studentSelected,
    required bool settingsReady,
    required bool alreadyPaid,
    required double expected,
    required double paid,
    required double remaining,
    required Map<String, dynamic>? ledger,
    required QueryDocumentSnapshot<Map<String, dynamic>>? studentDoc,
  }) {
    final hasReceipt = ledger?['lastPaymentId'] != null;
    final canCollect = studentSelected &&
        settingsReady &&
        !alreadyPaid &&
        _selectedFeeHeads.isNotEmpty &&
        expected > 0 &&
        !_isSavingPayment;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.account_balance_wallet_outlined, color: Color(0xFF38A8FF), size: 21),
              SizedBox(width: 8),
              Text(
                'Payment Details',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _amountSummaryBox(
                label: 'Total Fee',
                amount: studentSelected ? expected : 0,
                color: const Color(0xFF00D9A5),
              ),
              const SizedBox(width: 8),
              _amountSummaryBox(
                label: 'Amount Paid',
                amount: studentSelected ? paid : 0,
                color: const Color(0xFF00D9A5),
              ),
              const SizedBox(width: 8),
              _amountSummaryBox(
                label: 'Remaining Due',
                amount: studentSelected ? remaining : 0,
                color: remaining > 0 ? Colors.redAccent : const Color(0xFF00D9A5),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _receivedAmountController,
            enabled: studentSelected && settingsReady && !alreadyPaid && !_isSavingPayment,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            decoration: _inputDecoration('Received Amount (Partial/Full)', Icons.currency_rupee_rounded),
          ),
          const SizedBox(height: 14),
          const Text(
            'Payment Mode',
            style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w800, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _paymentModeButton('Cash', Icons.payments_rounded, studentSelected && !alreadyPaid)),
              const SizedBox(width: 8),
              Expanded(child: _paymentModeButton('UPI', Icons.qr_code_rounded, studentSelected && !alreadyPaid)),
              const SizedBox(width: 8),
              Expanded(child: _paymentModeButton('Bank Transfer', Icons.account_balance_rounded, studentSelected && !alreadyPaid)),
            ],
          ),
          const Spacer(),
          if (studentSelected && !settingsReady)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orangeAccent.withOpacity(0.08),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                _activeFeeSettingsMessage ?? 'Fixed fee structure Settings me save karein.',
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 10.5),
              ),
            ),
          if (alreadyPaid)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF00A884).withOpacity(0.08),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                '✓ ${_monthName(_selectedMonth)} ka payment complete hai. Next month collection automatically unlock hoga.',
                style: const TextStyle(color: Color(0xFF00D9A5), fontSize: 10.5, fontWeight: FontWeight.w700),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: hasReceipt ? () => _printLastReceipt(ledger) : null,
                  icon: const Icon(Icons.print_rounded),
                  label: const Text('Print Receipt'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: hasReceipt ? () => _whatsappLastReceipt(ledger) : null,
                  icon: const Icon(Icons.send_rounded, color: Color(0xFF25D366)),
                  label: const Text('WhatsApp Receipt'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00A884),
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              onPressed: canCollect && studentDoc != null
                  ? () => _collectPayment(studentDoc, ledger)
                  : null,
              icon: _isSavingPayment
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Icon(alreadyPaid ? Icons.lock_rounded : Icons.check_circle_rounded, color: Colors.white),
              label: Text(
                alreadyPaid
                    ? 'PAID - LOCKED'
                    : _isSavingPayment
                        ? 'Saving...'
                        : 'Collect Payment',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _paymentModeButton(String value, IconData icon, bool enabled) {
    final selected = _paymentMode == value;
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? const Color(0xFF00D9A5) : Colors.white60,
        backgroundColor: selected ? const Color(0xFF00A884).withOpacity(0.12) : Colors.transparent,
        side: BorderSide(
          color: selected ? const Color(0xFF00D9A5) : Colors.white12,
        ),
        padding: const EdgeInsets.symmetric(vertical: 13),
      ),
      onPressed: enabled && !_isSavingPayment ? () => setState(() => _paymentMode = value) : null,
      icon: Icon(icon, size: 17),
      label: Text(value, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _mainPaymentPanel(
    QueryDocumentSnapshot<Map<String, dynamic>>? studentDoc,
    Map<String, dynamic>? ledger,
  ) {
    final studentSelected = studentDoc != null;
    final student = studentDoc?.data() ?? <String, dynamic>{};
    final name = student['name']?.toString().trim() ?? '';
    final studentClass = student['class']?.toString().trim() ?? '';
    final roll = student['rollNo']?.toString().trim() ?? '';
    final feeStudentUid = studentSelected &&
            _studentUidConfig['masterEnabled'] == true &&
            _studentUidConfig['feesEnabled'] == true
        ? (student[_testStudentUidField]?.toString().trim() ?? '')
        : '';

    final oldPaid = studentSelected ? _toDouble(ledger?['totalPaid']) : 0.0;
    final oldExpected = studentSelected ? _toDouble(ledger?['expectedAmount']) : 0.0;
    final expected = studentSelected
        ? (oldExpected > 0 ? oldExpected : _selectedFeesTotal)
        : 0.0;
    final remaining = studentSelected
        ? (expected - oldPaid).clamp(0, double.infinity).toDouble()
        : 0.0;
    final status = studentSelected ? _feeStatus(expected, oldPaid) : 'DUE';
    final alreadyPaid = studentSelected && status == 'PAID';
    final statusColor = _statusColor(status);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF102129),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF00A884).withOpacity(0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: const Color(0x2200A884),
                child: Text(
                  studentSelected && name.isNotEmpty ? name[0].toUpperCase() : '—',
                  style: const TextStyle(color: Color(0xFF00D9A5), fontWeight: FontWeight.w900, fontSize: 18),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      studentSelected ? name : 'Student select karein',
                      style: TextStyle(
                        color: studentSelected ? Colors.white : Colors.white54,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      studentSelected
                          ? '$studentClass  •  Roll No: $roll  •  Month: ${_monthName(_selectedMonth)}'
                          : 'Name ya Roll No search karein, phir neeche matching student select karein.',
                      style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                    ),
                    if (feeStudentUid.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Student UID: $feeStudentUid',
                        style: const TextStyle(
                          color: Color(0xFF00D9A5),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (studentSelected) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    status == 'PARTIAL' ? 'PARTIAL PAID' : status,
                    style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _isSavingPayment ? null : _clearStudentAndSearch,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                  label: const Text('Change Student'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 850;
              final feePanel = _feeStructurePanel(
                studentSelected: studentSelected,
                settingsReady: studentSelected && _activeFeeSettingsReady,
                alreadyPaid: alreadyPaid,
                oldExpected: oldExpected,
              );
              final paymentPanel = _paymentDetailsPanel(
                studentSelected: studentSelected,
                settingsReady: studentSelected && _activeFeeSettingsReady,
                alreadyPaid: alreadyPaid,
                expected: expected,
                paid: oldPaid,
                remaining: remaining,
                ledger: ledger,
                studentDoc: studentDoc,
              );

              if (wide) {
                return SizedBox(
                  height: 440,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 6, child: feePanel),
                      const SizedBox(width: 12),
                      Expanded(flex: 5, child: paymentPanel),
                    ],
                  ),
                );
              }

              return Column(
                children: [
                  feePanel,
                  const SizedBox(height: 12),
                  SizedBox(height: 430, child: paymentPanel),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _studentCard(
    QueryDocumentSnapshot<Map<String, dynamic>> studentDoc,
    Map<String, dynamic>? ledger, {
    required bool canSelect,
  }) {
    final student = studentDoc.data();
    final name = student['name']?.toString() ?? 'Student';
    final studentClass = student['class']?.toString() ?? '';
    final roll = student['rollNo']?.toString() ?? '';
    final expected = _toDouble(ledger?['expectedAmount']);
    final paid = _toDouble(ledger?['totalPaid']);
    final balance = expected > 0
        ? (expected - paid).clamp(0, double.infinity).toDouble()
        : 0.0;
    final status = _feeStatus(expected, paid);
    final color = _statusColor(status);
    final isActive = _activeStudentId == studentDoc.id;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: canSelect && !_isSavingPayment
          ? () => _openInlineCollector(studentDoc, ledger)
          : null,
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF183139) : const Color(0xFF172229),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isActive
                ? const Color(0xFF00D9A5).withOpacity(0.65)
                : Colors.white.withOpacity(0.04),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isActive ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
              color: canSelect
                  ? (isActive ? const Color(0xFF00D9A5) : Colors.white38)
                  : Colors.white12,
              size: 22,
            ),
            const SizedBox(width: 10),
            CircleAvatar(
              backgroundColor: const Color(0x2200A884),
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : 'S',
                style: const TextStyle(color: Color(0xFF00D9A5), fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: Text(studentClass, style: const TextStyle(color: Colors.white60, fontSize: 11)),
            ),
            SizedBox(
              width: 80,
              child: Text('Roll $roll', style: const TextStyle(color: Colors.white60, fontSize: 11)),
            ),
            if (expected > 0) ...[
              SizedBox(
                width: 100,
                child: Text(
                  'Due ${_money(balance)}',
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 10.5),
                ),
              ),
            ],
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                status == 'PARTIAL' ? 'PARTIAL' : status,
                style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_studentUidConfigLoaded) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B141A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF00A884)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Fees Collection'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _studentsStream,
        builder: (context, studentSnapshot) {
          if (studentSnapshot.connectionState == ConnectionState.waiting &&
              !studentSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF00A884)));
          }
          if (studentSnapshot.hasError) {
            return Center(
              child: Text(
                'Students load error: ${studentSnapshot.error}',
                style: const TextStyle(color: Colors.redAccent),
              ),
            );
          }

          final students = studentSnapshot.data?.docs ?? [];

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _ledgerStream,
            builder: (context, ledgerSnapshot) {
              final ledgerByIdentity = <String, Map<String, dynamic>>{};
              final legacyLedgerByStudentId = <String, Map<String, dynamic>>{};

              for (final doc in ledgerSnapshot.data?.docs ?? []) {
                final raw = doc.data();
                final data = <String, dynamic>{
                  ...raw,
                  '__docId': doc.id,
                };

                final feeIdentity = data['feeIdentity']?.toString() ?? '';
                if (feeIdentity.isNotEmpty) {
                  ledgerByIdentity[feeIdentity] = data;
                }

                final studentId = data['studentId']?.toString() ?? '';
                if (studentId.isNotEmpty) {
                  legacyLedgerByStudentId[studentId] = data;
                }
              }

              Map<String, dynamic>? ledgerForStudent(
                QueryDocumentSnapshot<Map<String, dynamic>> studentDoc,
              ) {
                final student = studentDoc.data();
                final identity =
                    _feeIdentityForStudent(student, _studentUidConfig);

                final byIdentity = ledgerByIdentity[identity];
                if (byIdentity != null) return byIdentity;

                final legacy = legacyLedgerByStudentId[studentDoc.id];
                if (legacy != null &&
                    _legacyLedgerMatchesStudent(legacy, student)) {
                  return legacy;
                }

                return null;
              }

              final nameQuery = _nameSearchController.text.trim().toLowerCase();
              final rollQuery = _rollSearchController.text.trim().toLowerCase();
              final searchStarted = nameQuery.isNotEmpty || rollQuery.isNotEmpty;

              final filtered = students.where((doc) {
                final data = doc.data();
                final cls = data['class']?.toString() ?? '';
                final name = data['name']?.toString().toLowerCase() ?? '';
                final roll = data['rollNo']?.toString().toLowerCase() ?? '';

                final classOk = _selectedClass == 'All Classes' || cls == _selectedClass;
                final nameOk = nameQuery.isEmpty || name.contains(nameQuery);
                final rollOk = rollQuery.isEmpty || roll.contains(rollQuery);
                return classOk && nameOk && rollOk;
              }).toList();

              filtered.sort((a, b) {
                final ad = a.data();
                final bd = b.data();
                final ac = ad['class']?.toString() ?? '';
                final bc = bd['class']?.toString() ?? '';
                final classCompare = ac.compareTo(bc);
                if (classCompare != 0) return classCompare;
                final ar = int.tryParse(ad['rollNo']?.toString() ?? '') ?? 99999;
                final br = int.tryParse(bd['rollNo']?.toString() ?? '') ?? 99999;
                return ar.compareTo(br);
              });

              int paidCount = 0;
              int partialCount = 0;
              int dueCount = 0;

              // Summary selected class/search ke visible students ko reflect karega.
              for (final doc in filtered) {
                final data = ledgerForStudent(doc);
                final expected = _toDouble(data?['expectedAmount']);
                final paid = _toDouble(data?['totalPaid']);
                final status = _feeStatus(expected, paid);
                if (status == 'PAID') {
                  paidCount++;
                } else if (status == 'PARTIAL') {
                  partialCount++;
                } else {
                  dueCount++;
                }
              }

              QueryDocumentSnapshot<Map<String, dynamic>>? activeStudentDoc;
              if (_activeStudentId != null) {
                for (final doc in students) {
                  if (doc.id == _activeStudentId) {
                    activeStudentDoc = doc;
                    break;
                  }
                }
              }

              final activeLedger = activeStudentDoc == null
                  ? null
                  : ledgerForStudent(activeStudentDoc);

              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _summaryCard(
                          title: 'Total Students',
                          count: filtered.length,
                          icon: Icons.groups_rounded,
                          color: Colors.blueAccent,
                        ),
                        _summaryCard(
                          title: 'Paid',
                          count: paidCount,
                          icon: Icons.check_circle_rounded,
                          color: const Color(0xFF00A884),
                        ),
                        _summaryCard(
                          title: 'Partial Paid',
                          count: partialCount,
                          icon: Icons.timelapse_rounded,
                          color: Colors.orangeAccent,
                        ),
                        _summaryCard(
                          title: 'Due',
                          count: dueCount,
                          icon: Icons.warning_amber_rounded,
                          color: Colors.redAccent,
                        ),
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      const FeeTransactionHistoryScreen(),
                                ),
                              );
                            },
                            child: Container(
                              width: 185,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: const Color(0xFF172229),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: const Color(0xFFB388FF)
                                      .withOpacity(0.32),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFB388FF)
                                          .withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(
                                      Icons.history_rounded,
                                      color: Color(0xFFB388FF),
                                    ),
                                  ),
                                  const SizedBox(width: 11),
                                  const Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'History',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 17,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        Text(
                                          'Transactions',
                                          style: TextStyle(
                                            color: Colors.white54,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121F26),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white10),
                      ),

child: Row(
  children: [
    Expanded(
      flex: 2,
      child: DropdownButtonFormField<String>(
        value: _selectedMonth,
        dropdownColor: const Color(0xFF172229),
        style: const TextStyle(color: Colors.white),
        decoration: _inputDecoration(
          'Month',
          Icons.calendar_month_rounded,
        ),
        items: _monthList()
            .map(
              (value) => DropdownMenuItem(
                value: value,
                child: Text(_monthName(value)),
              ),
            )
            .toList(),
        onChanged: (value) {
          if (value != null) {
            setState(() {
              _selectedMonth = value;
              _ledgerStream = _ledgerStreamForMonth(value);
              _resetActiveSelection();
            });
          }
        },
      ),
    ),

    const SizedBox(width: 10),

    Expanded(
      flex: 2,
      child: DropdownButtonFormField<String>(
        value: _selectedClass,
        dropdownColor: const Color(0xFF172229),
        style: const TextStyle(color: Colors.white),
        decoration: _inputDecoration(
          'Class',
          Icons.class_rounded,
        ),
        items: _classes
            .map(
              (value) => DropdownMenuItem(
                value: value,
                child: Text(value),
              ),
            )
            .toList(),
        onChanged: (value) {
          if (value != null) {
            setState(() {
              _selectedClass = value;
              _resetActiveSelection();
              _nameSearchController.clear();
              _rollSearchController.clear();
            });
          }
        },
      ),
    ),

    const SizedBox(width: 10),

    Expanded(
      flex: 3,
      child: TextField(
        controller: _nameSearchController,
        style: const TextStyle(color: Colors.white),
        decoration: _inputDecoration(
          'Student Name',
          Icons.person_search_rounded,
        ),
        onChanged: (_) {
          setState(() {
            if (_activeStudentId != null) {
              _resetActiveSelection();
            }
          });
        },
      ),
    ),

    const SizedBox(width: 10),

    Expanded(
      flex: 2,
      child: TextField(
        controller: _rollSearchController,
        style: const TextStyle(color: Colors.white),
        decoration: _inputDecoration(
          'Roll No',
          Icons.numbers_rounded,
        ),
        onChanged: (_) {
          setState(() {
            if (_activeStudentId != null) {
              _resetActiveSelection();
            }
          });
        },
      ),
    ),
  ],
),
),                      
                    const SizedBox(height: 12),
                    _mainPaymentPanel(activeStudentDoc, activeLedger),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF101D24),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: Row(
                                children: [
                                  const Icon(Icons.groups_2_rounded, color: Color(0xFF38A8FF), size: 19),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Student List (${filtered.length} result${filtered.length == 1 ? '' : 's'})',
                                    style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w800),
                                  ),
                                  const Spacer(),
                                  Text(
                                    searchStarted
                                        ? 'Matching student select karein'
                                        : 'Name ya Roll No search karne ke baad selection active hoga',
                                    style: const TextStyle(color: Colors.white38, fontSize: 9.5),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 1, color: Colors.white10),
                            Container(
                              child: filtered.isEmpty
                                  ? const Center(
                                      child: Text('No students found', style: TextStyle(color: Colors.white54)),
                                    )
                                  : ListView.separated(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      padding: const EdgeInsets.all(10),
                                      itemCount: filtered.length,
                                      separatorBuilder: (_, __) => const SizedBox(height: 7),
                                      itemBuilder: (context, index) {
                                        final student = filtered[index];
                                        return _studentCard(
                                          student,
                                          ledgerForStudent(student),
                                          canSelect: searchStarted,
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

}

// ============================================================
// PAYMENT COLLECTION SETTINGS
// ============================================================

class FeeCollectionSettingsScreen extends StatefulWidget {
  const FeeCollectionSettingsScreen({super.key});

  @override
  State<FeeCollectionSettingsScreen> createState() =>
      _FeeCollectionSettingsScreenState();
}

class _FeeCollectionSettingsScreenState
    extends State<FeeCollectionSettingsScreen> {
  static const List<String> _feeHeads = [
    'Tuition Fees',
    'Admission Fees',
    'Registration Fees',
    'Nobikaron Fees',
    'Bidya Bharati Sahojog Rashi',
    'Building Fees',
    'Shishu Bharati Fees',
    'Library Fees',
    'Medical Fees',
    'Game Fees',
    'Development Fees',
    'Electric Fees',
    'Cultural Fees',
    'Computer Fees',
    'Computer Lab Fees',
    'Educational Development Fees',
    'Exam Fees',
    'Miscellaneous Fees',
    'Late Fees',
    'Vehicle Fees',
  ];

  final List<String> _classes =
      List.generate(12, (index) => 'Class ${index + 1}');
  final Map<String, TextEditingController> _controllers = {};

  String _selectedClass = 'Class 1';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final head in _feeHeads) {
      _controllers[head] = TextEditingController();
    }
    _loadSettings();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _docId(String className) => className.replaceAll(' ', '_');

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  int get _configuredCount {
    var count = 0;
    for (final head in _feeHeads) {
      final amount = double.tryParse(_controllers[head]!.text.trim()) ?? 0.0;
      if (amount > 0) count++;
    }
    return count;
  }

  Future<void> _loadSettings() async {
    setState(() => _loading = true);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('fee_settings')
          .doc(_docId(_selectedClass))
          .get();
      final data = doc.data() ?? <String, dynamic>{};
      final fees = Map<String, dynamic>.from(data['fees'] ?? {});

      for (final head in _feeHeads) {
        final amount = _toDouble(fees[head]);
        _controllers[head]!.text = amount > 0 ? amount.toStringAsFixed(0) : '';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Settings load error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveSettings() async {
    if (_saving) return;

    final fees = <String, double>{};
    for (final head in _feeHeads) {
      final raw = _controllers[head]!.text.trim();
      final amount = raw.isEmpty ? 0.0 : double.tryParse(raw);
      if (amount == null || amount < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('$head ka amount valid nahi hai.'),
          ),
        );
        return;
      }
      fees[head] = amount;
    }

    final configuredHeads = _feeHeads.where((head) => (fees[head] ?? 0) > 0).toList();
    if (configuredHeads.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text(
            'Kam se kam ek fee type ka fixed amount set karein. Tabhi collection panel active hoga.',
          ),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('fee_settings')
          .doc(_docId(_selectedClass))
          .set({
        'className': _selectedClass,
        'fees': fees,
        'configured': true,
        'configuredHeads': configuredHeads,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text(
            '$_selectedClass fee structure saved. ${configuredHeads.length} fee types collection ke liye active hain.',
          ),
        ),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Settings save error: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Payment Collection Settings'),
      ),
      body: Row(
        children: [
          Container(
            width: 190,
            color: const Color(0xFF121B22),
            child: ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: _classes.length,
              itemBuilder: (context, index) {
                final cls = _classes[index];
                final selected = cls == _selectedClass;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    selected: selected,
                    selectedTileColor: const Color(0x2200A884),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    leading: Icon(
                      Icons.class_rounded,
                      color: selected ? const Color(0xFF00D9A5) : Colors.white38,
                    ),
                    title: Text(
                      cls,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white60,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                    onTap: () async {
                      if (cls == _selectedClass || _saving) return;
                      setState(() => _selectedClass = cls);
                      await _loadSettings();
                    },
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00A884)),
                  )
                : Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$_selectedClass Fee Structure',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          'Koi default amount nahi hai. School yahan fixed amount save karega. Jis fee type me amount 0/blank hai, wo collection panel me nahi aayega.',
                          style: TextStyle(color: Colors.white54),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(
                            color: _configuredCount > 0
                                ? const Color(0xFF00A884).withOpacity(0.08)
                                : Colors.orangeAccent.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _configuredCount > 0
                                ? '$_configuredCount fee types configured. Save karne ke baad Fees Collection panel automatic active hoga.'
                                : 'Abhi fixed fee amount set nahi hai. Fees Collection disabled rahega.',
                            style: TextStyle(
                              color: _configuredCount > 0
                                  ? const Color(0xFF00D9A5)
                                  : Colors.orangeAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: ListView.separated(
                            itemCount: _feeHeads.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final head = _feeHeads[index];
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF172229),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        head,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 190,
                                      child: TextField(
                                        controller: _controllers[head],
                                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                        style: const TextStyle(color: Colors.white),
                                        onChanged: (_) => setState(() {}),
                                        decoration: InputDecoration(
                                          prefixText: '₹ ',
                                          prefixStyle: const TextStyle(color: Color(0xFF00D9A5)),
                                          hintText: 'Fixed amount',
                                          hintStyle: const TextStyle(color: Colors.white24),
                                          filled: true,
                                          fillColor: const Color(0xFF0B141A),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(9),
                                            borderSide: BorderSide.none,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00A884),
                              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
                            ),
                            onPressed: _saving ? null : _saveSettings,
                            icon: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.save_rounded, color: Colors.white),
                            label: Text(
                              _saving ? 'Saving...' : 'Save / Update Fee Structure',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}



// ============================================================
// TEACHERS DIRECTORY
// ============================================================
class TeachersDirectoryScreen extends StatefulWidget {
  const TeachersDirectoryScreen({super.key});

  @override
  State<TeachersDirectoryScreen> createState() =>
      _TeachersDirectoryScreenState();
}

class _TeachersDirectoryScreenState
    extends State<TeachersDirectoryScreen> {
  final TextEditingController _searchController =
      TextEditingController();

  String _statusFilter = 'All';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ============================================================
  // GOOGLE APPS SCRIPT
  // ============================================================

  Future<String> _getTeacherScriptUrl() async {
    return _windowsGoogleScriptUrl();
  }

  Future<Map<String, dynamic>> _callTeacherApi(
    Map<String, dynamic> body,
  ) async {
    final scriptUrl = await _getTeacherScriptUrl();

    final response = await WindowsBackendBridge.post(
          Uri.parse(scriptUrl),
          headers: {
            'Content-Type': 'text/plain;charset=utf-8',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception(
        'Google API error: ${response.statusCode}',
      );
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map) {
      throw Exception('Google API se invalid response mila.');
    }

    return Map<String, dynamic>.from(decoded);
  }

  // ============================================================
  // TEACHER PHOTO
  // ============================================================

  Widget _teacherPhoto(
    Map<String, dynamic> data,
    String name,
  ) {
    final photoUrl =
        data['photoUrl']?.toString().trim() ?? '';

    final photoBase64 =
        data['photoBase64']?.toString().trim() ?? '';

    if (photoUrl.isNotEmpty) {
      return Image.network(
        photoUrl,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
errorBuilder: (
          context,
          error,
          stackTrace,
        ) {
          return _teacherFallback(name);
        },
      );
    }

    if (photoBase64.isNotEmpty) {
      try {
        return Image.memory(
          base64Decode(photoBase64),
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
        );
      } catch (_) {}
    }

    return _teacherFallback(name);
  }

  Widget _teacherFallback(String name) {
    return Container(
      color: const Color(0xFF10191F),
      alignment: Alignment.center,
      child: Text(
        name.trim().isEmpty
            ? 'T'
            : name.trim()[0].toUpperCase(),
        style: const TextStyle(
          color: Colors.purpleAccent,
          fontSize: 28,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  // ============================================================
  // SCHEDULE
  // ============================================================

  Future<void> _openSchedule(
    String docId,
    Map<String, dynamic> data,
  ) async {
    final oldSchedule = data['schedule'] is Map
        ? Map<String, dynamic>.from(data['schedule'])
        : <String, dynamic>{};

    final monday = TextEditingController(
      text: oldSchedule['Monday']?.toString() ?? '',
    );

    final tuesday = TextEditingController(
      text: oldSchedule['Tuesday']?.toString() ?? '',
    );

    final wednesday = TextEditingController(
      text: oldSchedule['Wednesday']?.toString() ?? '',
    );

    final thursday = TextEditingController(
      text: oldSchedule['Thursday']?.toString() ?? '',
    );

    final friday = TextEditingController(
      text: oldSchedule['Friday']?.toString() ?? '',
    );

    final saturday = TextEditingController(
      text: oldSchedule['Saturday']?.toString() ?? '',
    );

    bool saving = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Widget scheduleField(
              String day,
              TextEditingController controller,
            ) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: controller,
                  style:
                      const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: day,
                    hintText:
                        'Example: 09:00-10:00 Class 6 Mathematics',
                    labelStyle: const TextStyle(
                      color: Colors.purpleAccent,
                    ),
                    hintStyle: const TextStyle(
                      color: Colors.white24,
                      fontSize: 11,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF10191F),
                    border: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              );
            }

            return AlertDialog(
              backgroundColor:
                  const Color(0xFF172229),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(20),
              ),
              title: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.purpleAccent
                          .withOpacity(0.12),
                      borderRadius:
                          BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.calendar_month_rounded,
                      color: Colors.purpleAccent,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Weekly Schedule',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight:
                                FontWeight.w800,
                          ),
                        ),
                        Text(
                          data['name']?.toString() ??
                              'Teacher',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      scheduleField(
                        'Monday',
                        monday,
                      ),
                      scheduleField(
                        'Tuesday',
                        tuesday,
                      ),
                      scheduleField(
                        'Wednesday',
                        wednesday,
                      ),
                      scheduleField(
                        'Thursday',
                        thursday,
                      ),
                      scheduleField(
                        'Friday',
                        friday,
                      ),
                      scheduleField(
                        'Saturday',
                        saturday,
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.pop(ctx),
                  child: const Text(
                    'Cancel',
                    style:
                        TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        Colors.purpleAccent,
                  ),
                  onPressed: saving
                      ? null
                      : () async {
                          final schedule =
                              <String, String>{
                            'Monday':
                                monday.text.trim(),
                            'Tuesday':
                                tuesday.text.trim(),
                            'Wednesday':
                                wednesday.text.trim(),
                            'Thursday':
                                thursday.text.trim(),
                            'Friday':
                                friday.text.trim(),
                            'Saturday':
                                saturday.text.trim(),
                          };

                          setDialogState(
                            () => saving = true,
                          );

                          try {
                            Map<String, dynamic>
                                result =
                                await _callTeacherApi({
                              'action':
                                  'update_teacher_schedule',
                              'teacherId':
                                  data['teacherId']
                                          ?.toString()
                                          .trim() ??
                                      '',
                              'phone':
                                  data['phone']
                                          ?.toString()
                                          .trim() ??
                                      '',
                              'schedule': schedule,
                            });

                            // OLD FIRESTORE TEACHER:
                            // Google Sheet me na mile to
                            // automatically migrate karega.
                            if (result['success'] != true &&
                                result['message']
                                        ?.toString()
                                        .contains(
                                          'Teacher Google Sheet me nahi mila',
                                        ) ==
                                    true) {
                              result =
                                  await _callTeacherApi({
                                'action':
                                    'add_teacher',
                                'name':
                                    data['name'] ??
                                        '',
                                'designation':
                                    data['designation'] ??
                                        'Teacher',
                                'subject':
                                    data['subject'] ??
                                        '',
                                'qualification':
                                    data['qualification'] ??
                                        '',
                                'phone':
                                    data['phone'] ??
                                        '',
                                'email':
                                    data['email'] ??
                                        '',
                                'dateOfBirth':
                                    data['dateOfBirth'] ??
                                        '',
                                'joiningDate':
                                    data['joiningDate'] ??
                                        '',
                                'address':
                                    data['address'] ??
                                        '',
                                'assignedClasses':
                                    data['assignedClasses'] ??
                                        '',
                                'employmentType':
                                    data['employmentType'] ??
                                        'Permanent',
                                'status':
                                    data['status'] ??
                                        'Active',
                                'photoBase64':
                                    data['photoBase64']
                                            ?.toString() ??
                                        '',
                                'photoUrl':
                                    data['photoUrl']
                                            ?.toString() ??
                                        '',
                                'schedule': schedule,
                              });
                            }

                            if (result['success'] !=
                                true) {
                              throw Exception(
                                result['message'] ??
                                    'Schedule update failed',
                              );
                            }

                            final updateData =
                                <String, dynamic>{
                              'schedule': schedule,
                              'updatedAt':
                                  FieldValue
                                      .serverTimestamp(),
                              'employeeId':
                                  FieldValue.delete(),
                            };

                            final returnedTeacherId =
                                result['teacherId']
                                    ?.toString()
                                    .trim();

                            final returnedPhotoUrl =
                                result['photoUrl']
                                    ?.toString()
                                    .trim();

                            if (returnedTeacherId !=
                                    null &&
                                returnedTeacherId
                                    .isNotEmpty) {
                              updateData['teacherId'] =
                                  returnedTeacherId;
                            }

                            if (returnedPhotoUrl !=
                                    null &&
                                returnedPhotoUrl
                                    .isNotEmpty) {
                              updateData['photoUrl'] =
                                  returnedPhotoUrl;
                              updateData[
                                      'photoBase64'] =
                                  FieldValue.delete();
                            }

                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'teachers_directory',
                                )
                                .doc(docId)
                                .update(updateData);

                            if (!mounted) return;

                            Navigator.pop(ctx);

                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(
                              const SnackBar(
                                backgroundColor:
                                    Color(0xFF00A884),
                                content: Text(
                                  'Teacher schedule successfully saved!',
                                ),
                              ),
                            );
                          } catch (e) {
                            setDialogState(
                              () => saving = false,
                            );

                            if (!mounted) return;

                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(
                              SnackBar(
                                backgroundColor:
                                    Colors.redAccent,
                                content: Text(
                                  'Schedule save error: $e',
                                ),
                              ),
                            );
                          }
                        },
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.save_rounded,
                          color: Colors.white,
                          size: 17,
                        ),
                  label: Text(
                    saving
                        ? 'Saving...'
                        : 'Save Schedule',
                    style: const TextStyle(
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    monday.dispose();
    tuesday.dispose();
    wednesday.dispose();
    thursday.dispose();
    friday.dispose();
    saturday.dispose();
  }

  // ============================================================
  // EDIT TEACHER
  // ============================================================

  Future<void> _editTeacher(
    String docId,
    Map<String, dynamic> data,
  ) async {
    final nameCtrl = TextEditingController(
      text: data['name']?.toString() ?? '',
    );

    final designationCtrl = TextEditingController(
      text: data['designation']?.toString() ??
          'Teacher',
    );

    final subjectCtrl = TextEditingController(
      text: data['subject']?.toString() ?? '',
    );

    final qualificationCtrl = TextEditingController(
      text: data['qualification']?.toString() ?? '',
    );

    final phoneCtrl = TextEditingController(
      text: data['phone']?.toString() ?? '',
    );

    final emailCtrl = TextEditingController(
      text: data['email']?.toString() ?? '',
    );

    final dobCtrl = TextEditingController(
      text: data['dateOfBirth']?.toString() ?? '',
    );

    final joiningCtrl = TextEditingController(
      text: data['joiningDate']?.toString() ?? '',
    );

    final classesCtrl = TextEditingController(
      text:
          data['assignedClasses']?.toString() ?? '',
    );

    final addressCtrl = TextEditingController(
      text: data['address']?.toString() ?? '',
    );

    final oldPhone =
        data['phone']?.toString().trim() ?? '';

    final oldEmployment =
        data['employmentType']?.toString() ??
            'Permanent';

    final oldStatus =
        data['status']?.toString() ?? 'Active';

    String employmentType = [
      'Permanent',
      'Contract',
      'Guest',
    ].contains(oldEmployment)
        ? oldEmployment
        : 'Permanent';

    String status = [
      'Active',
      'On Leave',
      'Inactive',
    ].contains(oldStatus)
        ? oldStatus
        : 'Active';

    bool saving = false;
    Uint8List? selectedPhotoBytes;
    String selectedPhotoMimeType = 'image/jpeg';
    final existingPhotoUrl = data['photoUrl']?.toString().trim() ?? '';
    final existingPhotoBase64 =
        data['photoBase64']?.toString().trim() ?? '';

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            InputDecoration input(
              String label,
              IconData icon,
            ) {
              return InputDecoration(
                labelText: label,
                labelStyle: const TextStyle(
                  color: Colors.white54,
                ),
                prefixIcon: Icon(
                  icon,
                  color: Colors.purpleAccent,
                  size: 19,
                ),
                filled: true,
                fillColor:
                    const Color(0xFF10191F),
                border: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              );
            }

            Widget teacherEditPhotoPreview() {
              if (selectedPhotoBytes != null) {
                return Image.memory(
                  selectedPhotoBytes!,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                );
              }

              if (existingPhotoUrl.isNotEmpty) {
                return Image.network(
                  existingPhotoUrl,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
errorBuilder: (_, __, ___) => _teacherFallback(
                    nameCtrl.text.trim().isEmpty ? 'Teacher' : nameCtrl.text.trim(),
                  ),
                );
              }

              if (existingPhotoBase64.isNotEmpty) {
                try {
                  return Image.memory(
                    base64Decode(existingPhotoBase64),
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                  );
                } catch (_) {}
              }

              return _teacherFallback(
                nameCtrl.text.trim().isEmpty ? 'Teacher' : nameCtrl.text.trim(),
              );
            }

            return AlertDialog(
              backgroundColor:
                  const Color(0xFF172229),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(20),
              ),
              title: const Row(
                children: [
                  Icon(
                    Icons.edit_rounded,
                    color: Colors.blueAccent,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Edit Teacher',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight:
                          FontWeight.w800,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 650,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: 82,
                            height: 82,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selectedPhotoBytes != null
                                    ? const Color(0xFF00A884)
                                    : Colors.purpleAccent.withOpacity(0.55),
                                width: 2,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: teacherEditPhotoPreview(),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: selectedPhotoBytes != null
                                      ? const Color(0xFF00A884)
                                      : Colors.white24,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 13,
                                ),
                              ),
                              onPressed: saving
                                  ? null
                                  : () async {
                                      final picker = ImagePicker();
                                      final image = await picker.pickImage(
                                        source: ImageSource.gallery,
                                        maxWidth: 700,
                                        imageQuality: 65,
                                      );

                                      if (image == null) return;

                                      final bytes = await image.readAsBytes();

                                      if (bytes.length > 700000) {
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            backgroundColor: Colors.redAccent,
                                            content: Text(
                                              'Photo size zyada hai. Chhota photo select karein.',
                                            ),
                                          ),
                                        );
                                        return;
                                      }

                                      final fileName = image.name.toLowerCase();
                                      setDialogState(() {
                                        selectedPhotoBytes = bytes;
                                        if (fileName.endsWith('.png')) {
                                          selectedPhotoMimeType = 'image/png';
                                        } else if (fileName.endsWith('.webp')) {
                                          selectedPhotoMimeType = 'image/webp';
                                        } else {
                                          selectedPhotoMimeType = 'image/jpeg';
                                        }
                                      });
                                    },
                              icon: Icon(
                                selectedPhotoBytes != null
                                    ? Icons.check_circle_rounded
                                    : Icons.add_a_photo_outlined,
                                color: selectedPhotoBytes != null
                                    ? const Color(0xFF00A884)
                                    : Colors.white70,
                              ),
                              label: Text(
                                selectedPhotoBytes != null
                                    ? 'New Photo Ready'
                                    : 'Change Teacher Photo',
                                style: TextStyle(
                                  color: selectedPhotoBytes != null
                                      ? const Color(0xFF00A884)
                                      : Colors.white70,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: nameCtrl,
                        style: const TextStyle(
                          color: Colors.white,
                        ),
                        decoration: input(
                          'Teacher Full Name *',
                          Icons.person_outline_rounded,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller:
                            designationCtrl,
                        style: const TextStyle(
                          color: Colors.white,
                        ),
                        decoration: input(
                          'Designation',
                          Icons.work_outline_rounded,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller:
                                  subjectCtrl,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                              ),
                              decoration: input(
                                'Subject / Department *',
                                Icons
                                    .menu_book_rounded,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller:
                                  qualificationCtrl,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                              ),
                              decoration: input(
                                'Qualification',
                                Icons
                                    .school_outlined,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller:
                                  phoneCtrl,
                              keyboardType:
                                  TextInputType
                                      .phone,
                              maxLength: 10,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                              ),
                              decoration: input(
                                'Mobile Number *',
                                Icons
                                    .phone_outlined,
                              ).copyWith(
                                counterText: '',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller:
                                  emailCtrl,
                              keyboardType:
                                  TextInputType
                                      .emailAddress,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                              ),
                              decoration: input(
                                'Email Address',
                                Icons
                                    .email_outlined,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: dobCtrl,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                              ),
                              decoration: input(
                                'Date of Birth',
                                Icons
                                    .cake_outlined,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller:
                                  joiningCtrl,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                              ),
                              decoration: input(
                                'Joining Date',
                                Icons
                                    .calendar_today_outlined,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: classesCtrl,
                        style: const TextStyle(
                          color: Colors.white,
                        ),
                        decoration: input(
                          'Assigned Classes',
                          Icons.class_outlined,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: addressCtrl,
                        minLines: 2,
                        maxLines: 3,
                        style: const TextStyle(
                          color: Colors.white,
                        ),
                        decoration: input(
                          'Address',
                          Icons.location_on_outlined,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child:
                                DropdownButtonFormField<
                                    String>(
                              value:
                                  employmentType,
                              dropdownColor:
                                  const Color(
                                    0xFF172229,
                                  ),
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                              ),
                              decoration: input(
                                'Employment Type',
                                Icons
                                    .business_center_outlined,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value:
                                      'Permanent',
                                  child: Text(
                                    'Permanent',
                                  ),
                                ),
                                DropdownMenuItem(
                                  value:
                                      'Contract',
                                  child: Text(
                                    'Contract',
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'Guest',
                                  child: Text(
                                    'Guest',
                                  ),
                                ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setDialogState(
                                    () {
                                      employmentType =
                                          value;
                                    },
                                  );
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child:
                                DropdownButtonFormField<
                                    String>(
                              value: status,
                              dropdownColor:
                                  const Color(
                                    0xFF172229,
                                  ),
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white,
                              ),
                              decoration: input(
                                'Status',
                                Icons
                                    .verified_user_outlined,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'Active',
                                  child: Text(
                                    'Active',
                                  ),
                                ),
                                DropdownMenuItem(
                                  value:
                                      'On Leave',
                                  child: Text(
                                    'On Leave',
                                  ),
                                ),
                                DropdownMenuItem(
                                  value:
                                      'Inactive',
                                  child: Text(
                                    'Inactive',
                                  ),
                                ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setDialogState(
                                    () {
                                      status = value;
                                    },
                                  );
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.pop(ctx),
                  child: const Text(
                    'Cancel',
                    style:
                        TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        const Color(0xFF00A884),
                  ),
                  onPressed: saving
                      ? null
                      : () async {
                          final name =
                              nameCtrl.text.trim();

                          final subject =
                              subjectCtrl.text.trim();

                          final phone =
                              phoneCtrl.text.trim();

                          if (name.isEmpty ||
                              subject.isEmpty) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(
                              const SnackBar(
                                backgroundColor:
                                    Colors.redAccent,
                                content: Text(
                                  'Name aur Subject required hain.',
                                ),
                              ),
                            );
                            return;
                          }

                          if (!RegExp(
                            r'^[0-9]{10}$',
                          ).hasMatch(phone)) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(
                              const SnackBar(
                                backgroundColor:
                                    Colors.redAccent,
                                content: Text(
                                  'Valid 10 digit Mobile Number daalein.',
                                ),
                              ),
                            );
                            return;
                          }

                          String normalizeTeacherPhone(dynamic value) {
                            String digits = (value ?? '')
                                .toString()
                                .replaceAll(RegExp(r'\D'), '');

                            if (digits.length == 12 &&
                                digits.startsWith('91')) {
                              digits = digits.substring(2);
                            }

                            return digits;
                          }

                          final normalizedPhone =
                              normalizeTeacherPhone(phone);

                          final existingTeachers =
                              await FirebaseFirestore.instance
                                  .collection('teachers_directory')
                                  .get();

                          final duplicatePhone =
                              existingTeachers.docs.any((teacherDoc) {
                            if (teacherDoc.id == docId) {
                              return false;
                            }

                            final teacherData = teacherDoc.data();

                            return normalizeTeacherPhone(
                                  teacherData['phone'],
                                ) ==
                                normalizedPhone;
                          });

                          if (duplicatePhone) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                backgroundColor: Colors.orangeAccent,
                                content: Text(
                                  'Is Mobile Number se dusra teacher already registered hai.',
                                ),
                              ),
                            );
                            return;
                          }

                          setDialogState(
                            () => saving = true,
                          );

                          try {
                            Map<String, dynamic>
                                result =
                                await _callTeacherApi({
                              'action':
                                  'edit_teacher',
                              'teacherId':
                                  data['teacherId']
                                          ?.toString()
                                          .trim() ??
                                      '',
                              'oldPhone':
                                  oldPhone,
                              'name': name,
                              'designation':
                                  designationCtrl
                                      .text
                                      .trim(),
                              'subject':
                                  subject,
                              'qualification':
                                  qualificationCtrl
                                      .text
                                      .trim(),
                              'phone': phone,
                              'email':
                                  emailCtrl.text
                                      .trim(),
                              'dateOfBirth':
                                  dobCtrl.text
                                      .trim(),
                              'joiningDate':
                                  joiningCtrl.text
                                      .trim(),
                              'address':
                                  addressCtrl.text
                                      .trim(),
                              'assignedClasses':
                                  classesCtrl.text
                                      .trim(),
                              'employmentType':
                                  employmentType,
                              'status': status,
                              'photoBase64': selectedPhotoBytes == null
                                  ? ''
                                  : base64Encode(selectedPhotoBytes!),
                              'photoMimeType': selectedPhotoMimeType,
                              'schedule':
                                  data['schedule'] ??
                                      {},
                            });

                            // Old Firestore-only teacher:
                            // Google Sheet me automatically
                            // add/migrate ho jayega.
                            if (result['success'] != true &&
                                result['message']
                                        ?.toString()
                                        .contains(
                                          'Teacher Google Sheet me nahi mila',
                                        ) ==
                                    true) {
                              result =
                                  await _callTeacherApi({
                                'action':
                                    'add_teacher',
                                'name': name,
                                'designation':
                                    designationCtrl
                                        .text
                                        .trim(),
                                'subject':
                                    subject,
                                'qualification':
                                    qualificationCtrl
                                        .text
                                        .trim(),
                                'phone': phone,
                                'email':
                                    emailCtrl.text
                                        .trim(),
                                'dateOfBirth':
                                    dobCtrl.text
                                        .trim(),
                                'joiningDate':
                                    joiningCtrl.text
                                        .trim(),
                                'address':
                                    addressCtrl.text
                                        .trim(),
                                'assignedClasses':
                                    classesCtrl.text
                                        .trim(),
                                'employmentType':
                                    employmentType,
                                'status': status,
                                'photoBase64': selectedPhotoBytes == null
                                    ? (data['photoBase64']?.toString() ?? '')
                                    : base64Encode(selectedPhotoBytes!),
                                'photoMimeType': selectedPhotoBytes == null
                                    ? (data['photoMimeType']?.toString() ?? 'image/jpeg')
                                    : selectedPhotoMimeType,
                                'photoUrl': selectedPhotoBytes == null
                                    ? (data['photoUrl']?.toString() ?? '')
                                    : '',
                                'schedule':
                                    data['schedule'] ??
                                        {},
                              });
                            }

                            if (result['success'] !=
                                true) {
                              throw Exception(
                                result['message'] ??
                                    'Teacher update failed',
                              );
                            }

                            final updateData =
                                <String, dynamic>{
                              'name': name,
                              'designation':
                                  designationCtrl
                                      .text
                                      .trim(),
                              'subject':
                                  subject,
                              'qualification':
                                  qualificationCtrl
                                      .text
                                      .trim(),
                              'phone': phone,
                              'email':
                                  emailCtrl.text
                                      .trim(),
                              'dateOfBirth':
                                  dobCtrl.text
                                      .trim(),
                              'joiningDate':
                                  joiningCtrl.text
                                      .trim(),
                              'address':
                                  addressCtrl.text
                                      .trim(),
                              'assignedClasses':
                                  classesCtrl.text
                                      .trim(),
                              'employmentType':
                                  employmentType,
                              'status': status,
                              'updatedAt':
                                  FieldValue
                                      .serverTimestamp(),

                              // Old Employee ID hata dega
                              'employeeId':
                                  FieldValue.delete(),
                            };

                            final teacherId =
                                result['teacherId']
                                    ?.toString()
                                    .trim();

                            final photoUrl =
                                result['photoUrl']
                                    ?.toString()
                                    .trim();

                            if (teacherId != null &&
                                teacherId
                                    .isNotEmpty) {
                              updateData['teacherId'] =
                                  teacherId;
                            }

                            if (photoUrl != null &&
                                photoUrl.isNotEmpty) {
                              updateData['photoUrl'] =
                                  photoUrl;
                              updateData[
                                      'photoBase64'] =
                                  FieldValue.delete();
                            }

                            await FirebaseFirestore
                                .instance
                                .collection(
                                  'teachers_directory',
                                )
                                .doc(docId)
                                .update(updateData);

                            if (!mounted) return;

                            Navigator.pop(ctx);

                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(
                              const SnackBar(
                                backgroundColor:
                                    Color(0xFF00A884),
                                content: Text(
                                  'Teacher Google Sheet aur Firestore dono me update ho gaya!',
                                ),
                              ),
                            );
                          } catch (e) {
                            setDialogState(
                              () => saving = false,
                            );

                            if (!mounted) return;

                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(
                              SnackBar(
                                backgroundColor:
                                    Colors.redAccent,
                                content: Text(
                                  'Teacher update error: $e',
                                ),
                              ),
                            );
                          }
                        },
                  icon: saving
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child:
                              CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(
                          Icons.save_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                  label: Text(
                    saving
                        ? 'Saving...'
                        : 'Save Changes',
                    style: const TextStyle(
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    nameCtrl.dispose();
    designationCtrl.dispose();
    subjectCtrl.dispose();
    qualificationCtrl.dispose();
    phoneCtrl.dispose();
    emailCtrl.dispose();
    dobCtrl.dispose();
    joiningCtrl.dispose();
    classesCtrl.dispose();
    addressCtrl.dispose();
  }

  // ============================================================
  // DELETE TEACHER
  // ============================================================

  Future<void> _deleteTeacher(
    String docId,
    Map<String, dynamic> data,
  ) async {
    final passwordController =
        TextEditingController();

    bool obscureText = true;
    bool deleting = false;
    String? errorText;

    final confirmed =
        await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            return AlertDialog(
              backgroundColor:
                  const Color(0xFF172229),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(18),
              ),
              title: const Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.redAccent,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Delete Teacher?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight:
                          FontWeight.w800,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize:
                    MainAxisSize.min,
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    '${data['name'] ?? 'Teacher'} ka Sheet, Drive photo aur Firestore record delete hoga.',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Admin Password daalein:',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller:
                        passwordController,
                    obscureText:
                        obscureText,
                    style: const TextStyle(
                      color: Colors.white,
                    ),
                    decoration:
                        InputDecoration(
                      hintText:
                          'Admin Password',
                      hintStyle:
                          const TextStyle(
                        color:
                            Colors.white30,
                      ),
                      filled: true,
                      fillColor:
                          const Color(
                        0xFF10191F,
                      ),
                      prefixIcon:
                          const Icon(
                        Icons
                            .lock_outline_rounded,
                        color:
                            Colors.redAccent,
                      ),
                      suffixIcon:
                          IconButton(
                        icon: Icon(
                          obscureText
                              ? Icons
                                  .visibility_off
                              : Icons
                                  .visibility,
                          color:
                              Colors.white38,
                        ),
                        onPressed: () {
                          setDialogState(
                            () {
                              obscureText =
                                  !obscureText;
                            },
                          );
                        },
                      ),
                      border:
                          OutlineInputBorder(
                        borderRadius:
                            BorderRadius
                                .circular(12),
                        borderSide:
                            BorderSide.none,
                      ),
                    ),
                  ),
                  if (errorText !=
                      null) ...[
                    const SizedBox(
                      height: 8,
                    ),
                    Text(
                      errorText!,
                      style:
                          const TextStyle(
                        color:
                            Colors.redAccent,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: deleting
                      ? null
                      : () =>
                          Navigator.pop(
                            ctx,
                            false,
                          ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      color: Colors.grey,
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  style:
                      ElevatedButton
                          .styleFrom(
                    backgroundColor:
                        Colors.redAccent,
                  ),
                  onPressed: deleting
                      ? null
                      : () async {
                          final password =
                              passwordController
                                  .text
                                  .trim();

                          if (password
                              .isEmpty) {
                            setDialogState(
                              () {
                                errorText =
                                    'Admin Password daalein.';
                              },
                            );
                            return;
                          }

                          setDialogState(
                            () {
                              deleting =
                                  true;
                              errorText =
                                  null;
                            },
                          );

                          try {
                            final user =
                                FirebaseAuth
                                    .instance
                                    .currentUser;

                            if (user ==
                                    null ||
                                user.email ==
                                    null) {
                              throw Exception();
                            }

                            final credential =
                                EmailAuthProvider
                                    .credential(
                              email:
                                  user.email!,
                              password:
                                  password,
                            );

                            await user
                                .reauthenticateWithCredential(
                              credential,
                            );

                            if (!mounted) {
                              return;
                            }

                            Navigator.pop(
                              ctx,
                              true,
                            );
                          } catch (_) {
                            setDialogState(
                              () {
                                deleting =
                                    false;
                                errorText =
                                    'Galat Admin Password!';
                              },
                            );
                          }
                        },
                  icon: deleting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(
                            color:
                                Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(
                          Icons
                              .delete_forever_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                  label: const Text(
                    'Delete Teacher',
                    style: TextStyle(
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    passwordController.dispose();

    if (confirmed != true) return;

    try {
      final result =
          await _callTeacherApi({
        'action': 'delete_teacher',
        'teacherId':
            data['teacherId']
                    ?.toString()
                    .trim() ??
                '',
        'phone':
            data['phone']
                    ?.toString()
                    .trim() ??
                '',
      });

      if (result['success'] != true) {
        throw Exception(
          result['message'] ??
              'Teacher Google delete failed',
        );
      }

      await FirebaseFirestore.instance
          .collection('teachers_directory')
          .doc(docId)
          .delete();

      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          backgroundColor:
              Colors.redAccent,
          content: Text(
            'Teacher Google Sheet, Drive aur Firestore se delete ho gaya!',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          backgroundColor:
              Colors.redAccent,
          content: Text(
            'Teacher delete error: $e',
          ),
        ),
      );
    }
  }

  // ============================================================
  // BUILD DIRECTORY
  // ============================================================


  Future<void> _showTeacherWindowsIdCard(
    String docId,
    Map<String, dynamic> data,
  ) async {
    final qrData = await _windowsBuildPersonQrPayload(
      type: 'teacher',
      collection: 'teachers_directory',
      documentId: docId,
      person: data,
    );
    final custom=await WindowsDocumentTemplates.selected('teacherId',{...data,'teacherId':data['teacherId'] ?? docId},qr:qrData);
    if(custom!=null){if(mounted)await WindowsDocumentTemplates.preview(context,custom,title:'Teacher ID card');return;}
    if (!mounted) return;
    final name = data['name']?.toString().trim() ?? 'Teacher';
    final teacherId = data['teacherId']?.toString().trim().isNotEmpty == true
        ? data['teacherId'].toString().trim()
        : docId;
    final designation = data['designation']?.toString().trim() ?? 'Teacher';
    final subject = data['subject']?.toString().trim() ?? '';

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFFF4F7FA),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4A148C), Color(0xFF7B1FA2)],
                  ),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.school_rounded, color: Colors.white),
                    SizedBox(width: 10),
                    Text('VIDYA SAARTHI • TEACHER ID',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 120,
                    height: 145,
                    decoration: BoxDecoration(
                      color: const Color(0xFFECEFF1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: _teacherPhoto(data, name),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: const TextStyle(color: Color(0xFF4A148C), fontSize: 22, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 8),
                        Text('$designation${subject.isEmpty ? '' : ' • $subject'}', style: const TextStyle(color: Colors.black87)),
                        const SizedBox(height: 6),
                        Text('Teacher ID: $teacherId', style: const TextStyle(color: Colors.black54, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        const Text('QR: Attendance + School Mobile Linking', style: TextStyle(color: Colors.black45, fontSize: 11)),
                      ],
                    ),
                  ),
                  QrImageView(data: qrData, size: 135),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'This QR is school-isolated and contains the active school connection identity + attendance geofence metadata.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black45, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor:
            const Color(0xFF111B21),
        elevation: 0,
        title: const Row(
          children: [
            Icon(
              Icons.groups_2_rounded,
              color:
                  Colors.purpleAccent,
            ),
            SizedBox(width: 10),
            Text(
              'Teachers Directory',
              style: TextStyle(
                color: Colors.white,
                fontWeight:
                    FontWeight.w800,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding:
                const EdgeInsets.symmetric(
              vertical: 9,
              horizontal: 12,
            ),
            child: ElevatedButton.icon(
              style:
                  ElevatedButton.styleFrom(
                backgroundColor:
                    Colors.purpleAccent,
                foregroundColor:
                    Colors.white,
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(
                    11,
                  ),
                ),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const AddTeacherScreen(),
                  ),
                );
              },
              icon: const Icon(
                Icons
                    .person_add_alt_1_rounded,
                size: 18,
              ),
              label: const Text(
                'Add Teacher',
                style: TextStyle(
                  fontWeight:
                      FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding:
                const EdgeInsets.all(14),
            color:
                const Color(0xFF111B21),
            child: Column(
              children: [
                TextField(
                  controller:
                      _searchController,
                  onChanged: (_) =>
                      setState(() {}),
                  style: const TextStyle(
                    color: Colors.white,
                  ),
                  decoration:
                      InputDecoration(
                    hintText:
                        'Search teacher, subject, mobile...',
                    hintStyle:
                        const TextStyle(
                      color:
                          Colors.white30,
                    ),
                    prefixIcon:
                        const Icon(
                      Icons.search_rounded,
                      color: Colors
                          .purpleAccent,
                    ),
                    filled: true,
                    fillColor:
                        const Color(
                      0xFF0B141A,
                    ),
                    border:
                        OutlineInputBorder(
                      borderRadius:
                          BorderRadius
                              .circular(13),
                      borderSide:
                          BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final filter in [
                      'All',
                      'Active',
                      'On Leave',
                      'Inactive',
                    ])
                      ChoiceChip(
                        label:
                            Text(filter),
                        selected:
                            _statusFilter ==
                                filter,
                        selectedColor:
                            Colors
                                .purpleAccent,
                        backgroundColor:
                            const Color(
                          0xFF172229,
                        ),
                        labelStyle:
                            TextStyle(
                          color:
                              _statusFilter ==
                                      filter
                                  ? Colors
                                      .white
                                  : Colors
                                      .white54,
                          fontSize: 11,
                          fontWeight:
                              FontWeight
                                  .w700,
                        ),
                        onSelected: (_) {
                          setState(() {
                            _statusFilter =
                                filter;
                          });
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child:
                StreamBuilder<QuerySnapshot>(
              stream:
                  FirebaseFirestore.instance
                      .collection(
                        'teachers_directory',
                      )
                      .snapshots(),
              builder:
                  (context, snapshot) {
                if (snapshot
                        .connectionState ==
                    ConnectionState
                        .waiting) {
                  return const Center(
                    child:
                        CircularProgressIndicator(
                      color: Colors
                          .purpleAccent,
                    ),
                  );
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'Teacher data load error: ${snapshot.error}',
                      style:
                          const TextStyle(
                        color:
                            Colors.redAccent,
                      ),
                    ),
                  );
                }

                if (!snapshot.hasData ||
                    snapshot
                        .data!.docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'Abhi koi teacher registered nahi hai.',
                      style: TextStyle(
                        color:
                            Colors.white38,
                      ),
                    ),
                  );
                }

                final query =
                    _searchController.text
                        .trim()
                        .toLowerCase();

                final filteredDocs =
                    snapshot.data!.docs
                        .where((doc) {
                  final data =
                      doc.data()
                          as Map<String,
                              dynamic>;

                  final name =
                      data['name']
                              ?.toString()
                              .toLowerCase() ??
                          '';

                  final subject =
                      data['subject']
                              ?.toString()
                              .toLowerCase() ??
                          '';

                  final phone =
                      data['phone']
                              ?.toString()
                              .toLowerCase() ??
                          '';

                  final qualification =
                      data['qualification']
                              ?.toString()
                              .toLowerCase() ??
                          '';

                  final status =
                      data['status']
                              ?.toString() ??
                          'Active';

                  final searchMatch =
                      query.isEmpty ||
                          name.contains(
                            query,
                          ) ||
                          subject.contains(
                            query,
                          ) ||
                          phone.contains(
                            query,
                          ) ||
                          qualification
                              .contains(
                            query,
                          );

                  final statusMatch =
                      _statusFilter ==
                              'All' ||
                          status ==
                              _statusFilter;

                  return searchMatch &&
                      statusMatch;
                }).toList();

                final uniqueTeacherDocs = <String, dynamic>{};
                for (final doc in filteredDocs) {
                  final data = doc.data() as Map<String, dynamic>;
                  final teacherId = data['teacherId']?.toString().trim() ?? '';
                  final digits = (data['phone'] ?? '')
                      .toString()
                      .replaceAll(RegExp(r'\D'), '');
                  final phone = digits.length == 12 && digits.startsWith('91')
                      ? digits.substring(2)
                      : digits;
                  final key = teacherId.isNotEmpty
                      ? 'ID:${teacherId.toLowerCase()}'
                      : 'PHONE:$phone';
                  if (key == 'PHONE:' || !uniqueTeacherDocs.containsKey(key)) {
                    uniqueTeacherDocs[key.isEmpty ? doc.id : key] = doc;
                  }
                }
                final docs = uniqueTeacherDocs.values.toList();

                docs.sort(
                  (a, b) {
                    final aData =
                        a.data()
                            as Map<String,
                                dynamic>;

                    final bData =
                        b.data()
                            as Map<String,
                                dynamic>;

                    return (aData['name']
                                ?.toString()
                                .toLowerCase() ??
                            '')
                        .compareTo(
                      bData['name']
                              ?.toString()
                              .toLowerCase() ??
                          '',
                    );
                  },
                );

                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'Search/filter me koi teacher nahi mila.',
                      style: TextStyle(
                        color:
                            Colors.white38,
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  padding:
                      const EdgeInsets.all(
                    14,
                  ),
                  itemCount:
                      docs.length,
                  itemBuilder:
                      (context, index) {
                    final doc =
                        docs[index];

                    final data =
                        doc.data()
                            as Map<String,
                                dynamic>;

                    final name =
                        data['name']
                                ?.toString() ??
                            'Teacher';

                    final status =
                        data['status']
                                ?.toString() ??
                            'Active';

                    return Container(
                      margin:
                          const EdgeInsets
                              .only(
                        bottom: 12,
                      ),
                      padding:
                          const EdgeInsets
                              .all(14),
                      decoration:
                          BoxDecoration(
                        color:
                            const Color(
                          0xFF111B21,
                        ),
                        borderRadius:
                            BorderRadius
                                .circular(
                          17,
                        ),
                        border:
                            Border.all(
                          color: Colors
                              .white
                              .withOpacity(
                            0.055,
                          ),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            padding:
                                const EdgeInsets
                                    .all(3),
                            decoration:
                                BoxDecoration(
                              shape:
                                  BoxShape.circle,
                              border:
                                  Border.all(
                                color: Colors
                                    .purpleAccent,
                                width: 2,
                              ),
                            ),
                            child: ClipOval(
                              child:
                                  _teacherPhoto(
                                data,
                                name,
                              ),
                            ),
                          ),
                          const SizedBox(
                            width: 14,
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  runSpacing:
                                      6,
                                  crossAxisAlignment:
                                      WrapCrossAlignment
                                          .center,
                                  children: [
                                    Text(
                                      name,
                                      style:
                                          const TextStyle(
                                        color:
                                            Colors.white,
                                        fontSize:
                                            16,
                                        fontWeight:
                                            FontWeight
                                                .w800,
                                      ),
                                    ),
                                    Container(
                                      padding:
                                          const EdgeInsets
                                              .symmetric(
                                        horizontal:
                                            8,
                                        vertical:
                                            4,
                                      ),
                                      decoration:
                                          BoxDecoration(
                                        color: status ==
                                                'Active'
                                            ? const Color(
                                                0xFF00A884,
                                              ).withOpacity(
                                                0.12,
                                              )
                                            : Colors
                                                .orangeAccent
                                                .withOpacity(
                                                0.12,
                                              ),
                                        borderRadius:
                                            BorderRadius
                                                .circular(
                                          20,
                                        ),
                                      ),
                                      child: Text(
                                        status,
                                        style:
                                            TextStyle(
                                          color: status ==
                                                  'Active'
                                              ? const Color(
                                                  0xFF00D9A5,
                                                )
                                              : Colors
                                                  .orangeAccent,
                                          fontSize:
                                              9,
                                          fontWeight:
                                              FontWeight
                                                  .w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(
                                  height: 7,
                                ),
                                Text(
                                  '${data['designation'] ?? 'Teacher'} • ${data['subject'] ?? 'Subject not assigned'}',
                                  style:
                                      const TextStyle(
                                    color:
                                        Colors.white70,
                                    fontSize:
                                        11.5,
                                    fontWeight:
                                        FontWeight
                                            .w600,
                                  ),
                                ),
                                const SizedBox(
                                  height: 5,
                                ),
                                Text(
                                  'Qualification: ${data['qualification'] ?? 'N/A'}',
                                  style:
                                      const TextStyle(
                                    color:
                                        Colors.white38,
                                    fontSize:
                                        10.5,
                                  ),
                                ),
                                const SizedBox(
                                  height: 5,
                                ),
                                Text(
                                  'Classes: ${data['assignedClasses'] ?? 'Not Assigned'}',
                                  style:
                                      const TextStyle(
                                    color:
                                        Colors.white38,
                                    fontSize:
                                        10.5,
                                  ),
                                ),
                                const SizedBox(
                                  height: 5,
                                ),
                                Text(
                                  '${data['phone'] ?? ''}${(data['email']?.toString().isNotEmpty ?? false) ? ' • ${data['email']}' : ''}',
                                  style:
                                      const TextStyle(
                                    color:
                                        Colors.white38,
                                    fontSize:
                                        10.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(
                            width: 12,
                          ),

                          // ==================================================
                          // SCHEDULE / EDIT / DELETE
                          // ==================================================
                          Column(
                            mainAxisSize:
                                MainAxisSize.min,
                            children: [
                              OutlinedButton.icon(
                                style:
                                    OutlinedButton
                                        .styleFrom(
                                  foregroundColor:
                                      Colors
                                          .purpleAccent,
                                  side:
                                      BorderSide(
                                    color: Colors
                                        .purpleAccent
                                        .withOpacity(
                                      0.45,
                                    ),
                                  ),
                                  shape:
                                      RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius
                                            .circular(
                                      10,
                                    ),
                                  ),
                                ),
                                onPressed: () =>
                                    _openSchedule(
                                  doc.id,
                                  data,
                                ),
                                icon: const Icon(
                                  Icons
                                      .calendar_month_rounded,
                                  size: 16,
                                ),
                                label:
                                    const Text(
                                  'Schedule',
                                  style:
                                      TextStyle(
                                    fontSize:
                                        10.5,
                                    fontWeight:
                                        FontWeight
                                            .w700,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 7),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF69C2FF),
                                  side: BorderSide(color: const Color(0xFF69C2FF).withOpacity(.45)),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                onPressed: () => _showTeacherWindowsIdCard(doc.id, data),
                                icon: const Icon(Icons.badge_rounded, size: 16),
                                label: const Text('ID Card', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700)),
                              ),
                              const SizedBox(height: 7),
                              Row(
                                mainAxisSize:
                                    MainAxisSize
                                        .min,
                                children: [
                                  Tooltip(
                                    message:
                                        'Edit Teacher',
                                    child:
                                        IconButton(
                                      style:
                                          IconButton
                                              .styleFrom(
                                        backgroundColor:
                                            Colors
                                                .blueAccent
                                                .withOpacity(
                                          0.12,
                                        ),
                                        foregroundColor:
                                            Colors
                                                .blueAccent,
                                      ),
                                      onPressed: () =>
                                          _editTeacher(
                                        doc.id,
                                        data,
                                      ),
                                      icon:
                                          const Icon(
                                        Icons
                                            .edit_rounded,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(
                                    width: 6,
                                  ),
                                  Tooltip(
                                    message:
                                        'Delete Teacher',
                                    child:
                                        IconButton(
                                      style:
                                          IconButton
                                              .styleFrom(
                                        backgroundColor:
                                            Colors
                                                .redAccent
                                                .withOpacity(
                                          0.12,
                                        ),
                                        foregroundColor:
                                            Colors
                                                .redAccent,
                                      ),
                                      onPressed: () =>
                                          _deleteTeacher(
                                        doc.id,
                                        data,
                                      ),
                                      icon:
                                          const Icon(
                                        Icons
                                            .delete_outline_rounded,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}


// ============================================================
// ADD TEACHER SCREEN
// ============================================================
class AddTeacherScreen extends StatefulWidget {
  const AddTeacherScreen({super.key});

  @override
  State<AddTeacherScreen> createState() =>
      _AddTeacherScreenState();
}

class _AddTeacherScreenState
    extends State<AddTeacherScreen> {
  final _nameCtrl =
      TextEditingController();

  final _designationCtrl =
      TextEditingController(
    text: 'Teacher',
  );

  final _subjectCtrl =
      TextEditingController();

  final _qualificationCtrl =
      TextEditingController();

  final _phoneCtrl =
      TextEditingController();

  final _emailCtrl =
      TextEditingController();

  final _dobCtrl =
      TextEditingController();

  final _joiningCtrl =
      TextEditingController();

  final _addressCtrl =
      TextEditingController();

  final _classesCtrl =
      TextEditingController();

  String _employmentType =
      'Permanent';

  String _status = 'Active';

  List<int>? _photoBytes;
  String _photoMimeType =
      'image/jpeg';

  bool _saving = false;

  @override
  void initState() {
    super.initState();

    final now = DateTime.now();

    _joiningCtrl.text =
        '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')}/'
        '${now.year}';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _designationCtrl.dispose();
    _subjectCtrl.dispose();
    _qualificationCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _dobCtrl.dispose();
    _joiningCtrl.dispose();
    _addressCtrl.dispose();
    _classesCtrl.dispose();
    super.dispose();
  }

  InputDecoration _field(
    String label,
    IconData icon,
  ) {
    return InputDecoration(
      labelText: label,
      labelStyle:
          const TextStyle(
        color: Colors.white54,
      ),
      prefixIcon: Icon(
        icon,
        color:
            Colors.purpleAccent,
        size: 19,
      ),
      filled: true,
      fillColor:
          const Color(0xFF10191F),
      border: OutlineInputBorder(
        borderRadius:
            BorderRadius.circular(12),
        borderSide:
            BorderSide.none,
      ),
    );
  }

  Future<String> _getTeacherScriptUrl() async {
    return _windowsGoogleScriptUrl();
  }

  Future<Map<String, dynamic>>
      _callTeacherApi(
    Map<String, dynamic> body,
  ) async {
    final scriptUrl =
        await _getTeacherScriptUrl();

    final response = await WindowsBackendBridge.post(
          Uri.parse(scriptUrl),
          headers: {
            'Content-Type':
                'text/plain;charset=utf-8',
          },
          body: jsonEncode(body),
        )
        .timeout(
          const Duration(seconds: 30),
        );

    if (response.statusCode !=
        200) {
      throw Exception(
        'Google API error: ${response.statusCode}',
      );
    }

    final decoded =
        jsonDecode(response.body);

    if (decoded is! Map) {
      throw Exception(
        'Google API se invalid response mila.',
      );
    }

    return Map<String, dynamic>.from(
      decoded,
    );
  }

  // ============================================================
  // PICK PHOTO
  // ============================================================

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();

    final image =
        await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 700,
      imageQuality: 65,
    );

    if (image == null) return;

    final bytes =
        await image.readAsBytes();

    if (bytes.length > 700000) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          backgroundColor:
              Colors.redAccent,
          content: Text(
            'Photo size zyada hai. Chhota photo select karein.',
          ),
        ),
      );

      return;
    }

    setState(() {
      _photoBytes = bytes;

      final name =
          image.name.toLowerCase();

      if (name.endsWith('.png')) {
        _photoMimeType =
            'image/png';
      } else if (
          name.endsWith('.webp')) {
        _photoMimeType =
            'image/webp';
      } else {
        _photoMimeType =
            'image/jpeg';
      }
    });
  }

  // ============================================================
  // SAVE TEACHER
  // ============================================================

  Future<void> _saveTeacher() async {
    final name =
        _nameCtrl.text.trim();

    final subject =
        _subjectCtrl.text.trim();

    final phone =
        _phoneCtrl.text.trim();

    if (name.isEmpty ||
        subject.isEmpty ||
        phone.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          backgroundColor:
              Colors.redAccent,
          content: Text(
            'Name, Subject aur Mobile required hain.',
          ),
        ),
      );
      return;
    }

    if (!RegExp(
      r'^[0-9]{10}$',
    ).hasMatch(phone)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          backgroundColor:
              Colors.redAccent,
          content: Text(
            'Valid 10 digit Mobile Number daalein.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _saving = true;
    });

    String createdTeacherId = '';

    try {
      // Firestore duplicate check.
      // Purane data me +91 / spaces ho tab bhi same mobile duplicate maana jayega.
      String normalizeTeacherPhone(dynamic value) {
        String digits = (value ?? '')
            .toString()
            .replaceAll(RegExp(r'\D'), '');

        if (digits.length == 12 && digits.startsWith('91')) {
          digits = digits.substring(2);
        }

        return digits;
      }

      final normalizedPhone = normalizeTeacherPhone(phone);

      final existingTeachers =
          await FirebaseFirestore.instance
              .collection('teachers_directory')
              .get();

      final alreadyExists = existingTeachers.docs.any((doc) {
        final data = doc.data();

        return normalizeTeacherPhone(data['phone']) ==
            normalizedPhone;
      });

      if (alreadyExists) {
        throw Exception(
          'Is Mobile Number se teacher already registered hai.',
        );
      }

      final schedule =
          <String, String>{
        'Monday': '',
        'Tuesday': '',
        'Wednesday': '',
        'Thursday': '',
        'Friday': '',
        'Saturday': '',
      };

      // FIRST:
      // Google Sheet + Drive
      final result =
          await _callTeacherApi({
        'action': 'add_teacher',
        'name': name,
        'designation':
            _designationCtrl
                .text
                .trim(),
        'subject': subject,
        'qualification':
            _qualificationCtrl
                .text
                .trim(),
        'phone': phone,
        'email':
            _emailCtrl.text.trim(),
        'dateOfBirth':
            _dobCtrl.text.trim(),
        'joiningDate':
            _joiningCtrl
                .text
                .trim(),
        'address':
            _addressCtrl
                .text
                .trim(),
        'assignedClasses':
            _classesCtrl
                .text
                .trim(),
        'employmentType':
            _employmentType,
        'status': _status,
        'photoBase64':
            _photoBytes == null
                ? ''
                : base64Encode(
                    _photoBytes!,
                  ),
        'photoMimeType':
            _photoMimeType,
        'schedule': schedule,
      });

      if (result['success'] != true) {
        throw Exception(
          result['message'] ??
              'Teacher Google Sheet save failed',
        );
      }

      createdTeacherId =
          result['teacherId']
                  ?.toString()
                  .trim() ??
              '';

      final photoUrl =
          result['photoUrl']
                  ?.toString()
                  .trim() ??
              '';

      if (createdTeacherId.isEmpty) {
        throw Exception(
          'Teacher ID backend se nahi mila.',
        );
      }

      // SECOND:
      // Firestore
      final ref =
          FirebaseFirestore.instance
              .collection(
                'teachers_directory',
              )
              .doc();

      await ref.set({
        'teacherId':
            createdTeacherId,
        'name': name,
        'designation':
            _designationCtrl
                .text
                .trim(),
        'subject': subject,
        'qualification':
            _qualificationCtrl
                .text
                .trim(),
        'phone': phone,
        'email':
            _emailCtrl.text.trim(),
        'dateOfBirth':
            _dobCtrl.text.trim(),
        'joiningDate':
            _joiningCtrl
                .text
                .trim(),
        'address':
            _addressCtrl
                .text
                .trim(),
        'assignedClasses':
            _classesCtrl
                .text
                .trim(),
        'employmentType':
            _employmentType,
        'status': _status,

        // Base64 Firestore me save nahi hoga.
        // Sirf Google Drive URL.
        'photoUrl': photoUrl,

        'schedule': schedule,

        'createdAt':
            FieldValue
                .serverTimestamp(),

        'updatedAt':
            FieldValue
                .serverTimestamp(),
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          backgroundColor:
              Color(0xFF00A884),
          content: Text(
            'Teacher Google Sheet, Drive aur Firestore me save ho gaya!',
          ),
        ),
      );

      Navigator.pop(context);
    } catch (e) {
      // Google me save ho gaya,
      // lekin Firestore fail hua:
      // Google record/photo rollback.
      if (createdTeacherId.isNotEmpty) {
        try {
          await _callTeacherApi({
            'action':
                'delete_teacher',
            'teacherId':
                createdTeacherId,
            'phone': phone,
          });
        } catch (_) {}
      }

      if (!mounted) return;

      setState(() {
        _saving = false;
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          backgroundColor:
              Colors.redAccent,
          content: Text(
            'Teacher save error: $e',
          ),
        ),
      );
    }
  }

  // ============================================================
  // ADD TEACHER UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor:
            const Color(0xFF111B21),
        title: const Text(
          'Add New Teacher',
          style: TextStyle(
            color: Colors.white,
            fontWeight:
                FontWeight.w800,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding:
            const EdgeInsets.all(18),
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(
              maxWidth: 850,
            ),
            child: Container(
              padding:
                  const EdgeInsets.all(
                22,
              ),
              decoration:
                  BoxDecoration(
                color:
                    const Color(
                  0xFF172229,
                ),
                borderRadius:
                    BorderRadius
                        .circular(
                  20,
                ),
                border: Border.all(
                  color: Colors.white
                      .withOpacity(
                    0.06,
                  ),
                ),
              ),
              child: Column(
                children: [
                  GestureDetector(
                    onTap: _saving
                        ? null
                        : _pickPhoto,
                    child: Container(
                      width: 115,
                      height: 115,
                      padding:
                          const EdgeInsets
                              .all(4),
                      decoration:
                          BoxDecoration(
                        shape:
                            BoxShape.circle,
                        border:
                            Border.all(
                          color: Colors
                              .purpleAccent,
                          width: 2,
                        ),
                      ),
                      child: ClipOval(
                        child:
                            _photoBytes !=
                                    null
                                ? Image
                                    .memory(
                                    base64Decode(
                                      base64Encode(
                                        _photoBytes!,
                                      ),
                                    ),
                                    fit: BoxFit
                                        .cover,
                                  )
                                : Container(
                                    color:
                                        const Color(
                                      0xFF10191F,
                                    ),
                                    child:
                                        const Icon(
                                      Icons
                                          .add_a_photo_rounded,
                                      color: Colors
                                          .purpleAccent,
                                      size:
                                          35,
                                    ),
                                  ),
                      ),
                    ),
                  ),

                  const SizedBox(
                    height: 8,
                  ),

                  const Text(
                    'Upload Teacher Photo',
                    style: TextStyle(
                      color:
                          Colors.white54,
                      fontSize: 11,
                    ),
                  ),

                  const SizedBox(
                    height: 22,
                  ),

                  TextField(
                    controller:
                        _nameCtrl,
                    style:
                        const TextStyle(
                      color:
                          Colors.white,
                    ),
                    decoration:
                        _field(
                      'Teacher Full Name *',
                      Icons
                          .person_outline_rounded,
                    ),
                  ),

                  const SizedBox(
                    height: 11,
                  ),

                  // EMPLOYEE ID REMOVED
                  TextField(
                    controller:
                        _designationCtrl,
                    style:
                        const TextStyle(
                      color:
                          Colors.white,
                    ),
                    decoration:
                        _field(
                      'Designation',
                      Icons
                          .work_outline_rounded,
                    ),
                  ),

                  const SizedBox(
                    height: 11,
                  ),

                  Row(
                    children: [
                      Expanded(
                        child:
                            TextField(
                          controller:
                              _subjectCtrl,
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                          ),
                          decoration:
                              _field(
                            'Subject / Department *',
                            Icons
                                .menu_book_rounded,
                          ),
                        ),
                      ),
                      const SizedBox(
                        width: 11,
                      ),
                      Expanded(
                        child:
                            TextField(
                          controller:
                              _qualificationCtrl,
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                          ),
                          decoration:
                              _field(
                            'Qualification',
                            Icons
                                .school_outlined,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(
                    height: 11,
                  ),

                  Row(
                    children: [
                      Expanded(
                        child:
                            TextField(
                          controller:
                              _phoneCtrl,
                          keyboardType:
                              TextInputType
                                  .phone,
                          maxLength: 10,
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                          ),
                          decoration:
                              _field(
                            'Mobile Number *',
                            Icons
                                .phone_outlined,
                          ).copyWith(
                            counterText: '',
                          ),
                        ),
                      ),
                      const SizedBox(
                        width: 11,
                      ),
                      Expanded(
                        child:
                            TextField(
                          controller:
                              _emailCtrl,
                          keyboardType:
                              TextInputType
                                  .emailAddress,
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                          ),
                          decoration:
                              _field(
                            'Email Address',
                            Icons
                                .email_outlined,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(
                    height: 11,
                  ),

                  Row(
                    children: [
                      Expanded(
                        child:
                            TextField(
                          controller:
                              _dobCtrl,
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                          ),
                          decoration:
                              _field(
                            'Date of Birth',
                            Icons
                                .cake_outlined,
                          ),
                        ),
                      ),
                      const SizedBox(
                        width: 11,
                      ),
                      Expanded(
                        child:
                            TextField(
                          controller:
                              _joiningCtrl,
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                          ),
                          decoration:
                              _field(
                            'Joining Date',
                            Icons
                                .calendar_today_outlined,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(
                    height: 11,
                  ),

                  TextField(
                    controller:
                        _classesCtrl,
                    style:
                        const TextStyle(
                      color:
                          Colors.white,
                    ),
                    decoration:
                        _field(
                      'Assigned Classes (Example: Class 5, Class 6)',
                      Icons
                          .class_outlined,
                    ),
                  ),

                  const SizedBox(
                    height: 11,
                  ),

                  TextField(
                    controller:
                        _addressCtrl,
                    minLines: 2,
                    maxLines: 3,
                    style:
                        const TextStyle(
                      color:
                          Colors.white,
                    ),
                    decoration:
                        _field(
                      'Address',
                      Icons
                          .location_on_outlined,
                    ),
                  ),

                  const SizedBox(
                    height: 11,
                  ),

                  Row(
                    children: [
                      Expanded(
                        child:
                            DropdownButtonFormField<
                                String>(
                          value:
                              _employmentType,
                          dropdownColor:
                              const Color(
                            0xFF172229,
                          ),
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                          ),
                          decoration:
                              _field(
                            'Employment Type',
                            Icons
                                .business_center_outlined,
                          ),
                          items:
                              const [
                            DropdownMenuItem(
                              value:
                                  'Permanent',
                              child: Text(
                                'Permanent',
                              ),
                            ),
                            DropdownMenuItem(
                              value:
                                  'Contract',
                              child: Text(
                                'Contract',
                              ),
                            ),
                            DropdownMenuItem(
                              value:
                                  'Guest',
                              child: Text(
                                'Guest',
                              ),
                            ),
                          ],
                          onChanged:
                              (value) {
                            if (value !=
                                null) {
                              setState(
                                () {
                                  _employmentType =
                                      value;
                                },
                              );
                            }
                          },
                        ),
                      ),
                      const SizedBox(
                        width: 11,
                      ),
                      Expanded(
                        child:
                            DropdownButtonFormField<
                                String>(
                          value:
                              _status,
                          dropdownColor:
                              const Color(
                            0xFF172229,
                          ),
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                          ),
                          decoration:
                              _field(
                            'Status',
                            Icons
                                .verified_user_outlined,
                          ),
                          items:
                              const [
                            DropdownMenuItem(
                              value:
                                  'Active',
                              child: Text(
                                'Active',
                              ),
                            ),
                            DropdownMenuItem(
                              value:
                                  'On Leave',
                              child: Text(
                                'On Leave',
                              ),
                            ),
                            DropdownMenuItem(
                              value:
                                  'Inactive',
                              child: Text(
                                'Inactive',
                              ),
                            ),
                          ],
                          onChanged:
                              (value) {
                            if (value !=
                                null) {
                              setState(
                                () {
                                  _status =
                                      value;
                                },
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(
                    height: 22,
                  ),

                  SizedBox(
                    width:
                        double.infinity,
                    height: 50,
                    child:
                        ElevatedButton.icon(
                      style:
                          ElevatedButton
                              .styleFrom(
                        backgroundColor:
                            Colors
                                .purpleAccent,
                        shape:
                            RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            13,
                          ),
                        ),
                      ),
                      onPressed:
                          _saving
                              ? null
                              : _saveTeacher,
                      icon: _saving
                          ? const SizedBox(
                              width: 19,
                              height: 19,
                              child:
                                  CircularProgressIndicator(
                                strokeWidth:
                                    2,
                                color: Colors
                                    .white,
                              ),
                            )
                          : const Icon(
                              Icons
                                  .save_rounded,
                              color:
                                  Colors.white,
                            ),
                      label: Text(
                        _saving
                            ? 'Saving Teacher...'
                            : 'SAVE TEACHER PROFILE',
                        style:
                            const TextStyle(
                          color:
                              Colors.white,
                          fontWeight:
                              FontWeight
                                  .w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
            
// ============================================================
// ALL STUDENTS LIST
// ============================================================
class AllStudentsListScreen extends StatefulWidget {
  const AllStudentsListScreen({super.key});

  @override
  State<AllStudentsListScreen> createState() => _AllStudentsListScreenState();
}

class _AllStudentsListScreenState extends State<AllStudentsListScreen> {
  String _selectedClassFilter = 'All Classes';

  final List<String> _classes = [
    'All Classes',
    ...List.generate(12, (index) => 'Class ${index + 1}'),
  ];


  List<Map<String, dynamic>> _studentExamResults = <Map<String, dynamic>>[];
  bool _studentExamResultsLoading = true;
  final Set<String> _movingStudentIds = <String>{};

  @override
  void initState() {
    super.initState();
    _warmStudentExamResults();
  }

  Future<void> _warmStudentExamResults() async {
    try {
      final cached = _ExamCenterDataCache.snapshot;
      final snapshot = cached ?? await _ExamCenterDataCache.refresh();
      if (!mounted) return;
      setState(() {
        _studentExamResults =
            List<Map<String, dynamic>>.from(snapshot.results);
        _studentExamResultsLoading = false;
      });
    } catch (e) {
      debugPrint('Student result preload warning: $e');
      if (!mounted) return;
      setState(() => _studentExamResultsLoading = false);
    }
  }

  String _normalizeStudentRoll(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    final number = int.tryParse(raw);
    return number?.toString() ?? raw.toLowerCase();
  }

  int _studentClassNumber(dynamic value) {
    final raw = value?.toString() ?? '';
    return int.tryParse(raw.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  String _studentDirectoryIdentity(Map<String, dynamic> student) {
    final classNumber = _studentClassNumber(student['class']);
    final roll = _normalizeStudentRoll(student['rollNo']);

    if (classNumber > 0 && roll.isNotEmpty) {
      return 'class:$classNumber|roll:$roll';
    }

    final name = student['name']?.toString().trim().toLowerCase() ?? '';
    final contact = (student['parentContact'] ?? '')
        .toString()
        .replaceAll(RegExp(r'\D'), '');
    return 'name:$name|contact:$contact';
  }

  String _studentDirectoryDate(dynamic value) {
    if (value == null) return 'N/A';

    DateTime? date;
    if (value is DateTime) {
      date = value;
    } else if (value is int) {
      date = DateTime.fromMillisecondsSinceEpoch(value);
    }

    final raw = value.toString().trim();
    if (raw.isEmpty) return 'N/A';

    date ??= DateTime.tryParse(raw);

    if (date == null) {
      final simple = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$')
          .firstMatch(raw);
      if (simple != null) {
        final day = int.tryParse(simple.group(1) ?? '');
        final month = int.tryParse(simple.group(2) ?? '');
        final year = int.tryParse(simple.group(3) ?? '');
        if (day != null && month != null && year != null) {
          date = DateTime(year, month, day);
        }
      }
    }

    if (date == null) {
      final verbose = RegExp(
        r'^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+'
        r'(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+'
        r'(\d{1,2})\s+(\d{4})',
        caseSensitive: false,
      ).firstMatch(raw);

      if (verbose != null) {
        const months = <String, int>{
          'jan': 1,
          'feb': 2,
          'mar': 3,
          'apr': 4,
          'may': 5,
          'jun': 6,
          'jul': 7,
          'aug': 8,
          'sep': 9,
          'oct': 10,
          'nov': 11,
          'dec': 12,
        };
        final month = months[(verbose.group(1) ?? '').toLowerCase()];
        final day = int.tryParse(verbose.group(2) ?? '');
        final year = int.tryParse(verbose.group(3) ?? '');
        if (month != null && day != null && year != null) {
          date = DateTime(year, month, day);
        }
      }
    }

    if (date == null) return raw;

    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year.toString().padLeft(4, '0')}';
  }

  Map<String, dynamic>? _latestExamResultForStudent(
    String docId,
    Map<String, dynamic> student,
  ) {
    final studentClass = student['class']?.toString().trim() ?? '';
    final roll = _normalizeStudentRoll(student['rollNo']);

    final matches = _studentExamResults.where((result) {
      final resultStudentId = result['studentId']?.toString().trim() ?? '';
      if (resultStudentId.isNotEmpty && resultStudentId == docId) {
        return true;
      }

      return (result['studentClass']?.toString().trim() ?? '') == studentClass &&
          _normalizeStudentRoll(result['rollNo']) == roll;
    }).map((e) => Map<String, dynamic>.from(e)).toList();

    matches.sort(
      (a, b) => (b['timestamp'] as num? ?? 0)
          .compareTo(a['timestamp'] as num? ?? 0),
    );

    if (matches.isNotEmpty) return matches.first;

    final storedResult = student['lastExamResult']?.toString().trim() ?? '';
    if (storedResult.isNotEmpty) {
      return <String, dynamic>{
        'result': storedResult,
        'examId': student['promotionExamId'] ?? '',
        'isFinal': student['promotionExamId'] != null,
        'examName': student['lastExamName']?.toString() ?? 'Previous Exam',
        'percentage': student['lastExamPercentage'] ?? 0,
        'timestamp': student['lastExamTimestamp'] ?? 0,
      };
    }

    return null;
  }

  Future<String> _studentBackendScriptUrl() async {
    return _windowsGoogleScriptUrl();
  }

  Future<Map<String, dynamic>> _postStudentClassChange({
    required String oldClass,
    required String newClass,
    required String rollNo,
    required String oldStudentId,
    required String newStudentId,
    required String movement,
    Map<String, dynamic>? latestResult,
  }) async {
    final response = await WindowsBackendBridge.post(
      Uri.parse(await _studentBackendScriptUrl()),
      headers: const {'Content-Type': 'text/plain;charset=utf-8'},
      body: jsonEncode({
        'action': 'change_student_class',
        'oldClass': oldClass,
        'newClass': newClass,
        'rollNo': rollNo,
        'oldStudentId': oldStudentId,
        'newStudentId': newStudentId,
        'movement': movement,
        'examName': latestResult?['examName']?.toString() ?? '',
        'result': latestResult?['result']?.toString() ?? '',
        'percentage': latestResult?['percentage'] ?? 0,
        'updatedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Google class update failed: ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw Exception('Google class update response invalid hai.');
    }

    final result = Map<String, dynamic>.from(decoded);
    if (result['success'] != true) {
      throw Exception(result['message'] ?? 'Google class update failed');
    }

    return result;
  }

  Future<void> _changeStudentClass(String docId, Map<String,dynamic> student, int direction) async {
    if (_movingStudentIds.contains(docId)) return;
    final result = _latestExamResultForStudent(docId, student);
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Enter the final exam result before promotion or retention.')));
      return;
    }
    final status = result['result']?.toString().toUpperCase() ?? '';
    final force = direction > 0 && status == 'FAIL';
    final decision = direction < 0 ? 'FAIL' : status;
    final yes = await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:Text(direction < 0 ? 'Retain in the same class?' : force ? 'Force promote this student?' : 'Apply final exam decision?'),
      content:Text('${student['name']} • ${student['class']}\nFinal result: $status'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Confirm'))]));
    if(yes!=true||!mounted)return;
    setState(()=>_movingStudentIds.add(docId));
    try {
      if(direction < 0 && status != 'FAIL')throw StateError('Retention is only for a final-exam FAIL result.');
      final message=await SchoolPromotionService.apply(studentId:docId,student:student,exam:result,result:decision,force:force);
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(message)));
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}
    finally{if(mounted)setState(()=>_movingStudentIds.remove(docId));}
  }

  Future<void> _deleteStudent(String docId) async {
    final passwordController = TextEditingController();
    bool obscureText = true;
    bool isLoading = false;
    String? errorMessage;

    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F2C34),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
                  SizedBox(width: 10),
                  Text('Delete Student?', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Kya aap sach mein is student ka record hamesha ke liye delete karna chahte hain? Yeh wapas nahi aayega.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 18),
                  const Text('Admin Password daalein:', style: TextStyle(color: Colors.white, fontSize: 12)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: passwordController,
                    obscureText: obscureText,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Enter Admin Password',
                      hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                      filled: true,
                      fillColor: const Color(0xFF121B22),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      suffixIcon: IconButton(
                        icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility, color: Colors.grey, size: 18),
                        onPressed: () => setDialogState(() => obscureText = !obscureText),
                      ),
                    ),
                  ),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(errorMessage!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ]
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isLoading ? null : () => Navigator.pop(ctx, false),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                  onPressed: isLoading
                      ? null
                      : () async {
                          final pass = passwordController.text.trim();
                          if (pass.isEmpty) {
                            setDialogState(() => errorMessage = 'Password daalna zaroori hai.');
                            return;
                          }
                          setDialogState(() {
                            isLoading = true;
                            errorMessage = null;
                          });

                          try {
                            final user = FirebaseAuth.instance.currentUser;
                            if (user != null && user.email != null) {
                              final credential = EmailAuthProvider.credential(email: user.email!, password: pass);
                              await user.reauthenticateWithCredential(credential);
                              Navigator.pop(ctx, true);
                            } else {
                              setDialogState(() { isLoading = false; errorMessage = 'Admin user nahi mila.'; });
                            }
                          } catch (e) {
                            setDialogState(() { isLoading = false; errorMessage = 'Galat Password!'; });
                          }
                        },
                  child: isLoading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Delete Now', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          }
        );
      },
    );

    if (confirm != true) return;

    try {
      final studentsRef =
          FirebaseFirestore.instance.collection('students_directory');
      final studentDoc = await studentsRef.doc(docId).get();

      if (!studentDoc.exists) {
        throw Exception('Student Firestore me nahi mila.');
      }

      final data = studentDoc.data()!;
      final studentClass = data['class']?.toString().trim() ?? '';
      final normalizedRoll = _normalizeStudentRoll(data['rollNo']);
      final classNumber = _studentClassNumber(studentClass);

      if (classNumber <= 0 || normalizedRoll.isEmpty) {
        throw Exception('Student Class / Roll valid nahi hai.');
      }

      // IMPORTANT: agar kisi purane failed request ka add/edit Google outbox
      // me pada ho, delete ke baad woh student ko dobara create na kare.
      final googleOutbox = await FirebaseFirestore.instance
          .collection('_windows_google_outbox')
          .get();

      for (final queued in googleOutbox.docs) {
        final queuedData = queued.data();
        final action = queuedData['action']?.toString().trim() ?? '';
        if (action != 'add_student' &&
            action != 'edit_student' &&
            action != 'change_student_class') {
          continue;
        }

        final rawBody = queuedData['body'];
        if (rawBody is! Map) continue;
        final body = Map<String, dynamic>.from(rawBody);
        final queuedClass =
            (body['studentClass'] ?? body['class'] ?? body['oldClass'])
                ?.toString() ??
            '';
        final queuedRoll =
            _normalizeStudentRoll(body['roll'] ?? body['rollNo']);

        if (_studentClassNumber(queuedClass) == classNumber &&
            queuedRoll == normalizedRoll) {
          await queued.reference.delete();
        }
      }

      final scriptUrl = await _windowsGoogleScriptUrl();

      Future<Map<String, dynamic>> deleteFromGoogle() async {
        final response = await WindowsBackendBridge.post(
          Uri.parse(scriptUrl),
          headers: const {'Content-Type': 'text/plain;charset=utf-8'},
          body: jsonEncode({
            'action': 'delete_student',
            'studentClass': 'Class $classNumber',
            'roll': normalizedRoll,
          }),
        );

        if (response.statusCode != 200) {
          throw Exception('Google delete failed: ${response.statusCode}');
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map) {
          throw Exception('Google delete response invalid hai.');
        }
        return Map<String, dynamic>.from(decoded);
      }

      // Current Apps Script one matching row per call delete karta hai.
      // Purane duplicate rows ho to sab remove hon, isliye alreadyDeleted
      // milne tak repeat karte hain (safety cap 20).
      var googleFullyDeleted = false;
      for (var attempt = 0; attempt < 20; attempt++) {
        final result = await deleteFromGoogle();
        if (result['success'] != true) {
          throw Exception(
            result['message'] ?? 'Student Google Sheet delete failed.',
          );
        }
        if (result['alreadyDeleted'] == true) {
          googleFullyDeleted = true;
          break;
        }
      }

      if (!googleFullyDeleted) {
        throw Exception('Student duplicate cleanup limit exceed hua.');
      }

      // Same student ke saare legacy aliases (Roll_1 / Roll_01 / etc.)
      // local profile se delete karo. Tracked delete Firebase ke saare alias
      // documents ko bhi next sync me delete karega.
      final allStudents = await studentsRef.get();
      var deletedCount = 0;

      for (final student in allStudents.docs) {
        final studentData = student.data();
        final sameClass =
            _studentClassNumber(studentData['class']) == classNumber;
        final sameRoll =
            _normalizeStudentRoll(studentData['rollNo']) == normalizedRoll;

        if (sameClass && sameRoll) {
          await student.reference.delete();
          deletedCount++;
        }
      }

      if (deletedCount == 0) {
        await studentsRef.doc(docId).delete();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('Student permanently delete ho gaya!'),
          ),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Delete error: $e')));
    }
  }

  void _editStudent(String docId, Map<String, dynamic> data) {
    final nameCtrl = TextEditingController(text: data['name']?.toString() ?? '');
    final parentCtrl = TextEditingController(text: data['parentName']?.toString() ?? '');
    final contactCtrl = TextEditingController(text: data['parentContact']?.toString() ?? '');
    final addressCtrl = TextEditingController(text: data['address']?.toString() ?? '');
    final pinCtrl = TextEditingController(text: data['pinCode']?.toString() ?? '');
    final districtCtrl = TextEditingController(text: data['district']?.toString() ?? '');
    final stateCtrl = TextEditingController(text: data['state']?.toString() ?? '');
    final admissionCtrl = TextEditingController(text: data['joiningDate']?.toString() ?? '');
    final dobCtrl = TextEditingController(text: data['dateOfBirth']?.toString() ?? '');

    final existingPhotoUrl = data['photoUrl']?.toString().trim() ?? '';
    Uint8List? selectedPhotoBytes;
    String selectedPhotoMimeType = 'image/jpeg';
    String hostelFacility = data['hostelFacility']?.toString() ?? 'No';
    bool saving = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Widget studentEditPhotoPreview() {
              if (selectedPhotoBytes != null) {
                return Image.memory(
                  selectedPhotoBytes!,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                );
              }

              if (existingPhotoUrl.isNotEmpty) {
                return Image.network(
                  existingPhotoUrl,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
errorBuilder: (_, __, ___) => const ColoredBox(
                    color: Color(0xFF121B22),
                    child: Icon(
                      Icons.person_rounded,
                      size: 38,
                      color: Color(0xFF00A884),
                    ),
                  ),
                );
              }

              return const ColoredBox(
                color: Color(0xFF121B22),
                child: Icon(
                  Icons.person_rounded,
                  size: 38,
                  color: Color(0xFF00A884),
                ),
              );
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF1F2C34),
              title: Text(
                'Edit Student (${data['class'] ?? ''} - Roll ${data['rollNo'] ?? ''})',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 82,
                            height: 82,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selectedPhotoBytes != null
                                    ? const Color(0xFF00A884)
                                    : Colors.white24,
                                width: 2,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: studentEditPhotoPreview(),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: selectedPhotoBytes != null
                                      ? const Color(0xFF00A884)
                                      : Colors.white24,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 13,
                                ),
                              ),
                              onPressed: saving
                                  ? null
                                  : () async {
                                      final picker = ImagePicker();
                                      final image = await picker.pickImage(
                                        source: ImageSource.gallery,
                                        maxWidth: 700,
                                        imageQuality: 65,
                                      );
                                      if (image == null) return;

                                      final bytes = await image.readAsBytes();
                                      if (bytes.length > 700000) {
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            backgroundColor: Colors.redAccent,
                                            content: Text(
                                              'Photo size zyada hai. Chhota photo select karein.',
                                            ),
                                          ),
                                        );
                                        return;
                                      }

                                      final fileName = image.name.toLowerCase();
                                      setDialogState(() {
                                        selectedPhotoBytes = bytes;
                                        if (fileName.endsWith('.png')) {
                                          selectedPhotoMimeType = 'image/png';
                                        } else if (fileName.endsWith('.webp')) {
                                          selectedPhotoMimeType = 'image/webp';
                                        } else {
                                          selectedPhotoMimeType = 'image/jpeg';
                                        }
                                      });
                                    },
                              icon: Icon(
                                selectedPhotoBytes != null
                                    ? Icons.check_circle_rounded
                                    : Icons.add_a_photo_outlined,
                                color: selectedPhotoBytes != null
                                    ? const Color(0xFF00A884)
                                    : Colors.white70,
                              ),
                              label: Text(
                                selectedPhotoBytes != null
                                    ? 'New Photo Ready'
                                    : 'Change Student Photo',
                                style: TextStyle(
                                  color: selectedPhotoBytes != null
                                      ? const Color(0xFF00A884)
                                      : Colors.white70,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: nameCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInput('Full Name'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: parentCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInput("Parent's Name"),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: contactCtrl,
                        keyboardType: TextInputType.phone,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInput('Contact No'),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: hostelFacility,
                        dropdownColor: const Color(0xFF1F2C34),
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInput('Hostel Facility'),
                        items: const [
                          DropdownMenuItem(
                            value: 'No',
                            child: Text('Hostel Facility: No'),
                          ),
                          DropdownMenuItem(
                            value: 'Yes',
                            child: Text('Hostel Facility: Yes'),
                          ),
                        ],
                        onChanged: saving
                            ? null
                            : (value) {
                                if (value != null) {
                                  setDialogState(() => hostelFacility = value);
                                }
                              },
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: addressCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInput('Address'),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: districtCtrl,
                              style: const TextStyle(color: Colors.white),
                              decoration: _dialogInput('District'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: stateCtrl,
                              style: const TextStyle(color: Colors.white),
                              decoration: _dialogInput('State'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: pinCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInput('PIN Code'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: admissionCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInput('Admission Date'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: dobCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInput('Date of Birth'),
                      ),
                    ],
                  ),
                ),
              ),
              actionsAlignment: MainAxisAlignment.spaceBetween,
              actions: [
                TextButton.icon(
                  onPressed: saving
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _deleteStudent(docId);
                        },
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                    size: 18,
                  ),
                  label: const Text(
                    'Delete Student',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: saving ? null : () => Navigator.pop(ctx),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00A884),
                      ),
                      onPressed: saving
                          ? null
                          : () async {
                              setDialogState(() => saving = true);

                              try {
                                final scriptUrl =
                                    await _windowsGoogleScriptUrl();

                                final studentClass =
                                    data['class']?.toString() ?? '';
                                final rollNo =
                                    data['rollNo']?.toString() ?? '';

                                final response = await WindowsBackendBridge.post(
                                  Uri.parse(scriptUrl),
                                  headers: {
                                    'Content-Type':
                                        'text/plain;charset=utf-8',
                                  },
                                  body: jsonEncode({
                                    'action': 'edit_student',
                                    'name': nameCtrl.text.trim(),
                                    'parentName': parentCtrl.text.trim(),
                                    'studentClass': studentClass,
                                    'roll': rollNo,
                                    'contact': contactCtrl.text.trim(),
                                    'photoBase64': selectedPhotoBytes == null
                                        ? ''
                                        : base64Encode(selectedPhotoBytes!),
                                    'photoMimeType': selectedPhotoMimeType,
                                    'hostelFacility': hostelFacility,
                                    'address': addressCtrl.text.trim(),
                                    'district': districtCtrl.text.trim(),
                                    'state': stateCtrl.text.trim(),
                                    'pinCode': pinCtrl.text.trim(),
                                    'joiningDate': admissionCtrl.text.trim(),
                                    'dateOfBirth': dobCtrl.text.trim(),
                                  }),
                                );

                                if (response.statusCode != 200) {
                                  throw Exception(
                                    'Google update failed: ${response.statusCode}',
                                  );
                                }

                                final decoded = jsonDecode(response.body);
                                if (decoded is! Map) {
                                  throw Exception('Google update response invalid hai.');
                                }

                                final result = Map<String, dynamic>.from(decoded);
                                if (result['success'] != true) {
                                  throw Exception(
                                    result['message'] ?? 'Google update failed',
                                  );
                                }

                                final returnedPhotoUrl =
                                    result['photoUrl']?.toString().trim() ?? '';

                                final updateData = <String, dynamic>{
                                  'name': nameCtrl.text.trim(),
                                  'parentName': parentCtrl.text.trim(),
                                  'parentContact': contactCtrl.text.trim(),
                                  'hostelFacility': hostelFacility,
                                  'address': addressCtrl.text.trim(),
                                  'district': districtCtrl.text.trim(),
                                  'state': stateCtrl.text.trim(),
                                  'pinCode': pinCtrl.text.trim(),
                                  'joiningDate': admissionCtrl.text.trim(),
                                  'dateOfBirth': dobCtrl.text.trim(),
                                  'updatedAt': FieldValue.serverTimestamp(),
                                };

                                if (returnedPhotoUrl.isNotEmpty) {
                                  updateData['photoUrl'] = returnedPhotoUrl;
                                }

                                await FirebaseFirestore.instance
                                    .collection('students_directory')
                                    .doc(docId)
                                    .update(updateData);

                                if (!mounted) return;

                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: const Color(0xFF00A884),
                                    content: Text(
                                      selectedPhotoBytes == null
                                          ? 'Student Firestore aur Google Sheet dono me update ho gaya!'
                                          : 'Student details aur photo successfully update ho gaye!',
                                    ),
                                  ),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                setDialogState(() => saving = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: Colors.redAccent,
                                    content: Text('Update error: $e'),
                                  ),
                                );
                              }
                            },
                      child: saving
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Save Changes',
                              style: TextStyle(color: Colors.white),
                            ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121B22),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Student Directory Records'),
      ),
      body: Column(
        children: [
          Container(
            color: const Color(0xFF1F2C34),
            height: 52,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              itemCount: _classes.length,
              itemBuilder: (context, index) {
                final currentClass = _classes[index];
                final selected = currentClass == _selectedClassFilter;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(
                      currentClass,
                      style: TextStyle(color: selected ? Colors.white : Colors.grey, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    selected: selected,
                    selectedColor: const Color(0xFF00A884),
                    backgroundColor: const Color(0xFF121B22),
                    onSelected: (_) => setState(() => _selectedClassFilter = currentClass),
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _selectedClassFilter == 'All Classes'
                  ? FirebaseFirestore.instance
                      .collection('students_directory')
                      .snapshots()
                  : FirebaseFirestore.instance
                      .collection('students_directory')
                      .where('class', isEqualTo: _selectedClassFilter)
                      .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF00A884),
                    ),
                  );
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(
                    child: Text(
                      _selectedClassFilter == 'All Classes'
                          ? 'Abhi koi student registered nahi hai.'
                          : '$_selectedClassFilter me koi student registered nahi hai.',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  );
                }

                final rawDocs = snapshot.data!.docs.toList();

                // Same Class + same Roll is one student. Old/synced duplicate
                // documents are not shown twice in Student Directory.
                final uniqueByStudent = <String, dynamic>{};
                for (final doc in rawDocs) {
                  final data = doc.data() as Map<String, dynamic>;
                  final key = _studentDirectoryIdentity(data);
                  final existing = uniqueByStudent[key];

                  if (existing == null) {
                    uniqueByStudent[key] = doc;
                    continue;
                  }

                  final expectedId =
                      '${data['class']}_Roll_${data['rollNo']}';
                  final existingData =
                      existing.data() as Map<String, dynamic>;
                  final existingExpectedId =
                      '${existingData['class']}_Roll_${existingData['rollNo']}';

                  final currentIsCanonical = doc.id == expectedId;
                  final existingIsCanonical =
                      existing.id == existingExpectedId;

                  if (currentIsCanonical && !existingIsCanonical) {
                    uniqueByStudent[key] = doc;
                  }
                }

                final docs = uniqueByStudent.values.toList();
                docs.sort((a, b) {
                  final aData = a.data() as Map<String, dynamic>;
                  final bData = b.data() as Map<String, dynamic>;

                  final aClassText = aData['class']?.toString() ?? '';
                  final bClassText = bData['class']?.toString() ?? '';

                  final aClass =
                      int.tryParse(aClassText.replaceAll(RegExp(r'[^0-9]'), '')) ??
                          999999;
                  final bClass =
                      int.tryParse(bClassText.replaceAll(RegExp(r'[^0-9]'), '')) ??
                          999999;

                  if (aClass != bClass) {
                    return aClass.compareTo(bClass);
                  }

                  final aRoll =
                      int.tryParse(aData['rollNo']?.toString() ?? '') ?? 999999;
                  final bRoll =
                      int.tryParse(bData['rollNo']?.toString() ?? '') ?? 999999;

                  return aRoll.compareTo(bRoll);
                });

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final student = doc.data() as Map<String, dynamic>;
                    final photoUrl = student['photoUrl']?.toString();
                    final latestResult =
                        _latestExamResultForStudent(doc.id, student);
                    final resultStatus =
                        latestResult?['result']?.toString().trim() ?? '';
                    final resultPercentage =
                        (latestResult?['percentage'] as num?)?.toDouble();
                    final resultExamName =
                        latestResult?['examName']?.toString().trim() ?? '';
                    final classNumber =
                        _studentClassNumber(student['class']);
                    final isMoving = _movingStudentIds.contains(doc.id);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0xFF1F2C34), borderRadius: BorderRadius.circular(12)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 56,
                            height: 56,
                            child: ClipOval(
                              child: (photoUrl != null && photoUrl.isNotEmpty)
                                  ? Image.network(
                                      photoUrl,
                                      fit: BoxFit.cover,
errorBuilder: (context, error, stackTrace) => const ColoredBox(color: Color(0xFF121B22), child: Icon(Icons.person, size: 30, color: Color(0xFF00A884))),
                                    )
                                  : const ColoredBox(color: Color(0xFF121B22), child: Icon(Icons.person, size: 30, color: Color(0xFF00A884))),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(student['name']?.toString() ?? '', translate: false,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.blueAccent.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        student['class']?.toString() ?? 'N/A',
                                        style: const TextStyle(
                                          color: Colors.blueAccent,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF00A884)
                                            .withOpacity(0.18),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'Roll: ${student['rollNo'] ?? 'N/A'}',
                                        style: const TextStyle(
                                          color: Color(0xFF00A884),
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text('Parent: ${student['parentName'] ?? 'N/A'} • Contact: ${student['parentContact'] ?? 'N/A'}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                const SizedBox(height: 3),
                                Text('Address: ${student['address'] ?? ''}, ${student['district'] ?? ''}, ${student['state'] ?? ''} - ${student['pinCode'] ?? ''}', style: const TextStyle(color: Colors.white60, fontSize: 11)),
                                const SizedBox(height: 3),
                                Text(
                                  'Hostel: ${student['hostelFacility'] ?? 'No'} • '
                                  'Admission: ${_studentDirectoryDate(student['joiningDate'])} • '
                                  'DOB: ${_studentDirectoryDate(student['dateOfBirth'])}',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 9,
                                        vertical: 7,
                                      ),
                                      decoration: BoxDecoration(
                                        color: resultStatus == 'PASS'
                                            ? const Color(0xFF00A884)
                                                .withOpacity(0.14)
                                            : resultStatus == 'FAIL'
                                                ? Colors.redAccent
                                                    .withOpacity(0.12)
                                                : Colors.white
                                                    .withOpacity(0.05),
                                        borderRadius: BorderRadius.circular(9),
                                        border: Border.all(
                                          color: resultStatus == 'PASS'
                                              ? const Color(0xFF00D9A5)
                                                  .withOpacity(0.30)
                                              : resultStatus == 'FAIL'
                                                  ? Colors.redAccent
                                                      .withOpacity(0.28)
                                                  : Colors.white12,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            resultStatus == 'PASS'
                                                ? Icons.check_circle_rounded
                                                : resultStatus == 'FAIL'
                                                    ? Icons.cancel_rounded
                                                    : Icons.fact_check_outlined,
                                            color: resultStatus == 'PASS'
                                                ? const Color(0xFF00D9A5)
                                                : resultStatus == 'FAIL'
                                                    ? Colors.redAccent
                                                    : Colors.white38,
                                            size: 15,
                                          ),
                                          const SizedBox(width: 5),
                                          Text(
                                            _studentExamResultsLoading &&
                                                    latestResult == null
                                                ? 'Result loading...'
                                                : resultStatus.isEmpty
                                                    ? 'Result: Not entered'
                                                    : '${resultExamName.isEmpty ? 'Latest' : resultExamName}: $resultStatus'
                                                        '${resultPercentage == null ? '' : ' • ${resultPercentage.toStringAsFixed(1)}%'}',
                                            style: TextStyle(
                                              color: resultStatus == 'PASS'
                                                  ? const Color(0xFF00D9A5)
                                                  : resultStatus == 'FAIL'
                                                      ? Colors.redAccent
                                                      : Colors.white54,
                                              fontSize: 9.8,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor:
                                            const Color(0xFF00D9A5),
                                        side: BorderSide(
                                          color: const Color(0xFF00A884)
                                              .withOpacity(0.38),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(9),
                                        ),
                                      ),
                                      onPressed: isMoving || classNumber >= 12
                                          ? null
                                          : () => _changeStudentClass(
                                                doc.id,
                                                Map<String, dynamic>.from(student),
                                                1,
                                              ),
                                      icon: isMoving
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.trending_up_rounded,
                                              size: 16,
                                            ),
                                      label: const Text(
                                        'Promote',
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.orangeAccent,
                                        side: BorderSide(
                                          color: Colors.orangeAccent
                                              .withOpacity(0.34),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(9),
                                        ),
                                      ),
                                      onPressed: isMoving || classNumber <= 1
                                          ? null
                                          : () => _changeStudentClass(
                                                doc.id,
                                                Map<String, dynamic>.from(student),
                                                -1,
                                              ),
                                      icon: const Icon(
                                        Icons.trending_down_rounded,
                                        size: 16,
                                      ),
                                      label: const Text(
                                        'Demote',
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF7CB9FF),
                                      side: BorderSide(
                                        color: const Color(0xFF7CB9FF).withOpacity(0.32),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                    ),
                                    onPressed: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => StudentDocumentsScreen(
                                            studentId: doc.id,
                                            studentData: Map<String, dynamic>.from(student),
                                          ),
                                        ),
                                      );
                                    },
                                    icon: const Icon(
                                      Icons.folder_copy_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Student All Documents',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF25D366).withOpacity(0.12),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: const Color(0xFF25D366).withOpacity(0.30)),
                                ),
                                child: IconButton(
                                  tooltip: WindowsUiLanguage.translate('WhatsApp Parent'),
                                  icon: const FaIcon(
                                    FontAwesomeIcons.whatsapp,
                                    color: Color(0xFF25D366),
                                    size: 22,
                                  ),
                                  onPressed: () {
                                    final contact = student['parentContact']?.toString() ?? '';
                                    final cleanNum = contact.replaceAll(RegExp(r'\D'), '');
                                    if (cleanNum.length >= 10) {
                                      final waNum = cleanNum.length == 10 ? '91$cleanNum' : cleanNum;
                                      html.window.open('https://wa.me/$waNum', '_blank');
                                    } else {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(backgroundColor: Colors.redAccent, content: Text('Student ka valid contact number nahi hai!')),
                                      );
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.blueAccent.withOpacity(0.10),
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  tooltip: WindowsUiLanguage.translate('Edit Record'),
                                  icon: const Icon(Icons.edit_rounded, color: Colors.blueAccent, size: 18),
                                  onPressed: () => _editStudent(doc.id, student),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _dialogInput(String hint) {
    return InputDecoration(
      labelText: hint,
      labelStyle: const TextStyle(color: Colors.grey, fontSize: 13),
      filled: true,
      fillColor: const Color(0xFF121B22),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
    );
  }
}

// ============================================================
// ADVANCED SETTINGS
// ============================================================
class PasswordManagementScreen extends StatelessWidget {
  const PasswordManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF172229),
        title: const Text('Password Management'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              children: const [
                WindowsSettingsPanel(),
                SizedBox(height: 14),
                _WindowsSectionPasswordLocksPanel(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AdvancedSettingsScreen extends StatefulWidget {
  const AdvancedSettingsScreen({super.key,this.connectionsOnly=false});
  final bool connectionsOnly;

  @override
  State<AdvancedSettingsScreen> createState() => _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState extends State<AdvancedSettingsScreen> {
  final _gmail = TextEditingController();
  final _script = TextEditingController();
  String? _linkedGmail;
  String? _linkedScript;
  bool _loading = true;
  bool _saving = false;

  bool get _linked =>
      (_linkedGmail?.trim().isNotEmpty ?? false) &&
      (_linkedScript?.trim().isNotEmpty ?? false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _gmail.dispose();
    _script.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await WindowsExternalConnections.load();
      if (!mounted) return;
      setState(() {
        _linkedGmail = data['googleEmail']?.toString().trim();
        _linkedScript = data['googleScriptUrl']?.toString().trim();
        _gmail.text = _linkedGmail ?? '';
        _script.text = _linkedScript ?? '';
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Advanced Settings load error: $e')),
      );
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final email = _gmail.text.trim();
    final url = _script.text.trim();

    if (email.isEmpty || !email.toLowerCase().endsWith('@gmail.com')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Valid School Gmail ID daalein.'),
        ),
      );
      return;
    }
    if (!url.startsWith('https://script.google.com/')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Valid Google Apps Script /exec URL daalein.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await WindowsSyncEngine.instance.changeGoogleConnection(
        email: email,
        scriptUrl: url,
      );
      if (!mounted) return;
      setState(() {
        _linkedGmail = email;
        _linkedScript = url;
        _saving = false;
      });
      unawaited(
        WindowsBackendBridge.testRemote(Uri.parse(url)),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF00A884),
          content: Text('Google Drive configuration save ho gayi.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Save error: $e'),
        ),
      );
    }
  }

  Future<void> _unlink() async {
    final sure = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF172229),
        title: const Text(
          'Are you sure?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Google Drive / Apps Script connection remove hoga. Existing Drive files delete nahi honge.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;

    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DriveUnlinkSecurityDialog(),
    );
    if (verified != true || !mounted) return;

    setState(() => _saving = true);
    try {
      await WindowsSyncEngine.instance.disconnectGoogle();
      if (!mounted) return;
      setState(() {
        _linkedGmail = null;
        _linkedScript = null;
        _gmail.clear();
        _script.clear();
        _saving = false;
      });
      WindowsServiceStatus.instance.unhealthy(
        WindowsServiceType.googleDrive,
        'Google Drive / Apps Script disconnected.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text('Google Drive configuration unlink ho gayi.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Unlink error: $e'),
        ),
      );
    }
  }

  InputDecoration _input(String text, IconData icon) => InputDecoration(
        hintText: text,
        hintStyle: const TextStyle(color: Colors.white30),
        prefixIcon: Icon(icon, color: Colors.orangeAccent),
        filled: true,
        fillColor: const Color(0xFF0F191F),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      );

  Widget _info(String label, String value, IconData icon) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: const Color(0xFF0F191F),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF4DA3FF)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 10)),
                  const SizedBox(height: 3),
                  SelectableText(
                    value,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF172229),
        title: const Text('Advanced Settings'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00A884)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF2A2417), Color(0xFF172229)],
                          ),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                              color: Colors.orangeAccent.withOpacity(0.20)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.security_rounded,
                                color: Colors.orangeAccent, size: 30),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Protected settings: Google Drive, Local Data aur Student UID yahan manage karein.',
                                style: TextStyle(
                                    color: Colors.white70, height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: const Color(0xFF172229),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.add_to_drive_rounded,
                                    color: Color(0xFF4DA3FF)),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    'Google Drive Integration',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const WindowsStatusLed(
                                  service: WindowsServiceType.googleDrive,
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            if (_linked) ...[
                              _info('Linked Gmail ID', _linkedGmail ?? '',
                                  Icons.mail_outline_rounded),
                              const SizedBox(height: 10),
                              _info('Google Apps Script URL',
                                  _linkedScript ?? '', Icons.link_rounded),
                              const SizedBox(height: 14),
                              const Text(
                                'Student documents, fee history, exam data aur report cards linked Google backend me save honge.',
                                style: TextStyle(
                                    color: Color(0xFF00D9A5),
                                    fontSize: 11,
                                    height: 1.4),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: _saving ? null : _unlink,
                                  icon: const Icon(Icons.sync_alt_rounded),
                                  label: const Text(
                                      'Unlink / Change Google Drive Account'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.orangeAccent,
                                    side: BorderSide(
                                        color: Colors.orangeAccent
                                            .withOpacity(0.5)),
                                  ),
                                ),
                              ),
                            ] else ...[
                              TextField(
                                controller: _gmail,
                                style: const TextStyle(color: Colors.white),
                                decoration:
                                    _input('School Gmail ID', Icons.mail_outline),
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _script,
                                style: const TextStyle(color: Colors.white),
                                decoration: _input(
                                    'Google Apps Script /exec URL',
                                    Icons.link_rounded),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: _saving ? null : _save,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        const Color(0xFF00A884),
                                  ),
                                  icon: _saving
                                      ? const SizedBox(
                                          width: 17,
                                          height: 17,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white),
                                        )
                                      : const Icon(Icons.cloud_done_rounded,
                                          color: Colors.white),
                                  label: Text(
                                    _saving ? 'Saving...' : 'Connect Google Drive',
                                    style:
                                        const TextStyle(color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      const WindowsSettingsPanel(
                        showLocalLock: false,
                        showFirebase: true,
                      ),
                      const SizedBox(height: 14),
                      const WindowsLicenseSettingsPanel(),
                      if(!widget.connectionsOnly)const PromotionPolicySwitch(),
                      const SizedBox(height: 14),
                      if(!widget.connectionsOnly)const WindowsLocalStorageCard(),
                      const SizedBox(height: 14),
                      if(!widget.connectionsOnly)const _AdvancedStudentUidSettingsPanel(),
                      if (!widget.connectionsOnly) ...[
                        const SizedBox(height: 20),
                        OutlinedButton.icon(icon: const Icon(Icons.restore_rounded),
                          label: const Text('Reset app settings'),
                          onPressed: () => WindowsPreferencesReset.confirmAndReset(context)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}



class _WindowsSectionPasswordLocksPanel extends StatefulWidget {
  const _WindowsSectionPasswordLocksPanel();

  @override
  State<_WindowsSectionPasswordLocksPanel> createState() =>
      _WindowsSectionPasswordLocksPanelState();
}

class _WindowsSectionPasswordLocksPanelState
    extends State<_WindowsSectionPasswordLocksPanel> {
  final Map<String, bool> _configured = <String, bool>{};
  final Map<String, bool> _enabled = <String, bool>{};
  String? _busyKey;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final configured = <String, bool>{};
    final enabled = <String, bool>{};

    try {
      for (final definition in _windowsSectionLockDefinitions) {
        configured[definition.key] =
            await WindowsSectionLocks.configured(definition.key);
        enabled[definition.key] =
            await WindowsSectionLocks.enabled(definition.key);
      }
    } catch (e) {
      debugPrint('Section lock settings load warning: $e');
    }

    if (!mounted) return;
    setState(() {
      _configured
        ..clear()
        ..addAll(configured);
      _enabled
        ..clear()
        ..addAll(enabled);
      _loading = false;
      _busyKey = null;
    });
  }

  Future<void> _editPassword(
    _WindowsSectionLockDefinition definition,
  ) async {
    final isChange = _configured[definition.key] == true;
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    bool saving = false;
    bool obscure = true;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> save() async {
              if (saving) return;

              if (isChange && current.text.isEmpty) {
                setDialogState(() => error = 'Current password required hai.');
                return;
              }
              if (next.text.trim().length < 6) {
                setDialogState(
                  () => error = 'Password kam se kam 6 characters ka ho.',
                );
                return;
              }
              if (next.text != confirm.text) {
                setDialogState(() => error = 'Password match nahi kar raha.');
                return;
              }

              setDialogState(() {
                saving = true;
                error = null;
              });

              try {
                if (isChange) {
                  await WindowsSectionLocks.changePassword(
                    sectionKey: definition.key,
                    currentPassword: current.text,
                    newPassword: next.text,
                  );
                } else {
                  await WindowsSectionLocks.addPassword(
                    sectionKey: definition.key,
                    password: next.text,
                  );
                }

                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop(true);
              } catch (e) {
                if (!dialogContext.mounted) return;
                setDialogState(() {
                  saving = false;
                  error = e
                      .toString()
                      .replaceFirst('FormatException: ', '')
                      .replaceFirst('StateError: ', '')
                      .replaceFirst('Bad state: ', '');
                });
              }
            }

            InputDecoration field(String label) {
              return InputDecoration(
                labelText: label,
                labelStyle: const TextStyle(color: Colors.white54),
                prefixIcon: const Icon(
                  Icons.password_rounded,
                  color: Color(0xFF00A884),
                ),
                suffixIcon: IconButton(
                  onPressed: saving
                      ? null
                      : () => setDialogState(() => obscure = !obscure),
                  icon: Icon(
                    obscure
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    color: Colors.white54,
                  ),
                ),
                filled: true,
                fillColor: const Color(0xFF0F191F),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              );
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF172229),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              title: Row(
                children: [
                  Icon(definition.icon, color: definition.color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isChange
                          ? 'Change ${definition.title} Password'
                          : 'Add ${definition.title} Password',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 470,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isChange) ...[
                      TextField(
                        controller: current,
                        obscureText: obscure,
                        enabled: !saving,
                        style: const TextStyle(color: Colors.white),
                        decoration: field('Current Password'),
                      ),
                      const SizedBox(height: 10),
                    ],
                    TextField(
                      controller: next,
                      obscureText: obscure,
                      enabled: !saving,
                      style: const TextStyle(color: Colors.white),
                      decoration: field('New Password'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: confirm,
                      obscureText: obscure,
                      enabled: !saving,
                      style: const TextStyle(color: Colors.white),
                      decoration: field('Confirm Password'),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 9),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          error!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: saving ? null : save,
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_rounded, size: 17),
                  label: Text(isChange ? 'Change Password' : 'Add Password'),
                ),
              ],
            );
          },
        );
      },
    );

    current.dispose();
    next.dispose();
    confirm.dispose();

    if (saved == true && mounted) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text(
            '${definition.title} password save ho gaya aur lock ON hai.',
          ),
        ),
      );
    }
  }

  Future<void> _toggle(
    _WindowsSectionLockDefinition definition,
    bool value,
  ) async {
    if (_busyKey != null) return;

    if (value && _configured[definition.key] != true) {
      await _editPassword(definition);
      return;
    }

    setState(() => _busyKey = definition.key);
    try {
      await WindowsSectionLocks.setEnabled(
        sectionKey: definition.key,
        value: value,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyKey = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Lock update error: $e'),
        ),
      );
    }
  }

  Widget _status(bool enabled) {
    final color = enabled ? const Color(0xFF00D9A5) : Colors.white38;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.24)),
      ),
      child: Text(
        enabled ? 'ON' : 'OFF',
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _row(_WindowsSectionLockDefinition definition) {
    final configured = _configured[definition.key] == true;
    final enabled = _enabled[definition.key] == true;
    final busy = _busyKey == definition.key;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFF0F191F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: definition.color.withOpacity(0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: definition.color.withOpacity(0.11),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(definition.icon, color: definition.color, size: 20),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      definition.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      definition.subtitle,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              _status(enabled),
              const SizedBox(width: 5),
              Switch(
                value: enabled,
                activeColor: definition.color,
                onChanged: _loading || busy
                    ? null
                    : (value) => _toggle(definition, value),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _loading || busy
                    ? null
                    : () => _editPassword(definition),
                icon: Icon(
                  configured ? Icons.key_rounded : Icons.add_rounded,
                  size: 16,
                ),
                label: Text(
                  configured ? 'Change Password' : 'Add Password',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: definition.color,
                  side: BorderSide(
                    color: definition.color.withOpacity(0.45),
                  ),
                ),
              ),
              if (!configured)
                const Text(
                  'Password not set',
                  style: TextStyle(color: Colors.white30, fontSize: 10),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_rounded, color: Colors.orangeAccent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Section Password Locks',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          const Text(
            'Ye passwords App Open/Firebase password aur Local Settings Lock se completely independent hain. Password ON hone par section kholte waqt alag password maanga jayega.',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10.5,
              height: 1.45,
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 18),
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFF00D9A5)),
              ),
            )
          else
            for (final definition in _windowsSectionLockDefinitions)
              _row(definition),
        ],
      ),
    );
  }
}

class _AdvancedStudentUidSettingsPanel extends StatefulWidget {
  const _AdvancedStudentUidSettingsPanel();

  @override
  State<_AdvancedStudentUidSettingsPanel> createState() =>
      _AdvancedStudentUidSettingsPanelState();
}

class _AdvancedStudentUidSettingsPanelState
    extends State<_AdvancedStudentUidSettingsPanel> {
  final TextEditingController _uidStartController =
      TextEditingController(text: 'TEST-000001');

  bool _uidSettingsLoading = true;
  bool _uidMasterEnabled = false;
  bool _uidFeesEnabled = false;
  bool _uidIdCardEnabled = false;
  bool _uidEverActivated = false;
  String _uidPrefix = 'TEST-';
  int _uidPadding = 6;
  int _uidNextNumber = 1;
  String _uidLastIssued = '';

  @override
  void initState() {
    super.initState();
    _fetchUidTestSettings();
  }

  @override
  void dispose() {
    _uidStartController.dispose();
    super.dispose();
  }

  Future<void> _fetchUidTestSettings() async {
    try {
      final data = await _loadTestStudentUidConfig();
      if (!mounted) return;

      final prefix = data['prefix']?.toString() ?? 'TEST-';
      final padding = (data['padding'] as num?)?.toInt() ?? 6;
      final nextNumber = (data['nextNumber'] as num?)?.toInt() ?? 1;
      final everActivated = data['everActivated'] == true;

      setState(() {
        _uidMasterEnabled = data['masterEnabled'] == true;
        _uidFeesEnabled = data['feesEnabled'] == true;
        _uidIdCardEnabled = data['idCardEnabled'] == true;
        _uidEverActivated = everActivated;
        _uidPrefix = prefix;
        _uidPadding = padding;
        _uidNextNumber = nextNumber;
        _uidLastIssued = data['lastIssuedUid']?.toString() ?? '';
        _uidSettingsLoading = false;

        if (everActivated) {
          _uidStartController.text =
              _formatTestStudentUid(prefix, padding, nextNumber);
        } else {
          _uidStartController.text =
              data['startPattern']?.toString() ?? 'TEST-000001';
        }
      });
    } catch (e) {
      debugPrint('Test UID settings load error: $e');
      if (!mounted) return;
      setState(() => _uidSettingsLoading = false);
    }
  }

  int _classSortNumber(String value) {
    return int.tryParse(value.replaceAll(RegExp(r'[^0-9]'), '')) ?? 999999;
  }

  int _rollSortNumber(String value) {
    return int.tryParse(value.trim()) ?? 999999;
  }

  Future<String?> _showUidActivationPasswordDialog() async {
    final passwordController = TextEditingController();
    int secondsLeft = 20;
    bool countdownStarted = false;

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            if (!countdownStarted) {
              countdownStarted = true;

              Future<void>(() async {
                while (secondsLeft > 0) {
                  await Future<void>.delayed(const Duration(seconds: 1));
                  if (!dialogContext.mounted) return;
                  setDialogState(() => secondsLeft--);
                }
              });
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF172229),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              title: const Row(
                children: [
                  Icon(Icons.badge_rounded, color: Color(0xFF00D9A5)),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Activate TEST Student UID?',
                      style: TextStyle(color: Colors.white, fontSize: 17),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 470,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Kya school ke sabhi existing students Student Directory me add ho chuke hain?\n\n'
                      'TEST UID activate hone par existing students ko Class 1 → Class 12 aur Roll No order me permanent TEST UID assign hoga. '
                      'Delete hone ke baad purana UID dobara issue nahi hoga. Final production UID baad me alag se activate kiya jayega.',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orangeAccent.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.orangeAccent.withOpacity(0.25),
                        ),
                      ),
                      child: Text(
                        secondsLeft > 0
                            ? 'Student Directory verify karein... Password option $secondsLeft sec baad unlock hoga.'
                            : 'Verification time complete. Ab Admin Password enter karein.',
                        style: TextStyle(
                          color: secondsLeft > 0
                              ? Colors.orangeAccent
                              : const Color(0xFF00D9A5),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: passwordController,
                      enabled: secondsLeft == 0,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Admin Password',
                        labelStyle: const TextStyle(color: Colors.white54),
                        prefixIcon: const Icon(
                          Icons.lock_outline_rounded,
                          color: Color(0xFF00A884),
                        ),
                        filled: true,
                        fillColor: const Color(0xFF0F191F),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: secondsLeft == 0 &&
                          passwordController.text.trim().isNotEmpty
                      ? () => Navigator.pop(
                            dialogContext,
                            passwordController.text,
                          )
                      : null,
                  icon: const Icon(Icons.verified_user_rounded, size: 18),
                  label: const Text('Verify & Activate'),
                ),
              ],
            );
          },
        );
      },
    );

    passwordController.dispose();
    return result;
  }

  Future<void> _verifyCurrentAdminPassword(String password) async {
    final user = FirebaseAuth.instance.currentUser;
    final email = user?.email?.trim() ?? '';

    if (user == null || email.isEmpty) {
      throw Exception('Admin login session nahi mila.');
    }

    final credential = EmailAuthProvider.credential(
      email: email,
      password: password,
    );

    await user.reauthenticateWithCredential(credential);
  }

  Future<void> _activateUidTestMode() async {
    if (_uidSettingsLoading) return;

    Map<String, dynamic>? parsedPattern;

    if (!_uidEverActivated) {
      try {
        parsedPattern = _parseTestUidPattern(_uidStartController.text);
      } on FormatException catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(e.message.toString()),
          ),
        );
        return;
      }
    }

    final password = await _showUidActivationPasswordDialog();
    if (password == null || password.isEmpty || !mounted) return;

    setState(() => _uidSettingsLoading = true);

    try {
      await _verifyCurrentAdminPassword(password);

      final freshConfig = await _loadTestStudentUidConfig();
      final everActivated = freshConfig['everActivated'] == true;

      final prefix = everActivated
          ? (freshConfig['prefix']?.toString() ?? _uidPrefix)
          : parsedPattern!['prefix'].toString();
      final padding = everActivated
          ? ((freshConfig['padding'] as num?)?.toInt() ?? _uidPadding)
          : parsedPattern!['padding'] as int;
      var nextNumber = everActivated
          ? ((freshConfig['nextNumber'] as num?)?.toInt() ?? _uidNextNumber)
          : parsedPattern!['startNumber'] as int;

      final students = await FirebaseFirestore.instance
          .collection('students_directory')
          .get();

      final docs = [...students.docs];
      docs.sort((a, b) {
        final ad = a.data();
        final bd = b.data();

        final classCompare = _classSortNumber(
          ad['class']?.toString() ?? '',
        ).compareTo(
          _classSortNumber(bd['class']?.toString() ?? ''),
        );
        if (classCompare != 0) return classCompare;

        final rollCompare = _rollSortNumber(
          ad['rollNo']?.toString() ?? '',
        ).compareTo(
          _rollSortNumber(bd['rollNo']?.toString() ?? ''),
        );
        if (rollCompare != 0) return rollCompare;

        return (ad['name']?.toString() ?? '')
            .toLowerCase()
            .compareTo((bd['name']?.toString() ?? '').toLowerCase());
      });

      final missing = docs.where((doc) {
        return (doc.data()[_testStudentUidField]?.toString().trim() ?? '')
            .isEmpty;
      }).toList();

      final assignments = <MapEntry<
          DocumentReference<Map<String, dynamic>>, String>>[];
      var reservedNextNumber = nextNumber;
      String lastIssued = freshConfig['lastIssuedUid']?.toString() ?? '';

      for (final doc in missing) {
        final uid =
            _formatTestStudentUid(prefix, padding, reservedNextNumber);
        assignments.add(MapEntry(doc.reference, uid));
        lastIssued = uid;
        reservedNextNumber++;
      }

      // Counter pehle reserve hota hai. Agar network/batch beech me fail bhi ho,
      // reserved UID dobara reuse nahi hoga; sirf gap aa sakta hai.
      await _testStudentUidConfigRef().set(
        {
          'testMode': true,
          'masterEnabled': false,
          'everActivated': true,
          'prefix': prefix,
          'padding': padding,
          'startPattern': everActivated
              ? freshConfig['startPattern']?.toString()
              : _uidStartController.text.trim(),
          'nextNumber': reservedNextNumber,
          'lastIssuedUid': lastIssued,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      for (var start = 0; start < assignments.length; start += 400) {
        final batch = FirebaseFirestore.instance.batch();
        final end = (start + 400 < assignments.length)
            ? start + 400
            : assignments.length;

        for (var i = start; i < end; i++) {
          final assignment = assignments[i];
          batch.update(assignment.key, {
            _testStudentUidField: assignment.value,
            'studentUidTestAssignedAt': FieldValue.serverTimestamp(),
          });
        }

        await batch.commit();
      }

      await _testStudentUidConfigRef().set(
        {
          'masterEnabled': true,
          'feesEnabled': freshConfig['feesEnabled'] == true,
          'idCardEnabled': freshConfig['idCardEnabled'] == true,
          'activatedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      await _fetchUidTestSettings();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text(
            missing.isEmpty
                ? 'TEST Student UID ON ho gaya. Sab existing students ke UID pehle se assigned hain.'
                : 'TEST Student UID ON. ${missing.length} existing students ko UID assign hua.',
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _uidSettingsLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            e.code == 'wrong-password' || e.code == 'invalid-credential'
                ? 'Admin Password galat hai.'
                : 'Admin verification failed: ${e.message ?? e.code}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _uidSettingsLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('TEST UID activation error: $e'),
        ),
      );
    }
  }

  Future<void> _setUidMasterEnabled(bool value) async {
    if (value) {
      await _activateUidTestMode();
      return;
    }

    setState(() => _uidSettingsLoading = true);

    try {
      await _testStudentUidConfigRef().set(
        {
          'masterEnabled': false,
          'feesEnabled': false,
          'idCardEnabled': false,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      await _fetchUidTestSettings();
    } catch (e) {
      if (!mounted) return;
      setState(() => _uidSettingsLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('TEST UID OFF error: $e'),
        ),
      );
    }
  }

  Future<void> _setUidFeatureFlag(String field, bool value) async {
    if (!_uidMasterEnabled) return;

    setState(() => _uidSettingsLoading = true);
    try {
      await _testStudentUidConfigRef().set(
        {
          field: value,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      await _fetchUidTestSettings();
    } catch (e) {
      if (!mounted) return;
      setState(() => _uidSettingsLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('TEST UID setting save error: $e'),
        ),
      );
    }
  }

  InputDecoration _uidInput(String hint, IconData icon) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
        prefixIcon: Icon(icon, color: const Color(0xFF00A884), size: 19),
        filled: true,
        fillColor: const Color(0xFF0F191F),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF00A884)),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.04)),
        ),
      );

  Widget _toggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFF0F191F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.055)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: enabled ? Colors.white : Colors.white30,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: enabled ? Colors.white38 : Colors.white24,
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            activeColor: const Color(0xFF00D9A5),
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final statusColor =
        _uidMasterEnabled ? const Color(0xFF00D9A5) : Colors.grey;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF00D9A5).withOpacity(0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF00A884).withOpacity(0.11),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.badge_rounded,
                  color: Color(0xFF00D9A5),
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Student UID — TEST MODE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Fees identity + optional ID Card UID preview',
                      style: TextStyle(color: Colors.white38, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _uidMasterEnabled ? 'TEST ON' : 'TEST OFF',
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Container(height: 1, color: Colors.white.withOpacity(0.055)),
          const SizedBox(height: 15),
          if (_uidSettingsLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(color: Color(0xFF00A884)),
              ),
            )
          else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: Colors.orangeAccent.withOpacity(0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orangeAccent.withOpacity(0.18)),
              ),
              child: const Text(
                'Abhi TEST mode hai. Default example TEST-000001 hai. Assigned TEST UID delete hone ke baad reuse nahi hoga.',
                style: TextStyle(color: Colors.white60, fontSize: 11, height: 1.45),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _uidStartController,
              enabled: !_uidEverActivated && !_uidMasterEnabled,
              style: const TextStyle(color: Colors.white),
              decoration: _uidInput(
                'Starting UID — Example: TEST-000001',
                Icons.tag_rounded,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _uidEverActivated
                  ? 'Sequence locked. Next UID: ${_formatTestStudentUid(_uidPrefix, _uidPadding, _uidNextNumber)}'
                  : 'Class 1 Roll 1 se numbering start hogi, phir Class/Roll order me aage badegi.',
              style: const TextStyle(color: Colors.white38, fontSize: 10.5),
            ),
            if (_uidLastIssued.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                'Last issued TEST UID: $_uidLastIssued',
                style: const TextStyle(
                  color: Color(0xFF00D9A5),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 14),
            _toggle(
              title: 'Enable Student UID',
              subtitle: _uidMasterEnabled
                  ? 'TEST UID assignment active hai.'
                  : 'ON karne par 20 sec warning + Admin Password verification hoga.',
              value: _uidMasterEnabled,
              onChanged: _setUidMasterEnabled,
            ),
            const SizedBox(height: 10),
            _toggle(
              title: 'Use Student UID for Fees',
              subtitle: _uidMasterEnabled
                  ? 'ON: fee ledger TEST UID se link hoga.'
                  : 'Pehle master Student UID ON karein.',
              value: _uidFeesEnabled,
              enabled: _uidMasterEnabled,
              onChanged: (value) => _setUidFeatureFlag('feesEnabled', value),
            ),
            const SizedBox(height: 10),
            _toggle(
              title: 'Show Student UID on ID Card',
              subtitle: _uidMasterEnabled
                  ? 'ON: ID Card par same TEST UID dikhai dega.'
                  : 'Pehle master Student UID ON karein.',
              value: _uidIdCardEnabled,
              enabled: _uidMasterEnabled,
              onChanged: (value) => _setUidFeatureFlag('idCardEnabled', value),
            ),
          ],
        ],
      ),
    );
  }
}
class _DriveUnlinkSecurityDialog extends StatefulWidget {
  const _DriveUnlinkSecurityDialog();

  @override
  State<_DriveUnlinkSecurityDialog> createState() =>
      _DriveUnlinkSecurityDialogState();
}

class _DriveUnlinkSecurityDialogState
    extends State<_DriveUnlinkSecurityDialog> {
  final _password = TextEditingController();
  Timer? _timer;
  int _seconds = 30;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_seconds <= 1) {
        timer.cancel();
        setState(() => _seconds = 0);
      } else {
        setState(() => _seconds--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _password.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_seconds > 0 || _busy) return;
    final pass = _password.text.trim();
    if (pass.isEmpty) {
      setState(() => _error = 'Admin Password daalein.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await WindowsLocalSecurity.initialize();
      if (!WindowsLocalSecurity.verifyPassword(pass)) {
        throw Exception('Invalid Local Admin password');
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Galat Admin Password.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _seconds > 0;
    return AlertDialog(
      backgroundColor: const Color(0xFF172229),
      title: Text(
        waiting ? 'Security Waiting Period' : 'Admin Verification',
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 420,
        child: waiting
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$_seconds',
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 52,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Text(
                    'seconds remaining',
                    style: TextStyle(color: Colors.white54),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Countdown complete hone ke baad Admin Password maanga jayega.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white60),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _password,
                    autofocus: true,
                    obscureText: _obscure,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Admin Password',
                      hintStyle: const TextStyle(color: Colors.white30),
                      filled: true,
                      fillColor: const Color(0xFF0F191F),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                          color: Colors.white38,
                        ),
                      ),
                    ),
                    onSubmitted: (_) => _verify(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(_error!,
                          style: const TextStyle(
                              color: Colors.redAccent, fontSize: 11)),
                    ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        if (!waiting)
          ElevatedButton(
            onPressed: _busy ? null : _verify,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00A884),
            ),
            child: Text(
              _busy ? 'Verifying...' : 'Verify & Continue',
              style: const TextStyle(color: Colors.white),
            ),
          ),
      ],
    );
  }
}


// ============================================================
// STUDENT ALL DOCUMENTS
// PDF/JPG/JPEG only. Combined per-student limit = 2 MB.
// ============================================================
class StudentDocumentsScreen extends StatefulWidget {
  final String studentId;
  final Map<String, dynamic> studentData;

  const StudentDocumentsScreen({
    super.key,
    required this.studentId,
    required this.studentData,
  });

  @override
  State<StudentDocumentsScreen> createState() =>
      _StudentDocumentsScreenState();
}

class _StudentDocumentsScreenState
    extends State<StudentDocumentsScreen> {
  static const int _maxBytes = 2 * 1024 * 1024;
  bool _loading = true;
  bool _uploading = false;
  String? _error;
  List<Map<String, dynamic>> _documents = [];

  String get _name =>
      widget.studentData['name']?.toString().trim() ?? 'Student';
  String get _studentClass =>
      widget.studentData['class']?.toString().trim() ?? '';
  String get _roll =>
      widget.studentData['rollNo']?.toString().trim() ?? '';

  int get _totalBytes => _documents.fold<int>(
        0,
        (sum, item) =>
            sum + ((item['sizeBytes'] as num?)?.toInt() ?? 0),
      );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String> _scriptUrl() async {
    return _windowsGoogleScriptUrl();
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final response = await WindowsBackendBridge.post(
      Uri.parse(await _scriptUrl()),
      headers: {'Content-Type': 'text/plain;charset=utf-8'},
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      throw Exception('Google backend error: ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw Exception('Google backend response invalid hai.');
    }
    final result = Map<String, dynamic>.from(decoded);
    if (result['success'] != true) {
      throw Exception(result['message'] ?? 'Google backend operation failed');
    }
    return result;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _post({
        'action': 'list_student_documents',
        'studentId': widget.studentId,
        'studentName': _name,
        'studentClass': _studentClass,
        'rollNo': _roll,
      });
      final raw = result['documents'];
      final docs = raw is List
          ? raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _documents = docs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<String?> _askName(String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF172229),
        title: const Text('Document Name',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Aadhaar Card / Birth Certificate / Marksheet',
            hintStyle: const TextStyle(color: Colors.white30),
            filled: true,
            fillColor: const Color(0xFF0F191F),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(ctx, value);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00A884),
            ),
            child: const Text('Continue',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _upload({Map<String, dynamic>? replace}) async {
    if (_uploading) return;
    final docName = await _askName(replace?['documentName']?.toString());
    if (docName == null || !mounted) return;

    final input = html.FileUploadInputElement()
      ..accept = '.pdf,.jpg,.jpeg,application/pdf,image/jpeg';
    input.click();
    await input.onChange.first;

    final files = input.files;
    if (files == null || files.isEmpty || !mounted) return;

    final file = files.first;
    var mime = file.type.toLowerCase().trim();
    final lower = file.name.toLowerCase();

    if (mime.isEmpty) {
      if (lower.endsWith('.pdf')) {
        mime = 'application/pdf';
      } else if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
        mime = 'image/jpeg';
      }
    }

    if (mime != 'application/pdf' &&
        mime != 'image/jpeg' &&
        mime != 'image/jpg') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Sirf PDF/JPG/JPEG document allowed hai.'),
        ),
      );
      return;
    }

    final oldSize = (replace?['sizeBytes'] as num?)?.toInt() ?? 0;
    if (_totalBytes - oldSize + file.size > _maxBytes) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
              '2 MB total limit exceed hoga. Used ${_formatBytes(_totalBytes)}.'),
        ),
      );
      return;
    }

    setState(() => _uploading = true);
    try {
      final reader = html.FileReader();
      reader.readAsDataUrl(file);
      await reader.onLoad.first;
      final dataUrl = reader.result?.toString() ?? '';
      if (dataUrl.isEmpty) throw Exception('File read nahi ho paya.');

      await _post({
        'action': 'upload_student_document',
        'studentId': widget.studentId,
        'studentName': _name,
        'studentClass': _studentClass,
        'rollNo': _roll,
        'documentName': docName,
        'fileName': file.name,
        'mimeType': mime,
        'fileBase64': dataUrl,
        'replaceDocumentId': replace?['documentId']?.toString() ?? '',
        'uploadedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
      });

      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text(replace == null
              ? 'Document Google Drive me upload ho gaya.'
              : 'Document Google Drive me replace ho gaya.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Document upload error: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> document) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF172229),
        title: const Text('Delete Document?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          '${document['documentName'] ?? 'Document'} Google Drive se delete hoga.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _post({
        'action': 'delete_student_document',
        'studentId': widget.studentId,
        'documentId': document['documentId']?.toString() ?? '',
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Delete error: $e'),
        ),
      );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final ratio = (_totalBytes / _maxBytes).clamp(0.0, 1.0).toDouble();
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Student All Documents'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : () => _upload(),
        backgroundColor: const Color(0xFF00A884),
        foregroundColor: Colors.white,
        icon: _uploading
            ? const SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.upload_file_rounded),
        label: Text(_uploading ? 'Uploading...' : 'Upload Document'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 95),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF123D38), Color(0xFF172229)],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Icon(Icons.folder_copy_rounded,
                      color: Color(0xFF00D9A5), size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800)),
                        Text('$_studentClass • Roll $_roll',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: const Color(0xFF172229),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text('Storage',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800)),
                      const Spacer(),
                      Text('${_formatBytes(_totalBytes)} / 2.00 MB',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 10.5)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: ratio,
                    minHeight: 7,
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      ratio >= .9
                          ? Colors.redAccent
                          : ratio >= .7
                              ? Colors.orangeAccent
                              : const Color(0xFF00A884),
                    ),
                  ),
                  const SizedBox(height: 7),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'PDF/JPG/JPEG only • sab documents mila kar maximum 2 MB.',
                      style: TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(
                  child:
                      CircularProgressIndicator(color: Color(0xFF00A884)))
            else if (_error != null)
              Text(_error!,
                  style: const TextStyle(color: Colors.redAccent))
            else if (_documents.isEmpty)
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: const Color(0xFF172229),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Text(
                  'Abhi koi document upload nahi hai.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54),
                ),
              )
            else
              ..._documents.map((document) {
                final mime = document['mimeType']?.toString() ?? '';
                final isPdf = mime.contains('pdf');
                final size = (document['sizeBytes'] as num?)?.toInt() ?? 0;
                final url = document['fileUrl']?.toString() ?? '';
                return Container(
                  margin: const EdgeInsets.only(bottom: 9),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF172229),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isPdf
                            ? Icons.picture_as_pdf_rounded
                            : Icons.image_rounded,
                        color: isPdf
                            ? Colors.redAccent
                            : const Color(0xFF4DA3FF),
                        size: 28,
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(document['documentName']?.toString() ??
                                'Document',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800)),
                            Text(
                              '${document['fileName'] ?? ''} • ${_formatBytes(size)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 9.5),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: url.isEmpty
                            ? null
                            : () => html.window.open(url, '_blank'),
                        icon: const Icon(Icons.visibility_rounded, size: 16),
                        label: const Text('View'),
                      ),
                      TextButton.icon(
                        onPressed:
                            _uploading ? null : () => _upload(replace: document),
                        icon: const Icon(Icons.edit_document, size: 16),
                        label: const Text('Edit'),
                      ),
                      IconButton(
                        tooltip: WindowsUiLanguage.translate('Delete'),
                        onPressed:
                            _uploading ? null : () => _delete(document),
                        icon: const Icon(Icons.delete_outline_rounded,
                            color: Colors.redAccent, size: 19),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}


// ============================================================
// FEE TRANSACTION HISTORY
// ============================================================
class FeeTransactionHistoryScreen extends StatefulWidget {
  const FeeTransactionHistoryScreen({super.key});

  @override
  State<FeeTransactionHistoryScreen> createState() =>
      _FeeTransactionHistoryScreenState();
}

class _FeeTransactionHistoryScreenState
    extends State<FeeTransactionHistoryScreen> {
  final _search = TextEditingController();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _payments = [];
  String _classFilter = 'All Classes';
  String _monthFilter = 'All Months';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<String> _scriptUrl() async {
    return _windowsGoogleScriptUrl();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await WindowsBackendBridge.post(
        Uri.parse(await _scriptUrl()),
        headers: {'Content-Type': 'text/plain;charset=utf-8'},
        body: jsonEncode({'action': 'list_fee_payments'}),
      );
      if (response.statusCode != 200) {
        throw Exception('History load failed: ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw Exception('History response invalid hai.');
      final result = Map<String, dynamic>.from(decoded);
      if (result['success'] != true) {
        throw Exception(result['message'] ?? 'History load failed');
      }
      final raw = result['payments'];
      final payments = raw is List
          ? raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _payments = payments;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  double _n(dynamic value) =>
      (value as num?)?.toDouble() ??
      double.tryParse(value?.toString() ?? '') ??
      0;

  String _money(dynamic value) => '₹${_n(value).toStringAsFixed(0)}';

  List<String> get _months {
    final values = _payments
        .map((e) => e['month']?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    return ['All Months', ...values];
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return _payments.where((p) {
      if (_classFilter != 'All Classes' &&
          p['studentClass']?.toString() != _classFilter) {
        return false;
      }
      if (_monthFilter != 'All Months' &&
          p['month']?.toString() != _monthFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      final haystack = [
        p['receiptNo'],
        p['studentName'],
        p['rollNo'],
        p['studentClass'],
        p['paymentMode'],
        p['status'],
      ].join(' ').toLowerCase();
      return haystack.contains(q);
    }).toList();
  }

  Widget _metric(
      String title, String value, IconData icon, Color color) {
    return Container(
      width: 190,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w900)),
                Text(title,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 9.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _filtered;
    final total = data.fold<double>(
        0, (sum, p) => sum + _n(p['installmentAmount']));

    double byMode(String mode) => data
        .where((p) =>
            p['paymentMode']?.toString().toLowerCase() ==
            mode.toLowerCase())
        .fold<double>(
            0, (sum, p) => sum + _n(p['installmentAmount']));

    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Transaction History'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00A884)))
          : _error != null
              ? Center(
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _metric('Transactions', '${data.length}',
                              Icons.receipt_long_rounded,
                              const Color(0xFFB388FF)),
                          _metric('Total Collected', _money(total),
                              Icons.account_balance_wallet_rounded,
                              const Color(0xFF00D9A5)),
                          _metric('Cash', _money(byMode('Cash')),
                              Icons.payments_rounded, Colors.greenAccent),
                          _metric('UPI', _money(byMode('UPI')),
                              Icons.qr_code_2_rounded,
                              const Color(0xFF38A8FF)),
                          _metric('Bank Transfer',
                              _money(byMode('Bank Transfer')),
                              Icons.account_balance_rounded,
                              Colors.orangeAccent),
                        ],
                      ),
                      const SizedBox(height: 14),
                      LayoutBuilder(
                        builder: (context, c) {
                          final compact = c.maxWidth < 760;
                          final search = TextField(
                            controller: _search,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText:
                                  'Search student / receipt / roll / mode',
                              hintStyle:
                                  const TextStyle(color: Colors.white30),
                              prefixIcon: const Icon(Icons.search_rounded,
                                  color: Color(0xFF00A884)),
                              filled: true,
                              fillColor: const Color(0xFF172229),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(11),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          );
                          final cls = DropdownButtonFormField<String>(
                            value: _classFilter,
                            dropdownColor: const Color(0xFF172229),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Class',
                              labelStyle: TextStyle(color: Colors.white54),
                              filled: true,
                              fillColor: Color(0xFF172229),
                              border: OutlineInputBorder(
                                  borderSide: BorderSide.none),
                            ),
                            items: [
                              'All Classes',
                              ...List.generate(
                                  10, (i) => 'Class ${i + 1}')
                            ]
                                .map((v) =>
                                    DropdownMenuItem(value: v, child: Text(v)))
                                .toList(),
                            onChanged: (v) {
                              if (v != null) {
                                setState(() => _classFilter = v);
                              }
                            },
                          );
                          final month = DropdownButtonFormField<String>(
                            value: _months.contains(_monthFilter)
                                ? _monthFilter
                                : 'All Months',
                            dropdownColor: const Color(0xFF172229),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Month',
                              labelStyle: TextStyle(color: Colors.white54),
                              filled: true,
                              fillColor: Color(0xFF172229),
                              border: OutlineInputBorder(
                                  borderSide: BorderSide.none),
                            ),
                            items: _months
                                .map((v) =>
                                    DropdownMenuItem(value: v, child: Text(v)))
                                .toList(),
                            onChanged: (v) {
                              if (v != null) {
                                setState(() => _monthFilter = v);
                              }
                            },
                          );
                          if (compact) {
                            return Column(
                              children: [
                                search,
                                const SizedBox(height: 10),
                                cls,
                                const SizedBox(height: 10),
                                month,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(flex: 3, child: search),
                              const SizedBox(width: 10),
                              Expanded(flex: 2, child: cls),
                              const SizedBox(width: 10),
                              Expanded(flex: 2, child: month),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                      if (data.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(30),
                          child: Text('Matching transaction nahi mila.',
                              style: TextStyle(color: Colors.white54)),
                        )
                      else
                        ...data.map((p) {
                          final status = p['status']?.toString() ?? '';
                          final paid = status == 'PAID';
                          final url = p['fileUrl']?.toString().trim() ?? '';
                          return Container(
                            margin: const EdgeInsets.only(bottom: 9),
                            padding: const EdgeInsets.all(13),
                            decoration: BoxDecoration(
                              color: const Color(0xFF172229),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.receipt_rounded,
                                    color: Color(0xFFB388FF), size: 28),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p['studentName']?.toString() ??
                                            'Student',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w800),
                                      ),
                                      Text(
                                        '${p['studentClass'] ?? ''} • Roll ${p['rollNo'] ?? ''} • ${p['month'] ?? ''}',
                                        style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 10),
                                      ),
                                      Text(
                                        'Receipt ${p['receiptNo'] ?? ''} • ${p['dateText'] ?? ''} ${p['timeText'] ?? ''} • ${p['paymentMode'] ?? ''}',
                                        style: const TextStyle(
                                            color: Colors.white30,
                                            fontSize: 9.5),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: (paid
                                            ? const Color(0xFF00A884)
                                            : Colors.orangeAccent)
                                        .withOpacity(.1),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    status.isEmpty ? 'PAYMENT' : status,
                                    style: TextStyle(
                                      color: paid
                                          ? const Color(0xFF00D9A5)
                                          : Colors.orangeAccent,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      _money(p['installmentAmount']),
                                      style: const TextStyle(
                                          color: Color(0xFF00D9A5),
                                          fontSize: 16,
                                          fontWeight: FontWeight.w900),
                                    ),
                                    TextButton.icon(
                                      onPressed: url.isEmpty
                                          ? null
                                          : () =>
                                              html.window.open(url, '_blank'),
                                      icon: const Icon(
                                          Icons.picture_as_pdf_rounded,
                                          size: 15),
                                      label: const Text('Receipt'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        }),
                    ],
                  ),
                ),
    );
  }
}


// ============================================================
// EXAM CENTER
// ============================================================
class ExamCenterScreen extends StatefulWidget {
  const ExamCenterScreen({super.key});

  @override
  State<ExamCenterScreen> createState() => _ExamCenterScreenState();
}

class _ExamCenterScreenState extends State<ExamCenterScreen> {
  bool _loading = false;
  bool _saving = false;
  String? _error;
  int _academicYearRolloverMonth = 1;

  List<Map<String, dynamic>> _exams = [];
  List<Map<String, dynamic>> _results = [];
  Map<String, int> _studentCounts = <String, int>{};

  final List<String> _classList =
      List.generate(12, (index) => 'Class ${index + 1}');

  @override
  void initState() {
    super.initState();

    final cached = _ExamCenterDataCache.snapshot;
    if (cached != null) {
      _exams = List<Map<String, dynamic>>.from(cached.exams);
      _results = List<Map<String, dynamic>>.from(cached.results);
      _studentCounts = Map<String, int>.from(cached.studentCounts);
      _loading = false;
    } else {
      _loading = true;
    }

    _loadAcademicYearRolloverMonth();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(silent: cached != null);
    });
  }

  Future<void> _loadAcademicYearRolloverMonth() async {
    final month = await WindowsAcademicYearSettings.load();
    if (!mounted) return;
    setState(() => _academicYearRolloverMonth = month);
  }

  Future<String> _scriptUrl() async {
    return _windowsGoogleScriptUrl();
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final result = await WindowsExamService.request(body);
    if (result['success'] != true) throw StateError(result['message']?.toString() ?? 'Exam operation failed');
    return result;
  }

  Future<Map<String, int>> _loadStudentCounts(
    List<Map<String, dynamic>> exams,
  ) async {
    final classes = exams
        .map((e) => e['studentClass']?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();

    final entries = await Future.wait<MapEntry<String, int>>(
      classes.map((className) async {
        final snapshot = await FirebaseFirestore.instance
            .collection('students_directory')
            .where('class', isEqualTo: className)
            .get();
        return MapEntry(className, snapshot.docs.length);
      }),
    );
    return Map<String, int>.fromEntries(entries);
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = _exams.isEmpty && _results.isEmpty;
        _error = null;
      });
    } else if (mounted) {
      setState(() => _error = null);
    }

    try {
      final snapshot = await _ExamCenterDataCache.refresh(force: true);

      if (!mounted) return;
      setState(() {
        _exams = List<Map<String, dynamic>>.from(snapshot.exams);
        _results = List<Map<String, dynamic>>.from(snapshot.results);
        _studentCounts = Map<String, int>.from(snapshot.studentCounts);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  int _classNumber(String value) =>
      int.tryParse(value.replaceAll(RegExp(r'[^0-9]'), '')) ?? 999999;

  double _number(dynamic value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;

  int _timestamp(dynamic value) => value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? 0;

  List<Map<String, dynamic>> _forExam(String examId) => _results
      .where((e) => e['examId']?.toString() == examId)
      .toList();

  List<List<Map<String, dynamic>>> _examGroups() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final exam in _exams) {
      final displayName = exam['examName']?.toString().trim() ?? 'Exam';
      final key = displayName.toLowerCase();
      grouped.putIfAbsent(key, () => <Map<String, dynamic>>[]);
      grouped[key]!.add(exam);
    }

    final groups = grouped.values.toList();
    for (final group in groups) {
      group.sort((a, b) => _classNumber(
            a['studentClass']?.toString() ?? '',
          ).compareTo(_classNumber(
            b['studentClass']?.toString() ?? '',
          )));
    }

    groups.sort((a, b) {
      int latest(List<Map<String, dynamic>> group) => group.fold<int>(
            0,
            (best, e) {
              final value = _timestamp(e['timestamp']);
              return value > best ? value : best;
            },
          );
      return latest(b).compareTo(latest(a));
    });
    return groups;
  }

  int _expectedForExam(Map<String, dynamic> exam) =>
      _studentCounts[exam['studentClass']?.toString() ?? ''] ?? 0;

  int _pendingForExam(Map<String, dynamic> exam) {
    final expected = _expectedForExam(exam);
    final done = _forExam(exam['examId']?.toString() ?? '').length;
    final pending = expected - done;
    return pending > 0 ? pending : 0;
  }

  int _groupExpected(List<Map<String, dynamic>> group) => group.fold<int>(
        0,
        (sum, exam) => sum + _expectedForExam(exam),
      );

  int _groupCompleted(List<Map<String, dynamic>> group) => group.fold<int>(
        0,
        (sum, exam) =>
            sum + _forExam(exam['examId']?.toString() ?? '').length,
      );

  double _groupProgress(List<Map<String, dynamic>> group) {
    final expected = _groupExpected(group);
    if (expected <= 0) return 0;
    return (_groupCompleted(group) / expected).clamp(0.0, 1.0).toDouble();
  }

  String _academicYear() {
    final now = DateTime.now();
    return WindowsAcademicYearSettings.format(
      now,
      _academicYearRolloverMonth,
    );
  }

  Future<void> _openMarks(Map<String, dynamic> exam) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExamMarksEntryScreen(
          exam: Map<String, dynamic>.from(exam),
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _createExam() async {
    if (_saving) return;

    final examName = TextEditingController();
    final defaultSubjects =
        TextEditingController(text: 'English, Mathematics, Science');
    final defaultFull = TextEditingController(text: '100');
    final defaultPass = TextEditingController(text: '33');

    final selectedClasses = <String>{'Class 1'};
    final subjectsByClass = <String, TextEditingController>{};
    final fullByClass = <String, TextEditingController>{};
    final passByClass = <String, TextEditingController>{};
    String? dialogError;
    bool isFinalExam=false;

    void ensureClass(String className) {
      subjectsByClass.putIfAbsent(
        className,
        () => TextEditingController(text: defaultSubjects.text),
      );
      fullByClass.putIfAbsent(
        className,
        () => TextEditingController(text: defaultFull.text),
      );
      passByClass.putIfAbsent(
        className,
        () => TextEditingController(text: defaultPass.text),
      );
    }

    ensureClass('Class 1');

    final payloads = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final selectedSorted = selectedClasses.toList()
            ..sort((a, b) => _classNumber(a).compareTo(_classNumber(b)));

          return AlertDialog(
            backgroundColor: const Color(0xFF111B22),
            insetPadding: const EdgeInsets.all(18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            title: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.add_task_rounded,
                    color: Colors.orangeAccent,
                  ),
                ),
                const SizedBox(width: 11),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Create Exam',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'One exam • multiple classes • class-wise custom settings',
                        style: TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close_rounded, color: Colors.white54),
                ),
              ],
            ),
            content: SizedBox(
              width: 820,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: examName,
                      style: const TextStyle(color: Colors.white),
                      decoration: _dialogInput(
                        'Exam Name — Example: Final Exam 2026',
                        Icons.edit_note_rounded,
                      ),
                    ),
                    CheckboxListTile(value:isFinalExam,onChanged:(v)=>setDialogState(()=>isFinalExam=v ?? false),title:const Text('Final exam — apply PASS / FAIL promotion decisions')),
                    const SizedBox(height: 16),
                    const Text(
                      'SELECT CLASSES',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _classList.map((className) {
                        final selected = selectedClasses.contains(className);
                        return FilterChip(
                          selected: selected,
                          label: Text(className),
                          selectedColor:
                              const Color(0xFF00A884).withOpacity(0.28),
                          checkmarkColor: const Color(0xFF00D9A5),
                          backgroundColor: const Color(0xFF172229),
                          side: BorderSide(
                            color: selected
                                ? const Color(0xFF00D9A5)
                                : Colors.white12,
                          ),
                          labelStyle: TextStyle(
                            color: selected
                                ? const Color(0xFF00D9A5)
                                : Colors.white70,
                            fontWeight: FontWeight.w700,
                          ),
                          onSelected: (value) {
                            setDialogState(() {
                              if (value) {
                                selectedClasses.add(className);
                                ensureClass(className);
                              } else {
                                selectedClasses.remove(className);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D171D),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'DEFAULT CLASS SETTINGS',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: defaultSubjects,
                            minLines: 1,
                            maxLines: 2,
                            style: const TextStyle(color: Colors.white),
                            decoration: _dialogInput(
                              'Default Subjects — comma separated',
                              Icons.menu_book_rounded,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: defaultFull,
                                  keyboardType: TextInputType.number,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: _dialogInput(
                                    'Full Marks / Subject',
                                    Icons.score_rounded,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: defaultPass,
                                  keyboardType: TextInputType.number,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: _dialogInput(
                                    'Pass Marks / Subject',
                                    Icons.task_alt_rounded,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: OutlinedButton.icon(
                              onPressed: selectedClasses.isEmpty
                                  ? null
                                  : () {
                                      for (final className in selectedClasses) {
                                        ensureClass(className);
                                        subjectsByClass[className]!.text =
                                            defaultSubjects.text;
                                        fullByClass[className]!.text =
                                            defaultFull.text;
                                        passByClass[className]!.text =
                                            defaultPass.text;
                                      }
                                      setDialogState(() {});
                                    },
                              icon: const Icon(
                                Icons.content_copy_rounded,
                                size: 16,
                              ),
                              label: const Text('Apply to selected classes'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (selectedSorted.isNotEmpty) ...[
                      const Text(
                        'CLASS-WISE CUSTOMIZATION',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...selectedSorted.map((className) {
                        ensureClass(className);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF172229),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white10),
                          ),
                          child: ExpansionTile(
                            tilePadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 2,
                            ),
                            childrenPadding:
                                const EdgeInsets.fromLTRB(14, 0, 14, 14),
                            iconColor: const Color(0xFF00D9A5),
                            collapsedIconColor: Colors.white38,
                            title: Text(
                              className,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: const Text(
                              'Subjects / Full marks / Pass marks customize karein',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                              ),
                            ),
                            children: [
                              TextField(
                                controller: subjectsByClass[className],
                                minLines: 1,
                                maxLines: 3,
                                style: const TextStyle(color: Colors.white),
                                decoration: _dialogInput(
                                  'Subjects — comma separated',
                                  Icons.menu_book_rounded,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: fullByClass[className],
                                      keyboardType: TextInputType.number,
                                      style:
                                          const TextStyle(color: Colors.white),
                                      decoration: _dialogInput(
                                        'Full Marks',
                                        Icons.score_rounded,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: TextField(
                                      controller: passByClass[className],
                                      keyboardType: TextInputType.number,
                                      style:
                                          const TextStyle(color: Colors.white),
                                      decoration: _dialogInput(
                                        'Pass Marks',
                                        Icons.task_alt_rounded,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                    if (dialogError != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          dialogError!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00A884),
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  final name = examName.text.trim();
                  if (name.isEmpty) {
                    setDialogState(() => dialogError = 'Exam name bharein.');
                    return;
                  }
                  if (selectedClasses.isEmpty) {
                    setDialogState(() =>
                        dialogError = 'Kam se kam ek class select karein.');
                    return;
                  }

                  final configs = <Map<String, dynamic>>[];
                  for (final className in selectedSorted) {
                    final subjectList = subjectsByClass[className]!
                        .text
                        .split(',')
                        .map((e) => e.trim())
                        .where((e) => e.isNotEmpty)
                        .toList();
                    final fullMarks = double.tryParse(
                      fullByClass[className]!.text.trim(),
                    );
                    final passMarks = double.tryParse(
                      passByClass[className]!.text.trim(),
                    );

                    if (subjectList.isEmpty ||
                        fullMarks == null ||
                        fullMarks <= 0 ||
                        passMarks == null ||
                        passMarks < 0 ||
                        passMarks > fullMarks) {
                      setDialogState(() => dialogError =
                          '$className ki subjects/full/pass marks setting check karein.');
                      return;
                    }

                    configs.add({
                      'examName': name,
                      'isFinal': isFinalExam,
                      'studentClass': className,
                      'subjects': subjectList,
                      'fullMarks': fullMarks,
                      'passMarks': passMarks,
                    });
                  }

                  Navigator.pop(dialogContext, configs);
                },
                icon: const Icon(Icons.rocket_launch_rounded, size: 18),
                label: const Text('Create Exam'),
              ),
            ],
          );
        },
      ),
    );

    examName.dispose();
    defaultSubjects.dispose();
    defaultFull.dispose();
    defaultPass.dispose();
    for (final c in subjectsByClass.values) c.dispose();
    for (final c in fullByClass.values) c.dispose();
    for (final c in passByClass.values) c.dispose();

    if (payloads == null || payloads.isEmpty || !mounted) return;

    setState(() => _saving = true);
    var created = 0;

    try {
      for (final payload in payloads) {
        final savedExam = await _post({
          'action': 'save_exam',
          ...payload,
          'createdBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
        });
        final savedId=savedExam['examId']?.toString() ?? '';
        if(savedId.isNotEmpty)await FirebaseFirestore.instance.collection('school_settings').doc('exam_$savedId').set({...payload,'examId':savedId});
        created++;
      }
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text(
            '${payloads.first['examName']} $created class configuration ke saath create ho gaya.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            created > 0
                ? '$created class save hui, baaki save nahi ho payi: $e'
                : 'Exam create error: $e',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _dialogInput(String label, IconData icon) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        prefixIcon: Icon(icon, color: Colors.orangeAccent),
        filled: true,
        fillColor: const Color(0xFF0F191F),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.07)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: Colors.orangeAccent),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide.none,
        ),
      );

  Widget _metricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      width: 205,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.18)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withOpacity(0.11),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white30, fontSize: 8.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallPill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.09),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.18)),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.w800,
          ),
        ),
      );

  Widget _sectionHeader(String title, String subtitle, IconData icon) => Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFF00A884).withOpacity(0.10),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: const Color(0xFF00D9A5), size: 19),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.white38, fontSize: 9.5),
                ),
              ],
            ),
          ),
        ],
      );

  Future<void> _openExamGroup(List<Map<String, dynamic>> group) async {
    if (group.isEmpty) return;
    final examName = group.first['examName']?.toString() ?? 'Exam';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF111B22),
        insetPadding: const EdgeInsets.all(18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.orangeAccent.withOpacity(0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.school_rounded, color: Colors.orangeAccent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    examName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '${group.length} class configuration${group.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.pop(dialogContext),
              icon: const Icon(Icons.close_rounded, color: Colors.white54),
            ),
          ],
        ),
        content: SizedBox(
          width: 860,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 610),
            child: SingleChildScrollView(
              child: Column(
                children: group.map((exam) {
                  final id = exam['examId']?.toString() ?? '';
                  final className = exam['studentClass']?.toString() ?? '';
                  final results = _forExam(id);
                  final expected = _expectedForExam(exam);
                  final progress = expected > 0
                      ? (results.length / expected).clamp(0.0, 1.0).toDouble()
                      : 0.0;
                  final subjects = exam['subjects'] is List
                      ? List<dynamic>.from(exam['subjects'] as List)
                      : <dynamic>[];

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF172229),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: const Color(0xFF00A884).withOpacity(0.10),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Center(
                                child: Text(
                                  className.replaceAll('Class ', ''),
                                  style: const TextStyle(
                                    color: Color(0xFF00D9A5),
                                    fontSize: 16,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    className,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  Text(
                                    '${subjects.length} subjects • Full ${exam['fullMarks'] ?? 0} • Pass ${exam['passMarks'] ?? 0}',
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 9.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00A884),
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () {
                                Navigator.pop(dialogContext);
                                _openMarks(exam);
                              },
                              icon: const Icon(Icons.edit_note_rounded, size: 17),
                              label: const Text('Marks & Results'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 11),
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: LinearProgressIndicator(
                                  minHeight: 7,
                                  value: progress,
                                  backgroundColor: Colors.white10,
                                  color: const Color(0xFF00D9A5),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              expected <= 0
                                  ? '${results.length} entered'
                                  : '${results.length}/$expected',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _examGroupCard(List<Map<String, dynamic>> group) {
    final examName = group.first['examName']?.toString() ?? 'Exam';
    final allResults = <Map<String, dynamic>>[];
    final subjectSet = <String>{};

    for (final exam in group) {
      allResults.addAll(_forExam(exam['examId']?.toString() ?? ''));
      if (exam['subjects'] is List) {
        for (final subject in exam['subjects'] as List) {
          final value = subject.toString().trim();
          if (value.isNotEmpty) subjectSet.add(value);
        }
      }
    }

    final pass = allResults.where((e) => e['result'] == 'PASS').length;
    final fail = allResults.where((e) => e['result'] == 'FAIL').length;

    Map<String, dynamic>? topper;
    for (final result in allResults) {
      if (topper == null ||
          _number(result['percentage']) > _number(topper['percentage'])) {
        topper = result;
      }
    }

    final progress = _groupProgress(group);
    final expected = _groupExpected(group);
    final completed = _groupCompleted(group);
    final classes = group
        .map((e) => e['studentClass']?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openExamGroup(group),
      child: Ink(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF172229),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.orangeAccent.withOpacity(0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFFA726), Color(0xFFFF7043)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.fact_check_rounded,
                    color: Colors.black,
                    size: 25,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        examName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${group.length} class${group.length == 1 ? '' : 'es'} • ${subjectSet.length} unique subjects',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                _smallPill(
                  expected > 0 && completed >= expected
                      ? 'COMPLETE'
                      : completed > 0
                          ? 'IN PROGRESS'
                          : 'READY',
                  expected > 0 && completed >= expected
                      ? const Color(0xFF00D9A5)
                      : completed > 0
                          ? Colors.orangeAccent
                          : const Color(0xFF38A8FF),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: classes
                  .map(
                    (className) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F191F),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Text(
                        className,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: LinearProgressIndicator(
                      minHeight: 8,
                      value: progress,
                      backgroundColor: Colors.white10,
                      color: const Color(0xFF00D9A5),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  expected <= 0 ? '$completed results' : '$completed/$expected',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                _smallPill('Results ${allResults.length}', const Color(0xFF38A8FF)),
                _smallPill('Pass $pass', const Color(0xFF00D9A5)),
                _smallPill('Fail $fail', Colors.redAccent),
                if (topper != null)
                  _smallPill(
                    'Top ${topper['studentName'] ?? ''} • ${_number(topper['percentage']).toStringAsFixed(1)}%',
                    Colors.amberAccent,
                  ),
              ],
            ),
            if (subjectSet.isNotEmpty) ...[
              const SizedBox(height: 11),
              Text(
                'Subjects: ${subjectSet.take(8).join(' • ')}${subjectSet.length > 8 ? ' • +${subjectSet.length - 8}' : ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white30,
                  fontSize: 9.2,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00A884),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => _openExamGroup(group),
                icon: const Icon(Icons.dashboard_customize_rounded, size: 17),
                label: const Text('Manage Classes'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _performanceOverview() {
    final byClass = <String, List<double>>{};
    for (final result in _results) {
      final className = result['studentClass']?.toString().trim() ?? '';
      if (className.isEmpty) continue;
      byClass.putIfAbsent(className, () => <double>[]);
      byClass[className]!.add(_number(result['percentage']));
    }

    final classes = byClass.keys.toList()
      ..sort((a, b) => _classNumber(a).compareTo(_classNumber(b)));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            'Performance Overview',
            'Average percentage by class',
            Icons.bar_chart_rounded,
          ),
          const SizedBox(height: 14),
          if (classes.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 26),
              child: Center(
                child: Text(
                  'Marks save hone ke baad class performance yahan dikhega.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 10.5),
                ),
              ),
            )
          else
            ...classes.map((className) {
              final values = byClass[className]!;
              final average = values.isEmpty
                  ? 0.0
                  : values.fold<double>(0, (sum, value) => sum + value) /
                      values.length;
              final factor = (average / 100).clamp(0.0, 1.0).toDouble();

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 58,
                      child: Text(
                        className,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) => Stack(
                          children: [
                            Container(
                              height: 8,
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                            Container(
                              width: constraints.maxWidth * factor,
                              height: 8,
                              decoration: BoxDecoration(
                                color: const Color(0xFF00D9A5),
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 46,
                      child: Text(
                        '${average.toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _recentResults() {
    final recent = List<Map<String, dynamic>>.from(_results)
      ..sort((a, b) =>
          _timestamp(b['timestamp']).compareTo(_timestamp(a['timestamp'])));
    final items = recent.take(6).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            'Recent Results',
            'Latest saved student results',
            Icons.history_edu_rounded,
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'Abhi koi result save nahi hua.',
                  style: TextStyle(color: Colors.white38, fontSize: 10.5),
                ),
              ),
            )
          else
            ...items.map((result) {
              final passed = result['result'] == 'PASS';
              final reportUrl =
                  result['reportCardUrl']?.toString().trim() ?? '';

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F191F),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      passed ? Icons.check_circle_rounded : Icons.cancel_rounded,
                      color: passed
                          ? const Color(0xFF00D9A5)
                          : Colors.redAccent,
                      size: 18,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            result['studentName']?.toString() ?? 'Student',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            '${result['studentClass'] ?? ''} • ${result['examName'] ?? 'Exam'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${_number(result['percentage']).toStringAsFixed(1)}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (result.isNotEmpty)
                      IconButton(
                        tooltip: WindowsUiLanguage.translate('Open Report Card'),
                        onPressed: () async {if(!await WindowsDocumentTemplates.previewReport(context,result))html.window.open(reportUrl, '_blank');},
                        icon: const Icon(
                          Icons.picture_as_pdf_rounded,
                          color: Colors.orangeAccent,
                          size: 18,
                        ),
                      ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _emptyState() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 42),
        decoration: BoxDecoration(
          color: const Color(0xFF172229),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.add_task_rounded,
              color: Colors.orangeAccent,
              size: 46,
            ),
            const SizedBox(height: 13),
            const Text(
              'Create your first exam',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'Final Exam, Half Yearly, Unit Test — ek exam ke andar Class 1–10 customize karein.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 10.5),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00A884),
                foregroundColor: Colors.white,
              ),
              onPressed: _saving ? null : _createExam,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create Exam'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final groups = _examGroups();
    final passTotal = _results.where((e) => e['result'] == 'PASS').length;
    final failTotal = _results.where((e) => e['result'] == 'FAIL').length;
    final totalResults = passTotal + failTotal;
    final passRate = totalResults == 0 ? 0.0 : passTotal / totalResults * 100;
    final pendingMarks =
        _exams.fold<int>(0, (sum, exam) => sum + _pendingForExam(exam));

    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111B22),
        elevation: 0,
        title: const Text(
          'Exam Center',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF172229),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.calendar_month_rounded,
                    color: Color(0xFF00D9A5),
                    size: 15,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _academicYear(),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: WindowsUiLanguage.translate('Refresh'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00A884)),
            )
          : RefreshIndicator(
                  onRefresh: _load,
                  color: const Color(0xFF00A884),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 100),
                    children: [
                      if (_error != null) ListTile(leading: const Icon(Icons.cloud_off, color: Colors.orange), title: Text(_error!), trailing: TextButton(onPressed: _load, child: const Text('Retry'))),
                      const Text('Exam tools work offline. With Local Data OFF, offline edits last only for this session. Enable Local Data to keep them on this PC.', style: TextStyle(color: Colors.orangeAccent)),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF11343A),
                              Color(0xFF172229),
                              Color(0xFF2A2417),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.orangeAccent.withOpacity(0.18),
                          ),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final compact = constraints.maxWidth < 680;
                            final intro = Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Examination Dashboard',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                const Text(
                                  'Plan • Conduct • Evaluate • Generate Report Cards',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 10.5,
                                  ),
                                ),
                                const SizedBox(height: 11),
                                const Text(
                                  'Ek Final Exam create karke Class 1–10 ko ek hi exam card ke andar class-wise subjects, full marks aur pass marks ke saath customize karein.',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 11,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            );
                            return intro;
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _metricCard(
                            title: 'Total Exams',
                            value: '${groups.length}',
                            subtitle: '${_exams.length} class configurations',
                            icon: Icons.assignment_rounded,
                            color: Colors.orangeAccent,
                          ),
                          _metricCard(
                            title: 'Results Entered',
                            value: '${_results.length}',
                            subtitle: 'Student result records',
                            icon: Icons.edit_note_rounded,
                            color: const Color(0xFF38A8FF),
                          ),
                          _metricCard(
                            title: 'Pass Rate',
                            value: '${passRate.toStringAsFixed(1)}%',
                            subtitle: '$passTotal pass • $failTotal fail',
                            icon: Icons.trending_up_rounded,
                            color: const Color(0xFF00D9A5),
                          ),
                          _metricCard(
                            title: 'Pending Marks',
                            value: '$pendingMarks',
                            subtitle: 'Student results remaining',
                            icon: Icons.pending_actions_rounded,
                            color: Colors.purpleAccent,
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth >= 980;

                          final main = Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFF111B22),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: _sectionHeader(
                                        'Exam Groups',
                                        'Final Exam / Half Yearly / Unit Test — class-wise settings inside',
                                        Icons.view_agenda_rounded,
                                      ),
                                    ),
                                    if (groups.isNotEmpty) ...[
                                      const SizedBox(width: 12),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor:
                                              const Color(0xFF00A884),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 11,
                                          ),
                                        ),
                                        onPressed:
                                            _saving ? null : _createExam,
                                        icon: const Icon(
                                          Icons.add_rounded,
                                          size: 17,
                                        ),
                                        label: const Text(
                                          'Create Exam',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 14),
                                if (groups.isEmpty)
                                  _emptyState()
                                else
                                  ...groups.map(
                                    (group) => Padding(
                                      padding: const EdgeInsets.only(bottom: 10),
                                      child: _examGroupCard(group),
                                    ),
                                  ),
                              ],
                            ),
                          );

                          final side = Column(
                            children: [
                              _performanceOverview(),
                              const SizedBox(height: 12),
                              _recentResults(),
                            ],
                          );

                          if (!wide) {
                            return Column(
                              children: [
                                main,
                                const SizedBox(height: 12),
                                side,
                              ],
                            );
                          }

                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 7, child: main),
                              const SizedBox(width: 12),
                              Expanded(flex: 4, child: side),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
    );
  }
}

class ExamMarksEntryScreen extends StatefulWidget {
  final Map<String, dynamic> exam;

  const ExamMarksEntryScreen({
    super.key,
    required this.exam,
  });

  @override
  State<ExamMarksEntryScreen> createState() =>
      _ExamMarksEntryScreenState();
}

class _ExamMarksEntryScreenState
    extends State<ExamMarksEntryScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _results = [];

  String get _examId =>
      widget.exam['examId']?.toString() ?? '';
  String get _examName =>
      widget.exam['examName']?.toString() ?? 'Exam';
  String get _studentClass =>
      widget.exam['studentClass']?.toString() ?? '';

  double get _fullMarks =>
      (widget.exam['fullMarks'] as num?)?.toDouble() ??
      double.tryParse(widget.exam['fullMarks']?.toString() ?? '') ??
      0;

  double get _passMarks =>
      (widget.exam['passMarks'] as num?)?.toDouble() ??
      double.tryParse(widget.exam['passMarks']?.toString() ?? '') ??
      0;

  List<String> get _subjects {
    final raw = widget.exam['subjects'];
    return raw is List
        ? raw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList()
        : <String>[];
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String> _scriptUrl() async {
    return _windowsGoogleScriptUrl();
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final result = await WindowsExamService.request(body);
    if (result['success'] != true) throw StateError(result['message']?.toString() ?? 'Exam operation failed');
    return result;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _post({'action': 'list_exam_center'});
      final raw = result['results'];
      final all = raw is List
          ? raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _results = all
            .where((e) => e['examId']?.toString() == _examId)
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Map<String, dynamic>? _resultFor(String studentId) {
    for (final result in _results) {
      if (result['studentId']?.toString() == studentId) return result;
    }
    return null;
  }

  Future<void> _enterMarks(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final student = await SchoolPersonIdentity.ensure('students_directory',doc.id);
    final existing = _resultFor(doc.id);
    final existingMarks = existing?['marks'] is Map
        ? Map<String, dynamic>.from(existing!['marks'] as Map)
        : <String, dynamic>{};

    final controllers = <String, TextEditingController>{
      for (final subject in _subjects)
        subject: TextEditingController(
          text: existingMarks[subject]?.toString() ?? '',
        ),
    };

    String? dialogError;
    bool saving = false;

    var savedOffline = false;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF172229),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(student['name']?.toString() ?? 'Student', translate: false,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                '$_studentClass • Roll ${student['rollNo'] ?? ''} • $_examName',
                style: const TextStyle(
                    color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ..._subjects.map(
                    (subject) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TextField(
                        controller: controllers[subject],
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText:
                              '$subject (0-${_fullMarks.toStringAsFixed(0)})',
                          labelStyle:
                              const TextStyle(color: Colors.white54),
                          suffixText: '/ ${_fullMarks.toStringAsFixed(0)}',
                          suffixStyle:
                              const TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: const Color(0xFF0F191F),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(11),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: Colors.orangeAccent.withOpacity(.07),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Pass rule: har subject me minimum ${_passMarks.toStringAsFixed(0)} marks. Save ke baad total, %, grade, PASS/FAIL aur Report Card PDF automatic generate hoga.',
                      style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 10,
                          height: 1.4),
                    ),
                  ),
                  if (dialogError != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        dialogError!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 11),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00A884)),
              onPressed: saving
                  ? null
                  : () async {
                      final marks = <String, double>{};
                      for (final subject in _subjects) {
                        final value = double.tryParse(
                            controllers[subject]!.text.trim());
                        if (value == null ||
                            value < 0 ||
                            value > _fullMarks) {
                          setDialogState(() => dialogError =
                              '$subject marks invalid hain.');
                          return;
                        }
                        marks[subject] = value;
                      }

                      setDialogState(() {
                        saving = true;
                        dialogError = null;
                      });

                      try {
                        final resultStatus=marks.values.every((m)=>m>=_passMarks)?'PASS':'FAIL';
                        final isFinal=await SchoolPromotionService.isFinal(widget.exam);
                        final total=marks.values.fold<double>(0,(a,b)=>a+b);
                        final resultData={'examId':_examId,'examName':_examName,'studentId':doc.id,'personId':student['mobileStableId'] ?? doc.id,'studentName':student['name'] ?? '', 'studentClass':_studentClass,'rollNo':student['rollNo'] ?? '', 'marks':marks,'fullMarks':_fullMarks,'passMarks':_passMarks,'totalMarks':total,'percentage':_subjects.isEmpty?0:total/(_subjects.length*_fullMarks)*100,'result':resultStatus,'isFinal':isFinal,'timestamp':DateTime.now().millisecondsSinceEpoch};
                        final savedResult = await _post({
                          'action': 'save_exam_result',
                          ...resultData,
                          'examId': _examId,
                          'studentId': doc.id,
                          'studentName':
                              student['name']?.toString() ?? '',
                          'studentClass': _studentClass,
                          'rollNo': student['rollNo']?.toString() ?? '',
                          'marks': marks,
                          'updatedBy':
                              FirebaseAuth.instance.currentUser?.email ??
                                  'Admin',
                        });
                        await FirebaseFirestore.instance.collection('exam_results').doc('${_examId}_${doc.id}').set(resultData);
                        savedOffline = savedResult['windowsLocalFallback'] == true;
                        if(isFinal){
                          try{await SchoolPromotionService.apply(studentId:doc.id,student:student,exam:{...widget.exam,'isFinal':true},result:resultStatus);}
                          catch(e){await FirebaseFirestore.instance.collection('students_directory').doc(doc.id).set({'promotionPending':true,'promotionError':'$e'},SetOptions(merge:true));}
                        }
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx, true);
                      } catch (e) {
                        setDialogState(() {
                          saving = false;
                          dialogError = 'Save error: $e';
                        });
                      }
                    },
              icon: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.save_rounded,
                      color: Colors.white, size: 17),
              label: Text(
                saving ? 'Saving...' : 'Save & Generate Report Card',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );

    for (final controller in controllers.values) {
      controller.dispose();
    }

    if (saved == true && mounted) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00A884),
          content: Text(
              savedOffline ? 'Marks saved offline. Google report card generation is pending school connection.' : 'Marks saved aur report card Google Drive me generate ho gaya.'),
        ),
      );
    }
  }

  Widget _metric(String label, String value, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: color.withOpacity(.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(.18)),
        ),
        child: Text(
          '$label: $value',
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w800),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final pass =
        _results.where((e) => e['result'] == 'PASS').length;
    final fail =
        _results.where((e) => e['result'] == 'FAIL').length;
    final average = _results.isEmpty
        ? 0.0
        : _results.fold<double>(
              0,
              (sum, e) =>
                  sum +
                  ((e['percentage'] as num?)?.toDouble() ?? 0),
            ) /
            _results.length;

    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: Text('$_examName • $_studentClass'),
        actions: [
          IconButton(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: const Color(0xFF121F26),
            padding: const EdgeInsets.all(11),
            child: Wrap(
              spacing: 9,
              runSpacing: 8,
              children: [
                _metric('Results', '${_results.length}',
                    const Color(0xFF38A8FF)),
                _metric('Pass', '$pass', const Color(0xFF00D9A5)),
                _metric('Fail', '$fail', Colors.redAccent),
                _metric('Average', '${average.toStringAsFixed(1)}%',
                    Colors.orangeAccent),
              ],
            ),
          ),
          if (_loading)
            const Expanded(
              child: Center(
                  child: CircularProgressIndicator(
                      color: Color(0xFF00A884))),
            )
          else if (_error != null)
            Expanded(
              child: Center(
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            )
          else
            Expanded(
              child: StreamBuilder<
                  QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('students_directory')
                    .where('class', isEqualTo: _studentClass)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState ==
                          ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFF00A884)),
                    );
                  }

                  final students = snapshot.data?.docs.toList() ?? [];
                  students.sort((a, b) {
                    final ar = int.tryParse(
                            a.data()['rollNo']?.toString() ?? '') ??
                        999999;
                    final br = int.tryParse(
                            b.data()['rollNo']?.toString() ?? '') ??
                        999999;
                    return ar.compareTo(br);
                  });

                  if (students.isEmpty) {
                    return const Center(
                      child: Text('Is class me koi student nahi mila.',
                          style: TextStyle(color: Colors.white54)),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: students.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final doc = students[index];
                      final student = doc.data();
                      final result = _resultFor(doc.id);
                      final reportUrl =
                          result?['reportCardUrl']?.toString().trim() ??
                              '';
                      final passed = result?['result'] == 'PASS';

                      return Container(
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: const Color(0xFF172229),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor:
                                  const Color(0xFF00A884).withOpacity(.13),
                              foregroundColor: const Color(0xFF00D9A5),
                              child: Text(
                                student['name']
                                            ?.toString()
                                            .isNotEmpty ==
                                        true
                                    ? student['name']
                                        .toString()
                                        .substring(0, 1)
                                        .toUpperCase()
                                    : 'S',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    student['name']?.toString() ??
                                        'Student',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    'Roll ${student['rollNo'] ?? ''}'
                                    '${result == null ? ' • Marks pending' : ' • ${result['total'] ?? 0}/${result['maximum'] ?? 0} • ${result['percentage'] ?? 0}% • Grade ${result['grade'] ?? ''}'}',
                                    style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 10),
                                  ),
                                ],
                              ),
                            ),
                            if (result != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: (passed
                                          ? const Color(0xFF00A884)
                                          : Colors.redAccent)
                                      .withOpacity(.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  result['result']?.toString() ?? '',
                                  style: TextStyle(
                                      color: passed
                                          ? const Color(0xFF00D9A5)
                                          : Colors.redAccent,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w900),
                                ),
                              ),
                            if (result != null)
                              IconButton(
                                tooltip: WindowsUiLanguage.translate('Report Card PDF'),
                                onPressed: () async {if(!await WindowsDocumentTemplates.previewReport(context,result!))html.window.open(reportUrl, '_blank');},
                                icon: const Icon(
                                    Icons.picture_as_pdf_rounded,
                                    color: Colors.orangeAccent),
                              ),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      const Color(0xFF00A884)),
                              onPressed: () => _enterMarks(doc),
                              icon: Icon(
                                result == null
                                    ? Icons.add_rounded
                                    : Icons.edit_rounded,
                                color: Colors.white,
                                size: 16,
                              ),
                              label: Text(
                                result == null
                                    ? 'Enter Marks'
                                    : 'Edit Marks',
                                style: const TextStyle(
                                    color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}




class WindowsSchoolExpensesScreen extends StatefulWidget {
  const WindowsSchoolExpensesScreen({super.key});

  @override
  State<WindowsSchoolExpensesScreen> createState() => _WindowsSchoolExpensesScreenState();
}

class _WindowsSchoolExpensesScreenState extends State<WindowsSchoolExpensesScreen> {
  final List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> body) async {
    final scriptUrl = await _windowsGoogleScriptUrl();
    final response = await WindowsBackendBridge.post(
      Uri.parse(scriptUrl),
      headers: const {'Content-Type': 'text/plain;charset=utf-8'},
      body: jsonEncode(body),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw StateError('Expense backend response invalid hai.');
    final result = Map<String, dynamic>.from(decoded);
    if (result['success'] != true) throw StateError(result['message']?.toString() ?? 'Expense operation failed.');
    return result;
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final result = await _call(const {'action': 'list_school_expenses'});
      final raw = result['expenses'];
      final list = raw is List
          ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];
      list.sort((a,b) => (b['timestamp'] as num? ?? 0).compareTo(a['timestamp'] as num? ?? 0));
      if (!mounted) return;
      setState(() { _items..clear()..addAll(list); _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  double get _total => _items.fold<double>(0, (sum, item) => sum + (double.tryParse(item['amount']?.toString() ?? '') ?? 0));

  Future<void> _addExpense() async {
    final title = TextEditingController();
    final amount = TextEditingController();
    final paidTo = TextEditingController();
    final note = TextEditingController();
    String category = 'General';
    bool saving = false;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          backgroundColor: const Color(0xFF172229),
          title: const Text('Add School Expense', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: title, decoration: const InputDecoration(labelText: 'Expense Title')),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount ₹'))),
                  const SizedBox(width: 10),
                  Expanded(child: DropdownButtonFormField<String>(
                    value: category,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: const ['General','Electricity','Salary','Maintenance','Stationery','Transport','Event','Other']
                        .map((e) => DropdownMenuItem(value:e, child:Text(e))).toList(),
                    onChanged: (v) { if (v != null) setDlg(() => category = v); },
                  )),
                ]),
                const SizedBox(height: 10),
                TextField(controller: paidTo, decoration: const InputDecoration(labelText: 'Paid To / Vendor')),
                const SizedBox(height: 10),
                TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Note')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: saving ? null : () async {
                final value = double.tryParse(amount.text.trim());
                if (title.text.trim().isEmpty || value == null || value <= 0) return;
                setDlg(() => saving = true);
                try {
                  await _call({
                    'action':'save_school_expense',
                    'expenseId':'EXP-${DateTime.now().millisecondsSinceEpoch}',
                    'title':title.text.trim(),
                    'category':category,
                    'amount':value,
                    'paidTo':paidTo.text.trim(),
                    'note':note.text.trim(),
                    'dateText':DateTime.now().toIso8601String().split('T').first,
                    'timestamp':DateTime.now().millisecondsSinceEpoch,
                  });
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('$e')));
                    setDlg(() => saving = false);
                  }
                }
              },
              child: Text(saving ? 'Saving...' : 'Save Expense'),
            ),
          ],
        ),
      ),
    );
    title.dispose(); amount.dispose(); paidTo.dispose(); note.dispose();
    if (saved == true) await _load();
  }

  Future<void> _delete(Map<String,dynamic> item) async {
    final id = item['expenseId']?.toString() ?? '';
    if (id.isEmpty) return;
    await _call({'action':'delete_school_expense','expenseId':id});
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        title: Text(windowsTr('expenses')),
        actions:[
          IconButton(onPressed:_load, icon:const Icon(Icons.refresh_rounded)),
          const SizedBox(width:6),
          Padding(
            padding: const EdgeInsets.only(right:12),
            child: FilledButton.icon(onPressed:_addExpense, icon:const Icon(Icons.add_rounded), label:const Text('Add Expense')),
          ),
        ],
      ),
      body: _loading
          ? const Center(child:CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children:[
                  Row(children:[
                    _WindowsMetricCard(icon:Icons.account_balance_wallet_rounded, label:'Total Expenses', value:'₹${_total.toStringAsFixed(2)}', color:Colors.amberAccent),
                    const SizedBox(width:12),
                    _WindowsMetricCard(icon:Icons.receipt_long_rounded, label:'Entries', value:'${_items.length}', color:const Color(0xFF69C2FF)),
                  ]),
                  if (_error != null) Padding(padding:const EdgeInsets.all(10), child:Text(_error!, style:const TextStyle(color:Colors.redAccent))),
                  const SizedBox(height:14),
                  Expanded(
                    child: _items.isEmpty
                        ? const Center(child:Text('Abhi koi school expense entry nahi hai.', style:TextStyle(color:Colors.white38)))
                        : ListView.separated(
                            itemCount:_items.length,
                            separatorBuilder:(_,__)=>const SizedBox(height:8),
                            itemBuilder:(context,index){
                              final e=_items[index];
                              return Container(
                                padding:const EdgeInsets.all(14),
                                decoration:BoxDecoration(color:const Color(0xFF111B21), borderRadius:BorderRadius.circular(14), border:Border.all(color:Colors.white10)),
                                child:Row(children:[
                                  const CircleAvatar(backgroundColor:Color(0x3321C98B), child:Icon(Icons.payments_rounded,color:Color(0xFF00D9A5))),
                                  const SizedBox(width:12),
                                  Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                                    Text(e['title']?.toString() ?? 'Expense', style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w800)),
                                    const SizedBox(height:4),
                                    Text('${e['category'] ?? 'General'} • ${e['dateText'] ?? ''}${(e['paidTo']?.toString().trim().isNotEmpty ?? false) ? ' • ${e['paidTo']}' : ''}', style:const TextStyle(color:Colors.white38,fontSize:10.5)),
                                    if (e['note']?.toString().trim().isNotEmpty == true) Text(e['note'].toString(), style:const TextStyle(color:Colors.white54,fontSize:10.5)),
                                  ])),
                                  Text('₹${(double.tryParse(e['amount']?.toString() ?? '') ?? 0).toStringAsFixed(2)}', style:const TextStyle(color:Colors.amberAccent,fontSize:16,fontWeight:FontWeight.w900)),
                                  IconButton(onPressed:()=>_delete(e), icon:const Icon(Icons.delete_outline_rounded,color:Colors.redAccent)),
                                ]),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}

class WindowsAttendanceScreen extends StatefulWidget {
  const WindowsAttendanceScreen({super.key});

  @override
  State<WindowsAttendanceScreen> createState() => _WindowsAttendanceScreenState();
}

class _WindowsAttendanceScreenState extends State<WindowsAttendanceScreen> {
  final TextEditingController _qr = TextEditingController();
  bool _busy = false;
  String _mode = 'entry';
  String _status = 'QR scan/paste karein.';
  double? _distance;

  @override
  void dispose(){ _qr.dispose(); super.dispose(); }

  Future<Map<String,dynamic>> _call(Map<String,dynamic> body) async {
    final scriptUrl = await _windowsGoogleScriptUrl();
    final response = await WindowsBackendBridge.post(
      Uri.parse(scriptUrl),
      headers: const {'Content-Type':'text/plain;charset=utf-8'},
      body: jsonEncode(body),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw StateError('Attendance backend response invalid.');
    final result = Map<String,dynamic>.from(decoded);
    if(result['success'] != true) throw StateError(result['message']?.toString() ?? 'Attendance failed.');
    return result;
  }

  Future<void> _mark() async {
    if(_busy) return;
    final payload = _windowsParsePersonQr(_qr.text);
    if(payload == null){ setState(()=>_status='Invalid Vidya Saarthi QR.'); return; }
    setState((){_busy=true; _distance=null; _status='School + GPS verify ho raha hai...';});
    try{
      final activeProfile = await _windowsActiveSchoolProfileId();
      final qrProfile = payload['schoolProfileId']?.toString().trim() ?? '';
      if(qrProfile.isNotEmpty && qrProfile != activeProfile){
        throw StateError('Ye QR kisi doosre school ka hai. Attendance blocked.');
      }

      final type = payload['type']?.toString().trim() ?? '';
      final personId = payload['personId']?.toString().trim() ?? '';
      final qrToken = payload['linkToken']?.toString().trim() ?? '';
      final qrVersion = int.tryParse(payload['v']?.toString() ?? '') ?? 0;
      if (personId.isEmpty) throw StateError('QR person ID missing hai.');
      if (qrVersion < 2 || qrToken.isEmpty) {
        throw StateError('Old/unsafe QR attendance ke liye allowed nahi. Naya ID Card QR generate karein.');
      }
      if (type != 'student' && type != 'teacher') {
        throw StateError('QR Student/Teacher type invalid hai.');
      }

      final personCollection =
          type == 'teacher' ? 'teachers_directory' : 'students_directory';
      final personDoc = await FirebaseFirestore.instance
          .collection(personCollection)
          .doc(personId)
          .get();
      if (!personDoc.exists) {
        throw StateError('Is QR ka record active school me nahi mila.');
      }
      final savedToken = personDoc.data()?['mobileLinkToken']?.toString().trim() ?? '';
      if (savedToken.isEmpty || savedToken != qrToken) {
        throw StateError('QR security token match nahi hua. ID Card regenerate karein.');
      }

      final location = await _windowsSchoolLocationData();
      final schoolLat = double.tryParse(location['latitude']?.toString() ?? '');
      final schoolLng = double.tryParse(location['longitude']?.toString() ?? '');
      final radius = double.tryParse(location['radiusMeters']?.toString() ?? '') ?? 200.0;
      if(schoolLat == null || schoolLng == null){
        throw StateError('School Settings me school location save karein.');
      }
      final current = await _windowsCurrentPosition();
      final distance = _windowsDistanceMeters(current.latitude,current.longitude,schoolLat,schoolLng);
      _distance = distance;
      if(distance > radius){
        throw StateError('Attendance blocked: school se ${distance.toStringAsFixed(0)}m door. Allowed ${radius.toStringAsFixed(0)}m.');
      }

      Map<String,dynamic> body;
      if(type == 'teacher'){
        body={
          'action':'mark_teacher_attendance',
          'teacherId':payload['teacherId']?.toString().trim().isNotEmpty == true ? payload['teacherId'] : personId,
          'teacherName':payload['name'] ?? '',
          'mode':_mode,
          'source':'WINDOWS_QR_GEOFENCE',
          'markedBy':'Windows Admin',
          'deviceLatitude':current.latitude,
          'deviceLongitude':current.longitude,
          'distanceMeters':distance,
        };
      } else if(type == 'student'){
        body={
          'action':'mark_student_attendance',
          'studentId':personId,
          'studentName':payload['name'] ?? '',
          'studentClass':payload['class'] ?? '',
          'rollNo':payload['rollNo'] ?? '',
          'mode':_mode,
          'source':'WINDOWS_QR_GEOFENCE',
          'markedBy':'Windows Admin',
          'deviceLatitude':current.latitude,
          'deviceLongitude':current.longitude,
          'distanceMeters':distance,
        };
      } else {
        throw StateError('QR Student/Teacher type invalid hai.');
      }
      final result=await _call(body);
      if(!mounted) return;
      setState(()=>_status='${result['message'] ?? 'Attendance marked'} • ${distance.toStringAsFixed(0)}m');
      _qr.clear();
    }catch(e){
      if(!mounted) return;
      setState(()=>_status=e.toString().replaceFirst('Bad state: ',''));
    }finally{
      if(mounted) setState(()=>_busy=false);
    }
  }

  @override
  Widget build(BuildContext context){
    return Scaffold(
      backgroundColor:const Color(0xFF0B141A),
      appBar:AppBar(title:Text(windowsTr('attendance'))),
      body:Center(
        child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:820),
          child:ListView(
            padding:const EdgeInsets.all(20),
            children:[
              Container(
                padding:const EdgeInsets.all(18),
                decoration:BoxDecoration(color:const Color(0xFF111B21),borderRadius:BorderRadius.circular(18),border:Border.all(color:const Color(0xFF69C2FF).withOpacity(.2))),
                child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  const Text('Student / Teacher QR Attendance',style:TextStyle(color:Colors.white,fontSize:20,fontWeight:FontWeight.w900)),
                  const SizedBox(height:6),
                  const Text('USB QR scanner se scan karein ya QR text paste karein. Active school identity + Windows GPS 200m geofence verify hoga.',style:TextStyle(color:Colors.white54,height:1.4)),
                  const SizedBox(height:16),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value:'entry',label:Text('Entry'),icon:Icon(Icons.login_rounded)),
                      ButtonSegment(value:'exit',label:Text('Exit'),icon:Icon(Icons.logout_rounded)),
                    ],
                    selected:{_mode},
                    onSelectionChanged:(v)=>setState(()=>_mode=v.first),
                  ),
                  const SizedBox(height:14),
                  TextField(
                    controller:_qr,
                    minLines:3,
                    maxLines:6,
                    autofocus:true,
                    decoration:const InputDecoration(labelText:'Scan / Paste ID Card QR',prefixIcon:Icon(Icons.qr_code_scanner_rounded)),
                    onSubmitted:(_)=>_mark(),
                  ),
                  const SizedBox(height:12),
                  SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:_busy?null:_mark,icon:_busy?const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2,color:Colors.white)):const Icon(Icons.verified_rounded),label:Text(_busy?'Verifying...':'Verify Location & Mark Attendance'))),
                  const SizedBox(height:12),
                  Container(
                    width:double.infinity,
                    padding:const EdgeInsets.all(12),
                    decoration:BoxDecoration(color:const Color(0xFF0F191F),borderRadius:BorderRadius.circular(12)),
                    child:Text(_status,style:TextStyle(color:_status.toLowerCase().contains('blocked')||_status.toLowerCase().contains('invalid')?Colors.redAccent:const Color(0xFF00D9A5))),
                  ),
                ]),
              ),
              const SizedBox(height:14),
              const Text('Security: QR ke andar location hone se attendance approve nahi hoti. Actual Windows device GPS school location se distance calculate karta hai.',style:TextStyle(color:Colors.white38,fontSize:10.5)),
            ],
          ),
        ),
      ),
    );
  }
}

class WindowsTemplatesScreen extends StatefulWidget {
  const WindowsTemplatesScreen({super.key});
  @override
  State<WindowsTemplatesScreen> createState()=>_WindowsTemplatesScreenState();
}

class _WindowsTemplatesScreenState extends State<WindowsTemplatesScreen>{
  int _section=0;
  final List<String> _studentIdTemplates = const ['Portrait Classic','Portrait Modern','Portrait Green','Portrait Purple','Landscape Classic','Landscape Modern','Landscape Blue','Landscape Premium'];
  final List<String> _reportTemplates = const ['Academic Classic','Modern Result','Compact Marks','Formal Board'];
  final List<String> _receiptTemplates = const ['Compact Receipt','A4 Receipt','Thermal Style','Premium Receipt'];

  @override
  Widget build(BuildContext context){
    final items=_section==0?_studentIdTemplates:_section==1?_reportTemplates:_receiptTemplates;
    return Scaffold(
      backgroundColor:const Color(0xFF0B141A),
      appBar:AppBar(title:Text(windowsTr('templates'))),
      body:Padding(
        padding:const EdgeInsets.all(16),
        child:Column(children:[
          SegmentedButton<int>(
            segments:const [
              ButtonSegment(value:0,label:Text('ID Cards'),icon:Icon(Icons.badge_rounded)),
              ButtonSegment(value:1,label:Text('Report Cards'),icon:Icon(Icons.description_rounded)),
              ButtonSegment(value:2,label:Text('Receipts'),icon:Icon(Icons.receipt_long_rounded)),
            ],
            selected:{_section},onSelectionChanged:(v)=>setState(()=>_section=v.first),
          ),
          const SizedBox(height:16),
          Expanded(child:GridView.builder(
            gridDelegate:const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent:320,mainAxisExtent:210,crossAxisSpacing:12,mainAxisSpacing:12),
            itemCount:items.length + (_section==0?2:0),
            itemBuilder:(context,index){
              final isTeacher=_section==0 && index>=items.length;
              final title=isTeacher?'Teacher ID ${index-items.length+1}':items[index];
              final accent=isTeacher?Colors.purpleAccent:_section==1?Colors.orangeAccent:_section==2?Colors.greenAccent:const Color(0xFF69C2FF);
              return Container(
                padding:const EdgeInsets.all(14),
                decoration:BoxDecoration(color:const Color(0xFF111B21),borderRadius:BorderRadius.circular(16),border:Border.all(color:accent.withOpacity(.25))),
                child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Row(children:[Icon(isTeacher?Icons.school_rounded:_section==0?Icons.badge_rounded:_section==1?Icons.description_rounded:Icons.receipt_long_rounded,color:accent),const Spacer(),Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:3),decoration:BoxDecoration(color:accent.withOpacity(.12),borderRadius:BorderRadius.circular(20)),child:Text('LIVE',style:TextStyle(color:accent,fontSize:9,fontWeight:FontWeight.w900)))]),
                  const Spacer(),
                  Container(height:86,width:double.infinity,decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(10)),child:Center(child:Icon(_section==0?Icons.qr_code_2_rounded:_section==1?Icons.auto_stories_rounded:Icons.receipt_rounded,color:accent,size:50))),
                  const Spacer(),
                  Text(title,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w800)),
                  Text(isTeacher?'Dedicated Teacher QR ID template':_section==0?'Student QR ID template':_section==1?'Report card layout ready':'Fee receipt layout ready',style:const TextStyle(color:Colors.white38,fontSize:9.5)),
                ]),
              );
            },
          )),
        ]),
      ),
    );
  }
}

class _WindowsMetricCard extends StatelessWidget{
  const _WindowsMetricCard({required this.icon,required this.label,required this.value,required this.color});
  final IconData icon; final String label; final String value; final Color color;
  @override
  Widget build(BuildContext context)=>Expanded(child:Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF111B21),borderRadius:BorderRadius.circular(14),border:Border.all(color:color.withOpacity(.18))),child:Row(children:[Icon(icon,color:color,size:28),const SizedBox(width:12),Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:const TextStyle(color:Colors.white54,fontSize:10)),const SizedBox(height:3),Text(value,style:TextStyle(color:color,fontSize:18,fontWeight:FontWeight.w900))])])));
}
