import 'windows_ui_localization.dart';
import 'dart:convert';
import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'windows_local_firestore.dart';
import 'windows_local_auth.dart';
import 'windows_backend_bridge.dart';
import 'windows_connection_center.dart';
import 'windows_platform_client.dart';
import 'windows_school_identity.dart';

String schoolDateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class SchoolAttendanceOverview extends StatefulWidget {
  const SchoolAttendanceOverview({super.key});
  @override
  State<SchoolAttendanceOverview> createState() =>
      _SchoolAttendanceOverviewState();
}

class _SchoolAttendanceOverviewState extends State<SchoolAttendanceOverview> {
  DateTime _day = DateTime.now();
  String _role = 'student';
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _records = [];
  Map<String, dynamic> _calendar = {};
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final records = await FirebaseFirestore.instance
          .collection('attendance_records')
          .get();
      final calendar = await FirebaseFirestore.instance
          .collection('school_calendar')
          .doc(schoolDateKey(_day))
          .get();
      if (mounted)
        setState(() {
          _records = records.docs
              .map((d) => {'id': d.id, ...d.data()})
              .where(
                  (d) => d['date'] == schoolDateKey(_day) && d['role'] == _role)
              .toList();
          _calendar = calendar.data() ?? {};
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
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
    bool open = _calendar['isOpen'] is bool
        ? _calendar['isOpen']
        : _day.weekday != DateTime.sunday;
    final reason =
        TextEditingController(text: _calendar['reason']?.toString() ?? '');
    final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                    title: Text('School calendar • ${schoolDateKey(_day)}'),
                    content: SizedBox(
                        width: 400,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          SwitchListTile(
                              value: open,
                              onChanged: (v) => setD(() => open = v),
                              title:
                                  Text(open ? 'School open' : 'School closed'),
                              subtitle: const Text(
                                  'Closed days block attendance for students and teachers.')),
                          TextField(
                              controller: reason,
                              decoration: const InputDecoration(
                                  labelText: 'Reason / holiday name'))
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Save date'))
                    ])));
    if (saved == true) {
      await FirebaseFirestore.instance
          .collection('school_calendar')
          .doc(schoolDateKey(_day))
          .set({
        'date': schoolDateKey(_day),
        'isOpen': open,
        'reason': reason.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin'
      });
      await WindowsConnectionCenter.refreshProfileAndSync();
      if (mounted) _load();
    }
    reason.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: const Text('Attendance & school calendar'),
          actions: [
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh))
          ]),
      body: LayoutBuilder(builder: (ctx, c) {
        final cal = Card(
            child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('School calendar',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      CalendarDatePicker(
                          initialDate: _day,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                          onDateChanged: (d) {
                            setState(() => _day = d);
                            _load();
                          }),
                      Text(
                          (_calendar['isOpen'] is bool
                                  ? _calendar['isOpen']
                                  : _day.weekday != DateTime.sunday)
                              ? 'School open'
                              : 'School closed',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      if ((_calendar['reason']?.toString() ?? '').isNotEmpty)
                        Text(_calendar['reason'].toString()),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                          onPressed: _calendarEdit,
                          icon: const Icon(Icons.edit_calendar),
                          label: const Text('Set open / closed'))
                    ])));
        final table =
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 10,
              children: [
                Text(schoolDateKey(_day),
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.bold)),
                SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'student', label: Text('Students')),
                      ButtonSegment(value: 'teacher', label: Text('Teachers'))
                    ],
                    selected: {
                      _role
                    },
                    onSelectionChanged: (v) {
                      setState(() => _role = v.first);
                      _load();
                    })
              ]),
          const SizedBox(height: 18),
          Text(
              '${_records.length} check-ins • ${_records.where((r) => r['checkOut'] != null).length} check-outs',
              style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 16),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          if (!_loading && _records.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 35),
                child: Text('No attendance records for this date.')),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Name')),
                    DataColumn(label: Text('Class / ID')),
                    DataColumn(label: Text('Check-in')),
                    DataColumn(label: Text('Check-out')),
                    DataColumn(label: Text('Date'))
                  ],
                  rows: _records
                      .map((r) => DataRow(cells: [
                            DataCell(Text(r['name']?.toString() ?? '')),
                            DataCell(Text(_role == 'student'
                                ? '${r['studentClass']} • ${r['rollNo']}'
                                : r['personId']?.toString() ?? '')),
                            DataCell(Text(_time(r['checkIn']))),
                            DataCell(Text(_time(r['checkOut']))),
                            DataCell(Text(r['date'].toString()))
                          ]))
                      .toList()))
        ]);
        return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: c.maxWidth < 950
                ? Column(children: [cal, const SizedBox(height: 20), table])
                : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 350, child: cal),
                    const SizedBox(width: 24),
                    Expanded(child: table)
                  ]));
      }));
}

class WindowsSupportScreen extends StatefulWidget {
  const WindowsSupportScreen({super.key});
  @override
  State<WindowsSupportScreen> createState() => _WindowsSupportScreenState();
}

class _WindowsSupportScreenState extends State<WindowsSupportScreen> {
  final _message = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_message.text.trim().length < 10) {
      setState(
          () => _error = 'Describe the problem in at least 10 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await WindowsPlatformClient.instance.complaint(_message.text.trim());
      _message.clear();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Complaint sent to the developer.')));
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Report app problem')),
      body: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('Contact the developer',
                            style: TextStyle(
                                fontSize: 25, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        const Text(
                            'Tell us which screen had a problem and what happened.'),
                        const SizedBox(height: 22),
                        TextField(
                            controller: _message,
                            minLines: 7,
                            maxLines: 12,
                            maxLength: 3000,
                            decoration: const InputDecoration(
                                labelText: 'Your complaint',
                                hintText:
                                    'Describe the issue. Do not include passwords.')),
                        if (_error != null)
                          Text(_error!,
                              style: const TextStyle(color: Colors.redAccent)),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                            onPressed: _busy ? null : _send,
                            icon: const Icon(Icons.send_outlined),
                            label: Text(_busy ? 'Sending…' : 'Send complaint'))
                      ])))));
}

class SchoolPromotionService {
  static int? nextClassNumber(int current) {
    if (current < 1 || current > 12) throw ArgumentError('Invalid student class.');
    return current == 12 ? null : current + 1;
  }
  static Future<bool> forceEnabled() async =>
      (await FirebaseFirestore.instance
              .collection('school_settings')
              .doc('promotion_policy')
              .get())
          .data()?['allowForcedPromotion'] ==
      true;
  static Future<bool> isFinal(Map<String, dynamic> exam) async {
    if (exam['isFinal'] == true) return true;
    final d = await FirebaseFirestore.instance
        .collection('school_settings')
        .doc('exam_${exam['examId']}')
        .get();
    return d.data()?['isFinal'] == true;
  }

  static Future<String> apply(
      {required String studentId,
      required Map<String, dynamic> student,
      required Map<String, dynamic> exam,
      required String result,
      bool force = false}) async {
    if (!await isFinal(exam))
      throw StateError(
          'Promotion or retention is available only after a final exam.');
    if (result != 'PASS' && result != 'FAIL')
      throw StateError('Final PASS/FAIL result is missing.');
    if (force && !await forceEnabled())
      throw StateError(
          'Enable the administrator force-promotion switch first.');
    final ref = FirebaseFirestore.instance
        .collection('students_directory')
        .doc(studentId);
    final live = await SchoolPersonIdentity.ensure('students_directory',studentId);
    final examId = exam['examId']?.toString() ?? '';
    if (examId.isEmpty) throw StateError('Final exam ID missing.');
    if (live['promotionExamId'] == examId &&
        live['classMovement'] != 'RETAINED') return 'Already processed';
    final classNo = int.tryParse(
            live['class']?.toString().replaceAll(RegExp(r'[^0-9]'), '') ??
                '') ??
        0;
    if (classNo < 1 || classNo > 12) throw StateError('Invalid student class.');
    final shared = {
      'promotionExamId': examId,
      'lastExamResult': result,
      'lastExamName': exam['examName'] ?? 'Final exam',
      'lastExamTimestamp': DateTime.now().millisecondsSinceEpoch,
      'classChangedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
      'promotionPending': false,
      'promotionError': '',
      'classChangedAt': FieldValue.serverTimestamp()
    };
    if (result == 'FAIL' && !force) {
      await ref.set(
          {...shared, 'classMovement': 'RETAINED'}, SetOptions(merge: true));
      return 'Retained in ${live['class']}';
    }
    final nextClass = nextClassNumber(classNo);
    if (nextClass == null) {
      await ref.set(
          {...shared, 'classMovement': 'GRADUATED'}, SetOptions(merge: true));
      return 'Completed Class 12';
    }
    final newClass = 'Class $nextClass';
    final roll = live['rollNo']?.toString() ?? '';
    final directory = await FirebaseFirestore.instance.collection('students_directory').get();
    final occupied = directory.docs.where((d)=>d.data()['class']==newClass)
        .map((d)=>int.tryParse(d.data()['rollNo']?.toString() ?? '')).whereType<int>().toSet();
    var nextRoll = int.tryParse(roll) ?? 1;
    if(occupied.contains(nextRoll)){nextRoll=1;while(occupied.contains(nextRoll)){nextRoll++;}}
    final target = FirebaseFirestore.instance.collection('students_directory')
        .doc('${newClass}_Roll_$nextRoll');
    final stableId = live['mobileStableId'] ?? studentId;
    final url = await WindowsConnectionCenter.googleScriptUrl();
    final response = await WindowsBackendBridge.post(Uri.parse(url),
        headers: {'Content-Type': 'text/plain;charset=utf-8'},
        body: jsonEncode({
          'action': 'change_student_class',
          'oldClass': live['class'],
          'newClass': newClass,
          'rollNo': roll,
          'newRollNo': nextRoll.toString(),
          'oldStudentId': studentId,
          'newStudentId': target.id,
          'studentName': live['name'],
          'dob': live['dob'] ?? live['dateOfBirth'],
          'movement': force ? 'FORCE_PROMOTED' : 'PROMOTED',
          'examName': exam['examName'],
          'result': result,
          'updatedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin'
        }));
    final data = jsonDecode(response.body);
    if (response.statusCode >= 400 || data is! Map || data['success'] != true)
      throw StateError(data is Map
          ? data['message']?.toString() ?? 'Class sync failed'
          : 'Class sync failed');
    final aliases = List<String>.from(live['previousStudentIds'] ?? []);
    if (!aliases.contains(studentId)) aliases.add(studentId);
    final batch = FirebaseFirestore.instance.batch();
    batch.set(target, {
      ...live,
      ...shared,
      'class': newClass,
      'rollNo': nextRoll.toString(),
      'previousClass': live['class'],
      'mobileStableId': stableId,
      'previousStudentIds': aliases,
      'classMovement': force ? 'FORCE_PROMOTED' : 'PROMOTED'
    });
    batch.delete(ref);
    try { await batch.commit(); }
    catch(error){
      try { await WindowsBackendBridge.post(Uri.parse(url),
        headers:{'Content-Type':'text/plain;charset=utf-8'},body:jsonEncode({
          'action':'change_student_class','oldClass':newClass,'newClass':live['class'],
          'rollNo':nextRoll.toString(),'newRollNo':roll,'oldStudentId':target.id,
          'newStudentId':studentId,'studentName':live['name'],
          'dob':live['dob'] ?? live['dateOfBirth'],'movement':'ROLLBACK'})); } catch(_) {}
      rethrow;
    }
    return 'Promoted to $newClass • Roll $nextRoll';
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
  Widget build(BuildContext context) => SwitchListTile(
      value: _enabled,
      title: const Text('Allow force promotion of retained students'),
      subtitle: const Text(
          'Final-exam FAIL normally keeps a student in the same class. This switch enables an administrator override.'),
      onChanged: (v) async {
        await FirebaseFirestore.instance
            .collection('school_settings')
            .doc('promotion_policy')
            .set({
          'allowForcedPromotion': v,
          'updatedBy': FirebaseAuth.instance.currentUser?.email ?? 'Admin',
          'updatedAt': FieldValue.serverTimestamp()
        });
        if (mounted) setState(() => _enabled = v);
      });
}
