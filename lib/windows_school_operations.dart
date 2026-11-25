import 'windows_support_history.dart';
import 'windows_appearance.dart';
import 'promotion_session_policy.dart';
import 'windows_admin_security.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_ui_localization.dart';

import 'dart:convert';
import 'dart:async';
import 'windows_developer_notifications.dart';

import 'package:flutter/material.dart' hide Text, InputDecoration;

import 'windows_local_firestore.dart';
import 'windows_local_auth.dart';
import 'windows_backend_bridge.dart';
import 'windows_connection_center.dart';
import 'windows_platform_client.dart';
import 'windows_school_identity.dart';
import 'windows_local_settings.dart';

String schoolDateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class SchoolAttendanceOverview extends StatefulWidget {
  const SchoolAttendanceOverview({super.key});
  @override
  State<SchoolAttendanceOverview> createState() =>
      _SchoolAttendanceOverviewState();
}

class _SchoolAttendanceOverviewState extends State<SchoolAttendanceOverview> {
  late final String _profileId;
  DateTime _day = DateTime.now();
  String _role = 'student';
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _records = [];
  Map<String, dynamic> _calendar = {};
  @override
  void initState() {
    super.initState();
    _profileId = FirebaseFirestore.instance.activeProfileId;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final origin = FirebaseFirestore.instance.activeProfileId;
    final day = _day, role = _role;
    bool current() => mounted && origin == FirebaseFirestore.instance.activeProfileId && day == _day && role == _role;
    try {
      final records = await FirebaseFirestore.instance
          .collection('attendance_records')
          .get();
      final calendar = await FirebaseFirestore.instance
          .collection('school_calendar')
          .doc(schoolDateKey(day))
          .get();
      if (current())
        setState(() {
          _records = records.docs
              .map((d) => {'id': d.id, ...d.data()})
              .where(
                (d) => d['date'] == schoolDateKey(day) && d['role'] == role,
              )
              .toList();
          _calendar = calendar.data() ?? {};
          _error = null;
        });
    } catch (e) {
      if (current()) setState(() => _error = '$e');
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  Future<void> _editSchedule() async {
    final profile = _profileId;
    bool sameSchool() => FirebaseFirestore.instance.activeProfileId == profile;
    if (!sameSchool()) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('school_settings')
          .doc('attendance_schedule').get();
      if (!mounted || !sameSchool()) return;
      final data = doc.data() ?? {};
      var enabled = data['enabled'] == true;
      var checkoutEnabled = data['checkoutEnabled'] != false;
      TimeOfDay fromMinute(dynamic n, int fallback) {
        final m = n is int && n >= 0 && n < 1440 ? n : fallback;
        return TimeOfDay(hour: m ~/ 60, minute: m % 60);
      }
      var start = fromMinute(data['startMinute'], 8 * 60);
      var end = fromMinute(data['endMinute'], 10 * 60);
      int minute(TimeOfDay t) => t.hour * 60 + t.minute;
      final save = await showDialog<bool>(context: context, builder: (ctx) =>
        StatefulBuilder(builder: (ctx, update) {
          WindowsAppearance.watch(ctx);
          return AlertDialog(
            title: const Text('Student attendance schedule'),
            content: SizedBox(width: 380, child: Column(
              mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Only this school • Every day • India time (IST). Teachers can mark their own attendance once daily.'),
                SwitchListTile(contentPadding: EdgeInsets.zero,
                  title: const Text('Limit student attendance time'), value: enabled,
                  onChanged: (v) => update(() => enabled = v)),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Student check-out'),
                  subtitle: Text(checkoutEnabled ? 'Check-in and check-out' : 'Check-in only in student app'),
                  value: checkoutEnabled,
                  onChanged: (v) => update(() => checkoutEnabled = v),
                ),
                ListTile(title: const Text('Opens at'), trailing: Text(start.format(ctx)),
                  enabled: enabled, onTap: !enabled ? null : () async {
                    final t = await showTimePicker(context: ctx, initialTime: start);
                    if (t != null && ctx.mounted) update(() => start = t);
                  }),
                ListTile(title: const Text('Locks at'), trailing: Text(end.format(ctx)),
                  enabled: enabled, onTap: !enabled ? null : () async {
                    final t = await showTimePicker(context: ctx, initialTime: end);
                    if (t != null && ctx.mounted) update(() => end = t);
                  }),
                if (enabled && minute(start) >= minute(end))
                  Text('Lock time must be after opening time on the same day.',
                    style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.redAccent))),
                const Text('Pending captures stay locked and continue syncing after the window closes.'),
              ],
            )),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: enabled && minute(start) >= minute(end) ? null :
                () => Navigator.pop(ctx, true), child: const Text('Save schedule')),
            ],
          );
        }));
      if (save != true || !mounted || !sameSchool()) return;
      await FirebaseFirestore.instance.collection('school_settings').doc('attendance_schedule').set({
        'enabled': enabled, 'startMinute': minute(start), 'endMinute': minute(end),
        'checkoutEnabled': checkoutEnabled,
        'timeZone': 'Asia/Kolkata', 'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
      });
      if (!mounted || !sameSchool()) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Schedule saved locally. Syncing to this school’s student app…')));
      await WindowsConnectionCenter.refreshProfileAndSync();
    } catch (e) {
      if (mounted && sameSchool()) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Schedule save/sync failed: $e')));
    }
  }

  String _time(dynamic t) {
    final n = t is Timestamp
        ? t.millisecondsSinceEpoch
        : t is num
        ? t.toInt()
        : 0;
    if (n == 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(n);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _calendarEdit() async {
    final origin = _profileId, day = _day;
    if (FirebaseFirestore.instance.activeProfileId != origin) return;
    bool open = _calendar['isOpen'] is bool
        ? _calendar['isOpen']
        : day.weekday != DateTime.sunday;
    final reason = TextEditingController(
      text: _calendar['reason']?.toString() ?? '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) { WindowsAppearance.watch(ctx); return  StatefulBuilder(
        builder: (ctx, setD) { WindowsAppearance.watch(ctx); return  AlertDialog(
          title: Text('School calendar • ${schoolDateKey(day)}'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  value: open,
                  onChanged: (v) => setD(() => open = v),
                  title: Text(open ? 'School open' : 'School closed'),
                  subtitle: const Text(
                    'Closed days block attendance for students and teachers.',
                  ),
                ),
                TextField(
                  controller: reason,
                  decoration: const InputDecoration(
                    labelText: 'Reason / holiday name',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save date'),
            ),
          ],
        ); },
      ); },
    );
    if (FirebaseFirestore.instance.activeProfileId != origin) {
      reason.dispose();
      return;
    }
    if (saved == true) {
      await FirebaseFirestore.instance
          .collection('school_calendar')
          .doc(schoolDateKey(day))
          .set({
            'date': schoolDateKey(day),
            'isOpen': open,
            'reason': reason.text.trim(),
            'updatedAt': FieldValue.serverTimestamp(),
            'updatedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
          });
      await WindowsConnectionCenter.refreshProfileAndSync();
      if (mounted) _load();
    }
    reason.dispose();
  }

  @override
  Widget build(BuildContext context) { WindowsAppearance.watch(context);
    if (FirebaseFirestore.instance.activeProfileId != _profileId) {
      return const Scaffold(body: Center(child: Text('School changed. Reopen Attendance.')));
    }
    return Scaffold(
    appBar: AppBar(
      title: const Text('Attendance & school calendar'),
      actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
    ),
    body: LayoutBuilder(
      builder: (ctx, c) {WindowsAppearance.watch(ctx);
        final cal = Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'School calendar',
                  style: TextStyle(fontFamily: 'Segoe UI', fontSize: 18, fontWeight: FontWeight.w700),
                ),
                CalendarDatePicker(
                  initialDate: _day,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                  onDateChanged: (d) {
                    setState(() => _day = d);
                    _load();
                  },
                ),
                Text(
                  (_calendar['isOpen'] is bool
                          ? _calendar['isOpen']
                          : _day.weekday != DateTime.sunday)
                      ? 'School open'
                      : 'School closed',
                  style: const TextStyle(fontFamily: 'Segoe UI', fontWeight: FontWeight.bold),
                ),
                if ((_calendar['reason']?.toString() ?? '').isNotEmpty)
                  Text(_calendar['reason'].toString()),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _calendarEdit,
                  icon: const Icon(Icons.edit_calendar),
                  label: const Text('Set open / closed'),
                ),
              ],
            ),
          ),
        );
        final table = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 10,
              children: [
                Text(
                  schoolDateKey(_day),
                  style: const TextStyle(fontFamily: 'Segoe UI', 
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                PopupMenuButton<String>(
                  tooltip: 'Attendance options', icon: const Icon(Icons.more_vert),
                  onSelected: (_) => _editSchedule(),
                  itemBuilder: (_) => const [PopupMenuItem(value: 'schedule', child: Text('Schedule'))],
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'student', label: Text('Students')),
                    ButtonSegment(value: 'teacher', label: Text('Teachers')),
                  ],
                  selected: {_role},
                  onSelectionChanged: (v) {
                    setState(() => _role = v.first);
                    _load();
                  },
                ),
                ]),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '${_records.length} check-ins • ${_records.where((r) => r['checkOut'] != null).length} check-outs',
              style:  TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.white54)),
            ),
            const SizedBox(height: 16),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Text(_error!, style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.redAccent))),
            if (!_loading && _records.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 35),
                child: Text('No attendance records for this date.'),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Name')),
                  DataColumn(label: Text('Class / ID')),
                  DataColumn(label: Text('Check-in')),
                  DataColumn(label: Text('Check-out')),
                  DataColumn(label: Text('Date')),
                ],
                rows: _records
                    .map(
                      (r) => DataRow(
                        cells: [
                          DataCell(Text(r['name']?.toString() ?? '')),
                          DataCell(
                            Text(
                              _role == 'student'
                                  ? '${r['studentClass']} • ${r['rollNo']}'
                                  : r['personId']?.toString() ?? '',
                            ),
                          ),
                          DataCell(Text(_time(r['checkIn']))),
                          DataCell(Text(_time(r['checkOut']))),
                          DataCell(Text(r['date'].toString())),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: c.maxWidth < 950
              ? Column(children: [cal, const SizedBox(height: 20), table])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 350, child: cal),
                    const SizedBox(width: 24),
                    Expanded(child: table),
                  ],
                ),
        );
      },
    ),
  ); }
}

class WindowsSupportScreen extends StatefulWidget {
  const WindowsSupportScreen({super.key, this.inbox});
  final DeveloperInbox? inbox;
  @override
  State<WindowsSupportScreen> createState() => _WindowsSupportScreenState();
}

class _WindowsSupportScreenState extends State<WindowsSupportScreen> {
  final _message = TextEditingController();
  final _subject = TextEditingController();
  String _category = 'General';
  final _support = SchoolSupportClient();
  late final DeveloperInbox _inbox = widget.inbox ?? DeveloperInbox();
  bool get _ownsInbox => widget.inbox == null;
  Timer? _inboxTimer;
  @override
  void initState() {
    super.initState();
    if (_ownsInbox) {
      unawaited(_inbox.initialize());
      _inboxTimer = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(_inbox.tick()));
      unawaited(_inbox.flushSupport());
    }
  }
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _inboxTimer?.cancel();
    if (_ownsInbox) _inbox.dispose();
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    final body = _message.text.trim();
    final subject = _subject.text.trim();
    if (subject.isEmpty || body.length < 10) {
      setState(
        () => _error = 'Enter a subject and describe the problem in at least 10 characters.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await CentralSchoolCloud.saved();
      final text = 'Subject: $subject\nCategory: $_category\n\n$body';
      if (text.length > 3000) throw StateError('Total complaint is too long.');
      bool sent = true;
      if (account['managed'] == true) {
        sent = await _support.send(text, WindowsPlatformClient.version);
      } else {
        await WindowsPlatformClient.instance.complaint(text);
      }
      if (!mounted) return;
      _message.clear();
      _subject.clear();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(sent
          ? 'Complaint sent to the developer.'
          : 'Complaint saved locally. Delivery pending — see Complaint history.')));
      unawaited(_inbox.refresh());
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) { WindowsAppearance.watch(context); return  Scaffold(
    appBar: AppBar(title: const Text('App Support'), actions: [TextButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WindowsComplaintHistory())), icon: const Icon(Icons.history), label: const Text('Complaint history'))]),
    body: Stack(children: [SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 28, 92, 28),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Contact the developer',
                style: TextStyle(fontFamily: 'Segoe UI', fontSize: 25, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'Tell us which screen had a problem and what happened.',
              ),
              const SizedBox(height: 22),
              TextField(controller: _subject, enabled: !_busy, maxLength: 120,
                decoration: const InputDecoration(labelText: 'Subject')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [for (final c in ['General','Sync Engine','Student Records','Fees','Exam Center','Attendance','Staff salary','App update','Other'])
                  DropdownMenuItem(value: c, child: Text(c))],
                onChanged: _busy ? null : (v) => setState(() => _category = v ?? 'General')),
              const SizedBox(height: 12),
              TextField(
                controller: _message,
                enabled: !_busy,
                minLines: 7,
                maxLines: 12,
                maxLength: 2800,
                decoration: const InputDecoration(
                  labelText: 'Your complaint',
                  hintText: 'Describe the issue. Do not include passwords.',
                ),
              ),
              if (_error != null)
                Text(_error!, style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.redAccent))),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _busy ? null : _send,
                icon: const Icon(Icons.send_outlined),
                label: Text(_busy ? 'Sending…' : 'Send complaint'),
              ),
            ],
          ),
        ),
      ),
    ),
      Positioned(top: 28, right: 28, child: AnimatedBuilder(
        animation: _inbox,
        builder: (context, _) { WindowsAppearance.watch(context); return  IconButton(
          tooltip: 'Notifications',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (appearanceContext) { WindowsAppearance.watch(appearanceContext); return  DeveloperInboxScreen(inbox: _inbox); })),
          icon: Badge(isLabelVisible: _inbox.unread > 0,
            label: Text('${_inbox.unread}'), child: const Icon(Icons.notifications_outlined)),
        ); },
      )),
    ]),
  ); }
}

class SchoolPromotionService {
  static int? nextClassNumber(int current) {
    if (current < 1 || current > 12)
      throw ArgumentError('Invalid student class.');
    return current == 12 ? null : current + 1;
  }

  static Future<bool> forceEnabled() async =>
      (await FirebaseFirestore.instance
              .collection('school_settings')
              .doc('promotion_policy')
              .get())
          .data()?['allowForcedPromotion'] ==
      true;
  static Future<bool> isFinal(
    Map<String, dynamic> exam, {
    DateTime? now,
    int? rolloverMonth,
    bool allowPreviousSession = false,
  }) async {
    final db = FirebaseFirestore.instance,
        profile = FirebaseFirestore.instance.activeProfileId;
    final id = exam['examId']?.toString() ?? '';
    if (id.isEmpty) return false;
    final definitions = await Future.wait([
      db.collection('exams').doc(id).get(),
      db.collection('_local_exam_center_exams').doc(id).get(),
      db.collection('school_settings').doc('exam_$id').get(),
    ]);
    if (db.activeProfileId != profile)
      throw StateError('School changed during final-exam verification.');
    final month = rolloverMonth ?? await PromotionSessionPolicy.rolloverMonth();
    final existing = definitions.where((d) => d.exists).toList();
    final definition = existing.isEmpty ? null : existing.first.data();
    return definition?['isFinal'] == true &&
        PromotionSessionPolicy.matches(
          definition!,
          now ?? DateTime.now(),
          month,
          allowPreviousSession: allowPreviousSession,
        );
  }

  /// A promotion is a stable-person class update, never a delete/create.
  /// The durable local student + audit batch is sent by the existing Sync Engine.
  static Future<String> apply({
    required String studentId,
    required Map<String, dynamic> student,
    required Map<String, dynamic> exam,
    required String result,
    bool force = false,
    String reason = '',
  }) async {
    final db = FirebaseFirestore.instance;
    final profile = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    void own() {
      if (db.activeProfileId != profile ||
          (db.activeProfileIdentity['schoolSyncId']?.toString() ?? '') != school) {
        throw StateError('School changed during promotion. Reopen Exam Center.');
      }
    }

    final examId = exam['examId']?.toString().trim() ?? '';
    if (studentId.isEmpty || examId.isEmpty || studentId.contains('/')) {
      throw StateError('Valid exam and student IDs are required.');
    }
    if (force) {
      await WindowsAdminSecurity.requireConsumedAction(
        scope:'force-promotion',target:'$studentId/$examId');
      own();
    }
    if (!await isFinal(exam, allowPreviousSession: force)) {
      throw StateError('Only a verified completed Final Exam can change class.');
    }
    own();
    final definition =
        (await db.collection('exams').doc(examId).get()).data() ??
        (await db.collection('_local_exam_center_exams').doc(examId).get()).data();
    own();
    if (definition == null || definition['isFinal'] != true) {
      throw StateError('Final Exam definition is unavailable.');
    }
    final verifiedResult =
        (await db.collection('exam_center_results')
                .doc('${examId}_$studentId').get()).data() ??
        (await db.collection('exam_results')
                .doc('${examId}_$studentId').get()).data() ??
        (await db.collection('_local_exam_center_results')
                .doc('${examId}_$studentId').get()).data();
    own();
    if (verifiedResult == null ||
        verifiedResult['examId'] != null && verifiedResult['examId'] != examId ||
        verifiedResult['studentId'] != null &&
            verifiedResult['studentId'] != studentId ||
        verifiedResult['result'] != result ||
        !{'PASS', 'FAIL'}.contains(result)) {
      throw StateError('Save a matching verified final result before approval.');
    }
    final session = definition['academicSession']?.toString() ?? '';
    final resultSession = verifiedResult['academicSession']?.toString() ?? '';
    if (session != resultSession) {
      throw StateError('Result and Final Exam academic sessions differ.');
    }
    final subjects = (definition['subjects'] as List? ?? [])
        .map((s) => s.toString()).toList();
    if (subjects.isEmpty ||
        subjects.any((subject) => subject.trim().isEmpty) ||
        subjects.map((s) => s.toLowerCase().trim()).toSet().length !=
            subjects.length) {
      throw StateError('Valid Final Exam subjects are required before promotion.');
    }
    {
      final marks = verifiedResult['marks'];
      final maximum = definition['fullMarks'] ?? verifiedResult['fullMarks'];
      final pass = definition['passMarks'] ?? verifiedResult['passMarks'];
      if (marks is! Map || maximum is! num || pass is! num ||
          !maximum.isFinite || maximum <= 0 || !pass.isFinite ||
          pass < 0 || pass > maximum ||
          marks.length != subjects.length ||
          marks.keys.any((k) => !subjects.contains(k)) ||
          subjects.any((s) => marks[s] is! num ||
              !(marks[s] as num).isFinite ||
              (marks[s] as num) < 0 || (marks[s] as num) > maximum)) {
        throw StateError('Final Exam subject marks must be complete and valid.');
      }
      final computed = subjects.every((s) => (marks[s] as num) >= pass)
          ? 'PASS' : 'FAIL';
      if (computed != result) {
        throw StateError('Final result disagrees with saved marks.');
      }
    }
    if (force && (reason.trim().isEmpty || reason.trim().length > 500)) {
      throw StateError('Enter an admin override reason (maximum 500 characters).');
    }
    if (force && !await forceEnabled()) {
      throw StateError('Administrator force-promotion policy is disabled.');
    }
    own();

    final ref = db.collection('students_directory').doc(studentId);
    final live = (await ref.get()).data();
    own();
    if (live == null) throw StateError('Student changed. Refresh Exam Center.');
    if (live['deleted'] == true || live['_syncDeleted'] == true ||
        live['active'] == false ||
        live['status']?.toString().toLowerCase() == 'inactive') {
      throw StateError('Inactive/deleted student cannot be promoted.');
    }
    if (live['schoolId'] != null && live['schoolId'] != school) {
      throw StateError('This student belongs to another school.');
    }
    if (definition['schoolId'] != null && definition['schoolId'] != school ||
        verifiedResult['schoolId'] != null && verifiedResult['schoolId'] != school) {
      throw StateError('Foreign final exam or result.');
    }
    final stableId = live['mobileStableId'] ?? studentId;
    if (verifiedResult['personId'] != null &&
        verifiedResult['personId'] != stableId) {
      throw StateError('Result belongs to a previous student identity.');
    }
    if (live['classMovement'] == 'GRADUATED') {
      throw StateError('A graduated student cannot be promoted again.');
    }
    if (live['promotionExamId'] == examId) {
      if (live['classMovement'] == 'RETAINED' &&
          result == 'FAIL' && !force) return 'Already retained';
      if (live['classMovement'] != 'RETAINED') return 'Already processed';
    }
    if (force && (result != 'FAIL' ||
        live['classMovement'] != 'RETAINED' ||
        live['promotionExamId'] != examId)) {
      throw StateError('Override is allowed only for this retained Final Exam.');
    }
    int classNo(dynamic v) => int.tryParse(
        v?.toString().replaceAll(RegExp(r'[^0-9]'), '') ?? '') ?? 0;
    final currentClass = classNo(live['class']);
    if (currentClass < 1 || currentClass > 12) {
      throw StateError('Invalid current student class.');
    }
    final definedClass = classNo(definition['studentClass']);
    final resultClass = classNo(verifiedResult['studentClass']);
    if (live['studentClass'] != null &&
        classNo(live['studentClass']) != currentClass) {
      throw StateError('Conflicting student class fields; reconcile before promotion.');
    }
    if ((definedClass != 0 && definedClass != currentClass) ||
        (resultClass != 0 && resultClass != currentClass)) {
      throw StateError('Student class changed since the Final Exam result.');
    }
    final movement = result == 'FAIL' && !force ? 'RETAINED' :
        currentClass == 12 ? 'GRADUATED' :
        force ? 'FORCE_PROMOTED' : 'PROMOTED';
    final nextClass = movement == 'PROMOTED' || movement == 'FORCE_PROMOTED'
        ? 'Class ${currentClass + 1}' : live['class']?.toString() ?? '';
    final roll = live['rollNo']?.toString() ?? '';
    if (nextClass != live['class']) {
      // Reject occupied slots; never generate a replacement student ID.
      final directory = await db.collection('students_directory').get();
      own();
      if (directory.docs.any((row) =>
          row.id != studentId &&
          row.data()['class'] == nextClass &&
          row.data()['rollNo']?.toString() == roll &&
          (row.data()['section']?.toString().trim() ?? '') ==
              (live['section']?.toString().trim() ?? '') &&
          row.data()['deleted'] != true &&
          row.data()['_syncDeleted'] != true)) {
        throw StateError('Roll $roll in $nextClass is occupied. Resolve before promotion.');
      }
    }
    own();
    final now = DateTime.now().millisecondsSinceEpoch;
    final shared = <String, dynamic>{
      'promotionExamId': examId,
      'lastExamResult': result,
      'lastExamName': definition['examName'] ?? 'Final exam',
      'lastExamTimestamp': now,
      'classChangedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
      'promotionPending': true,
      'promotionSyncState': 'Pending',
      'promotionError': '',
      'classChangedAt': FieldValue.serverTimestamp(),
      'classMovement': movement,
      'promotionTransactionId': 'promotion:$examId:$studentId',
      if (force) 'promotionOverrideReason': reason.trim(),
    };
    final batch = db.batch();
    // Local serialized compare-and-swap blocks stale/duplicate approvals.
    batch.requireUnchanged(ref, live);
    batch.set(ref, {
      ...live, ...shared,
      if (school.isNotEmpty) 'schoolId': school,
      if (nextClass != live['class']) 'previousClass': live['class'],
      'class': nextClass,
      if (live.containsKey('studentClass')) 'studentClass': nextClass,
    });
    final eventRef = db.collection('school_settings')
        .doc('promotion_event_${examId}_${studentId}_$movement');
    if (eventRef.id.length > 200) {
      throw StateError('Promotion audit identity too long; student needs review.');
    }
    batch.requireUnchanged(eventRef, null);
    batch.set(
      eventRef,
      {
        'schoolId': school,
        'studentId': studentId, 'personId': stableId,
        'examId': examId, 'academicSession': session,
        'fromClass': live['class'], 'toClass': nextClass,
        'result': result, 'movement': movement, 'at': now,
        'reason': reason.trim(), 'manualAdminOverride': force,
        'actor': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
      },
    );
    batch.set(
      db.collection('school_settings').doc('promotion_audit_${examId}_$studentId'),
      {
        'schoolId': school,
        'studentId': studentId,
        'personId': stableId,
        'fromClass': live['class'],
        'toClass': nextClass,
        'examId': examId,
        'academicSession': session,
        'result': result,
        'movement': movement,
        'at': now,
        'reason': reason.trim(),
        'manualAdminOverride': force,
        'actor': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
        'syncState': 'Pending',
        'transactionId': 'promotion:$examId:$studentId',
      },
    );
    own();
    await batch.commit();
    own();
    if (movement == 'RETAINED') return 'Retained in $nextClass';
    if (movement == 'GRADUATED') return 'Completed Class 12';
    return 'Promoted to $nextClass • Roll $roll (sync pending)';
  }
}

class PromotionPolicySwitch extends StatefulWidget {
  const PromotionPolicySwitch({super.key});
  @override
  State<PromotionPolicySwitch> createState() => _PromotionPolicySwitchState();
}

class _PromotionPolicySwitchState extends State<PromotionPolicySwitch> {
  bool _enabled = false;
  @override
  void initState() {
    super.initState();
    SchoolPromotionService.forceEnabled().then((v) {
      if (mounted) setState(() => _enabled = v);
    });
  }

  @override
  Widget build(BuildContext context) { WindowsAppearance.watch(context); return  SwitchListTile(
    value: _enabled,
    title: const Text('Allow force promotion of retained students'),
    subtitle: const Text(
      'Final-exam FAIL normally keeps a student in the same class. This switch enables an administrator override.',
    ),
    onChanged: (v) async {
      final db = FirebaseFirestore.instance;
      final profile = db.activeProfileId;
      try {
        final approved=await requestWindowsAdminApproval(context,
          scope:'protected-settings',target:'school_settings/promotion_policy');
        if(approved==null || !mounted || db.activeProfileId!=profile)return;
        await WindowsAdminSecurity.consumeApproval(token:approved,
          scope:'protected-settings',target:'school_settings/promotion_policy');
        if(!mounted || db.activeProfileId!=profile)return;
        await db.collection('school_settings').doc('promotion_policy').set({
          'allowForcedPromotion':v,
          'updatedBy':FirebaseAuth.instance.currentUser?.email ?? 'Admin',
          'updatedAt':FieldValue.serverTimestamp(),
        });
        if(mounted && db.activeProfileId==profile)setState(()=>_enabled=v);
      }catch(error){
        if(mounted)ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content:Text('Administrator approval failed: $error')));
      }
    },
  ); }
}
