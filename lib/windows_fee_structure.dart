import 'promotion_session_policy.dart';
import 'windows_local_firestore.dart';

/// Existing fee records stay intact; session-specific structures use the same
/// school-scoped collection and durable versioned outbox.
class WindowsFeeStructure {
  static Future<String> currentSession() async => PromotionSessionPolicy.label(
      DateTime.now(), await PromotionSessionPolicy.rolloverMonth());

  static String documentId(String className, String session) =>
      '${className.replaceAll(' ', '_')}__${session.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}';

  static Future<Map<String, dynamic>> load(String className, {String? session}) async {
    final selected = session ?? await currentSession();
    final db = FirebaseFirestore.instance, origin = FirebaseFirestore.instance.activeProfileId;
    final row = await db.collection('fee_settings').doc(documentId(className, selected)).get();
    if (db.activeProfileId != origin) throw StateError('School changed.');
    if (row.exists) return row.data()!;
    final legacy = (await db.collection('fee_settings').doc(className.replaceAll(' ', '_')).get()).data();
    if (db.activeProfileId != origin) throw StateError('School changed.');
    if (legacy != null && (legacy['academicSession'] == selected ||
        legacy['academicSession'] == null && selected == await currentSession())) return legacy;
    return {};
  }

  static Future<void> save(String className, String session, Map<String, double> fees) async {
    final db = FirebaseFirestore.instance, origin = FirebaseFirestore.instance.activeProfileId;
    await db.ensureDurableSchoolRecords();
    final old = await load(className, session: session);
    if (db.activeProfileId != origin) throw StateError('School changed.');
    final merged = {...Map<String, dynamic>.from(old['fees'] as Map? ?? {}), ...fees};
    final heads = merged.entries.where((e) => e.value is num && e.value > 0).map((e) => e.key).toList();
    final retained = Map<String, dynamic>.from(old)..removeWhere((key, _) => key.startsWith('_sync') || key == 'operationId');
    final batch = db.batch();
    batch.set(db.collection('fee_settings').doc(documentId(className, session)), {
      ...retained, 'className': className, 'academicSession': session, 'fees': merged,
      'configured': heads.isNotEmpty, 'configuredHeads': heads, 'updatedAt': FieldValue.serverTimestamp(),
    }, const SetOptions(merge: true));
    batch.delete(db.collection('_local_fee_edit_locks').doc(documentId(className, session)));
    await batch.commit();
  }
}
