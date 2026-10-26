import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'windows_local_firestore.dart';

/// Received notifications are durable work, never upload receipts. The received
/// cursor advances atomically with the inbox; applied progress advances only
/// after the existing owner has verified local readback.
class WindowsSyncInbox {
  static void requireScope(String profile, String school) {
    final db = FirebaseFirestore.instance;
    if (db.activeProfileId != profile ||
        db.activeProfileIdentity['schoolSyncId'] != school)
      throw StateError('School changed during notification recovery.');
  }

  static Future<String?> cursor(String profile, String school) async {
    requireScope(profile, school);
    final r = await FirebaseFirestore.instance
        .collection('_windows_sync_status')
        .doc('received-events')
        .get();
    requireScope(profile, school);
    return r.data()?['schoolId'] == school
        ? (r.data()?['cursor'] as String?)
        : null;
  }

  static Future<void> receive(
    String profile,
    String school,
    Map<String, dynamic> event,
  ) async {
    requireScope(profile, school);
    final db = FirebaseFirestore.instance, batch = db.batch();
    final cursor = event['cursor'] as String;
    if (event['reset'] == true || (event['collections'] as List).isNotEmpty) {
      final key = sha256.convert(utf8.encode('$school/$cursor')).toString();
      batch.set(db.collection('_windows_sync_inbox').doc(key), {
        'schoolId': school,
        'cursor': cursor,
        'reset': event['reset'],
        'collections': event['collections'],
        'records': event['records'] ?? <String, dynamic>{},
      });
    }
    batch.set(db.collection('_windows_sync_status').doc('received-events'), {
      'schoolId': school,
      'cursor': cursor,
    });
    await batch.commit();
    requireScope(profile, school);
  }

  static Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> pending(
    String profile,
    String school,
  ) async {
    requireScope(profile, school);
    final rows = await FirebaseFirestore.instance
        .collection('_windows_sync_inbox')
        .get();
    requireScope(profile, school);
    return rows.docs.where((r) => r.data()['schoolId'] == school).toList();
  }

  static Future<void> applied(
    String profile,
    String school,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> rows,
  ) async {
    requireScope(profile, school);
    final db = FirebaseFirestore.instance;
    for (var offset = 0; offset < rows.length; offset += 100) {
      requireScope(profile, school);
      final chunk = rows.skip(offset).take(100).toList(), batch = db.batch();
      for (final row in chunk) {
        row.reference.requireOriginProfile();
        if (row.data()['schoolId'] != school) throw StateError('Foreign inbox');
        batch.delete(row.reference);
      }
      // Per-event evidence avoids advancing past an unapplied earlier event.
      batch.set(db.collection('_windows_sync_status').doc('applied-events'), {
        'schoolId': school,
        'verifiedAt': DateTime.now().millisecondsSinceEpoch,
        'cursors': chunk.map((r) => r.data()['cursor']).toList(),
      });
      await batch.commit();
      requireScope(profile, school);
    }
  }
}
