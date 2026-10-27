import 'package:flutter/material.dart';
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
    final aggregatePaid = (row['paidPaise'] as num?)?.toInt() ?? (row['status'] == 'Paid'
      ? (row['netPaise'] as num?)?.toInt() ?? ((row['amount'] as num? ?? 0) * 100).round() : 0);
    final itemizedPaid = payments.fold<int>(0, (sum, p) => sum + ((p['amountPaise'] as num?)?.toInt() ?? 0));
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

class StaffSalaryHistoryScreen extends StatelessWidget {
  const StaffSalaryHistoryScreen({super.key, required this.profile, this.staffId, this.teacherId, this.staffName, this.salaryRowId});
  final String profile;
  final String? staffId, teacherId, staffName, salaryRowId;
  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    final db = FirebaseFirestore.instance;
    return Scaffold(appBar: AppBar(title: Text(staffId == null ? 'Staff Salary • Payment History' : 'Payment history • ${staffName ?? 'Staff'}')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(stream: db.collection('teacher_salary').snapshots(), builder: (context, snapshot) {
        if (db.activeProfileId != profile) return const Center(child: Text('School changed. Reopen salary history.'));
        if (snapshot.hasError) return const Center(child: Text('Payment history could not be loaded. Reopen this page.'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final entries = salaryPaymentHistory(snapshot.data!.docs.map((d) => {...d.data(), 'id': d.id}).where((r) => r['schoolId'] == null || r['schoolId'] == db.activeProfileIdentity['schoolSyncId']), staffId: staffId, teacherId: teacherId, salaryRowId: salaryRowId);
        if (entries.isEmpty) return const Center(child: Text('No payments recorded.'));
        return SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('All salary months • Existing recorded payments', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
            columns: [for (final label in ['Name', 'Employee ID', 'Role', 'Salary month', 'Payment date', 'Payment time', 'Amount', 'Method', 'Reference']) DataColumn(label: Text(label))],
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
              ]);
            }).toList(),
          )),
        ]));
      }));
  }
}
