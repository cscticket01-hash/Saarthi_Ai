import 'package:flutter/material.dart';
import 'windows_local_firestore.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_sync_recovery.dart';

/// Local review evidence only. This is never an upload receipt or cloud ACK.
class WindowsIdCardReviews {
  static const collection = '_windows_id_card_reviews';
  static void guard(String profile, String school) {
    final db = FirebaseFirestore.instance;
    if (db.activeProfileId != profile || db.activeProfileIdentity['schoolSyncId'] != school) {
      throw StateError('School changed. Reopen ID-card review.');
    }
  }
  static Future<void> retain(PublishedIdInputConflict error, String name) async {
    final db = FirebaseFirestore.instance, profile = db.activeProfileId;
    final school = error.schoolId, id = error.documentId;
    if (school == null || id == null || error.inputRevision == null || error.cloudRevision == null) throw error;
    guard(profile, school);
    await db.collection(collection).doc(id).set({
      'schoolId': school, 'documentId': id, 'name': name, 'ownerRole': error.ownerRole,
      'personId': error.personId, 'personDocId': error.personDocId,
      'inputRevision': error.inputRevision, 'cloudRevision': error.cloudRevision,
      'status': 'needsReview', 'observedAt': DateTime.now().millisecondsSinceEpoch,
    });
    guard(profile, school);
  }
  static Future<bool> held(String school, String id, String inputRevision, Object? cachedRevision) async {
    final db = FirebaseFirestore.instance, profile = db.activeProfileId;
    guard(profile, school);
    final row = (await db.collection(collection).doc(id).get()).data();
    guard(profile, school);
    return row?['schoolId'] == school && row?['documentId'] == id &&
      row?['inputRevision'] == inputRevision && {'needsReview', 'keepPublished'}.contains(row?['status']) &&
      (cachedRevision == null || row?['cloudRevision'] == cachedRevision);
  }
  static Future<List<Map<String, dynamic>>> pending(String school) async {
    final db = FirebaseFirestore.instance, profile = db.activeProfileId;
    if (db.activeProfileIdentity['schoolSyncId'] != school || school.isEmpty) return [];
    final rows = await db.collection(collection).get();
    guard(profile, school);
    final pending = <Map<String, dynamic>>[];
    for (final doc in rows.docs) {
      final item = doc.data();
      if (item['schoolId'] != school || item['status'] != 'needsReview') continue;
      final cached = (await db.collection('documents').doc(doc.id).get()).data();
      guard(profile, school);
      if (cached?['schoolId'] == school && (cached?['_syncDeleted'] == true ||
          cached?['_syncRevision'] != null && cached?['_syncRevision'] != item['cloudRevision'])) continue;
      pending.add({...item, 'documentId': doc.id});
    }
    return pending;
  }
  static Future<void> supersede(String school, String id) async {
    final db = FirebaseFirestore.instance, profile = db.activeProfileId;
    guard(profile, school);
    final ref = db.collection(collection).doc(id), row = (await ref.get()).data();
    guard(profile, school);
    if (row?['schoolId'] == school) await ref.update({'status': 'superseded'});
  }
  static Future<void> keepPublished(String profile, Map<String, dynamic> captured,
      {Future<Map<String, dynamic>> Function()? read}) async {
    final school = captured['schoolId'] as String, id = captured['documentId'] as String;
    guard(profile, school);
    final reply = await (read?.call() ?? ManagedSchoolSession.callForSchool(school, 'managed/records',
      {'operation': 'read', 'collection': 'documents', 'syncProtocol': 2, 'id': id}));
    guard(profile, school);
    final row = (reply['records'] as Map?)?[id];
    if (reply['schoolId'] != school || reply['syncProtocol'] != 2 || row is! Map ||
        row['schoolId'] != school || row['id'] != null && row['id'] != id ||
        row['documentId'] != null && row['documentId'] != id ||
        row['_syncDeleted'] == true || row['documentKind'] != 'idCard' ||
        row['ownerRole'] != captured['ownerRole'] || row['studentId'] != captured['personDocId'] ||
        row['personId'] != captured['personId'] || row['_syncRevision'] != captured['cloudRevision'] ||
        row['contentHash'] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(row['contentHash'])) {
      throw StateError('Published card changed or identity is unverified. Both versions remain protected.');
    }
    final ref = FirebaseFirestore.instance.collection(collection).doc(id), current = (await ref.get()).data();
    guard(profile, school);
    if (current?['schoolId'] != school || current?['inputRevision'] != captured['inputRevision'] ||
        current?['cloudRevision'] != captured['cloudRevision'] || current?['status'] != 'needsReview') {
      throw StateError('ID-card review changed. Reopen this page.');
    }
    await ref.update({'status': 'keepPublished', 'reviewedAt': DateTime.now().millisecondsSinceEpoch});
    guard(profile, school);
  }
}

class WindowsIdCardReviewScreen extends StatefulWidget {
  const WindowsIdCardReviewScreen({super.key, required this.school, required this.profile});
  final String school, profile;
  @override
  State<WindowsIdCardReviewScreen> createState() => _WindowsIdCardReviewScreenState();
}
class _WindowsIdCardReviewScreenState extends State<WindowsIdCardReviewScreen> {
  late Future<List<Map<String, dynamic>>> rows;
  String? error, busy;
  @override
  void initState() {super.initState(); rows = WindowsIdCardReviews.pending(widget.school);}
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('ID-card review')),
    body: FutureBuilder<List<Map<String, dynamic>>>(future: rows, builder: (context, snapshot) {
      if (FirebaseFirestore.instance.activeProfileId != widget.profile) return const Center(child: Text('School changed. Reopen review.'));
      if (snapshot.hasError) return const Center(child: Text('Review could not be loaded. Reopen this page.'));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      return ListView(padding: const EdgeInsets.all(20), children: [
        const Text('These cards are already published. Local preparation inputs differ; the published cards and all pending changes remain protected. Other school records continue syncing.'),
        if (error != null) Text(error!, style: const TextStyle(color: Colors.orange)),
        if (snapshot.data!.isEmpty) const Text('No ID-card reviews pending.'),
        for (final row in snapshot.data!) Card(child: ListTile(title: Text(row['name']?.toString() ?? 'ID card'),
          subtitle: Text('${row['ownerRole']} • ${row['personDocId']}'),
          trailing: TextButton(onPressed: busy != null ? null : () async {
            setState(() {busy = row['documentId']; error = null;});
            try {
              await WindowsIdCardReviews.keepPublished(widget.profile, row);
              if (mounted) setState(() => rows = WindowsIdCardReviews.pending(widget.school));
            } catch (e) {if (mounted) setState(() => error = '$e');}
            finally {if (mounted) setState(() => busy = null);}
          }, child: Text(busy == row['documentId'] ? 'Verifying…' : 'Keep published ID')))),
      ]);
    }));
}
