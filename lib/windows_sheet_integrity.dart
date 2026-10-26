import 'windows_local_firestore.dart';

/// Bounded diagnosis invoked only by the existing serialized sync owner.
/// Findings grant no record write, restore, queue mutation or acknowledgement.
class WindowsSheetIntegrity {
  static Future<Map<String, dynamic>> audit({
    required String profile,
    required String school,
    required List<String> collections,
    required Future<Map<String, dynamic>> Function(String collection, int row) read,
  }) async {
    final db = FirebaseFirestore.instance;
    void scope() {
      if (db.activeProfileId != profile ||
          db.activeProfileIdentity['schoolSyncId'] != school) {
        throw StateError('School changed during Sheet integrity audit.');
      }
    }
    scope();
    if (collections.isEmpty || collections.toSet().length != collections.length) {
      throw ArgumentError('Audit collections required.');
    }
    final ref = db.collection('_windows_sync_status').doc('sheet-integrity');
    final prior = (await ref.get()).data();
    scope();
    if (prior != null && prior['schoolId'] != school) {
      throw StateError('Foreign Sheet integrity journal.');
    }
    final collection = collections.contains(prior?['nextCollection'])
        ? prior!['nextCollection'] as String : collections.first;
    final after = prior?['nextRow'] as int? ?? 2;
    if (after < 2 || after > 10000000) throw StateError('Invalid Sheet audit cursor.');
    final result = await read(collection, after);
    scope();
    const reasons = {
      'missing_live_row', 'unmanaged_payload_change', 'unmanaged_metadata_change',
      'readable_projection_change', 'workbook_missing', 'tab_missing',
    };
    final findings = result['findings'], next = result['nextRow'];
    if (result['success'] != true || result['schoolId'] != school ||
        result['integrityAuditVersion'] != 1 || result['collection'] != collection ||
        result['readOnly'] != true || result['observedAt'] is! int ||
        result['checked'] is! int || (result['checked'] as int) < 0 ||
        (result['checked'] as int) > 25 ||
        !{'unsupported_storage', 'no_verified_heads', 'workbook_missing',
          'tab_missing', 'bounded_verified_heads'}.contains(result['coverage']) ||
        findings is! List || findings.length > 25 ||
        findings.any((value) => value is! Map || !reasons.contains(value['reason']) ||
          (value['id'] != null && (value['id'] is! String ||
            (value['id'] as String).isEmpty || (value['id'] as String).length > 200 ||
            (value['id'] as String).contains('/')))) ||
        (next != null && (next is! int || next <= after || next > after + 25))) {
      throw StateError('Unverified Sheet integrity audit; cursor retained.');
    }
    final saved = <String, dynamic>{
      'schoolId': school,
      'collection': collection,
      'coverage': result['coverage'],
      'checked': result['checked'],
      'observedAt': result['observedAt'],
      'findings': findings.map((value) => {
        if ((value as Map)['id'] != null) 'id': value['id'],
        'reason': value['reason'],
      }).toList(),
      'nextCollection': next != null ? collection
          : collections[(collections.indexOf(collection) + 1) % collections.length],
      'nextRow': next ?? 2,
      'scope': 'last_bounded_page_only',
    };
    await ref.set(saved);
    scope();
    return saved;
  }
}
