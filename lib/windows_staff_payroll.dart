import 'windows_other_staff.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;
import 'windows_browser_print.dart';
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
      DropdownButtonFormField<String>(isExpanded: true, initialValue: mode, items: ['Cash', 'Bank transfer', 'UPI', 'Cheque'].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(), onChanged: (v) => setD(() => mode = v!)),
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
        final regular=pw.Font.ttf(await rootBundle.load('assets/id_card_regular.ttf'));
        final bold=pw.Font.ttf(await rootBundle.load('assets/id_card_bold.ttf'));
        final doc = pw.Document(theme:pw.ThemeData.withFont(base:regular,bold:bold));
        for (final r in rows) {
          doc.addPage(pw.Page(build: (_) => pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start, children:[
            pw.Text('VIDYA SAARTHI - PAYSLIP',style:pw.TextStyle(fontSize:22,fontWeight:pw.FontWeight.bold)),
            pw.SizedBox(height:20),if(_schoolName.isNotEmpty)pw.Text(_schoolName),pw.Text('${r['name']} | ${r['employeeId']??r['teacherId']??r['staffId']}'),
            pw.Text('${r['role']} | ${r['month']}'),pw.SizedBox(height:20),
            for (final key in {'Basic pay':'basicPaise','Allowances':'allowancePaise','Bonus':'bonusPaise','Overtime':'overtimePaise','Deductions':'deductionPaise'}.entries)
              pw.Padding(padding:const pw.EdgeInsets.only(bottom:10),child:pw.Text('${key.key}: Rs ${StaffPayroll.format((r[key.value] as num?)?.toInt() ?? 0)}')),
            pw.Divider(),pw.Text('Net salary: Rs ${StaffPayroll.format(StaffPayroll.total(r))}'),
            pw.Text('Paid: Rs ${StaffPayroll.format(StaffPayroll.paid(r))}'),
            pw.Text('Balance: Rs ${StaffPayroll.format(StaffPayroll.total(r)-StaffPayroll.paid(r))}'),
            pw.Text('Status: ${r['status'] ?? 'Pending'}'),
          ])));
        }
        await WindowsBrowserPrint.open(await doc.save());
      }
    } catch(e) { if(mounted) setState(() => _error='$e'); }
    finally { if(mounted) setState(() => _working=false); }
  }
  Future<void> _calculatePayroll() async {
    final person = await showDialog<Map<String,dynamic>>(context:context,builder:(ctx)=>SimpleDialog(title:const Text('Select staff to calculate salary'),children:[for(final person in _staff) SimpleDialogOption(onPressed:()=>Navigator.pop(ctx,person),child:Text('${person['name']} • ${person['employeeId']??person['teacherId']??person['id']} • ${person['role']}'))]));
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
  Widget build(BuildContext context) {
    final rows=_monthRows;
    final net=rows.fold<int>(0,(v,r)=>v+StaffPayroll.total(r));
    final paid=rows.fold<int>(0,(v,r)=>v+StaffPayroll.paid(r));
    final deductions=rows.fold<int>(0,(v,r)=>v+((r['deductionPaise'] as num?)?.toInt() ?? 0));
    final paidCount=rows.where((r)=>StaffPayroll.paid(r)>=StaffPayroll.total(r)).length;
    final people=_staff.where((s)=>(_role=='All staff'||s['role']==_role)&&'${s['name']} ${s['employeeId']} ${s['id']} ${s['designation']}'.toLowerCase().contains(_search.toLowerCase())).toList();
    final dark=ThemeData.dark(useMaterial3:true).copyWith(scaffoldBackgroundColor:const Color(0xff061826),
      colorScheme:const ColorScheme.dark(primary:Color(0xff7260ff),onPrimary:Colors.white,surface:Color(0xff102338)),
      dividerColor:const Color(0xff284157),cardColor:const Color(0xff102338));
    return Theme(data:dark,child:Scaffold(appBar:AppBar(backgroundColor:const Color(0xff0c233e),
      title:const Row(children:[Icon(Icons.account_balance_wallet,color:Colors.lightBlueAccent),SizedBox(width:16),
        Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Staff Salary',style:TextStyle(fontSize:25,fontWeight:FontWeight.bold)),
          Text('Manage monthly salaries for teachers, office staff and school workers.',style:TextStyle(fontSize:12,color:Colors.white70))])]),
      actions:[IconButton(tooltip:'Refresh',onPressed:_load,icon:const Icon(Icons.refresh))]),
      body:_loading ? const Center(child:CircularProgressIndicator()) : LayoutBuilder(builder:(context,constraints)=>
        ListView(padding:const EdgeInsets.all(20),children:[
          Wrap(spacing:12,runSpacing:12,crossAxisAlignment:WrapCrossAlignment.center,children:[
            IconButton(tooltip:'Previous month',onPressed:()=>setState((){_month=DateTime(_month.year,_month.month-1);_selected.clear();}),icon:const Icon(Icons.chevron_left)),
            OutlinedButton.icon(icon:const Icon(Icons.calendar_month),label:Text(_monthLabel),onPressed:() async {
              final day=await showDatePicker(context:context,initialDate:_month,firstDate:DateTime(2000),lastDate:DateTime(2100));
              if(day!=null&&mounted)setState((){_month=DateTime(day.year,day.month);_selected.clear();});
            }),
            IconButton(tooltip:'Next month',onPressed:()=>setState((){_month=DateTime(_month.year,_month.month+1);_selected.clear();}),icon:const Icon(Icons.chevron_right)),
            FilledButton.icon(onPressed:_staff.isEmpty?null:_calculatePayroll,icon:const Icon(Icons.calculate_outlined),label:const Text('Calculate Payroll')),
            FilledButton.icon(style:FilledButton.styleFrom(backgroundColor:const Color(0xff12b975)),onPressed:_selected.isEmpty?null:_paySelected,icon:const Icon(Icons.done_all),label:const Text('Mark Selected as Paid')),
            OutlinedButton.icon(onPressed:_working?null:()=>_output(),icon:const Icon(Icons.print_outlined),label:const Text('Generate Payslips')),
            OutlinedButton.icon(onPressed:_working?null:()=>_output(csv:true),icon:const Icon(Icons.download_outlined),label:const Text('Export CSV')),

          ]),const SizedBox(height:18),
          Wrap(spacing:12,runSpacing:12,children:[
            _metric('Total Staff','${_staff.length}',Colors.blue,Icons.groups_outlined,'${_staff.where((s)=>s['role']=='Teacher').length} Teachers'),
            _metric('Gross Salary','₹${StaffPayroll.format(net+deductions)}',Colors.teal,Icons.currency_rupee,'Total earnings'),
            _metric('Total Deductions','₹${StaffPayroll.format(deductions)}',Colors.pink,Icons.pie_chart_outline,'Recorded deductions'),
            _metric('Net payroll','₹${StaffPayroll.format(net)}',Colors.deepPurple,Icons.account_balance,'After all deductions'),
            _metric('Paid','₹${StaffPayroll.format(paid)}',Colors.green,Icons.check_circle_outline,'$paidCount staff paid'),
            _metric('Pending','₹${StaffPayroll.format(net-paid)}',Colors.orange,Icons.hourglass_empty,'Remaining balance'),
          ]),const SizedBox(height:18),
          if(!_local) const Padding(padding:EdgeInsets.all(12),child:Text('Local Data is OFF. Unsynced salary changes stay in this session only. Enable Local Data to keep them on this computer.')),
          const Text('Records belong to the active school. Teacher salary appears in the teacher app after school sync.',style:TextStyle(color:Colors.white54,fontSize:12)),
          if(_error!=null) Padding(padding:const EdgeInsets.all(12),child:Text(_error!,style:const TextStyle(color:Colors.redAccent))),
          const SizedBox(height:16),
          Wrap(spacing:10,runSpacing:10,children:[
            for(final role in ['All staff','Teacher','Office staff','Driver','Guard','Support staff','Other'])
              ChoiceChip(selectedColor:const Color(0xff6252ee),labelStyle:const TextStyle(color:Colors.white),label:Text('$role (${role=='All staff'?_staff.length:_staff.where((s)=>s['role']==role).length})'),selected:_role==role,onSelected:(_)=>setState(()=>_role=role)),
            SizedBox(width:320,child:TextField(onChanged:(v)=>setState(()=>_search=v),decoration:const InputDecoration(hintText:'Search by name, ID or department...',prefixIcon:Icon(Icons.search)))),
          ]),const SizedBox(height:16),
          if(people.isEmpty) const Padding(padding:EdgeInsets.all(30),child:Text('No staff found. Add teachers in Teachers and non-teaching staff in Other Staff.')),
          Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:Card(child:SingleChildScrollView(scrollDirection:Axis.horizontal,child:DataTable(
            headingRowColor:WidgetStateProperty.all(const Color(0xff172c42)),columnSpacing:14,dataRowMinHeight:64,dataRowMaxHeight:76,
            columns:[for(final label in ['Name / Employee ID','Role / Department','Attendance','Basic Pay','Allowances','Deductions','Net Salary','Status','Action'])DataColumn(label:Text(label))],
            rows:[for(final person in people)_tableRow(person,rows)],
          )))),if(constraints.maxWidth>=1350)...[const SizedBox(width:14),SizedBox(width:270,child:_monthSummary(net,paid,deductions,paidCount,rows.length))]]),
          if(constraints.maxWidth<1350)_monthSummary(net,paid,deductions,paidCount,rows.length),
          for(final row in rows.where((r)=>!_staff.any((s)=>s['id']==r['staffId'])))
            Card(child:ListTile(title:Text('${row['name'] ?? row['teacherId'] ?? 'Previous staff'} • ₹${StaffPayroll.format(StaffPayroll.total(row))}'),subtitle:Text('${row['status'] ?? 'Previous record'}'),trailing:IconButton(icon:const Icon(Icons.history),onPressed:()=>_history(row)))),
        ]))));
  }
  Widget _metric(String label,String value,Color color,IconData icon,String detail)=>SizedBox(width:205,child:Container(
    padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:color.withValues(alpha:.12),border:Border.all(color:color.withValues(alpha:.35)),borderRadius:BorderRadius.circular(10)),
    child:Row(children:[CircleAvatar(backgroundColor:color.withValues(alpha:.6),child:Icon(icon,color:Colors.white)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(label,style:const TextStyle(fontSize:12,color:Colors.white70)),const SizedBox(height:8),FittedBox(child:Text(value,style:const TextStyle(fontSize:22,fontWeight:FontWeight.bold))),const SizedBox(height:8),Text(detail,style:const TextStyle(fontSize:10,color:Colors.white54))]))])));
  Widget _monthSummary(int net,int paid,int deductions,int count,int total)=>Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Text('$_monthLabel Summary',style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold)),const SizedBox(height:20),
    Center(child:SizedBox(width:110,height:110,child:Stack(alignment:Alignment.center,children:[
      SizedBox.expand(child:CircularProgressIndicator(value:net==0?0:paid/net,strokeWidth:14,backgroundColor:Colors.orange,color:Colors.cyan)),Text('$total\nSalary records',textAlign:TextAlign.center)]))),
    const SizedBox(height:24),Text('Paid staff: $count'),const Divider(),Text('Gross Salary: ₹${StaffPayroll.format(net+deductions)}'),
    const SizedBox(height:10),Text('Total Deductions: ₹${StaffPayroll.format(deductions)}'),const Divider(),Text('Net Payable: ₹${StaffPayroll.format(net)}'),
    const SizedBox(height:10),Text('Paid Amount: ₹${StaffPayroll.format(paid)}',style:const TextStyle(color:Colors.greenAccent)),
    const SizedBox(height:10),Text('Pending Amount: ₹${StaffPayroll.format(net-paid)}',style:const TextStyle(color:Colors.orangeAccent)),
  ])));
  DataRow _tableRow(Map<String,dynamic> person,List<Map<String,dynamic>> rows) {
    final row=rows.where((r)=>r['staffId']==person['id']).firstOrNull;
    String amount(String key)=>row==null?'—':'₹${StaffPayroll.format((row[key] as num?)?.toInt()??0)}';
    final status=row?['status']?.toString()??'Not set';
    final color=status=='Paid'?Colors.green:Colors.orange;
    return DataRow(selected:_selected.contains(person['id']),onSelectChanged:(value)=>setState((){if(value==true)_selected.add(person['id'].toString());else _selected.remove(person['id']);}),cells:[
      DataCell(Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(person['name'].toString(),style:const TextStyle(fontWeight:FontWeight.bold)),Text((person['employeeId']??person['teacherId']??person['id']).toString(),style:const TextStyle(fontSize:11,color:Colors.white54))])),
      DataCell(Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(person['role'].toString()),Text(person['designation']?.toString()??'',style:const TextStyle(fontSize:11,color:Colors.white54))])),
      DataCell(Tooltip(message:'Attendance does not change salary automatically. Configure deductions in the salary editor.',child:Text(row?['attendanceSummary']?.toString()??'—'))),
      DataCell(Text(amount('basicPaise'))),DataCell(Text(amount('allowancePaise'))),DataCell(Text(amount('deductionPaise'))),DataCell(Text(row==null?'—':'₹${StaffPayroll.format(StaffPayroll.total(row))}')),
      DataCell(Chip(label:Text(status),backgroundColor:color.withValues(alpha:.2))),
      DataCell(Row(children:[
        if(row==null)TextButton(onPressed:()=>_salary(person,null),child:const Text('Set salary'))
        else FilledButton.tonal(onPressed:_working?null:()=>_output(row:row),child:const Text('View Payslip')),
        PopupMenuButton<String>(tooltip:'Salary actions',onSelected:(action){
          if(action=='edit')_salary(person,row);
          if(action=='pay'&&row!=null)_payment(row);
          if(action=='history'&&row!=null)_history(row);
        },itemBuilder:(_)=>[
          PopupMenuItem(value:'edit',child:Text(row==null?'Set salary':'Edit salary')),
          if(row!=null&&StaffPayroll.paid(row)<StaffPayroll.total(row))const PopupMenuItem(value:'pay',child:Text('Record payment')),
          if(row!=null)const PopupMenuItem(value:'history',child:Text('Payment history')),
        ]),
      ])),
    ]);
  }
}
