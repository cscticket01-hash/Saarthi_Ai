import 'package:flutter/foundation.dart' show mapEquals, listEquals;
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

  /// Explicit order excludes retired names even when older clients merge the
  /// fees map. Zero tombstones also prevent those clients charging a retired fee.
  static List<String> heads(Map<String, dynamic> data) {
    final fees = Map<String, dynamic>.from(data['fees'] as Map? ?? {});
    final order = data['feeHeadOrder'];
    return order is List ? order.whereType<String>().where(fees.containsKey).toSet().toList() : fees.keys.toList();
  }

  static Future<void> save(String className, String session, Map<String, double> fees, {bool replaceHeads = false, Map<String, dynamic>? expectedConfiguration}) async {
    final normalized = <String, double>{};
    final names = <String>{};
    for (final entry in fees.entries) {
      final name = entry.key.trim();
      if (name.isEmpty || name.length > 100 || !names.add(name.toLowerCase()) || !entry.value.isFinite || entry.value < 0) {
        throw ArgumentError('Fee names must be unique and amounts must be finite and non-negative.');
      }
      normalized[name] = entry.value;
    }
    final db = FirebaseFirestore.instance, origin = FirebaseFirestore.instance.activeProfileId;
    await db.ensureDurableSchoolRecords();
    final old = await load(className, session: session);
    if (db.activeProfileId != origin) throw StateError('School changed.');
    if (expectedConfiguration != null &&
        (!mapEquals(Map<String, dynamic>.from(old['fees'] as Map? ?? {}),
          Map<String, dynamic>.from(expectedConfiguration['fees'] as Map? ?? {})) ||
         !listEquals(heads(old), heads(expectedConfiguration)) ||
         old['configured'] != expectedConfiguration['configured'] ||
         old['feeStructureSaved'] != expectedConfiguration['feeStructureSaved'])) {
      throw StateError('Fee structure changed on another device. Cancel and reload before editing again.');
    }
    final previous = Map<String, dynamic>.from(old['fees'] as Map? ?? {});
    final merged = <String, dynamic>{
      for (final key in previous.keys) key: replaceHeads ? 0.0 : previous[key],
      ...normalized,
    };
    final heads = merged.entries.where((e) => e.value is num && e.value > 0).map((e) => e.key).toList();
    final retained = Map<String, dynamic>.from(old)..removeWhere((key, _) => key.startsWith('_sync') || key == 'operationId');
    final batch = db.batch();
    batch.set(db.collection('fee_settings').doc(documentId(className, session)), {
      ...retained, 'className': className, 'academicSession': session, 'fees': merged,
      'configured': heads.isNotEmpty, 'configuredHeads': heads,
      if (replaceHeads) 'feeHeadOrder': normalized.keys.toList(),
      if (replaceHeads) 'feeStructureSaved': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, const SetOptions(merge: true));
    batch.delete(db.collection('_local_fee_edit_locks').doc(documentId(className, session)));
    await batch.commit();
  }
}
