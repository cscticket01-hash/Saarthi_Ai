import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'windows_ui_localization.dart';
import 'windows_local_firestore.dart';
import 'windows_runtime_flags.dart';

/// Integer paise throughout calculations; rupee fields remain compatible with
/// the school-owned mobile backend's existing teacher_salary response.
class StaffPayroll {
  static Future<void> _tail = Future<void>.value();
  static String monthKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
  static int money(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return 0;
    if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(text)) {
      throw const FormatException('Enter a positive amount with at most two decimal places.');
    }
    final parts = text.split('.');
    return int.parse(parts[0]) * 100 + (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
  }
  static String format(int paise) => (paise / 100).toStringAsFixed(2);
  static int net({required int basic, int allowance = 0, int bonus = 0, int overtime = 0, int deduction = 0}) {
    if ([basic, allowance, bonus, overtime, deduction].any((v) => v < 0)) throw ArgumentError('Salary amounts cannot be negative.');
    final total = basic + allowance + bonus + overtime - deduction;
    if (total < 0) throw ArgumentError('Deductions cannot exceed earnings.');
    return total;
  }
  static String rowId(String staffId, String month) {
    if (staffId.trim().isEmpty || !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month)) throw ArgumentError('Staff and salary month are required.');
    return sha256.convert(utf8.encode(jsonEncode([staffId, month]))).toString();
  }
  static void _sameSchool(String profile) {
    if (FirebaseFirestore.instance.activeProfileId != profile) throw StateError('School changed. Reopen the salary page.');
  }
  static Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }
  static Future<List<Map<String, dynamic>>> staff(String profile) async {
    _sameSchool(profile);
    final teachers = await FirebaseFirestore.instance.collection('teachers_directory').get();
    final extra = await FirebaseFirestore.instance.collection('school_settings').doc('staff_payroll_directory').get();
    _sameSchool(profile);
    return [
      for (final d in teachers.docs) {
        'id': 'teacher:${d.id}',
        'teacherId': (d.data()['teacherId']?.toString().trim().isNotEmpty ?? false) ? d.data()['teacherId'] : d.id,
        'name': d.data()['name'] ?? d.data()['teacherName'] ?? d.id,
        'role': 'Teacher', 'designation': d.data()['designation'] ?? 'Teacher',
      },
      for (final d in (extra.data()?['staff'] as List? ?? [])) Map<String, dynamic>.from(d as Map),
    ];
  }
  static Future<void> addStaff(String profile, String name, String role, String designation) => _serial(() async {
    _sameSchool(profile);
    if (name.trim().isEmpty || name.trim().length > 120 || designation.length > 120) throw ArgumentError('Enter a staff name (up to 120 characters).');
    if (!['Office staff', 'Driver', 'Guard', 'Support staff', 'Other'].contains(role)) throw ArgumentError('Select a staff role. Add teachers in the Teachers section.');
    final ref = FirebaseFirestore.instance.collection('school_settings').doc('staff_payroll_directory');
    final previous = await ref.get();
    _sameSchool(profile);
    final people = List<dynamic>.from(previous.data()?['staff'] as List? ?? []);
    people.add({'id': 'staff:${DateTime.now().microsecondsSinceEpoch}', 'name': name.trim(), 'role': role, 'designation': designation.trim()});
    await ref.set({'staff': people}, SetOptions(merge: true));
  });
  static int paid(Map<String, dynamic> row) => (row['paidPaise'] as num?)?.toInt() ??
      (row['status']?.toString().toLowerCase() == 'paid' ? total(row) : 0);
  static int total(Map<String, dynamic> row) => (row['netPaise'] as num?)?.toInt() ?? ((row['amount'] as num? ?? 0) * 100).round();
  static Future<Map<String, dynamic>> save(String profile, Map<String, dynamic> person, String month,
      {required int basic, int allowance = 0, int bonus = 0, int overtime = 0, int deduction = 0}) => _serial(() async {
    _sameSchool(profile);
    final people = await staff(profile);
    final current = people.where((s) => s['id'] == person['id']);
    if (current.length != 1) throw StateError('Staff record is no longer available. Reload the page.');
    final employee = current.single;
    final amount = net(basic: basic, allowance: allowance, bonus: bonus, overtime: overtime, deduction: deduction);
    final id = rowId(employee['id'].toString(), month);
    final ref = FirebaseFirestore.instance.collection('teacher_salary').doc(id);
    final old = (await ref.get()).data() ?? <String, dynamic>{};
    _sameSchool(profile);
    final alreadyPaid = paid(old);
    if (amount < alreadyPaid) throw StateError('Net salary cannot be lower than the payments already recorded.');
    final row = <String, dynamic>{...old, 'id': id, 'staffId': employee['id'],
      'teacherId': employee['teacherId'] ?? '', 'name': employee['name'], 'role': employee['role'],
      'designation': employee['designation'], 'month': month, 'basicPaise': basic,
      'allowancePaise': allowance, 'bonusPaise': bonus, 'overtimePaise': overtime,
      'deductionPaise': deduction, 'netPaise': amount, 'amount': amount / 100,
      'paidPaise': alreadyPaid, 'balancePaise': amount - alreadyPaid,
      'status': alreadyPaid == amount ? 'Paid' : alreadyPaid == 0 ? 'Pending' : 'Part paid',
      'updatedAt': DateTime.now().millisecondsSinceEpoch};
    await ref.set(row);
    return row;
  });
  static Future<void> recordPayment(String profile, String id, int amount, {required String paymentId,
      required DateTime date, required String mode, String reference = ''}) => _serial(() async {
    _sameSchool(profile);
    if (amount <= 0 || paymentId.isEmpty || !['Cash', 'Bank transfer', 'UPI', 'Cheque'].contains(mode)) throw ArgumentError('Enter a valid payment amount and method.');
    final ref = FirebaseFirestore.instance.collection('teacher_salary').doc(id);
    final row = (await ref.get()).data();
    _sameSchool(profile);
    if (row == null || row['netPaise'] is! num) throw StateError('Create a monthly salary record first.');
    final payments = List<dynamic>.from(row['payments'] as List? ?? []);
    if (payments.any((p) => p['id'] == paymentId)) return; // retry is idempotent
    final next = paid(row) + amount;
    if (next > total(row)) throw StateError('Payment exceeds the remaining salary balance.');
    payments.add({'id': paymentId, 'amountPaise': amount, 'date': date.toIso8601String(), 'mode': mode, 'reference': reference.trim()});
    await ref.update({'payments': payments, 'paidPaise': next, 'balancePaise': total(row) - next,
      'status': next == total(row) ? 'Paid' : 'Part paid', 'updatedAt': DateTime.now().millisecondsSinceEpoch});
  });
}

class StaffSalaryScreen extends StatefulWidget {
  const StaffSalaryScreen({super.key});
  @override
  State<StaffSalaryScreen> createState() => _StaffSalaryScreenState();
}
class _StaffSalaryScreenState extends State<StaffSalaryScreen> {
  late final String _profile;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, dynamic>> _staff = [], _rows = [];
  bool _loading = true, _local = true;
  String _search = '', _role = 'All staff';
  String? _error;
  int _loadGeneration = 0;
  @override
  void initState() { super.initState(); _profile = FirebaseFirestore.instance.activeProfileId; _load(); }
  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() { _loading = true; _error = null; });
    try {
      final people = await StaffPayroll.staff(_profile);
      final salary = await FirebaseFirestore.instance.collection('teacher_salary').get();
      final local = await WindowsRuntimeFlags.localStorageEnabled();
      StaffPayroll._sameSchool(_profile);
      if (mounted && generation == _loadGeneration) setState(() {
        _staff = people; _rows = salary.docs.map((d) => {...d.data(), 'id': d.id}).toList(); _local = local;
      });
    } catch (e) { if (mounted && generation == _loadGeneration) setState(() => _error = '$e'); }
    finally { if (mounted && generation == _loadGeneration) setState(() => _loading = false); }
  }
  Future<void> _addStaff() async {
    final name = TextEditingController(), designation = TextEditingController();
    var role = 'Office staff';
    await _editor('Add staff member', (setDialog) => [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Staff name')),
      DropdownButtonFormField<String>(initialValue: role, decoration: const InputDecoration(labelText: 'Role'),
        items: ['Office staff', 'Driver', 'Guard', 'Support staff', 'Other'].map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
        onChanged: (v) => setDialog(() => role = v!)),
      TextField(controller: designation, decoration: const InputDecoration(labelText: 'Designation')),
      const Text('Teachers are loaded automatically from the Teachers section.'),
    ], () => StaffPayroll.addStaff(_profile, name.text, role, designation.text));
    // Dialog route may still be animating; controllers are disposed after exit.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose(); designation.dispose();
  }
  Future<void> _editor(String title, List<Widget> Function(StateSetter) fields, Future<void> Function() save) async {
    bool saving = false; String? error;
    final changed = await showDialog<bool>(context: context, barrierDismissible: false, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => PopScope(
      canPop: !saving, child: AlertDialog(title: Text(title), content: SizedBox(width: 470,
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [...fields(setD).expand((w) => [w, const SizedBox(height: 14)]),
            if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent))]))),
        actions: [TextButton(onPressed: saving ? null : () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: saving ? null : () async {
            setD(() { saving = true; error = null; });
            try { await save(); if (ctx.mounted) Navigator.pop(ctx, true); }
            catch (e) { if (ctx.mounted) setD(() { saving = false; error = '$e'; }); }
          }, child: Text(saving ? 'Saving…' : 'Save'))]))));
    if (changed == true && mounted) await _load();
  }
  Future<void> _salary(Map<String, dynamic> person, Map<String, dynamic>? old) async {
    final month = StaffPayroll.monthKey(_month);
    const keys = ['basicPaise', 'allowancePaise', 'bonusPaise', 'overtimePaise', 'deductionPaise'];
    const labels = ['Basic salary', 'Allowances', 'Bonus', 'Overtime', 'Deductions / advance adjustment'];
    final controllers = [for (final k in keys) TextEditingController(text: StaffPayroll.format((old?[k] as num?)?.toInt() ?? 0))];
    await _editor('${person['name']} • $month', (setD) {
      String net = '—';
      try { final v = controllers.map((c) => StaffPayroll.money(c.text)).toList(); net = StaffPayroll.format(StaffPayroll.net(basic:v[0],allowance:v[1],bonus:v[2],overtime:v[3],deduction:v[4])); } catch (_) {}
      return [for (var i = 0; i < controllers.length; i++) TextField(controller: controllers[i],
        keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setD(() {}),
        decoration: InputDecoration(labelText: labels[i], prefixText: '₹ ')),
        Text('Net salary: ₹$net', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const Text('Salary changes preserve all recorded payments.')];
    }, () async {
      final v = controllers.map((c) => StaffPayroll.money(c.text)).toList();
      await StaffPayroll.save(_profile, person, month, basic:v[0],allowance:v[1],bonus:v[2],overtime:v[3],deduction:v[4]);
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (final c in controllers) { c.dispose(); }
  }
  Future<void> _payment(Map<String, dynamic> row) async {
    final amount = TextEditingController(text: StaffPayroll.format(StaffPayroll.total(row) - StaffPayroll.paid(row)));
    final reference = TextEditingController();
    var mode = 'Bank transfer'; var date = DateTime.now();
    final paymentId = '${row['id']}:${DateTime.now().microsecondsSinceEpoch}';
    await _editor('Record payment • ${row['name']}', (setD) => [
      TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ ')),
      DropdownButtonFormField<String>(initialValue: mode, items: ['Cash', 'Bank transfer', 'UPI', 'Cheque'].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(), onChanged: (v) => setD(() => mode = v!)),
      TextButton.icon(icon: const Icon(Icons.event), label: Text('${date.day}/${date.month}/${date.year}'), onPressed: () async {
        final selected = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime.now());
        if (selected != null) setD(() => date = selected);
      }),
      TextField(controller: reference, decoration: const InputDecoration(labelText: 'Payment reference / note')),
      const Text('This records a payment already made. It does not transfer money.'),
    ], () => StaffPayroll.recordPayment(_profile, row['id'].toString(), StaffPayroll.money(amount.text), paymentId: paymentId, date: date, mode: mode, reference: reference.text));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    amount.dispose(); reference.dispose();
  }
  void _history(Map<String, dynamic> row) {
    final payments = row['payments'] as List? ?? [];
    showDialog<void>(context: context, builder: (ctx) => AlertDialog(title: Text('Payment history • ${row['name']}'),
      content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${row['month']} • Net ₹${StaffPayroll.format(StaffPayroll.total(row))} • Paid ₹${StaffPayroll.format(StaffPayroll.paid(row))}'),
        if (payments.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No payments recorded.')),
        for (final p in payments) ListTile(title: Text('₹${StaffPayroll.format((p['amountPaise'] as num).toInt())} • ${p['mode']}'),
          subtitle: Text('${p['date'].toString().split('T').first}\n${p['reference'] ?? ''}')),
      ]))), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))]));
  }
  @override
  Widget build(BuildContext context) {
    final month = StaffPayroll.monthKey(_month);
    final rows = _rows.where((r) => r['month'] == month).toList();
    final net = rows.fold<int>(0, (v,r) => v + StaffPayroll.total(r));
    final paid = rows.fold<int>(0, (v,r) => v + StaffPayroll.paid(r));
    final people = _staff.where((s) => (_role == 'All staff' || s['role'] == _role) && '${s['name']} ${s['designation']}'.toLowerCase().contains(_search.toLowerCase())).toList();
    return Scaffold(appBar: AppBar(title: const Text('Staff salary'), actions: [IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: _loading ? const Center(child: CircularProgressIndicator()) : ListView(padding: const EdgeInsets.all(24), children: [
        const Text('School payroll', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const Text('Monthly salaries for teachers, office staff and school workers.'),
        const SizedBox(height: 20),
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          IconButton(tooltip: 'Previous month', onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)), icon: const Icon(Icons.chevron_left)),
          OutlinedButton.icon(icon: const Icon(Icons.calendar_month), label: Text(month), onPressed: () async {
            final day = await showDatePicker(context: context, initialDate: _month, firstDate: DateTime(2000), lastDate: DateTime(2100));
            if (day != null && mounted) setState(() => _month = DateTime(day.year, day.month));
          }),
          IconButton(tooltip: 'Next month', onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)), icon: const Icon(Icons.chevron_right)),
          FilledButton.icon(onPressed: _addStaff, icon: const Icon(Icons.person_add_alt), label: const Text('Add staff member')),
        ]),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, children: [
          _summary('Net payroll', net, Colors.purpleAccent), _summary('Paid', paid, Colors.tealAccent), _summary('Balance due', net - paid, Colors.orangeAccent),
        ]),
        const SizedBox(height: 16),
        if (!_local) const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Local Data is OFF. Unsynced salary changes stay in this session only. Enable Local Data to keep them on this computer.'))),
        const Text('Records belong to the active school. Teacher salary appears in the teacher app after school sync.'),
        if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
        const SizedBox(height: 16),
        Wrap(spacing: 16, runSpacing: 12, children: [SizedBox(width: 300, child: TextField(onChanged: (v) => setState(() => _search = v), decoration: const InputDecoration(labelText: 'Search staff', prefixIcon: Icon(Icons.search)))),
          SizedBox(width: 210, child: DropdownButtonFormField<String>(initialValue: _role, decoration: const InputDecoration(labelText: 'Role'),
            items: ['All staff', 'Teacher', 'Office staff', 'Driver', 'Guard', 'Support staff', 'Other'].map((r) => DropdownMenuItem(value:r,child:Text(r))).toList(), onChanged: (v) => setState(() => _role = v!))) ]),
        const SizedBox(height: 20),
        if (people.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Text('No staff found. Add a teacher in Teachers, or add a staff member here.')),
        for (final person in people) _personCard(person, rows),
        // Preserve visibility of older salary records, even if a staff profile
        // was later removed. No financial record is silently deleted.
        for (final row in rows.where((r) => !_staff.any((s) => s['id'] == r['staffId'])))
          Card(child: ListTile(title: Text('${row['name'] ?? row['teacherId'] ?? 'Previous staff'} • ₹${StaffPayroll.format(StaffPayroll.total(row))}'), subtitle: Text('${row['status'] ?? 'Previous record'}'), trailing: IconButton(icon: const Icon(Icons.history), onPressed: () => _history(row)))),
      ]));
  }
  Widget _summary(String label, int value, Color color) => SizedBox(width: 240, child: Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label), const SizedBox(height: 8), Text('₹${StaffPayroll.format(value)}', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color))]))));
  Widget _personCard(Map<String, dynamic> person, List<Map<String, dynamic>> rows) {
    final matching = rows.where((r) => r['staffId'] == person['id']);
    final row = matching.isEmpty ? null : matching.first;
    return Card(margin: const EdgeInsets.only(bottom: 12), child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(person['name'].toString(), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
      Text('${person['role']} • ${person['designation']}'),
      const SizedBox(height: 12),
      Text(row == null ? 'Salary not set for this month.' : '${row['status']} • Net ₹${StaffPayroll.format(StaffPayroll.total(row))} • Paid ₹${StaffPayroll.format(StaffPayroll.paid(row))} • Due ₹${StaffPayroll.format(StaffPayroll.total(row) - StaffPayroll.paid(row))}'),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 8, children: [OutlinedButton.icon(onPressed: () => _salary(person, row), icon: const Icon(Icons.edit_outlined), label: Text(row == null ? 'Set salary' : 'Edit salary')),
        if (row != null && StaffPayroll.paid(row) < StaffPayroll.total(row)) FilledButton.icon(onPressed: () => _payment(row), icon: const Icon(Icons.payments_outlined), label: const Text('Record payment')),
        if (row != null) TextButton.icon(onPressed: () => _history(row), icon: const Icon(Icons.history), label: const Text('Payment history')),
      ]),
    ])));
  }
}
