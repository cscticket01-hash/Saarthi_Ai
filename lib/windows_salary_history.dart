import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'windows_save_pdf.dart';
import 'windows_appearance.dart';
import 'windows_local_firestore.dart';

String salaryPaymentTime(DateTime date) => '${(date.hour % 12 == 0 ? 12 : date.hour % 12).toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';
String salaryPaymentDate(DateTime date) => '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

/// Read-only projection. Never reconstruct missing financial events or times.
List<Map<String, dynamic>> salaryPaymentHistory(Iterable<Map<String, dynamic>> rows,
    {String? staffId, String? teacherId, String? salaryRowId}) {
  final entries = <Map<String, dynamic>>[];
  for (final row in rows) {
    if (staffId != null && row['staffId'] != staffId && (salaryRowId == null || row['id'] != salaryRowId) &&
        !(row['staffId'] == null && teacherId != null && teacherId.isNotEmpty && row['teacherId'] == teacherId)) continue;
    final payments = (row['payments'] as List? ?? []).whereType<Map>();
    for (final payment in payments) {
      entries.add({...Map<String, dynamic>.from(payment), 'name': row['name'],
        'employeeId': row['employeeId'] ?? row['teacherId'] ?? row['staffId'],
        'role': row['role'], 'month': row['month']});
    }
    final corrections = (row['paymentCorrections'] as List? ?? []).whereType<Map>().toList();
    for (final correction in corrections) {
      final before = (correction['previousPaise'] as num?)?.toInt() ?? 0;
      final revised = (correction['correctedPaise'] as num?)?.toInt() ?? 0;
      final timestamp = (correction['correctedAt'] as num?)?.toInt();
      entries.add({
        'id': correction['id'], 'name': row['name'],
        'employeeId': row['employeeId'] ?? row['teacherId'] ?? row['staffId'],
        'role': row['role'], 'month': row['month'],
        'amountPaise': revised - before,
        'mode': correction['eventType']=='reversal' ? 'Reversal' : 'Correction',
        'recordedBy': correction['authorizedBy'],
        'paymentId': correction['paymentId'],
        'date': timestamp == null ? null : DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true).toIso8601String(),
        'timeRecorded': timestamp != null,
        'reference': 'Original ₹${(before / 100).toStringAsFixed(2)} → Corrected ₹${(revised / 100).toStringAsFixed(2)} • Reason: ${correction['reason'] ?? ''}',
      });
    }
    final aggregatePaid = (row['paidPaise'] as num?)?.toInt() ?? (row['status'] == 'Paid'
      ? (row['netPaise'] as num?)?.toInt() ?? ((row['amount'] as num? ?? 0) * 100).round() : 0);
    final itemizedPaid = payments.fold<int>(0, (sum, p) => sum + ((p['amountPaise'] as num?)?.toInt() ?? 0)) +
      corrections.fold<int>(0, (sum, c) => sum + ((c['differencePaise'] as num?)?.toInt() ?? 0));
    if (aggregatePaid > itemizedPaid) {
      entries.add({'name': row['name'], 'employeeId': row['employeeId'] ?? row['teacherId'] ?? row['staffId'],
        'role': row['role'], 'month': row['month'], 'amountPaise': aggregatePaid - itemizedPaid,
        'reference': 'Legacy paid total; individual payment details were not recorded.'});
    }
  }
  entries.sort((a, b) => (DateTime.tryParse(b['date']?.toString() ?? '') ?? DateTime(1900))
      .compareTo(DateTime.tryParse(a['date']?.toString() ?? '') ?? DateTime(1900)));
  return entries;
}

class StaffSalaryHistoryScreen extends StatefulWidget {
  const StaffSalaryHistoryScreen({super.key, required this.profile, this.staffId, this.teacherId, this.staffName, this.salaryRowId});
  final String profile;
  final String? staffId, teacherId, staffName, salaryRowId;
  @override
  State<StaffSalaryHistoryScreen> createState()=>_StaffSalaryHistoryScreenState();
}
class _StaffSalaryHistoryScreenState extends State<StaffSalaryHistoryScreen> {
  String _month='All months',_search='';
  bool _exporting=false;
  late final Stream<QuerySnapshot<Map<String,dynamic>>> _stream;
  @override
  void initState(){super.initState();_stream=FirebaseFirestore.instance.collection('teacher_salary').snapshots();}
  String _csvCell(Object? value){
    var text=value?.toString()??'';
    if(RegExp(r'^[=+@\-\t\r]').hasMatch(text))text="'$text";
    return '"${text.replaceAll('"','""')}"';
  }
  Future<void> _export(List<Map<String,dynamic>> entries) async {
    if(_exporting||FirebaseFirestore.instance.activeProfileId!=widget.profile)return;
    setState(()=>_exporting=true);
    try{
      final lines=['Name,Employee ID,Role,Salary month,Payment date,Amount INR,Method,Reference,Recorded by,Event ID,Original payment ID',
        for(final e in entries)[e['name'],e['employeeId'],e['role'],e['month'],e['date'],e['amountPaise'] is num?((e['amountPaise'] as num)/100).toStringAsFixed(2):'',e['mode'],e['reference'],e['recordedBy'],e['id'],e['paymentId']].map(_csvCell).join(',')];
      await WindowsSavePdf.save(Uint8List.fromList(utf8.encode(lines.join('\r\n'))),'salary-payment-history.csv',csv:true);
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Export failed: $e')));}
    finally{if(mounted)setState(()=>_exporting=false);}
  }
  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    final db = FirebaseFirestore.instance;
    return Scaffold(appBar: AppBar(title: Text(widget.staffId == null ? 'Staff Salary • Payment History' : 'Payment history • ${widget.staffName ?? 'Staff'}')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(stream: _stream, builder: (context, snapshot) {
        if (db.activeProfileId != widget.profile) return const Center(child: Text('School changed. Reopen salary history.'));
        if (snapshot.hasError) return const Center(child: Text('Payment history could not be loaded. Reopen this page.'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final all = salaryPaymentHistory(snapshot.data!.docs.map((d) => {...d.data(), 'id': d.id}).where((r) => r['schoolId'] == null || r['schoolId'] == db.activeProfileIdentity['schoolSyncId']), staffId: widget.staffId, teacherId: widget.teacherId, salaryRowId: widget.salaryRowId);
        final months=all.map((e)=>e['month']?.toString()??'').where((v)=>v.isNotEmpty).toSet().toList()..sort((a,b)=>b.compareTo(a));
        final selected=months.contains(_month)?_month:'All months';
        final entries=all.where((e)=>(selected=='All months'||e['month']==selected)&&[e['name'],e['employeeId'],e['mode'],e['reference'],e['recordedBy'],e['id']].join(' ').toLowerCase().contains(_search.trim().toLowerCase())).toList();
        if (all.isEmpty) return const Center(child: Text('No payments recorded.'));
        return SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('All salary months • Existing recorded payments', style: TextStyle(fontFamily: 'Segoe UI', fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Wrap(spacing:16,runSpacing:10,crossAxisAlignment:WrapCrossAlignment.center,children:[
            DropdownButton<String>(value:selected,items:['All months',...months].map((m)=>DropdownMenuItem(value:m,child:Text(m))).toList(),onChanged:(m){if(m!=null)setState(()=>_month=m);}),
            SizedBox(width:280,child:TextField(onChanged:(s)=>setState(()=>_search=s),decoration:const InputDecoration(labelText:'Search payments',prefixIcon:Icon(Icons.search)))),
            OutlinedButton.icon(onPressed:_exporting||entries.isEmpty?null:()=>_export(entries),icon:const Icon(Icons.download),label:const Text('Export history CSV')),
            Text('${entries.length} records'),
          ]),
          const SizedBox(height:16),
          if(entries.isEmpty) const Text('No matching payments.'),
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
            columns: [for (final label in ['Name', 'Employee ID', 'Role', 'Salary month', 'Payment date', 'Payment time', 'Amount', 'Method', 'Reference', 'Recorded by']) DataColumn(label: Text(label))],
            rows: entries.map((entry) {
              final date = DateTime.tryParse(entry['date']?.toString() ?? '')?.toLocal();
              final knownTime = date != null && (entry['timeRecorded'] == true || date.hour != 0 || date.minute != 0 || date.second != 0);
              return DataRow(cells: [
                for (final key in ['name', 'employeeId', 'role', 'month']) DataCell(Text(entry[key]?.toString() ?? '—')),
                DataCell(Text(date == null ? 'Not recorded' : salaryPaymentDate(date))),
                DataCell(Text(knownTime ? salaryPaymentTime(date!) : 'Not recorded')),
                DataCell(Text(entry['amountPaise'] is num ? '₹${((entry['amountPaise'] as num) / 100).toStringAsFixed(2)}' : 'Not recorded')),
                DataCell(Text(entry['mode']?.toString() ?? 'Not recorded')),
                DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320), child: Text(entry['reference']?.toString() ?? ''))),
                DataCell(Text(entry['recordedBy']?.toString()??'Not recorded')),
              ]);
            }).toList(),
          )),
        ]));
      }));
  }
}
