import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'mobile/school_session.dart';
import 'mobile/school_notifications.dart';
import 'mobile/school_messaging.dart';
import 'school_document_renderer.dart';

@pragma('vm:entry-point')
Future<void> _backgroundNotice(RemoteMessage message) async {
  await SchoolSession.instance.restore();
  if(!SchoolSession.instance.loggedIn) return;
  try {await Firebase.initializeApp();await SchoolNotifications.show(message);} catch(_){}
}

final _messenger = GlobalKey<ScaffoldMessengerState>();
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SchoolSession.instance.restore();
  await SchoolNotifications.initialize();
  try {await SchoolMessaging.configure(SchoolSession.instance.messaging);} catch(_){}
  FirebaseMessaging.onBackgroundMessage(_backgroundNotice);
  try {
    if(SchoolMessaging.ready) await FirebaseMessaging.instance
        .requestPermission(alert: true, badge: true, sound: true);
  } catch (_) {}
  FirebaseMessaging.onMessage.listen((m) {
    final school = SchoolSession.instance.link?.projectId;
    if (SchoolNotifications.belongsToSession(m.data, school)) {
      unawaited(SchoolNotifications.show(m).catchError((_) {}));
    }
  });
  runApp(const SaarthiMobileApp());
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
              primary: Color(0xFF00D9A5), surface: Color(0xFF172229)),
          scaffoldBackgroundColor: const Color(0xFF0B141A),
          inputDecorationTheme: const InputDecorationTheme(
              filled: true, border: OutlineInputBorder())),
      home: SchoolSession.instance.loggedIn
          ? const _SchoolDashboard()
          : const _SchoolLogin());
}

class _QrScanner extends StatefulWidget {
  const _QrScanner();
  @override
  State<_QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<_QrScanner> {
  bool _done = false;
  String? _error;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Scan school ID card')),
      body: Column(children: [
        const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
                'Use the QR printed on your own student or teacher ID card.')),
        Expanded(
            child: MobileScanner(
                onDetect: (capture) {
                  if (_done) return;
                  for (final b in capture.barcodes) {
                    final raw = b.rawValue;
                    if (raw == null) continue;
                    try {
                      final link = SchoolLink.parse(raw);
                      _done = true;
                      Navigator.pop(context, link);
                      return;
                    } catch (e) {
                      if (mounted) setState(() => _error = e.toString());
                    }
                  }
                },
                errorBuilder: (context, error) => Center(
                    child: Text(
                        'Camera unavailable. Allow camera access in your phone settings.\n${error.errorCode.name}',
                        textAlign: TextAlign.center)))),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.orangeAccent)))
      ]));
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
        context, MaterialPageRoute(builder: (_) => const _QrScanner()));
    if (link == null || !mounted) return;
    setState(() {
      _link = link;
      _error = null;
      _roll.clear();
      _dob.clear();
    });
  }

  Future<void> _login() async {
    if (_link == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SchoolMessaging.stop();
      await SchoolNotifications.clear();
      await SchoolSession.instance.login(_link!,
          studentClass: _class,
          roll: _roll.text.trim(),
          dob: _dob.text.trim());
      try {
        if(await SchoolMessaging.configure(SchoolSession.instance.messaging)) return;
      } catch(_) {
        _messenger.currentState?.showSnackBar(const SnackBar(content:Text('School login is ready. Ask the school to finish notification setup.')));
      }
      if (mounted)
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => const _SchoolDashboard()));
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
                            const Icon(Icons.school_rounded,
                                color: Color(0xFF00D9A5), size: 62),
                            const SizedBox(height: 20),
                            const Text('Vidya Saarthi',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 29, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 8),
                            const Text('Your school, connected.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white54)),
                            const SizedBox(height: 32),
                            OutlinedButton.icon(
                                onPressed: _busy ? null : _scan,
                                icon: const Icon(Icons.qr_code_scanner),
                                label: Text(_link == null
                                    ? 'Scan your school ID'
                                    : 'Scan another ID')),
                            if (_link != null) ...[
                              const SizedBox(height: 20),
                              Text(
                                  _link!.role == 'student'
                                      ? 'Student login'
                                      : 'Teacher login',
                                  style: const TextStyle(
                                      fontSize: 21,
                                      fontWeight: FontWeight.bold)),
                              Text(_link!.projectId,
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 12)),
                              const SizedBox(height: 20),
                              if (_link!.role == 'student') ...[
                                DropdownButtonFormField<String>(
                                    initialValue: _class,
                                    decoration: const InputDecoration(
                                        labelText: 'Select class'),
                                    items: List.generate(
                                        10,
                                        (i) => DropdownMenuItem(
                                            value: 'Class ${i + 1}',
                                            child: Text('Class ${i + 1}'))),
                                    onChanged: (v) =>
                                        setState(() => _class = v!)),
                                const SizedBox(height: 14),
                                TextField(
                                    controller: _roll,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                        labelText: 'Roll number')),
                                const SizedBox(height: 14),
                                TextField(
                                    controller: _dob,
                                    keyboardType: TextInputType.datetime,
                                    decoration: const InputDecoration(
                                        labelText: 'Date of birth',
                                        hintText: 'DD/MM/YYYY')),
                                const SizedBox(height: 14)
                              ] else
                                const Text(
                                    'Your teacher ID QR securely identifies your school account.',
                                    style: TextStyle(color: Colors.white54)),
                              if (_error != null)
                                Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    child: Text(_error!,
                                        style: const TextStyle(
                                            color: Colors.redAccent))),
                              FilledButton(
                                  onPressed: _busy ? null : _login,
                                  child: Padding(
                                      padding: const EdgeInsets.all(9),
                                      child: Text(_busy
                                          ? 'Verifying school…'
                                          : 'Log in')))
                            ],
                            const SizedBox(height: 28),
                            const Text(
                                'School records are kept separate. The QR connects only to the issuing school.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.white38, fontSize: 11))
                          ]))))));
}

class _SchoolDashboard extends StatefulWidget {
  const _SchoolDashboard();
  @override
  State<_SchoolDashboard> createState() => _SchoolDashboardState();
}

class _SchoolDashboardState extends State<_SchoolDashboard> {
  StreamSubscription<void>? _noticeOpened;
  StreamSubscription<RemoteMessage>? _noticeReceived;
  final _s = SchoolSession.instance;
  int _page = 0;
  bool _loading = true, _busy = false, _blocked = false;
  String? _error;
  Map<String, dynamic> _data = {};
  List<Map<String, dynamic>> _attendance = [];
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month),
      _selectedDay = DateTime.now();
  Timer? _timer;
  String _attendanceMode = 'entry';
  bool get _teacher => _s.link!.role == 'teacher';
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
    _load();
    _presence();
    _timer = Timer.periodic(const Duration(seconds:30), (_) => _presence());
    _noticeOpened=SchoolNotifications.opened.listen((_)=>_load());
    _noticeReceived=FirebaseMessaging.onMessage.listen((m){
      if(SchoolNotifications.belongsToSession(m.data,_s.link?.projectId)) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _noticeOpened?.cancel();_noticeReceived?.cancel();
    super.dispose();
  }

  Future<void> _presence([String? token]) async {
    if(WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    try {
      final d =
          await _s.platformCall('mobile/heartbeat', {'fcmToken': token ?? ''});
      if (mounted) {final recovering=_blocked;setState((){_blocked=d['allowed']!=true;_error=null;});if(recovering&&!_blocked)await _load();}
    } catch (e) {
      if (mounted) setState((){_blocked=true;_error='Unable to connect. School Windows app is offline or unavailable.';});
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await _s.schoolCall('mobile_dashboard', {});
      if (mounted)
        setState(() {
          _data = d;
          _s.person = Map<String, dynamic>.from(d['person'] ?? {});
          _error = null;
        });
      await _loadAttendance();
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadAttendance() async {
    try {
      final d =
          await _s.schoolCall('mobile_attendance_list', {'month': _monthKey});
      if (mounted) setState(() => _attendance = _list(d['attendance']));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _logout() async {
    await SchoolMessaging.stop();
    await _s.logout();
    await SchoolNotifications.clear();
    if (mounted)
      Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const _SchoolLogin()),
          (_) => false);
  }

  Widget _card(Widget child) => Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(padding: const EdgeInsets.all(18), child: child));
  Widget _heading(String title, String subtitle) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(subtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 20)
      ]);
  bool _open(DateTime day) {
    final override = _list(_data['calendar'])
        .where((d) => (d['date'] ?? d['id']) == _day(day));
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

  Future<void> _markAttendance() async {
    if (_busy) return;
    final qr = await Navigator.push<SchoolLink>(
        context, MaterialPageRoute(builder: (_) => const _QrScanner()));
    if (qr == null || !mounted) return;
    if (qr.projectId != _s.link!.projectId ||
        qr.role != _s.link!.role ||
        qr.linkToken != _s.link!.linkToken) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Scan your own ID from the active school.')));
      return;
    }
    setState(() => _busy = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied)
        permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever)
        throw StateError('Allow location access to verify school attendance.');
      final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 20));
      final d = await _s.schoolCall('mobile_mark_attendance', {
        'role': qr.role,
        'personId': qr.personId,
        'linkToken': qr.linkToken,
        'mode': _attendanceMode,
        'latitude': position.latitude,
        'longitude': position.longitude
      });
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(d['message'].toString())));
      await _loadAttendance();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Bad state: ', ''))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _complaint() async {
    final message = TextEditingController();
    final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Report an app problem'),
                content: TextField(
                    controller: message,
                    minLines: 4,
                    maxLines: 6,
                    decoration: const InputDecoration(
                        hintText:
                            'Describe what happened. Do not include passwords.')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Send complaint'))
                ]));
    if (yes == true) {
      try {
        await _s.platformCall('complaint/create',
            {'message': message.text, 'version': SchoolSession.version});
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Complaint saved for the developer.')));
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    message.dispose();
  }

  Future<void> _showPdf(String kind, Map<String, dynamic> d) async {
    try {
      final selections =
          _data['templates'] is Map ? _data['templates'] as Map : {};
      final index = (selections[kind] as num?)?.toInt() ?? -1;
      final school = _data['school'] is Map ? _data['school'] as Map : {};
      final data = {
        'schoolName': school['schoolName'] ?? school['name'] ?? _s.schoolName,
        ...d
      };
      Future<Uint8List?> asset(String kind) async {
        final r = await _s.schoolCall('mobile_asset', {'kind': kind});
        return r['available'] == true
            ? base64Decode(r['base64'].toString()) : null;
      }
      final photo = kind == 'studentId' || kind == 'teacherId'
          ? await asset('photo') : null;
      final logo = await asset('logo');
      final pdf = await renderSchoolDocument(
          kind: kind,
          template: index,
          data: data,
          qr: _s.link!.rawQr,
          photo: photo,
          logo: logo);
      if (mounted)
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => Scaffold(
                    appBar: AppBar(
                        title: Text(kind == 'reportCard'
                            ? 'Report card'
                            : 'School ID card')),
                    body: PdfPreview(
                        build: (_) => pdf,
                        allowPrinting: true,
                        allowSharing: true,
                        canChangePageFormat: false,
                        canChangeOrientation: false))));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _update() async {
    try {
      final r =
          await _s.platformCall('updates/latest', {'platform': 'android'});
      final u = r['update'];
      if (u is! Map) throw StateError('No update is published yet.');
      final installed = int.tryParse(
              const String.fromEnvironment('APP_BUILD', defaultValue: '0')) ??
          0;
      final available = (u['versionCode'] as num?)?.toInt() ?? 0;
      if (available <= installed) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Your app is up to date.')));
        return;
      }
      final uri = Uri.parse(u['apkUrl'].toString());
      if (uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          !uri.path
              .startsWith('/cscticket01-hash/Saarthi_Ai/releases/download/'))
        throw StateError('Invalid update download address.');
      if (!mounted) return;
      final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: Text('Update ${u['versionName']}'),
                  content: const Text(
                      'Download the new signed app from the developer?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Later')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Download'))
                  ]));
      if (yes != true) return;
      setState(() => _busy = true);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/vidya-saarthi-update.apk');
      final client = http.Client();
      try {
        final response = await client.send(http.Request('GET', uri));
        if (response.statusCode != 200)
          throw StateError('Update download failed.');
        final sink = file.openWrite();
        await response.stream.pipe(sink);
      } finally {
        client.close();
      }
      final expected=u['sha256']?.toString().replaceFirst('sha256:','');
      if(expected!=null && (await sha256.bind(file.openRead()).first).toString()!=expected){
        await file.delete();throw StateError('Update verification failed. Download again.');
      }
      await OpenFilex.open(file.path);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _home() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _heading('Hello, ${_s.person['name'] ?? 'Student'}', _s.schoolName),
        _card(Row(children: [
          const Icon(Icons.verified_user_outlined,
              color: Colors.tealAccent, size: 35),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    _s.person['class']?.toString() ??
                        _s.person['designation']?.toString() ??
                        'School member',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(
                    _teacher
                        ? 'Teacher ID: ${_s.person['teacherId']}'
                        : 'Roll: ${_s.person['rollNo']}',
                    style: const TextStyle(color: Colors.white54))
              ]))
        ])),
        const SizedBox(height: 8),
        const Text('School notices',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 14),
        if (_list(_data['notices']).isEmpty)
          _card(const Text('No notices from your school yet.')),
        ..._list(_data['notices']).map((n) => _card(
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(n['title']?.toString() ?? 'School notice',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(n['description']?.toString() ??
                  n['message']?.toString() ??
                  ''),
              if (n['category'] != null)
                Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(n['category'].toString(),
                        style: const TextStyle(
                            color: Colors.tealAccent, fontSize: 11)))
            ])))
      ]);
  Widget _attendancePage() {
    final today = DateTime.now();
    var working = 0;
    for (var d = DateTime(_month.year, _month.month);
        d.month == _month.month && !d.isAfter(today);
        d = d.add(const Duration(days: 1))) {
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

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading('Attendance', 'Daily check-in and check-out at your school'),
      Row(children: [
        IconButton(
            onPressed: () {
              setState(() => _month = DateTime(_month.year, _month.month - 1));
              _loadAttendance();
            },
            icon: const Icon(Icons.chevron_left)),
        Expanded(
            child: Text(_monthKey,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.bold))),
        IconButton(
            onPressed: _month.year == today.year && _month.month == today.month
                ? null
                : () {
                    setState(
                        () => _month = DateTime(_month.year, _month.month + 1));
                    _loadAttendance();
                  },
            icon: const Icon(Icons.chevron_right))
      ]),
      const SizedBox(height: 12),
      _card(Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        Column(children: [
          Text('$present',
              style:
                  const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
          const Text('Present days')
        ]),
        Column(children: [
          Text('$working',
              style:
                  const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
          const Text('School days')
        ]),
        Column(children: [
          Text(
              working == 0
                  ? '—'
                  : '${(present / working * 100).clamp(0, 100).toStringAsFixed(0)}%',
              style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: Colors.tealAccent)),
          const Text('Attendance')
        ])
      ])),
      if (!_open(today))
        _card(const Text('School is closed today. Attendance is disabled.'))
      else ...[
        SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'entry', label: Text('Check in')),
              ButtonSegment(value: 'exit', label: Text('Check out'))
            ],
            selected: {
              _attendanceMode
            },
            onSelectionChanged: (v) =>
                setState(() => _attendanceMode = v.first)),
        const SizedBox(height: 12),
        FilledButton.icon(
            onPressed: _busy ? null : _markAttendance,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(_busy ? 'Verifying…' : 'Scan ID & mark attendance')),
        const SizedBox(height: 18)
      ],
      ..._attendance.map((r) => _card(Row(children: [
            Expanded(child: Text(r['date'].toString())),
            Text('${time(r['checkIn'])} → ${time(r['checkOut'])}')
          ])))
    ]);
  }

  Widget _documents() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _heading('My school documents', 'Your ID card and exam report cards'),
        _card(Column(children: [
          QrImageView(
              data: _s.link!.rawQr, size: 180, backgroundColor: Colors.white),
          const SizedBox(height: 12),
          Text(_s.person['name']?.toString() ?? ''),
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed: () => _showPdf('studentId', _s.person),
              icon: const Icon(Icons.badge_outlined),
              label: const Text('Open my ID card'))
        ])),
        const SizedBox(height: 10),
        const Text('Report cards',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        if (_list(_data['reportCards']).isEmpty)
          _card(const Text('Your school has not published a report card yet.')),
        ..._list(_data['reportCards']).map((r) => _card(ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(r['examName']?.toString() ?? 'Exam'),
            subtitle:
                Text('${r['result'] ?? 'Pending'} • ${r['percentage'] ?? 0}%'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPdf('reportCard', r))))
      ]);
  Widget _fees() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _heading('Fees', 'Your school fee ledger and payment history'),
        if (_list(_data['fees']).isEmpty)
          _card(const Text('Your school has not published a fee ledger yet.')),
        ..._list(_data['fees']).map((f) {
          final due = double.tryParse(
                  (f['remainingAmount'] ?? f['balance'] ?? f['dueAmount'] ?? 0)
                      .toString()) ??
              0;
          return _card(
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(
                  due <= 0
                      ? Icons.check_circle_outline
                      : Icons.pending_outlined,
                  color: due <= 0 ? Colors.tealAccent : Colors.orangeAccent),
              const SizedBox(width: 10),
              Text(due <= 0 ? 'Fees cleared' : 'Fees pending',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold))
            ]),
            const SizedBox(height: 12),
            Text('Balance: INR ${due.toStringAsFixed(2)}'),
            Text('Paid: INR ${f['totalPaid'] ?? f['paidAmount'] ?? 0}',
                style: const TextStyle(color: Colors.white54))
          ]));
        }),
        const SizedBox(height: 8),
        const Text('Payments',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ..._list(_data['payments']).map((p) => _card(ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('INR ${p['totalAmount'] ?? p['amount'] ?? 0}'),
            subtitle: Text(
                '${p['dateText'] ?? p['date'] ?? ''} • ${p['receiptNo'] ?? ''}'))))
      ]);
  Widget _salary() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _heading('My salary', 'Only your own salary records are shown.'),
        if (_list(_data['salary']).isEmpty)
          _card(const Text(
              'Salary details have not been added by your school yet.')),
        ..._list(_data['salary']).map((r) => _card(ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('INR ${r['amount'] ?? 0}'),
            subtitle:
                Text('${r['month'] ?? ''} • ${r['status'] ?? 'Pending'}'))))
      ]);
  Widget _calendar() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _heading('School calendar', 'Open days, holidays and school closures'),
        _card(CalendarDatePicker(
            initialDate: _selectedDay,
            firstDate: DateTime(2020),
            lastDate: DateTime(2100),
            onDateChanged: (d) => setState(() => _selectedDay = d))),
        _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_day(_selectedDay),
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(_open(_selectedDay) ? 'School open' : 'School closed',
              style: TextStyle(
                  color: _open(_selectedDay)
                      ? Colors.tealAccent
                      : Colors.orangeAccent)),
          ..._list(_data['calendar'])
              .where((d) => (d['date'] ?? d['id']) == _day(_selectedDay))
              .map((d) => Text(d['reason']?.toString() ?? ''))
        ]))
      ]);
  @override
  Widget build(BuildContext context) {
    final pages = _teacher
        ? [_attendancePage(), _salary(), _calendar()]
        : [_home(), _attendancePage(), _documents(), _fees(), _calendar()];
    return Scaffold(
        appBar: AppBar(title: Text(_s.schoolName), actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'complaint') _complaint();
                if (v == 'update') _update();
                if (v == 'logout') _logout();
              },
              itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'complaint', child: Text('Report app problem')),
                    PopupMenuItem(
                        value: 'update', child: Text('Check for updates')),
                    PopupMenuItem(
                        value: 'logout',
                        child: Text('Sign out / change school'))
                  ])
        ]),
        body: _blocked
            ? const Center(
                child: Padding(
                    padding: EdgeInsets.all(28),
                    child: Text(
                        'Unable to connect. Please check with your school; its Windows app, connection or licence is unavailable.',
                        textAlign: TextAlign.center)))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: const EdgeInsets.all(20), children: [
                  if (_loading || _busy) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(_error!,
                            style:
                                const TextStyle(color: Colors.orangeAccent))),
                  pages[_page]
                ])),
        bottomNavigationBar: NavigationBar(
            selectedIndex: _page,
            onDestinationSelected: (i) => setState(() => _page = i),
            destinations: _teacher
                ? const [
                    NavigationDestination(
                        icon: Icon(Icons.fact_check_outlined),
                        label: 'Attendance'),
                    NavigationDestination(
                        icon: Icon(Icons.account_balance_wallet_outlined),
                        label: 'Salary'),
                    NavigationDestination(
                        icon: Icon(Icons.calendar_month), label: 'Calendar')
                  ]
                : const [
                    NavigationDestination(
                        icon: Icon(Icons.home_outlined), label: 'Home'),
                    NavigationDestination(
                        icon: Icon(Icons.fact_check_outlined),
                        label: 'Attendance'),
                    NavigationDestination(
                        icon: Icon(Icons.badge_outlined), label: 'Documents'),
                    NavigationDestination(
                        icon: Icon(Icons.payments_outlined), label: 'Fees'),
                    NavigationDestination(
                        icon: Icon(Icons.calendar_month), label: 'Calendar')
                  ]));
  }
}
