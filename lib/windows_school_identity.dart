import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'windows_local_firestore.dart';

/// A class/roll ID can be reused. Mobile identity must belong to the person.
class SchoolPersonIdentity {
  static Future<Map<String, dynamic>> ensure(String collection, String id) async {
    final ref = FirebaseFirestore.instance.collection(collection).doc(id);
    final origin=FirebaseFirestore.instance.activeProfileId;
    void unchanged() { if(FirebaseFirestore.instance.activeProfileId != origin) throw StateError('School changed before QR creation.'); }
    final current = (await ref.get()).data();
    unchanged();
    if (current == null) throw StateError('School record changed. Refresh first.');
    var token = current['mobileLinkToken']?.toString() ?? '';
    if (token.length < 20) {
      final random = Random.secure();
      token = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', '');
    }
    final stable = current['mobileStableId']?.toString();
    final identity = stable?.startsWith('p-') == true
        ? stable!
        : 'p-${sha256.convert(utf8.encode(token))}';
    if (stable != identity || current['mobileLinkToken'] != token || current['mobileIdentityVersion'] != 1) {
      final previous = stable ?? id;
      if (collection == 'students_directory') {
        for (final name in ['fee_ledger', 'fee_payments', 'exam_results', 'attendance_records']) {
          unchanged();
          final records = await FirebaseFirestore.instance.collection(name)
              .where('studentId', isEqualTo: id).get();
          unchanged();
          for (final record in records.docs) {
            final d = record.data();
            final owner = d['personId']?.toString();
            if (owner != null && owner != previous && owner != id) continue;
            final recordedName = (d['studentName'] ?? d['name'] ?? '').toString().trim().toLowerCase();
            final currentName = (current['name'] ?? '').toString().trim().toLowerCase();
            if (recordedName.isEmpty || recordedName != currentName) continue;
            final birth = (d['dateOfBirth'] ?? d['dob'])?.toString();
            final currentBirth = (current['dateOfBirth'] ?? current['dob'])?.toString();
            if (birth != null && currentBirth != null && birth != currentBirth) continue;
            await record.reference.set({'personId': identity}, SetOptions(merge: true));
          }
        }
      }
      await ref.set({'mobileLinkToken': token, 'mobileStableId': identity, 'mobileIdentityVersion': 1,
        'mobileLinkUpdatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    }
    return {...current, 'mobileLinkToken': token, 'mobileStableId': identity, 'mobileIdentityVersion': 1};
  }
}
