import 'windows_payment_confirmation.dart';
import 'windows_appearance.dart';
import 'windows_other_staff.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'windows_payslip_template.dart';
import 'package:printing/printing.dart';
import 'windows_document_templates.dart';
import 'windows_salary_history.dart';
import 'windows_salary_payment_correction.dart';
import 'windows_local_settings.dart';
import 'windows_receipt_print_dialog.dart';
import 'windows_save_pdf.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'windows_ui_localization.dart';
import 'windows_local_firestore.dart';

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
    final extra = await OtherStaffDirectory.load(profile);
    _sameSchool(profile);
    return [
      for (final d in teachers.docs) {
        'id': 'teacher:${d.id}',
        'teacherId': (d.data()['teacherId']?.toString().trim().isNotEmpty ?? false) ? d.data()['teacherId'] : d.id,
        'employeeId': d.data()['teacherId'] ?? d.id,
        'name': d.data()['name'] ?? d.data()['teacherName'] ?? d.id,
        'role': 'Teacher', 'designation': d.data()['designation'] ?? 'Teacher',
      },
      for (final d in extra.where((p)=>p['active']!=false)) d,
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
      'teacherId': employee['teacherId'] ?? '', 'employeeId':employee['employeeId']??employee['teacherId']??'', 'name': employee['name'], 'role': employee['role'],
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
    if (payments.any((p) => p is! Map)) throw StateError('Stored payment history requires review. Original payments retained.');
    final prior = payments.where((p) => p is Map && p['id'] == paymentId).toList();
    if (prior.isNotEmpty) {
      // A repeated submit is idempotent only for this exact financial intent.
      // Reusing an ID for a correction must not falsely report a saved change.
      final same = prior.length == 1 && prior.single['amountPaise'] == amount &&
          prior.single['date'] == date.toIso8601String() &&
          prior.single['mode'] == mode && prior.single['reference'] == reference.trim();
      if (!same) throw StateError('Payment identity already belongs to different details. Original payment retained; review the correction.');
      return;
    }
    final next = paid(row) + amount;
    if (next > total(row)) throw StateError('Payment exceeds the remaining salary balance.');
    payments.add({'id': paymentId, 'amountPaise': amount, 'date': date.toIso8601String(), 'mode': mode, 'reference': reference.trim(), 'timeRecorded': true, 'recordedAt': DateTime.now().millisecondsSinceEpoch});
    await ref.update({'payments': payments, 'paidPaise': next, 'balancePaise': total(row) - next,
      'status': next == total(row) ? 'Paid' : 'Part paid', 'updatedAt': DateTime.now().millisecondsSinceEpoch});
  });

  /// A payment correction is a new immutable event, not a rewrite of the
  /// original record. Every write re-reads the current row under the existing
  /// serialized school-local queue before checking its expected amount.
  static Future<void> correctPayment(
    String profile,
    String salaryRowId,
    String paymentId, {
    required int expectedPaise,
    required int correctedPaise,
    required String reason,
    required String correctionId,
    required String appLockPassword,
  }) => _serial(() async {
    _sameSchool(profile);
    await WindowsLocalSecurity.initialize();
    if (!WindowsLocalSecurity.configured ||
        !WindowsLocalSecurity.verifyPassword(appLockPassword)) {
      throw StateError('App Lock verification required to modify a salary payment.');
    }
    final explanation = SalaryPaymentCorrectionPolicy.validateNote(reason);
    if (correctedPaise <= 0 || correctedPaise == expectedPaise ||
        expectedPaise <= 0 || correctionId.trim().isEmpty) {
      throw StateError('Enter a different, positive corrected amount.');
    }
    final doc = FirebaseFirestore.instance.collection('teacher_salary').doc(salaryRowId);
    final row = (await doc.get()).data();
    _sameSchool(profile);
    if (row == null || row['id'] != salaryRowId && row['id'] != null) {
      throw StateError('Salary record changed. Reopen Staff Salary.');
    }
    final payments = List<dynamic>.from(row['payments'] as List? ?? []);
    final matched = payments.where((v) => v is Map && v['id'] == paymentId).toList();
    if (matched.length != 1) throw StateError(
      'Original itemized payment not found. Legacy summaries cannot be silently modified.');
    final corrections = List<dynamic>.from(row['paymentCorrections'] as List? ?? []);
    final previous = corrections.where((v) => v is Map && v['id'] == correctionId).toList();
    if (previous.isNotEmpty) {
      if (previous.length != 1 || previous.single['paymentId'] != paymentId ||
          previous.single['previousPaise'] != expectedPaise ||
          previous.single['correctedPaise'] != correctedPaise ||
          previous.single['reason'] != explanation) {
        throw StateError('Correction ID conflicts with another operation.');
      }
      return; // A confirmed retry never creates a duplicate correction.
    }
    final effective = SalaryPaymentCorrectionPolicy.effectiveAmount(
        Map<String,dynamic>.from(matched.single as Map), corrections);
    if (effective != expectedPaise) throw StateError(
        'Someone modified this payment. Refresh and review before saving again.');
    final next = paid(row) + correctedPaise - effective;
    if (next < 0 || next > total(row)) throw StateError(
      'Correction exceeds the saved net salary. Review Edit salary first; original payment retained.');
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    corrections.add({
      'id': correctionId,
      'paymentId': paymentId,
      'originalPaise': (matched.single as Map)['amountPaise'],
      'previousPaise': effective,
      'correctedPaise': correctedPaise,
      'differencePaise': correctedPaise - effective,
      'reason': explanation,
      'authorizedBy': WindowsLocalSecurity.adminId,
      'correctedAt': timestamp,
    });
    _sameSchool(profile);
    if (!WindowsLocalSecurity.verifyPassword(appLockPassword)) {
      throw StateError('App Lock verification expired; original payment retained.');
    }
    await doc.update({
      'paymentCorrections': corrections,
      'paidPaise': next, 'balancePaise': total(row) - next,
      'status': next == total(row) ? 'Paid' : next == 0 ? 'Pending' : 'Part paid',
      'updatedAt': timestamp,
    });
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
  String _schoolName='';
  final Set<String> _selected = {};
  bool _working = false;
  int _loadGeneration = 0;
  @override
  void initState() { super.initState(); _profile = FirebaseFirestore.instance.activeProfileId; _load(); }
  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() { _loading = true; _error = null; });
    try {
      final people = await StaffPayroll.staff(_profile);
      final salary = await FirebaseFirestore.instance.collection('teacher_salary').get();
      final branding=(await FirebaseFirestore.instance.collection('school_config').doc('school_profile_cache').get()).data();
      final local = await FirebaseFirestore.instance.localPersistenceEnabled();
      StaffPayroll._sameSchool(_profile);
      if (mounted && generation == _loadGeneration) setState(() {
        _schoolName=branding?['schoolName']?.toString()??'';
        _staff = people; _rows = salary.docs.map((d) => {...d.data(), 'id': d.id}).toList(); _local = local;
      });
    } catch (e) { if (mounted && generation == _loadGeneration) setState(() => _error = '$e'); }
    finally { if (mounted && generation == _loadGeneration) setState(() => _loading = false); }
  }
  Future<void> _editor(String title, List<Widget> Function(StateSetter) fields, Future<void> Function() save, {String? paymentName, String Function()? paymentAmount}) async {
    bool saving = false; String? error;
    final changed = await showDialog<bool>(context: context, barrierDismissible: false, builder: (ctx) { WindowsAppearance.watch(ctx); return  StatefulBuilder(builder: (ctx, setD) { WindowsAppearance.watch(ctx); return  PopScope(
      canPop: !saving, child: AlertDialog(title: Text(title), content: SizedBox(width: 470,
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [...fields(setD).expand((w) => [w, SizedBox(height: 14)]),
            if (error != null) Text(error!, style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.redAccent)))]))),
        actions: [TextButton(onPressed: saving ? null : () => Navigator.pop(ctx, false), child: Text('Cancel')),
          FilledButton(onPressed: saving ? null : () async {
            setD(() { saving = true; error = null; });
            try {
              if (paymentName != null) {
                final confirmed = await confirmSchoolPayment(ctx, name: paymentName,
                  collecting: false, amount: paymentAmount!());
                if (!confirmed) {
                  if (ctx.mounted) setD(() => saving = false);
                  return;
                }
                StaffPayroll._sameSchool(_profile);
              }
              await save(); if (ctx.mounted) Navigator.pop(ctx, true);
            }
            catch (e) { if (ctx.mounted) setD(() { saving = false; error = '$e'; }); }
          }, child: Text(saving ? 'Saving…' : paymentName == null ? 'Save' : 'Pay'))])); }); });
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
        Text('Net salary: ₹$net', style: TextStyle(fontFamily: 'Segoe UI', fontSize: 20, fontWeight: FontWeight.bold)),
        Text('Salary changes preserve all recorded payments.')];
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
      DropdownButtonFormField<String>(isExpanded: true, initialValue: mode, items: ['Cash', 'Bank transfer', 'UPI', 'Cheque'].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(), onChanged: (v) => setD(() => mode = v!)),
      TextButton.icon(icon: Icon(Icons.event), label: Text('${date.day}/${date.month}/${date.year}'), onPressed: () async {
        final selected = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime.now());
        if (selected != null) setD(() => date = DateTime(selected.year, selected.month, selected.day, date.hour, date.minute, date.second));
      }),
      TextButton.icon(icon: Icon(Icons.schedule), label: Text('Payment time: ${salaryPaymentTime(date)}'), onPressed: () async {
        final selected = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(date));
        if (selected != null) setD(() => date = DateTime(date.year, date.month, date.day, selected.hour, selected.minute));
      }),
      TextField(controller: reference, decoration: const InputDecoration(labelText: 'Payment reference / note')),
      Text('This records a payment already made. It does not transfer money.'),
    ], () => StaffPayroll.recordPayment(_profile, row['id'].toString(), StaffPayroll.money(amount.text), paymentId: paymentId, date: date, mode: mode, reference: reference.text), paymentName: row['name']?.toString() ?? 'Staff member',
      paymentAmount: () {
        final value = StaffPayroll.money(amount.text);
        if (value <= 0 || value > StaffPayroll.total(row) - StaffPayroll.paid(row)) throw StateError('Enter an amount within the remaining salary balance.');
        return '₹${StaffPayroll.format(value)}';
      });
    await Future<void>.delayed(const Duration(milliseconds: 250));
    amount.dispose(); reference.dispose();
  }

  Future<void> _correctPayment(Map<String,dynamic> salary) async {
    StaffPayroll._sameSchool(_profile);
    final raw = List<dynamic>.from(salary['payments'] as List? ?? []);
    final eligible = raw.whereType<Map>().where((p) =>
        p['id'] is String && p['amountPaise'] is num).toList();
    if (eligible.isEmpty) {
      setState(() => _error = 'This is a legacy paid total without individual payment details. Open payment history for review; automatic correction is blocked.');
      return;
    }
    await WindowsLocalSecurity.initialize();
    if (!WindowsLocalSecurity.configured) {
      setState(() => _error = 'Configure this school App Lock before modifying payment records.');
      return;
    }
    final lock = TextEditingController();
    String? password;
    try {
      password = await showDialog<String>(context: context, barrierDismissible:false,
        builder: (dialog) {
          String? error;
          return StatefulBuilder(builder:(context, refresh) => AlertDialog(
            title: const Text('App Lock • Modify Payment'),
            content: SizedBox(width:410, child:Column(mainAxisSize:MainAxisSize.min,
              crossAxisAlignment:CrossAxisAlignment.start, children:[
                const Text('Confirm your school App Lock password before changing this financial record.'),
                const SizedBox(height:16),
                TextField(controller:lock, obscureText:true, autofocus:true,
                  decoration:const InputDecoration(labelText:'App Lock password')),
                if(error!=null) Padding(padding:const EdgeInsets.only(top:10),
                  child:Text(error!,style:const TextStyle(color:Colors.redAccent))),
              ])),
            actions:[
              TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Cancel')),
              FilledButton(onPressed:(){
                if (FirebaseFirestore.instance.activeProfileId != _profile ||
                    !WindowsLocalSecurity.verifyPassword(lock.text)) {
                  refresh(()=>error='App Lock incorrect or school changed.');
                  return;
                }
                Navigator.pop(dialog,lock.text);
              },child:const Text('Unlock')),
            ],
          ));
        });
    } finally { lock.dispose(); }
    if (password == null || !mounted) return;
    StaffPayroll._sameSchool(_profile);
    final corrections = List<dynamic>.from(salary['paymentCorrections'] as List? ?? []);
    final choices = <String,Map<String,dynamic>>{};
    for(final rawPayment in eligible) {
      final payment = Map<String,dynamic>.from(rawPayment);
      final id = payment['id'] as String;
      if(choices.containsKey(id)) continue;
      choices[id]=payment;
    }
    var selected = choices.keys.first;
    final amount = TextEditingController();
    final note = TextEditingController();
    int effective(String id) => SalaryPaymentCorrectionPolicy.effectiveAmount(
      choices[id]!,corrections);
    amount.text=StaffPayroll.format(effective(selected));
    final correctionId='${salary['id']}:correction:${DateTime.now().microsecondsSinceEpoch}';
    try {
      await _editor('Modify Payment • ${salary['name']}', (setD) => [
        DropdownButtonFormField<String>(
          value:selected,isExpanded:true,
          decoration:const InputDecoration(labelText:'Recorded payment to correct'),
          items:[for(final item in choices.entries)DropdownMenuItem(
            value:item.key,
            child:Text('Original ₹${StaffPayroll.format((item.value['amountPaise'] as num).toInt())} • ${item.key}',
              maxLines:1,overflow:TextOverflow.ellipsis))],
          onChanged:(v){if(v!=null)setD((){
            selected=v;amount.text=StaffPayroll.format(effective(selected));
          });},
        ),
        Text('Previous recorded: ₹${StaffPayroll.format(effective(selected))}'),
        TextField(controller:amount,
          keyboardType:const TextInputType.numberWithOptions(decimal:true),
          decoration:const InputDecoration(labelText:'Corrected recorded amount',prefixText:'₹ '),
          onChanged:(_)=>setD((){})),
        Builder(builder: (_) {
          final candidate=int.tryParse('') ?? (() {
            try {return StaffPayroll.money(amount.text);} catch (_) {return 0;}
          })();
          final change=candidate-effective(selected);
          return Text('Adjustment: ${change>=0?'+':''}₹${StaffPayroll.format(change)} • Original entry remains in audit history.');
        }),
        TextField(controller:note,minLines:5,maxLines:9,maxLength:3500,
          decoration:const InputDecoration(labelText:'Reason / detailed audit explanation',
            hintText:'Explain what was entered, why it was wrong, what evidence was checked, and who approved the correction.'),
          onChanged:(_)=>setD((){})),
        Text('Explanation: ${SalaryPaymentCorrectionPolicy.wordCount(note.text)} / 100–300 words required.'),
        const Text('This updates the recorded salary payment, not an actual bank transfer. The original event and every correction remain visible in the payslip and history.'),
      ], () async {
        final expected=effective(selected);
        final corrected=StaffPayroll.money(amount.text);
        await StaffPayroll.correctPayment(_profile,salary['id'].toString(),selected,
          expectedPaise:expected,correctedPaise:corrected,
          reason:note.text,correctionId:correctionId,appLockPassword:password!);
      });
    } finally {
      await Future<void>.delayed(const Duration(milliseconds:250));
      amount.dispose();note.dispose();
    }
  }

  Future<void> _history([Map<String, dynamic>? row]) => Navigator.push<void>(context,
    MaterialPageRoute(builder: (_) => StaffSalaryHistoryScreen(profile: _profile,
      staffId: row == null ? null : row['staffId']?.toString() ?? 'legacy:${row['id']}', salaryRowId: row?['id']?.toString(), teacherId: row?['teacherId']?.toString(),
      staffName: row?['name']?.toString())));
  List<Map<String,dynamic>> get _monthRows => _rows.where((r) => r['month'] == StaffPayroll.monthKey(_month)).toList();
  Future<void> _output({bool csv = false, Map<String,dynamic>? row}) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      StaffPayroll._sameSchool(_profile);
      final rows = row == null ? _monthRows : [row];
      if (rows.isEmpty) throw StateError('Create salary records for this month first.');
      if (csv) {
        String cell(Object? value) {
          var text = value?.toString() ?? '';
          if (RegExp(r'^[=+@\-\t\r]').hasMatch(text)) text = "'$text";
          return '"${text.replaceAll('"', '""')}"';
        }
        final content = ['Name,Employee ID,Role,Month,Basic,Allowances,Deductions,Net,Paid,Balance,Status',
          for (final r in rows) [r['name'],r['employeeId']??r['teacherId']??r['staffId'],r['role'],r['month'],
            StaffPayroll.format((r['basicPaise'] as num?)?.toInt() ?? 0),
            StaffPayroll.format((r['allowancePaise'] as num?)?.toInt() ?? 0),
            StaffPayroll.format((r['deductionPaise'] as num?)?.toInt() ?? 0),
            StaffPayroll.format(StaffPayroll.total(r)),StaffPayroll.format(StaffPayroll.paid(r)),
            StaffPayroll.format(StaffPayroll.total(r)-StaffPayroll.paid(r)),r['status']].map(cell).join(',')].join('\r\n');
        await WindowsSavePdf.save(Uint8List.fromList(utf8.encode(content)), 'staff-salary-${StaffPayroll.monthKey(_month)}.csv', csv:true);
      } else {
        final r=rows.single;
        final bytes=await renderWindowsPayslip({...r,'netPaise':StaffPayroll.total(r),'paidPaise':StaffPayroll.paid(r)},schoolName:_schoolName);
        StaffPayroll._sameSchool(_profile);
        if (mounted) await showDialog<void>(context:context,builder: (_) =>
          WindowsReceiptPrintDialog(
            receipt:Future.value(bytes),
            title:'Payslip • ${rows.single['name']}',
            subtitle:'${rows.single['month'] ?? ''} • Staff Salary',
            isCurrent:()=>FirebaseFirestore.instance.activeProfileId==_profile,
          ));
      }
    } catch(e) { if(mounted) setState(() => _error='$e'); }
    finally { if(mounted) setState(() => _working=false); }
  }
  Future<void> _calculatePayroll() async {
    final person = await showDialog<Map<String,dynamic>>(context:context,builder:(ctx){ WindowsAppearance.watch(ctx); return SimpleDialog(title:Text('Select staff to calculate salary'),children:[for(final person in _staff) SimpleDialogOption(onPressed:()=>Navigator.pop(ctx,person),child:Text('${person['name']} • ${person['employeeId']??person['teacherId']??person['id']} • ${person['role']}'))]); });
    if(person != null && mounted) await _salary(person,_monthRows.where((r)=>r['staffId']==person['id']).firstOrNull);
  }
  Future<void> _paySelected() async {
    final rows = _monthRows.where((r) => _selected.contains(r['staffId']) && StaffPayroll.paid(r)<StaffPayroll.total(r)).toList();
    if(rows.isEmpty) { setState(() => _error='Select staff with an unpaid salary record first.'); return; }
    // Every payment retains its existing amount/method/date confirmation.
    for(final row in rows) { if(!mounted) return; await _payment(row); }
  }
  static const _months=['January','February','March','April','May','June','July','August','September','October','November','December'];
  String get _monthLabel => '${_months[_month.month-1]} ${_month.year}';
  @override
  Widget build(BuildContext context) {WindowsAppearance.watch(context);
    final rows=_monthRows;
    final net=rows.fold<int>(0,(v,r)=>v+StaffPayroll.total(r));
    final paid=rows.fold<int>(0,(v,r)=>v+StaffPayroll.paid(r));
    final deductions=rows.fold<int>(0,(v,r)=>v+((r['deductionPaise'] as num?)?.toInt() ?? 0));
    final paidCount=rows.where((r)=>StaffPayroll.paid(r)>=StaffPayroll.total(r)).length;
    final people=_staff.where((s)=>(_role=='All staff'||s['role']==_role)&&'${s['name']} ${s['employeeId']} ${s['id']} ${s['designation']}'.toLowerCase().contains(_search.toLowerCase())).toList();
    final dark=Theme.of(context);
    return Theme(data:dark,child:Scaffold(appBar:AppBar(backgroundColor:WindowsAppearance.resolve(const Color(0xff0c233e)),
      title: Row(children:[Icon(Icons.account_balance_wallet,color: WindowsAppearance.foreground(Colors.lightBlueAccent)),SizedBox(width:16),
        Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Staff Salary',style:TextStyle(fontFamily: 'Segoe UI', fontSize:25,fontWeight:FontWeight.bold)),
          Text('Manage monthly salaries for teachers, office staff and school workers.',style:TextStyle(fontFamily: 'Segoe UI', fontSize:12,color:WindowsAppearance.foreground(Colors.white70)))])]),
      actions:[IconButton(tooltip:'Refresh',onPressed:_load,icon:Icon(Icons.refresh))]),
      body:_loading ? Center(child:CircularProgressIndicator()) : LayoutBuilder(builder:(context,constraints){ WindowsAppearance.watch(context); return
        ListView(padding:const EdgeInsets.all(20),children:[
          Wrap(spacing:12,runSpacing:12,crossAxisAlignment:WrapCrossAlignment.center,children:[
            IconButton(tooltip:'Previous month',onPressed:()=>setState((){_month=DateTime(_month.year,_month.month-1);_selected.clear();}),icon:Icon(Icons.chevron_left)),
            OutlinedButton.icon(icon:Icon(Icons.calendar_month),label:Text(_monthLabel),onPressed:() async {
              final day=await showDatePicker(context:context,initialDate:_month,firstDate:DateTime(2000),lastDate:DateTime(2100));
              if(day!=null&&mounted)setState((){_month=DateTime(day.year,day.month);_selected.clear();});
            }),
            IconButton(tooltip:'Next month',onPressed:()=>setState((){_month=DateTime(_month.year,_month.month+1);_selected.clear();}),icon:Icon(Icons.chevron_right)),
            FilledButton.icon(onPressed:_staff.isEmpty?null:_calculatePayroll,icon:Icon(Icons.calculate_outlined),label:Text('Calculate Payroll')),
            FilledButton.icon(style:FilledButton.styleFrom(backgroundColor: WindowsAppearance.primary, foregroundColor: WindowsAppearance.onPrimary),onPressed:_selected.isEmpty?null:_paySelected,icon:Icon(Icons.done_all),label:Text('Mark Selected as Paid')),
            OutlinedButton.icon(key: const ValueKey('salary-history'), onPressed:()=>_history(),icon:Icon(Icons.history),label:Text('Payment History')),
            OutlinedButton.icon(onPressed:_working?null:()=>_output(csv:true),icon:Icon(Icons.download_outlined),label:Text('Export CSV')),

          ]),SizedBox(height:18),
          Wrap(spacing:12,runSpacing:12,children:[
            _metric('Total Staff','${_staff.length}',WindowsAppearance.primary,Icons.groups_outlined,'${_staff.where((s)=>s['role']=='Teacher').length} Teachers'),
            _metric('Gross Salary','₹${StaffPayroll.format(net+deductions)}',WindowsAppearance.primary,Icons.currency_rupee,'Total earnings'),
            _metric('Total Deductions','₹${StaffPayroll.format(deductions)}',WindowsAppearance.foreground(Colors.redAccent),Icons.pie_chart_outline,'Recorded deductions'),
            _metric('Net payroll','₹${StaffPayroll.format(net)}',WindowsAppearance.primary,Icons.account_balance,'After all deductions'),
            _metric('Paid','₹${StaffPayroll.format(paid)}',Colors.green,Icons.check_circle_outline,'$paidCount staff paid'),
            _metric('Pending','₹${StaffPayroll.format(net-paid)}',Colors.orange,Icons.hourglass_empty,'Remaining balance'),
          ]),SizedBox(height:18),
          if(!_local) Padding(padding:EdgeInsets.all(12),child:Text('Local Data is OFF. Unsynced salary changes stay in this session only. Enable Local Data to keep them on this computer.')),
           Text('Records belong to the active school. Teacher salary appears in the teacher app after school sync.',style:TextStyle(fontFamily: 'Segoe UI', color:WindowsAppearance.foreground(Colors.white54),fontSize:12)),
          if(_error!=null) Padding(padding:const EdgeInsets.all(12),child:Text(_error!,style:TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.redAccent)))),
          SizedBox(height:16),
          Wrap(spacing:10,runSpacing:10,children:[
            for(final role in ['All staff','Teacher','Office staff','Driver','Guard','Support staff','Other'])
              ChoiceChip(selectedColor:WindowsAppearance.background(const Color(0xff6252ee)),labelStyle: TextStyle(fontFamily: 'Segoe UI', color:WindowsAppearance.resolve(Colors.white)),label:Text('$role (${role=='All staff'?_staff.length:_staff.where((s)=>s['role']==role).length})'),selected:_role==role,onSelected:(_)=>setState(()=>_role=role)),
            SizedBox(width:320,child:TextField(onChanged:(v)=>setState(()=>_search=v),decoration:const InputDecoration(hintText:'Search by name, ID or department...',prefixIcon:Icon(Icons.search)))),
          ]),SizedBox(height:16),
          if(people.isEmpty) Padding(padding:EdgeInsets.all(30),child:Text('No staff found. Add teachers in Teachers and non-teaching staff in Other Staff.')),
          Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:Card(child:SingleChildScrollView(scrollDirection:Axis.horizontal,child:DataTable(
            headingRowColor:WidgetStateProperty.all(WindowsAppearance.resolve(const Color(0xff172c42))),columnSpacing:14,dataRowMinHeight:64,dataRowMaxHeight:76,
            columns:[for(final label in ['Name / Employee ID','Role / Department','Attendance','Basic Pay','Allowances','Deductions','Net Salary','Status','Action'])DataColumn(label:Text(label))],
            rows:[for(final person in people)_tableRow(person,rows)],
          )))),if(constraints.maxWidth>=1350)...[SizedBox(width:14),SizedBox(width:270,child:_monthSummary(net,paid,deductions,paidCount,rows.length))]]),
          if(constraints.maxWidth<1350)_monthSummary(net,paid,deductions,paidCount,rows.length),
          for(final row in rows.where((r)=>!_staff.any((s)=>s['id']==r['staffId'])))
            Card(child:ListTile(title:Text('${row['name'] ?? row['teacherId'] ?? 'Previous staff'} • ₹${StaffPayroll.format(StaffPayroll.total(row))}'),subtitle:Text('${row['status'] ?? 'Previous record'}'),trailing:IconButton(icon:Icon(Icons.history),onPressed:()=>_history(row)))),
        ]); })));
  }
  Widget _metric(String label,String value,Color color,IconData icon,String detail)=>SizedBox(width:205,child:Container(
    padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:color.withValues(alpha:.12),border:Border.all(color:color.withValues(alpha:.35)),borderRadius:BorderRadius.circular(10)),
    child:Row(children:[CircleAvatar(backgroundColor:color.withValues(alpha:.6),child:Icon(icon,color:WindowsAppearance.onColor(color.withValues(alpha:.6)))),SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(label,style: TextStyle(fontFamily: 'Segoe UI', fontSize:12,color:WindowsAppearance.foreground(Colors.white70))),SizedBox(height:8),FittedBox(child:Text(value,style:TextStyle(fontFamily: 'Segoe UI', fontSize:22,fontWeight:FontWeight.bold))),SizedBox(height:8),Text(detail,style: TextStyle(fontFamily: 'Segoe UI', fontSize:10,color:WindowsAppearance.foreground(Colors.white54)))]))])));
  Widget _monthSummary(int net,int paid,int deductions,int count,int total)=>Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Text('$_monthLabel Summary',style:TextStyle(fontFamily: 'Segoe UI', fontSize:18,fontWeight:FontWeight.bold)),SizedBox(height:20),
    Center(child:SizedBox(width:110,height:110,child:Stack(alignment:Alignment.center,children:[
      SizedBox.expand(child:CircularProgressIndicator(value:net==0?0:paid/net,strokeWidth:14,backgroundColor: WindowsAppearance.background(Colors.orange),color: WindowsAppearance.foreground(Colors.cyan))),Text('$total\nSalary records',textAlign:TextAlign.center)]))),
    SizedBox(height:24),Text('Paid staff: $count'),const Divider(),Text('Gross Salary: ₹${StaffPayroll.format(net+deductions)}'),
    SizedBox(height:10),Text('Total Deductions: ₹${StaffPayroll.format(deductions)}'),const Divider(),Text('Net Payable: ₹${StaffPayroll.format(net)}'),
    SizedBox(height:10),Text('Paid Amount: ₹${StaffPayroll.format(paid)}',style:TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.greenAccent))),
    SizedBox(height:10),Text('Pending Amount: ₹${StaffPayroll.format(net-paid)}',style:TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.orangeAccent))),
  ])));
  DataRow _tableRow(Map<String,dynamic> person,List<Map<String,dynamic>> rows) {
    final row=rows.where((r)=>r['staffId']==person['id']).firstOrNull;
    String amount(String key)=>row==null?'—':'₹${StaffPayroll.format((row[key] as num?)?.toInt()??0)}';
    final status=row?['status']?.toString()??'Not set';
    final color=status=='Paid'?Colors.green:Colors.orange;
    return DataRow(selected:_selected.contains(person['id']),onSelectChanged:(value)=>setState((){if(value==true)_selected.add(person['id'].toString());else _selected.remove(person['id']);}),cells:[
      DataCell(Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(person['name'].toString(),style:TextStyle(fontFamily: 'Segoe UI', fontWeight:FontWeight.bold)),Text((person['employeeId']??person['teacherId']??person['id']).toString(),style: TextStyle(fontFamily: 'Segoe UI', fontSize:11,color:WindowsAppearance.foreground(Colors.white54)))])),
      DataCell(Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(person['role'].toString()),Text(person['designation']?.toString()??'',style: TextStyle(fontFamily: 'Segoe UI', fontSize:11,color:WindowsAppearance.foreground(Colors.white54)))])),
      DataCell(Tooltip(message:'Attendance does not change salary automatically. Configure deductions in the salary editor.',child:Text(row?['attendanceSummary']?.toString()??'—'))),
      DataCell(Text(amount('basicPaise'))),DataCell(Text(amount('allowancePaise'))),DataCell(Text(amount('deductionPaise'))),DataCell(Text(row==null?'—':'₹${StaffPayroll.format(StaffPayroll.total(row))}')),
      DataCell(Chip(label:Text(status),backgroundColor:color.withValues(alpha:.2))),
      DataCell(Row(children:[
        if(row==null)TextButton(onPressed:()=>_salary(person,null),child:Text('Set salary'))
        else FilledButton.tonal(onPressed:_working?null:()=>_output(row:row),child:Text('View Payslip')),
        PopupMenuButton<String>(tooltip:'Salary actions',onSelected:(action){
          if(action=='edit')_salary(person,row);
          if(action=='pay'&&row!=null)_payment(row);
          if(action=='correct'&&row!=null)_correctPayment(row);
          if(action=='history'&&row!=null)_history(row);
        },itemBuilder:(_)=>[
          PopupMenuItem(value:'edit',child:Text(row==null?'Set salary':'Edit salary')),
          if(row!=null&&StaffPayroll.paid(row)<StaffPayroll.total(row))const PopupMenuItem(value:'pay',child:Text('Record payment')),
          if(row!=null&&StaffPayroll.paid(row)>0)const PopupMenuItem(value:'correct',child:Text('Modify Payment • App Lock')),
          if(row!=null)const PopupMenuItem(value:'history',child:Text('Payment history')),
        ]),
      ])),
    ]);
  }
}
