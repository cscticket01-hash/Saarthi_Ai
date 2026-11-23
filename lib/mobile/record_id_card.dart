import 'package:flutter/material.dart';

/// Digital school ID built directly from the signed mobile school session.
/// This view never requests, renders, rasterizes, caches or uploads a PDF.
/// The optional historical PDF remains a separate explicit user action.
class MobileRecordIdCard extends StatelessWidget {
  const MobileRecordIdCard({
    super.key,
    required this.schoolName,
    required this.schoolId,
    required this.role,
    required this.personId,
    required this.person,
    required this.verified,
    this.portrait,
    this.showStudentUid = false,
    this.onOpenHistoricalPdf,
  });

  final String schoolName, schoolId, role, personId;
  final Map<String, dynamic> person;
  final bool verified;
  final Widget? portrait;
  final bool showStudentUid;
  final Future<void> Function()? onOpenHistoricalPdf;

  String _field(List<String> keys) {
    for (final key in keys) {
      final raw = person[key];
      if (raw == null || raw is Map || raw is List) continue;
      final value = raw.toString().trim();
      if (value.isNotEmpty && value.toLowerCase() != 'null') return value;
    }
    return '—';
  }

  @override
  Widget build(BuildContext context) {
    final kind = role == 'student' ? 'Student'
        : role == 'teacher' ? 'Teacher' : 'School Member';
    final owner = person['schoolId']?.toString();
    // A cached member from another school must never be displayed.
    if (!verified || schoolId.isEmpty || personId.isEmpty ||
        !{'student', 'teacher', 'staff'}.contains(role) ||
        (owner != null && owner.isNotEmpty && owner != schoolId)) {
      return const Text('Verified school ID data is unavailable. Refresh your school records.',
        textAlign: TextAlign.center);
    }

    Widget field(String label, List<String> keys) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 92, child: Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.black54))),
          Expanded(child: Text(_field(keys),
              style: const TextStyle(fontSize: 13,
                  color: Colors.black87, fontWeight: FontWeight.w600))),
        ]),
      );
    }

    Widget side({required bool back}) => Container(
      key: ValueKey(back ? 'mobile-id-back' : 'mobile-id-front'),
      width: 345,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFF067578), width: 2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(schoolName, textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF075D65),
            fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        Text('$kind ID · ${back ? 'Back' : 'Front'}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black54, fontSize: 11)),
        const Divider(),
        if (!back) ...[
          Center(child: portrait ?? const CircleAvatar(
              radius: 34, child: Icon(Icons.person_outline, size: 40))),
          const SizedBox(height: 8),
          Text(_field(['name', 'fullName']), textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black87,
              fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (role == 'student') ...[
            field('Class', ['class', 'className']),
            field('Roll No', ['rollNo', 'roll']),
            if (showStudentUid &&
                _field(['studentUid', 'studentUidTest', 'uniqueStudentId']) != '—')
              field('Student UID', ['studentUid', 'studentUidTest', 'uniqueStudentId']),
          ] else ...[
            field('Designation', ['designation', 'role']),
            field('ID', ['teacherId', 'employeeId']),
          ],
        ] else ...[
          field('Father / Guardian', ['parentName', 'fatherName']),
          field('Date of birth', ['dateOfBirth', 'dob']),
          field('Address', ['address', 'streetAddress']),
          field('Contact', ['parentContact', 'mobile', 'contact']),
          const SizedBox(height: 6),
          const Text('School records · authenticated member view',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54, fontSize: 10)),
        ],
      ]),
    );

    return Column(children: [
      const Text('Digital ID preview · no PDF generated',
        style: TextStyle(color: Colors.white70, fontSize: 12)),
      const SizedBox(height: 12),
      Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center,
        children: [side(back: false), side(back: true)]),
      if (onOpenHistoricalPdf != null) ...[
        const SizedBox(height: 10),
        TextButton.icon(onPressed: onOpenHistoricalPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('Open previously published PDF')),
      ],
    ]);
  }
}
