import 'mobile/complaint_screen.dart';
import 'qr_authentication_engine.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'mobile/dob_input_formatter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import 'mobile/school_session.dart';
import 'mobile/published_id_card.dart';
import 'mobile/attendance_history.dart';
import 'platform/github_updates.dart';
import 'mobile/settings_screen.dart';
import 'mobile/school_notifications.dart';
import 'mobile/school_messaging.dart';
import 'mobile/startup_gate.dart';
import 'mobile/attendance_background.dart';
import 'attendance_schedule.dart';
import 'school_document_renderer.dart';

@pragma('vm:entry-point')
Future<void> _backgroundNotice(RemoteMessage message) async {
  await SchoolSession.instance.restore();
  if (!SchoolSession.instance.loggedIn) return;
  try {
    await Firebase.initializeApp();
    if (SchoolNotifications.belongsToSession(
      message.data,
      SchoolSession.instance.link?.projectId,
    )) {
      await SchoolNotifications.show(message);
      try {
        await SchoolSession.instance.flushAttendance().timeout(
          const Duration(seconds: 20),
        );
      } catch (_) {}
    }
  } catch (_) {}
}

final _messenger = GlobalKey<ScaffoldMessengerState>();
StreamSubscription<String>? _messagingTokenChanges;
Future<void> _registerManagedNotifications() async {
  if (!SchoolMessaging.ready || SchoolSession.instance.link?.managed != true)
    return;
  _messagingTokenChanges ??= FirebaseMessaging.instance.onTokenRefresh.listen((
    token,
  ) {
    unawaited(
      SchoolSession.instance
          .registerNotificationDevice(token)
          .catchError((_) {}),
    );
  });
  final token = await FirebaseMessaging.instance.getToken();
  if (token != null)
    await SchoolSession.instance.registerNotificationDevice(token);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MobileStartupGate(
      restore: SchoolSession.instance.restore,
      readyBuilder: (_) => const SaarthiMobileApp(),
      onReady: () {
        unawaited(initializeAttendanceBackground());
        unawaited(_initializeMobileNotifications().catchError((_) {}));
      },
    ),
  );
}

Future<void> _initializeMobileNotifications() async {
  await SchoolNotifications.initialize();
  try {
    await SchoolMessaging.configure(
      SchoolSession.instance.messaging,
      centralSchool: SchoolSession.instance.link?.managed == true,
    );
    await _registerManagedNotifications();
  } catch (_) {}
  FirebaseMessaging.onBackgroundMessage(_backgroundNotice);
  try {
    if (SchoolMessaging.ready)
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
  } catch (_) {}
  FirebaseMessaging.onMessage.listen((m) {
    final school = SchoolSession.instance.link?.projectId;
    if (SchoolNotifications.belongsToSession(m.data, school)) {
      unawaited(SchoolNotifications.show(m).catchError((_) {}));
    }
  });
}

class SaarthiMobileApp extends StatelessWidget {
  const SaarthiMobileApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Vidya Saarthi',
    scaffoldMessengerKey: _messenger,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF00D9A5),
        surface: Color(0xFF172229),
      ),
      scaffoldBackgroundColor: const Color(0xFF0B141A),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(),
      ),
    ),
    home: SchoolSession.instance.loggedIn
        ? const _SchoolDashboard()
        : const _SchoolLogin(),
  );
}

class _QrScanner extends StatefulWidget {
  const _QrScanner();
  @override
  State<_QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<_QrScanner> {
  final _capture = QrAuthenticationEngine();
  final _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    autoZoom: true,
  );
  bool _torchOn = false, _choosingImage = false;
  double _zoom = 1;
  void _accept(List<Barcode> barcodes) {
    if (_capture.paused) return;
    for (final code in barcodes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      try {
        final link = _capture.capture(raw);
        if (link == null) return;
        // Scanner disposal on route exit: no artificial 2-second stop wait.
        if (mounted) Navigator.pop(context, link);
        return;
      } catch (_) {
        if (mounted) setState(() =>
          _error = 'Invalid or older ID QR. Ask your school to regenerate this card.');
        return;
      }
    }
  }
  Future<void> _gallery() async {
    if (_choosingImage) return;
    _choosingImage = true;
    try {
      final photo = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (photo == null || !mounted) return;
      final found = await _scanner.analyzeImage(photo.path);
      if (found == null) {
        if (mounted) setState(() => _error = 'No school ID QR found in that photo.');
      } else {
        _accept(found.barcodes);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not read that image. Choose a clear school ID QR.');
    } finally { _choosingImage = false; }
  }
  Future<void> _torch() async {
    try {
      await _scanner.toggleTorch();
      if (mounted) setState(() => _torchOn = !_torchOn);
    } catch (_) {}
  }
  Future<void> _changeZoom() async {
    final value = _zoom >= 3 ? 1.0 : _zoom + 0.5;
    try {
      await _scanner.setZoomScale(value);
      if (mounted) setState(() => _zoom = value);
    } catch (_) {}
  }
  String? _error;
  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan school ID card')),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Use the QR printed on your own student or teacher ID card.',
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(fit: StackFit.expand, children: [
              MobileScanner(
                controller: _scanner,
                onDetect: (capture) => _accept(capture.barcodes),
                errorBuilder: (context, error) => Center(
                  child: Text('Camera unavailable. Allow camera permission.\n${error.errorCode.name}',
                    textAlign: TextAlign.center),
                ),
              ),
              IgnorePointer(child: Center(child: FractionallySizedBox(
                widthFactor: .75,
                child: AspectRatio(
                  aspectRatio: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFF00D9A5),width: 3),
                    ),
                    child: const Center(
                      child: Icon(Icons.qr_code_scanner_rounded,
                        size: 44, color: Colors.white54)),
                  ),
                ),
              ))),
              Positioned(
                left: 12, right: 12, bottom: 14,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xDD0B141A),
                    borderRadius: BorderRadius.circular(22)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                      TextButton.icon(onPressed: _gallery,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Gallery')),
                      TextButton.icon(onPressed: _torch,
                        icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
                        label: const Text('Torch')),
                      TextButton.icon(onPressed: _changeZoom,
                        icon: const Icon(Icons.zoom_in),
                        label: Text('${_zoom.toStringAsFixed(1)}×')),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
                TextButton(
                  onPressed: () async {
                    try {
                      await _scanner.start().timeout(
                        const Duration(seconds: 5),
                      );
                      if (mounted)
                        setState(() {
                          _capture.retry();
                          _error = null;
                        });
                    } catch (_) {
                      if (mounted)
                        setState(
                          () => _error =
                              'Camera could not restart. Reopen the scanner and check camera permission.',
                        );
                    }
                  },
                  child: const Text('Scan again'),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _SchoolLogin extends StatefulWidget {
  const _SchoolLogin();
  @override
  State<_SchoolLogin> createState() => _SchoolLoginState();
}

class _SchoolLoginState extends State<_SchoolLogin> {
  SchoolLink? _link;
  String _class = 'Class 1';
  final _roll = TextEditingController(), _dob = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _roll.dispose();
    _dob.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final link = await Navigator.push<SchoolLink>(
      context,
      MaterialPageRoute(builder: (_) => const _QrScanner()),
    );
    if (link == null || !mounted) return;
    setState(() {
      _link = link;
      _error = null;
      _roll.clear();
      _dob.clear();
    });
    if (link.role == 'teacher') await _login();
  }

  Future<void> _login() async {
    if (_link == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SchoolSession.instance.login(
        _link!,
        studentClass: _class,
        roll: _roll.text.trim(),
        dob: _dob.text.trim(),
      );
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const _SchoolDashboard()),
      );
      // Optional notification setup must not hold an authenticated account on
      // the login screen. The native restart restores the same saved session.
      final account = SchoolSession.instance.link;
      final token = SchoolSession.instance.schoolToken;
      bool same() =>
          identical(SchoolSession.instance.link, account) &&
          SchoolSession.instance.schoolToken == token;
      final messaging = SchoolSession.instance.messaging;
      unawaited(() async {
        try {
          if (!same()) return;
          await SchoolMessaging.stop().timeout(const Duration(seconds: 5));
          if (!same()) return;
          await SchoolNotifications.clear().timeout(const Duration(seconds: 5));
          if (!same()) return;
          await SchoolMessaging.configure(
            messaging,
            centralSchool: account?.managed == true,
          ).timeout(const Duration(seconds: 10));
          if (same()) await _registerManagedNotifications();
        } catch (_) {
          _messenger.currentState?.showSnackBar(
            const SnackBar(
              content: Text(
                'Logged in. School notifications are unavailable; notices remain in your school dashboard.',
              ),
            ),
          );
        }
      }());
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(25),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.school_rounded,
                  color: Color(0xFF00D9A5),
                  size: 62,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Vidya Saarthi',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 29, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your school, connected.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54),
                ),
                const SizedBox(height: 32),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(
                    _link == null ? 'Scan your school ID' : 'Scan another ID',
                  ),
                ),
                if (_link != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    _link!.role == 'student'
                        ? 'Student login'
                        : 'Teacher login',
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    _link!.projectId,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                  if (_link!.role == 'student') ...[
                    DropdownButtonFormField<String>(
                      initialValue: _class,
                      decoration: const InputDecoration(
                        labelText: 'Select class',
                      ),
                      items: List.generate(
                        10,
                        (i) => DropdownMenuItem(
                          value: 'Class ${i + 1}',
                          child: Text('Class ${i + 1}'),
                        ),
                      ),
                      onChanged: (v) => setState(() => _class = v!),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _roll,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Roll number',
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _dob,
                      keyboardType: TextInputType.number,
                      inputFormatters: [DateOfBirthInputFormatter()],
                      decoration: const InputDecoration(
                        labelText: 'Date of birth',
                        hintText: 'DD/MM/YYYY',
                      ),
                    ),
                    const SizedBox(height: 14),
                  ] else
                    const Text(
                      'Your teacher ID QR securely identifies your school account.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  FilledButton(
                    onPressed: _busy ? null : _login,
                    child: Padding(
                      padding: const EdgeInsets.all(9),
                      child: Text(_busy ? 'Verifying school…' : 'Log in'),
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                const Text(
                  'School records are kept separate. The QR connects only to the issuing school.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _SchoolDashboard extends StatefulWidget {
  const _SchoolDashboard();
  @override
  State<_SchoolDashboard> createState() => _SchoolDashboardState();
}

class _SchoolDashboardState extends State<_SchoolDashboard>
    with WidgetsBindingObserver {
  StreamSubscription<void>? _noticeOpened;
  StreamSubscription<RemoteMessage>? _noticeReceived;
  final _s = SchoolSession.instance;
  int _page = 0;
  bool _loading = true, _busy = false, _blocked = false;
  String? _error;
  Map<String, dynamic> _data = {};
  late final _history = AttendanceHistoryController(
    load: _s.attendanceHistory,
    cached: _s.cachedAttendanceHistory,
    confirmations: _s.attendanceChanges,
    confirmationKey: () =>
        _s.lastAttendanceAck?.millisecondsSinceEpoch.toString() ?? '',
  );
  List<Map<String, dynamic>> get _attendance => _history.rows;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month),
      _selectedDay = DateTime.now();
  Timer? _timer;
  Timer? _attendanceClock;
  bool get _teacher => _s.link?.role == 'teacher';
  List<Map<String, dynamic>> _list(dynamic value) => value is List
      ? value.whereType<Map>().map((v) => Map<String, dynamic>.from(v)).toList()
      : [];
  String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String get _monthKey =>
      '${_month.year}-${_month.month.toString().padLeft(2, '0')}';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _s.attendanceChanges.addListener(_attendanceChanged);
    _history.addListener(_attendanceChanged);
    unawaited(_history.selectMonth(_monthKey));
    unawaited(_s.refreshAttendanceStatus().catchError((_) {}));
    var previousLock = _s.attendanceLockReason;
    var previousAttendanceDay = attendanceDay(DateTime.now());
    var lastQueueCheck = DateTime.now();
    _attendanceClock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed)
        return;
      final now = DateTime.now();
      if (_s.attendancePending > 0 &&
          now.difference(lastQueueCheck) >= const Duration(seconds: 5)) {
        lastQueueCheck = now;
        unawaited(_s.flushAttendance().catchError((_) {}));
      }
      final day = attendanceDay(now);
      if (day != previousAttendanceDay) {
        previousAttendanceDay = day;
        unawaited(_s.refreshAttendanceStatus().catchError((_) {}));
      }
      final lock = _s.attendanceLockReason;
      if (mounted && lock != previousLock) {
        previousLock = lock;
        setState(() {});
      }
    });
    _s.connectionChanges.addListener(_connectionChanged);
    _data = Map<String, dynamic>.from(_s.dashboard);
    _loading = _data.isEmpty;
    _load();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _presence());
    _noticeOpened = SchoolNotifications.opened.listen(
      (_) => _load(afterSignal: true),
    );
    _noticeReceived = FirebaseMessaging.onMessage.listen((m) {
      if (SchoolNotifications.belongsToSession(m.data, _s.link?.projectId))
        _load(afterSignal: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _attendanceClock?.cancel();
    _noticeOpened?.cancel();
    _noticeReceived?.cancel();
    _s.attendanceChanges.removeListener(_attendanceChanged);
    _history.removeListener(_attendanceChanged);
    _history.dispose();
    _s.connectionChanges.removeListener(_connectionChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load(afterSignal: true));
  }

  void _connectionChanged() {
    if (!mounted) return;
    setState(() {
      _data = Map<String, dynamic>.from(_s.dashboard);
      _error = _s.connectionState == SchoolConnectionState.connectionError
          ? _s.connectionMessage
          : null;
      _loading =
          _s.connectionState == SchoolConnectionState.syncing && _data.isEmpty;
    });
    if (_s.connectionState == SchoolConnectionState.connected &&
        _page == (_teacher ? 0 : 1))
      unawaited(_loadAttendance());
  }

  void _attendanceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _presence() async {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed)
      return;
    try {
      await _s.refreshAttendanceStatus();
      await _s.refreshIfIdleDue();
    } catch (_) {
      /* Session publishes its retained-cache error state. */
    }
  }

  Future<void> _load({bool afterSignal = false}) async {
    if (!mounted || _s.syncPaused) return;
    setState(() => _loading = _data.isEmpty);
    try {
      final d = await _s.refreshDashboard(afterSignal: afterSignal);
      if (mounted)
        setState(() {
          _data = Map<String, dynamic>.from(d);
          _blocked = false;
          _error = null;
        });
      if (_page == (_teacher ? 0 : 1)) unawaited(_loadAttendance());
      unawaited(_refreshPublishedCard().catchError((Object _) => null));
      unawaited(_registerManagedNotifications().catchError((_) {}));
    } on SchoolAccessDenied catch (e) {
      if (mounted)
        setState(() {
          _blocked = true;
          _error = e.message;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _blocked = !_s.cachedAccessAllowed;
          _error = _blocked
              ? 'School access needs online verification.'
              : _s.connectionState == SchoolConnectionState.connectionError
              ? _s.connectionMessage
              : null;
        });
    } finally {
      if (mounted)
        setState(
          () => _loading =
              _data.isEmpty &&
              _s.connectionState == SchoolConnectionState.syncing,
        );
    }
  }

  Future<void> _loadAttendance() => _history.selectMonth(_monthKey);

  Future<void> _logout() async {
    await _s.logout();
    if (mounted)
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const _SchoolLogin()),
        (_) => false,
      );
    // External messaging shutdown must not block navigation.
    unawaited(SchoolMessaging.stop().timeout(const Duration(seconds: 4))
      .catchError((Object _) {}));
    unawaited(SchoolNotifications.clear().timeout(const Duration(seconds: 4))
      .catchError((Object _) {}));
  }

  Widget _card(Widget child) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
  Widget _heading(String title, String subtitle) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 6),
      Text(
        subtitle,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      const SizedBox(height: 20),
    ],
  );
  bool _open(DateTime day) {
    final override = _list(
      _data['calendar'],
    ).where((d) => (d['date'] ?? d['id']) == _day(day));
    if (override.isNotEmpty && override.first['isOpen'] is bool)
      return override.first['isOpen'];
    final settings = _data['calendarSettings'] is Map
        ? _data['calendarSettings'] as Map
        : {};
    final closed = settings['closedWeekdays'] is List
        ? settings['closedWeekdays'] as List
        : [0];
    return !closed.contains(day.weekday % 7);
  }

  Future<void> _markAttendance(String mode) async {
    if (_busy || _s.attendanceLockFor(mode).isNotEmpty) return;
    setState(() => _busy = true);
    final activeLink = _s.link;
    try {
      if (activeLink == null) throw StateError('Sign in to your school first.');
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied)
        permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever)
        throw StateError('Allow location access to verify school attendance.');
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );
      if (!identical(activeLink, _s.link))
        throw StateError('School session changed.');
      final capturedAt = DateTime.now().millisecondsSinceEpoch;
      await _s.saveAttendance(
        {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy': position.accuracy,
        },
        capturedAt,
        mode,
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${mode == 'exit' ? 'Check-out' : 'Check-in'} saved.',
            ),
          ),
        );
      await _loadAttendance();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _complaint() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MobileComplaintScreen(session: _s),
      ),
    );
  }

  Future<Uint8List?>? _cardRefresh;
  Future<Uint8List?> _refreshPublishedCard() {
    if (_cardRefresh != null) return _cardRefresh!;
    final pending = _fetchPublishedCard();
    _cardRefresh = pending;
    pending.then(
      (_) {
        if (identical(_cardRefresh, pending)) _cardRefresh = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_cardRefresh, pending)) _cardRefresh = null;
      },
    );
    return pending;
  }

  Future<Uint8List?> _fetchPublishedCard() => _s.publishedIdCard();

  Future<void> _openSchoolDocument(Map<String, dynamic> document) async {
    final active = _s.link;
    try {
      final result = await _s.schoolCall('mobile_document', {
        'documentId': document['documentId'],
      });
      if (!mounted || !identical(active, _s.link)) return;
      final bytes = base64Decode(result['base64'].toString());
      if (result['documentRevision'] != document['documentRevision'] ||
          result['contentHash'] != document['contentHash'] ||
          result['mime'] != document['mimeType'] ||
          sha256.convert(bytes).toString() != document['contentHash']) {
        throw StateError(
          'Document changed. Refresh school documents and retry.',
        );
      }
      final title = document['documentName']?.toString() ?? 'School document';
      if (result['mime'] == 'application/pdf') {
        await _previewPdf(bytes, title);
      } else if ([
        'image/png',
        'image/jpeg',
        'image/webp',
      ].contains(result['mime'])) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: Text(title)),
              body: Center(
                child: InteractiveViewer(child: Image.memory(bytes)),
              ),
            ),
          ),
        );
      } else {
        throw StateError(
          'This document format cannot be previewed in the app.',
        );
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Unable to open this school document. Refresh and try again.',
            ),
          ),
        );
    }
  }

  Future<void> _openIdPdfExternally(Uint8List bytes) async {
    final owner = _s.link;
    try {
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/school-id-${sha256.convert(bytes)}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted || !identical(owner, _s.link)) return;
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to open a PDF viewer. Try Open my ID card.'),
          ),
        );
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to open your ID card. Please try again.'),
          ),
        );
    }
  }

  Future<void> _previewPdf(Uint8List pdf, String title) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: PdfPreview(
            build: (_) => pdf,
            allowPrinting: true,
            allowSharing: true,
            canChangePageFormat: false,
            canChangeOrientation: false,
          ),
        ),
      ),
    );
  }

  Future<void> _showPdf(String kind, Map<String, dynamic> d) async {
    Uint8List? previousReport;
    try {
      if (kind == 'studentId' || kind == 'teacherId') {
        final cached = await _s.cachedPdf('idCard');
        final manifest = _data['idCardPackage'];
        final expected = manifest is Map
            ? manifest['documentRevision']?.toString()
            : null;
        if (cached != null &&
            !(_data.containsKey('idCardPackage') && manifest == null) &&
            (expected == null || expected == _s.cachedPdfVersion('idCard'))) {
          unawaited(_refreshPublishedCard().catchError((Object _) => null));
          await _previewPdf(cached, 'School ID card • Front & back');
          return;
        }
        var published = await _refreshPublishedCard();
        if (published == null) {
          await _load(afterSignal: true);
          published = await _refreshPublishedCard();
        }
        if (published == null)
          throw StateError(
            'Your school is preparing your ID card. Please try again shortly.',
          );
        await _previewPdf(published, 'School ID card • Front & back');
        return;
      }
      final selections = _data['templates'] is Map
          ? _data['templates'] as Map
          : {};
      final index = (selections[kind] as num?)?.toInt() ?? -1;
      final school = _data['school'] is Map ? _data['school'] as Map : {};
      final data = {
        'schoolName': school['schoolName'] ?? school['name'] ?? _s.schoolName,
        ...d,
      };
      final reportKey =
          'report:${d['id'] ?? d['reportCardId'] ?? d['examName'] ?? 'current'}';
      final reportVersion = sha256
          .convert(utf8.encode(jsonEncode([index, school, d])))
          .toString();
      if (kind == 'reportCard') {
        previousReport = await _s.cachedPdf(reportKey);
        if (previousReport != null &&
            _s.cachedPdfVersion(reportKey) == reportVersion) {
          await _previewPdf(previousReport, 'Report card');
          return;
        }
      }
      Future<Uint8List?> asset(String kind) async {
        final r = await _s.schoolCall('mobile_asset', {'kind': kind});
        return r['available'] == true
            ? base64Decode(r['base64'].toString())
            : null;
      }

      final photo = kind == 'studentId' || kind == 'teacherId'
          ? await asset('photo')
          : null;
      final logo = await asset('logo');
      final pdf = await renderSchoolDocument(
        kind: kind,
        template: index,
        data: data,
        qr: _s.link!.rawQr,
        photo: photo,
        logo: logo,
      );
      if (kind == 'reportCard') {
        await _s.cachePdf(
          reportKey,
          reportVersion,
          pdf,
          expectedHash: sha256.convert(pdf).toString(),
        );
      }
      if (mounted)
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(
                title: Text(
                  kind == 'reportCard' ? 'Report card' : 'School ID card',
                ),
              ),
              body: PdfPreview(
                build: (_) => pdf,
                allowPrinting: true,
                allowSharing: true,
                canChangePageFormat: false,
                canChangeOrientation: false,
              ),
            ),
          ),
        );
    } catch (e) {
      if (previousReport != null &&
          e is! SchoolAccessDenied &&
          _s.cachedAccessAllowed) {
        await _previewPdf(previousReport, 'Report card • Saved copy');
        return;
      }
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _update({Map<String, dynamic>? update}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = update == null
          ? await _s.platformCall('updates/latest', {'platform': 'android'})
          : <String, dynamic>{'update': update};
      final u = r['update'];
      if (u is! Map) throw StateError('No update is published yet.');
      final installed =
          int.tryParse(
            const String.fromEnvironment('APP_BUILD', defaultValue: '0'),
          ) ??
          0;
      final available = (u['versionCode'] as num?)?.toInt() ?? 0;
      if (available <= installed) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "You’re up to date. Current: ${SchoolSession.version}; latest: ${u['versionName']}",
              ),
            ),
          );
        return;
      }
      final uri = Uri.parse(u['apkUrl'].toString());
      if (uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          !uri.path.startsWith(
            '/cscticket01-hash/Saarthi_Ai/releases/download/',
          ))
        throw StateError('Invalid update download address.');
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Update ${u['versionName']}'),
          content: SingleChildScrollView(
            child: Text(
              'Current: ${SchoolSession.version}\nLatest: ${u['versionName']}\n\nWhat’s New\n${u['whatsNew'] is List ? (u['whatsNew'] as List).join('\n') : u['releaseNotes'] ?? 'See the published release notes.'}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download'),
            ),
          ],
        ),
      );
      if (yes != true) return;
      setState(() => _busy = true);
      final dir = await getTemporaryDirectory();
      androidUpdateTransfer.value = null;
      final file = await downloadAndroidUpdate(
        Map<String, dynamic>.from(u),
        File('${dir.path}/vidya-saarthi-update.apk'),
        onProgress: (bytes, total) {
          androidUpdateTransfer.value = AndroidUpdateTransfer(bytes, total);
        },
      );
      final completed = androidUpdateTransfer.value;
      if (completed != null) {
        androidUpdateTransfer.value = AndroidUpdateTransfer(
          completed.received, completed.total, verified: true);
      }
      await OpenFilex.open(file.path);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(androidUpdateErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _home() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading('Hello, ${_s.person['name'] ?? 'Student'}', _s.schoolName),
      _card(
        Row(
          children: [
            const Icon(
              Icons.verified_user_outlined,
              color: Colors.tealAccent,
              size: 35,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _s.person['class']?.toString() ??
                        _s.person['designation']?.toString() ??
                        'School member',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    _teacher
                        ? 'Teacher ID: ${_s.person['teacherId']}'
                        : 'Roll: ${_s.person['rollNo']}',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'School notices',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 14),
      if (_list(_data['notices']).isEmpty)
        _card(const Text('No notices from your school yet.')),
      ..._list(_data['notices']).map(
        (n) => _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                n['title']?.toString() ?? 'School notice',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                n['description']?.toString() ?? n['message']?.toString() ?? '',
              ),
              if (n['category'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    n['category'].toString(),
                    style: const TextStyle(
                      color: Colors.tealAccent,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ],
  );
  Widget _attendancePage() {
    final today = attendanceIndiaTime(DateTime.now());
    final lockReason = _s.attendanceLockFor('entry');
    final exitLock = _s.attendanceLockFor('exit');
    var working = 0;
    for (
      var d = DateTime(_month.year, _month.month);
      d.month == _month.month && !d.isAfter(today);
      d = d.add(const Duration(days: 1))
    ) {
      if (_open(d)) working++;
    }
    final present = _attendance
        .where((r) => r['checkIn'] != null)
        .map((r) => r['date'])
        .toSet()
        .length;
    String time(dynamic n) {
      if (n is! num) return '—';
      final d = DateTime.fromMillisecondsSinceEpoch(n.toInt());
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Attendance', 'Your school day at a glance'),
        Row(
          children: [
            IconButton(
              onPressed: () {
                setState(
                  () => _month = DateTime(_month.year, _month.month - 1),
                );
                _loadAttendance();
              },
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                _monthKey,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            IconButton(
              onPressed:
                  _month.year == today.year && _month.month == today.month
                  ? null
                  : () {
                      setState(
                        () => _month = DateTime(_month.year, _month.month + 1),
                      );
                      _loadAttendance();
                    },
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _card(
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Column(
                children: [
                  Text(
                    _history.ready ? '$present' : '—',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text('Present days'),
                ],
              ),
              Column(
                children: [
                  Text(
                    '$working',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text('School days'),
                ],
              ),
              Column(
                children: [
                  Text(
                    !_history.ready || working == 0
                        ? '—'
                        : '${(present / working * 100).clamp(0, 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      color: Colors.tealAccent,
                    ),
                  ),
                  const Text('Attendance'),
                ],
              ),
            ],
          ),
        ),
        if (_s.attendanceScheduleLabel.isNotEmpty)
          _card(Row(children: [
            const Icon(Icons.schedule, color: Colors.tealAccent),
            const SizedBox(width: 12),
            Expanded(child: Text(_s.attendanceScheduleLabel)),
          ])),
        if (!_open(today))
          _card(const Text('School is closed today. Attendance is disabled.'))
        else ...[
          if (lockReason.isNotEmpty) _card(Text(lockReason)),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy || lockReason.isNotEmpty
                      ? null
                      : () => _markAttendance('entry'),
                  icon: const Icon(Icons.login),
                  label: const Text('Check in'),
                ),
              ),
              const SizedBox(width: 12),
              if (_s.studentCheckoutEnabled) Expanded(
                child: FilledButton.icon(
                  onPressed: _busy || exitLock.isNotEmpty
                      ? null
                      : () => _markAttendance('exit'),
                  icon: const Icon(Icons.logout),
                  label: const Text('Check out'),
                ),
              ),
            ],
          ),
          if (_s.studentCheckoutEnabled && exitLock.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(exitLock, style: const TextStyle(fontSize: 12)),
            ),
          const SizedBox(height: 18),
        ],
        ..._attendance.map(
          (r) => _card(
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r['date'].toString()),
                      if (r['captureTimeSource'] == 'DEVICE_REPORTED')
                        const Text(
                          'Attendance time',
                          style: TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
                Text(
                  '${time(r['entryCapturedAt'] ?? r['checkIn'])} → ${time(r['exitCapturedAt'] ?? r['checkOut'])}',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _documents() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading('My school documents', 'Your digital student wallet'),
      const SizedBox(height: 12),
      const Row(children: [
        Icon(Icons.verified_user_outlined, color: Colors.tealAccent),
        SizedBox(width: 10),
        Text('School-verified ID card',
          style: TextStyle(fontWeight: FontWeight.bold)),
      ]),
      _card(
        Column(
          children: [
            Text(_s.person['name']?.toString() ?? ''),
            const SizedBox(height: 12),
            PublishedIdCard(
              automatic: true,
              key: ValueKey(
                jsonEncode([
                  _s.link?.projectId,
                  _s.link?.role,
                  _s.link?.personId,
                  _data['idCardPackage'],
                ]),
              ),
              load: _refreshPublishedCard,
              refresh: () => _load(afterSignal: true),
              open: (bytes) =>
                  _previewPdf(bytes, 'School ID card • Front & back'),
              openExternally: _openIdPdfExternally,
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      const Row(children: [
        Icon(Icons.auto_stories_outlined, color: Colors.tealAccent),
        SizedBox(width: 10),
        Text('Marksheets & results',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 12),
      if (_list(_data['examinations']).isNotEmpty)
        const Text('Published examinations', style: TextStyle(color: Colors.white70)),
      for (final exam in _list(_data['examinations']))
        _card(
          Text(
            '${exam['examName'] ?? exam['name'] ?? exam['id']} • ${exam['academicSession'] ?? ''}',
          ),
        ),
      if (_list(_data['reportCards']).isEmpty)
        _card(const Text('Your school has not published a report card yet.')),
      ..._list(_data['reportCards']).map(
        (r) => _card(
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(r['examName']?.toString() ?? 'Exam'),
            subtitle: Text(
              '${r['result'] ?? 'Pending'} • ${r['percentage'] ?? 0}%',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPdf('reportCard', r),
          ),
        ),
      ),
      const SizedBox(height: 14),
      const Text(
        'Certificates & other documents',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 12),
      if (_list(_data['documents']).isEmpty)
        _card(
          const Text('Documents published by your school will appear here.'),
        ),
      for (final document in _list(_data['documents']))
        _card(
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined),
            title: Text(
              document['documentName']?.toString() ?? 'School document',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openSchoolDocument(document),
          ),
        ),
    ],
  );
  Widget _fees() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading('Fees', 'Your school fee ledger and payment history'),
      if (_list(_data['fees']).isEmpty)
        _card(const Text('Your school has not published a fee ledger yet.')),
      ..._list(_data['fees']).map((f) {
        final due =
            double.tryParse(
              (f['remainingAmount'] ??
                      f['balance'] ??
                      f['dueAmount'] ??
                      ((double.tryParse(
                                '${f['expectedAmount'] ?? f['totalAmount']}',
                              ) ??
                              0) -
                          (double.tryParse(
                                '${f['totalPaid'] ?? f['paidAmount']}',
                              ) ??
                              0)))
                  .toString(),
            ) ??
            0;
        return _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    due <= 0
                        ? Icons.check_circle_outline
                        : Icons.pending_outlined,
                    color: due <= 0 ? Colors.tealAccent : Colors.orangeAccent,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    due <= 0 ? 'Fees cleared' : 'Fees pending',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (f['month'] != null) Text('Month: ${f['month']}'),
              Text('Balance: INR ${due.toStringAsFixed(2)}'),
              Text(
                'Paid: INR ${f['totalPaid'] ?? f['paidAmount'] ?? 0}',
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          ),
        );
      }),
      for (final structure in _list(_data['feeStructures']))
        if (structure['fees'] is Map)
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Fee Structure • ${structure['academicSession'] ?? 'Legacy'}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                for (final head in (structure['fees'] as Map).entries)
                  Text('${head.key}: INR ${head.value}'),
              ],
            ),
          ),
      const SizedBox(height: 8),
      const Text(
        'Payments',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      ..._list(_data['payments']).map(
        (p) => _card(
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'INR ${p['installmentAmount'] ?? p['paidAmount'] ?? p['amount'] ?? p['totalAmount'] ?? p['totalPaid'] ?? 0}',
            ),
            subtitle: Text(
              '${p['dateText'] ?? p['date'] ?? ''} • ${p['receiptNo'] ?? ''}',
            ),
          ),
        ),
      ),
    ],
  );
  Widget _salary() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading('My salary', 'Only your own salary records are shown.'),
      if (_list(_data['salary']).isEmpty)
        _card(
          const Text('Salary details have not been added by your school yet.'),
        ),
      ..._list(_data['salary']).map(
        (r) => _card(
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('INR ${r['amount'] ?? 0}'),
            subtitle: Text('${r['month'] ?? ''} • ${r['status'] ?? 'Pending'}'),
          ),
        ),
      ),
    ],
  );
  Widget _calendar() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading('School calendar', 'Open days, holidays and school closures'),
      _card(
        CalendarDatePicker(
          initialDate: _selectedDay,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
          onDateChanged: (d) => setState(() => _selectedDay = d),
        ),
      ),
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _day(_selectedDay),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _open(_selectedDay) ? 'School open' : 'School closed',
              style: TextStyle(
                color: _open(_selectedDay)
                    ? Colors.tealAccent
                    : Colors.orangeAccent,
              ),
            ),
            ..._list(_data['calendar'])
                .where((d) => (d['date'] ?? d['id']) == _day(_selectedDay))
                .map((d) => Text(d['reason']?.toString() ?? '')),
          ],
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final pages = _teacher
        ? [_attendancePage, _salary, _calendar]
        : [_home, _attendancePage, _documents, _fees, _calendar];
    return Scaffold(
      appBar: AppBar(
        title: const VidyaSaarthiBrand(),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'complaint') _complaint();
              if (v == 'settings')
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MobileSettingsScreen(
                      version: SchoolSession.version,
                      buildNumber:
                          int.tryParse(
                            const String.fromEnvironment(
                              'APP_BUILD',
                              defaultValue: '0',
                            ),
                          ) ??
                          0,
                      checkUpdate: () => _s.platformCall('updates/latest', {
                        'platform': 'android',
                      }),
                      installUpdate: (update) => _update(update: update),
                    ),
                  ),
                );
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'complaint',
                child: Text('Report app problem'),
              ),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
              PopupMenuItem(
                value: 'logout',
                child: Text('Sign out / change school'),
              ),
            ],
          ),
        ],
      ),
      body: _blocked
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'Unable to connect. Please check with your school; its Windows app, connection or licence is unavailable.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.orangeAccent),
                      ),
                    ),
                  if (_loading && _data.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text('Loading school information…'),
                    ),
                  pages[_page](),
                ],
              ),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page,
        onDestinationSelected: (i) {
          setState(() => _page = i);
          if (i == (_teacher ? 0 : 1)) _loadAttendance();
          if (!_teacher && i == 2) unawaited(_load(afterSignal: true));
        },
        destinations: _teacher
            ? const [
                NavigationDestination(
                  icon: Icon(Icons.fact_check_outlined),
                  label: 'Attendance',
                ),
                NavigationDestination(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  label: 'Salary',
                ),
                NavigationDestination(
                  icon: Icon(Icons.calendar_month),
                  label: 'Calendar',
                ),
              ]
            : const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.fact_check_outlined),
                  label: 'Attendance',
                ),
                NavigationDestination(
                  icon: Icon(Icons.badge_outlined),
                  label: 'Documents',
                ),
                NavigationDestination(
                  icon: Icon(Icons.payments_outlined),
                  label: 'Fees',
                ),
                NavigationDestination(
                  icon: Icon(Icons.calendar_month),
                  label: 'Calendar',
                ),
              ],
      ),
    );
  }
}
