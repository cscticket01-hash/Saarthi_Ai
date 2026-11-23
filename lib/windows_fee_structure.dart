import 'package:flutter/foundation.dart' show mapEquals, listEquals;
import 'promotion_session_policy.dart';
import 'windows_local_firestore.dart';

/// Existing fee records stay intact; session-specific structures use the same
/// school-scoped collection and durable versioned outbox.
class WindowsFeeStructure {
  static Future<String> currentSession() async => PromotionSessionPolicy.label(
      DateTime.now(), await PromotionSessionPolicy.rolloverMonth());

  /// Never charge the current session for an older selected month.
  static Future<String> sessionForMonth(String month) async {
    final match = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(month);
    if (match == null) throw FormatException('Invalid fee month');
    final year = int.parse(match.group(1)!);
    final number = int.parse(match.group(2)!);
    if (year < 2000 || year > 2100 || number < 1 || number > 12) {
      throw FormatException('Invalid fee month');
    }
    return PromotionSessionPolicy.label(
        DateTime(year, number, 1), await PromotionSessionPolicy.rolloverMonth());
  }

  /// Old structures default to monthly. A paid ledger always keeps its
  /// original feeItems; changing the schedule only affects new invoices.
  static const billingFrequencies = ['monthly', 'annual', 'once'];

  static Map<String, String> frequencies(Map<String, dynamic> settings) {
    final saved = Map<String, dynamic>.from(settings['feeFrequencies'] as Map? ?? {});
    return {
      for (final head in heads(settings))
        head: billingFrequencies.contains(saved[head])
            ? saved[head].toString() : 'monthly',
    };
  }

  /// No network wait, no guessed admission date and no PDF generation.
  /// Annual heads are due in the school's session rollover month only.
  /// Once-per-enrollment heads require a person-generation-bound fee month;
  /// missing or reused student metadata is not permission to charge.
  static Map<String, double> chargeableAmounts(
    Map<String, dynamic> settings, String feeMonth,
    Map<String, dynamic> student, {required int rolloverMonth}
  ) {
    final parts = RegExp(r'^(\d{4})-(0[1-9]|1[0-2]).firstMatch(feeMonth);
    if (parts == null || rolloverMonth != 1 && rolloverMonth != 4) {
      throw FormatException('Invalid fee billing month or session rollover.');
    }
    final frequenciesByHead = frequencies(settings);
    final savedFees = Map<String, dynamic>.from(settings['fees'] as Map? ?? {});
    final boundPerson = student['mobileStableId']?.toString().trim() ?? '';
    final claimedPerson = student['feeAdmissionPersonId']?.toString().trim() ?? '';
    final firstMonth = student['feeAdmissionMonth']?.toString().trim() ?? '';
    final answer = <String, double>{};
    for (final head in heads(settings)) {
      final value = savedFees[head];
      final amount = value is num ? value.toDouble() :
          double.tryParse(value?.toString() ?? '') ?? 0;
      if (!amount.isFinite || amount < 0) throw StateError('Fee structure is invalid.');
      final frequency = frequenciesByHead[head] ?? 'monthly';
      final eligible = switch (frequency) {
        'monthly' => true,
        'annual' => int.parse(parts.group(2)!) == rolloverMonth,
        'once' => boundPerson.isNotEmpty && claimedPerson == boundPerson &&
            firstMonth == feeMonth,
        _ => false,
      };
      answer[head] = eligible ? amount : 0;
    }
    return answer;
  }

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

  static Future<void> save(String className, String session, Map<String, double> fees, {bool replaceHeads = false, Map<String, dynamic>? expectedConfiguration,
      Map<String, String>? feeFrequencies}) async {
    final normalized = <String, double>{};
    final names = <String>{};
    for (final entry in fees.entries) {
      final name = entry.key.trim();
      if (name.isEmpty || name.length > 100 || !names.add(name.toLowerCase()) || !entry.value.isFinite || entry.value < 0 ||
          (entry.value * 100 - (entry.value * 100).round()).abs() > .000001) {
        throw ArgumentError('Fee names must be unique and amounts must be finite and non-negative.');
      }
      normalized[name] = entry.value;
    }
    if (feeFrequencies != null && feeFrequencies.entries.any((item) =>
        !normalized.containsKey(item.key) || !billingFrequencies.contains(item.value))) {
      throw ArgumentError('Unknown fee head or billing frequency.');
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
         old['feeStructureSaved'] != expectedConfiguration['feeStructureSaved'] ||
         !mapEquals(frequencies(old), frequencies(expectedConfiguration)))) {
      throw StateError('Fee structure changed on another device. Cancel and reload before editing again.');
    }
    final previous = Map<String, dynamic>.from(old['fees'] as Map? ?? {});
    final merged = <String, dynamic>{
      for (final key in previous.keys) key: replaceHeads ? 0.0 : previous[key],
      ...normalized,
    };
    final existingFrequencies = frequencies(old);
    final nextFrequencies = <String, String>{
      for (final head in normalized.keys)
        head: feeFrequencies?[head] ?? existingFrequencies[head] ?? 'monthly',
    };
    final configuredHeads = merged.entries.where((e) => e.value is num && e.value > 0).map((e) => e.key).toList();
    final retained = Map<String, dynamic>.from(old)..removeWhere((key, _) => key.startsWith('_sync') || key == 'operationId');
    final batch = db.batch();
    batch.set(db.collection('fee_settings').doc(documentId(className, session)), {
      ...retained, 'className': className, 'academicSession': session, 'fees': merged,
      'configured': configuredHeads.isNotEmpty, 'configuredHeads': configuredHeads,
      'feeFrequencies': nextFrequencies,
      if (replaceHeads) 'feeHeadOrder': normalized.keys.toList(),
      if (replaceHeads) 'feeStructureSaved': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, const SetOptions(merge: true));
    batch.delete(db.collection('_local_fee_edit_locks').doc(documentId(className, session)));
    await batch.commit();
  }
}
).firstMatch(feeMonth);
    if (parts == null || rolloverMonth != 1 && rolloverMonth != 4) {
      throw FormatException('Invalid fee billing month or session rollover.');
    }
    final frequenciesByHead = frequencies(settings);
    final savedFees = Map<String, dynamic>.from(settings['fees'] as Map? ?? {});
    final boundPerson = student['mobileStableId']?.toString().trim() ?? '';
    final claimedPerson = student['feeAdmissionPersonId']?.toString().trim() ?? '';
    final firstMonth = student['feeAdmissionMonth']?.toString().trim() ?? '';
    final answer = <String, double>{};
    for (final head in heads(settings)) {
      final value = savedFees[head];
      final amount = value is num ? value.toDouble() :
          double.tryParse(value?.toString() ?? '') ?? 0;
      if (!amount.isFinite || amount < 0) throw StateError('Fee structure is invalid.');
      final frequency = frequenciesByHead[head] ?? 'monthly';
      final eligible = switch (frequency) {
        'monthly' => true,
        'annual' => int.parse(parts.group(2)!) == rolloverMonth,
        'once' => boundPerson.isNotEmpty && claimedPerson == boundPerson &&
            firstMonth == feeMonth,
        _ => false,
      };
      answer[head] = eligible ? amount : 0;
    }
    return answer;
  }

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

  static Future<void> save(String className, String session, Map<String, double> fees, {bool replaceHeads = false, Map<String, dynamic>? expectedConfiguration,
      Map<String, String>? feeFrequencies}) async {
    final normalized = <String, double>{};
    final names = <String>{};
    for (final entry in fees.entries) {
      final name = entry.key.trim();
      if (name.isEmpty || name.length > 100 || !names.add(name.toLowerCase()) || !entry.value.isFinite || entry.value < 0 ||
          (entry.value * 100 - (entry.value * 100).round()).abs() > .000001) {
        throw ArgumentError('Fee names must be unique and amounts must be finite and non-negative.');
      }
      normalized[name] = entry.value;
    }
    if (feeFrequencies != null && feeFrequencies.entries.any((item) =>
        !normalized.containsKey(item.key) || !billingFrequencies.contains(item.value))) {
      throw ArgumentError('Unknown fee head or billing frequency.');
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
         old['feeStructureSaved'] != expectedConfiguration['feeStructureSaved'] ||
         !mapEquals(frequencies(old), frequencies(expectedConfiguration)))) {
      throw StateError('Fee structure changed on another device. Cancel and reload before editing again.');
    }
    final previous = Map<String, dynamic>.from(old['fees'] as Map? ?? {});
    final merged = <String, dynamic>{
      for (final key in previous.keys) key: replaceHeads ? 0.0 : previous[key],
      ...normalized,
    };
    final existingFrequencies = frequencies(old);
    final nextFrequencies = <String, String>{
      for (final head in normalized.keys)
        head: feeFrequencies?[head] ?? existingFrequencies[head] ?? 'monthly',
    };
    final configuredHeads = merged.entries.where((e) => e.value is num && e.value > 0).map((e) => e.key).toList();
    final retained = Map<String, dynamic>.from(old)..removeWhere((key, _) => key.startsWith('_sync') || key == 'operationId');
    final batch = db.batch();
    batch.set(db.collection('fee_settings').doc(documentId(className, session)), {
      ...retained, 'className': className, 'academicSession': session, 'fees': merged,
      'configured': configuredHeads.isNotEmpty, 'configuredHeads': configuredHeads,
      'feeFrequencies': nextFrequencies,
      if (replaceHeads) 'feeHeadOrder': normalized.keys.toList(),
      if (replaceHeads) 'feeStructureSaved': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, const SetOptions(merge: true));
    batch.delete(db.collection('_local_fee_edit_locks').doc(documentId(className, session)));
    await batch.commit();
  }
}
