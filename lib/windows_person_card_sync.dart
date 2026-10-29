import 'windows_local_firestore.dart';
import 'windows_sync_dependencies.dart';
import 'windows_sync_recovery.dart';

class DeferredPersonCardFailure {
  DeferredPersonCardFailure(this.error, this.stack);
  final Object error;
  final StackTrace stack;
  Never rethrowFailure() => Error.throwWithStackTrace(error, stack);
}

/// Durable parent + card work. Physical record/file ACKs stay independent;
/// the parent dependency remains until its dependent card queue has settled.
class WindowsPersonCardSync {
  /// A record-local priority failure must not starve normal cloud reads.
  /// The normal owner still surfaces the original failure before completion.
  static Future<DeferredPersonCardFailure?> priorityPass(Future<void> Function() work) async {
    try { await work(); return null; }
    catch (error, stack) {
      if (!independentDocumentFailure(error)) rethrow;
      return DeferredPersonCardFailure(error, stack);
    }
  }

  static Future<int> run(String school, {
    required Future<void> Function(Map<String, Set<String>>) prepare,
    required Future<void> Function() pushParents,
    required Future<void> Function(Set<String>) sendCards,
    required String Function(String, String, Map<String, dynamic>) cardId,
    bool Function()? canAdmit,
    void Function(Map<String, dynamic>)? onActivity,
  }) async {
    final db = FirebaseFirestore.instance, origin = FirebaseFirestore.instance.activeProfileId;
    void scope() {
      if (db.activeProfileId != origin || db.activeProfileIdentity['schoolSyncId'] != school)
        throw StateError('School changed during person/card sync.');
    }
    scope();
    if (canAdmit?.call() == false) return 0;
    final ready = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    final targets = <String, Set<String>>{};
    for (final row in await WindowsSyncDependencies.read(school)) {
      final data = row.data(), collection = data['collection'];
      if (!{'students_directory', 'teachers_directory'}.contains(collection)) continue;
      final person = (await db.collection(collection as String).doc(data['documentId'] as String).get()).data();
      scope();
      if (person == null || person['_syncDeleted'] == true || person['deleted'] == true ||
          person['schoolId'] != school || person['_syncRevision'] != data['revision']) continue;
      ready.add(row);
      (targets[collection == 'students_directory' ? 'studentId' : 'teacherId'] ??= {})
          .add(data['documentId'] as String);
    }
    if (ready.isEmpty) return 0;
    final watch = Stopwatch()..start();
    Object? preparationFailure; StackTrace? preparationStack;
    try { await prepare(targets); }
    catch (error, stack) {
      if (error is! IdCardPreparationFailure) rethrow;
      preparationFailure = error; preparationStack = stack;
    }
    scope();
    if (canAdmit?.call() == false) return 0;
    // Identity normalization may have queued an additional parent revision.
    // Its verified ACK is required before publishing the child metadata.
    await pushParents();
    scope();
    if (canAdmit?.call() == false) return 0;
    final ids = <String>{};
    for (final row in ready) {
      final data = row.data(), collection = data['collection'] as String;
      final person = (await db.collection(collection).doc(data['documentId'] as String).get()).data();
      scope();
      if (person == null || person['_syncDeleted'] == true || person['deleted'] == true) continue;
      ids.add(cardId(collection, data['documentId'] as String, person));
    }
    await sendCards(ids);
    scope();
    if (preparationFailure != null) Error.throwWithStackTrace(preparationFailure, preparationStack!);
    final pending = (await db.collection('_windows_document_outbox').get()).docs.map((r) => r.id).toSet();
    scope();
    // Keep the durable dependency until the normal reconciliation owner has
    // checked publication/review state. An empty file queue is not an ACK.
    try { onActivity?.call({'stage': 'personCardJob', 'schoolId': school,
      'outcome': pending.intersection(ids).isEmpty ? 'priority_pass' : 'pending',
      'parents': ready.length, 'elapsedMillis': watch.elapsedMilliseconds}); } catch (_) {}
    return ready.length;
  }
}
