import 'student_lifecycle_policy.dart';
import 'deleted_owner_document_policy.dart';
import 'school_profile_policy.dart';
import 'school_timestamp.dart';
import 'windows_sync_comparison.dart';
import 'windows_record_change_policy.dart';
export 'school_timestamp.dart' show Timestamp;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';

import 'windows_local_storage.dart';
import 'storage/windows_sqlite_store.dart';
import 'windows_runtime_flags.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_service_status.dart';


typedef WindowsLocalTrackedMutationCallback =
    FutureOr<void> Function();

class WindowsLocalFirestoreSyncControl {
  WindowsLocalFirestoreSyncControl._();

  static const Object _zoneKey =
      #vidyaSaarthiRemoteSyncWrite;
  static const Object _userSaveKey = #vidyaSaarthiExplicitDirectorySave;
  static bool get explicitDirectorySave => Zone.current[_userSaveKey] == true;

  /// Only actual directory Save controls may select a changed local version.
  /// ID-card preparation and other tracked background writes cannot do so.
  static Future<T> runDirectorySave<T>(Future<T> Function() action) =>
      runZoned<Future<T>>(action, zoneValues:{_userSaveKey:true});

  static WindowsLocalTrackedMutationCallback?
      onTrackedMutation;

  static bool get trackingEnabled =>
      Zone.current[_zoneKey] != true;

  static Future<T> runWithoutSyncTracking<T>(
    Future<T> Function() action,
  ) {
    return runZoned<Future<T>>(
      action,
      zoneValues: <Object, Object?>{
        _zoneKey: true,
      },
    );
  }
}

class _ServerTimestampValue {
  const _ServerTimestampValue();
}

class _DeleteFieldValue {
  const _DeleteFieldValue();
}

class FieldValue {
  FieldValue._();

  static Object serverTimestamp() =>
      const _ServerTimestampValue();

  static Object delete() =>
      const _DeleteFieldValue();
}

class SetOptions {
  const SetOptions({
    this.merge = false,
  });

  final bool merge;
}

class FirebaseFirestore {
  FirebaseFirestore._();

  static final FirebaseFirestore instance =
      FirebaseFirestore._();

  final _LocalSchoolDatabase _database =
      _LocalSchoolDatabase();

  String get activeProfileId =>
      _database.activeProfileId;

  Map<String, dynamic> get activeProfileIdentity =>
      _database.activeProfileIdentity;

  /// Serialized active-profile snapshot. Other school profiles never leave storage.
  Future<Map<String, dynamic>> exportActiveSchoolSnapshot() =>
      _database.exportActiveSchoolSnapshot();

  Future<Map<String, dynamic>?> readSchoolRegistrationCache(String schoolId) async {
    final profile = activeProfileId;
    if (activeProfileIdentity['schoolSyncId'] != schoolId) throw StateError('School cache identity changed.');
    final result = await _database.readSchoolRegistrationCache(profile, schoolId);
    if (activeProfileId != profile || activeProfileIdentity['schoolSyncId'] != schoolId) throw StateError('School changed while reading cache.');
    return result == null ? null : _decodeMap(result);
  }

  Future<void> switchProfile(
    String profileId, {
    Map<String, dynamic>? identity,
  }) {
    return _database.switchProfile(
      profileId,
      identity: identity,
    );
  }

  /// Managed schools use durable, tenant-scoped storage regardless of the
  /// legacy standalone RAM-only preference. Authentication/licensing stay in
  /// the startup gate; this validates its saved identity against the live store.
  String? _persistenceBinding;
  Future<void> changeLocalStorageLocation(String path) => _database.changeStorageLocation(path);
  Future<void> reconcileDeletedOwnerDocuments() => _database.reconcileDeletedOwnerDocuments();
  Future<int>? _persistenceResolution;

  Future<bool> localPersistenceEnabled() async {
    final origin = activeProfileId;
    final identity = activeProfileIdentity;
    if (!validSchoolId(identity['schoolSyncId']?.toString() ?? '')) {
      return await WindowsRuntimeFlags.durableSchoolProfile(origin) ||
          await WindowsRuntimeFlags.localStorageEnabled();
    }
    // Cache only the validated storage decision, never credentials. The
    // authoritative login/session notifier and immutable profile identity
    // invalidate it. Avoid native credential I/O inside every database read.
    final revision = ManagedSchoolSession.changed.value;
    final binding = '$origin:${identity['schoolSyncId']}:${identity['schoolId']}:${identity['blocked']}:$revision';
    if (_persistenceBinding != binding || _persistenceResolution == null) {
      _persistenceBinding = binding;
      _persistenceResolution = _resolvePersistence(identity).catchError((Object error, StackTrace stack) {
        if (_persistenceBinding == binding) {
          _persistenceBinding = null;
          _persistenceResolution = null;
        }
        Error.throwWithStackTrace(error, stack);
      });
    }
    final mode = await _persistenceResolution!;
    if (origin != activeProfileId || _persistenceBinding != binding ||
        ManagedSchoolSession.changed.value != revision) {
      throw StateError('School changed during storage resolution.');
    }
    return mode == 1 || mode == 0 && (await WindowsRuntimeFlags.durableSchoolProfile(origin) || await WindowsRuntimeFlags.localStorageEnabled());
  }

  Future<int> _resolvePersistence(Map<String, dynamic> identity) async {
    final saved = await CentralSchoolCloud.saved();
    if (saved['managed'] != true) return 0; // Legacy standalone preference.
    return saved['uid'] is String && (saved['uid'] as String).isNotEmpty &&
        (saved['firebaseRefreshToken']?.toString() ?? '').isNotEmpty &&
        validSchoolId(saved['schoolId']?.toString() ?? '') &&
        identity['schoolSyncId'] == saved['schoolId'] &&
        (identity['schoolId'] == null || identity['schoolId'] == saved['schoolId']) &&
        identity['blocked'] != true ? 1 : -1;
  }

  /// Exam/fee school records cannot silently fall back to session-only storage.
  /// Promote only the active standalone profile, keeping the global setting.
  Future<void> ensureDurableSchoolRecords() async {
    if (await localPersistenceEnabled()) return;
    if ((await CentralSchoolCloud.saved())['managed'] == true) {
      throw StateError('Verified school context required for durable records.');
    }
    await _database.enableDurableProfile();
  }

  Future<void> resetVolatileSession() => _database.resetVolatileSession();
  Future<Map<String,dynamic>> migrateLocalDatabaseToSqlite({required bool approved}) =>
      _database.migrateToSqlite(approved:approved);

  CollectionReference<Map<String, dynamic>> collection(
    String path,
  ) {
    return CollectionReference<Map<String, dynamic>>._(
      firestore: this,
      collectionPath: path,
    );
  }

  WriteBatch batch() => WriteBatch._(this);

  Future<void> acknowledgeOutbox(DocumentReference<Map<String,dynamic>> ref, Map<String,dynamic> expected, {String? revision, Map<String,dynamic>? canonicalRecord}) {
    ref.requireOriginProfile();
    if(revision!=null && revision.isEmpty)throw StateError('Verified cloud revision required. Pending retained.');
    if(ref.collectionPath!='_windows_firebase_outbox') throw ArgumentError('Outbox reference required');
    return _database.applyOperations([_WriteOperation._(type:_WriteType.delete,
      collection:ref.collectionPath, documentId:ref.id, data:expected, acknowledgedRevision:revision,
      canonicalRecord:canonicalRecord)]);
  }

  /// Binds a legacy row only if its exact durable snapshot is still current.
  /// A foreign binding is never replaced, and payload fields are never copied
  /// from a stale reader into a newer operation.
  Future<Map<String,dynamic>?> migrateOutboxIdentity(
      DocumentReference<Map<String,dynamic>> ref, Map<String,dynamic> expected,
      {required String schoolId}) {
    ref.requireOriginProfile();
    if (ref.collectionPath != '_windows_firebase_outbox') {
      throw ArgumentError('Outbox reference required');
    }
    return _database.migrateOutboxIdentity(ref.id,expected,schoolId);
  }

  Future<Map<String,dynamic>?> bindOutboxWireData(DocumentReference<Map<String,dynamic>> ref,
      Map<String,dynamic> expected, Map<String,dynamic> data, String mode) {
    ref.requireOriginProfile();
    if(ref.collectionPath!='_windows_firebase_outbox')throw ArgumentError('Outbox required');
    return _database.bindOutboxWireData(ref.id,expected,data,mode);
  }

  Future<void> applyVerifiedStudentDeletion(String school,String id,String generation,String revision) =>
      _database.applyVerifiedStudentDeletion(school,id,generation,revision);

  /// Records a remote conflict only while the observed operation remains the
  /// exact durable current version. An administrator's newer review wins.
  Future<bool> recordOutboxConflict(DocumentReference<Map<String,dynamic>> ref,
      Map<String,dynamic> expected, Map<String,dynamic> remote) {
    ref.requireOriginProfile();
    if (ref.collectionPath != '_windows_firebase_outbox') {
      throw ArgumentError('Outbox reference required');
    }
    return _database.recordOutboxConflict(ref.id,expected,remote);
  }

  /// Failure metadata belongs only to the exact operation that failed.
  Future<bool> recordOutboxFailure(DocumentReference<Map<String,dynamic>> ref,
      Map<String,dynamic> expected, {required String state, required String error,
      String? failureCategory, int? retryCount, int? retryAtMillis,
      Map<String,dynamic>? diagnostic}) {
    ref.requireOriginProfile();
    if (ref.collectionPath != '_windows_firebase_outbox') {
      throw ArgumentError('Outbox reference required');
    }
    return _database.recordOutboxFailure(ref.id,expected,state:state,error:error,
      failureCategory:failureCategory,retryCount:retryCount,retryAtMillis:retryAtMillis,
      diagnostic:diagnostic);
  }

  /// Check the live outbox inside the serialized disk write, not a stale pull snapshot.
  Future<void> applySyncedDocument(DocumentReference<Map<String,dynamic>> ref, Map<String,dynamic>? data, {String? tombstoneRevision, int? tombstoneUpdatedAt}) {
    ref.requireOriginProfile();
    return WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>_database.applyOperations([
      _WriteOperation._(type:data==null?_WriteType.delete:_WriteType.set,
        collection:ref.collectionPath,documentId:ref.id,data:data,preservePending:true,
        tombstoneRevision:tombstoneRevision,tombstoneUpdatedAt:tombstoneUpdatedAt),
    ]));
  }

  /// Bounded cloud apply through the same serialized writer and live pending /
  /// restore guards as single-record downloads. Never admits an upload or ACK.
  Future<void> applySyncedCollectionBatch(String collection,
      Map<String,Map<String,dynamic>> records) {
    if(records.isEmpty)return Future<void>.value();
    final school=activeProfileIdentity['schoolSyncId'];
    if(records.length>100||collection.isEmpty||collection.startsWith('_')||
        collection.contains('/')||school is! String||school.isEmpty||
        records.values.any((row)=>row['schoolId']!=school)) {
      throw StateError('Bounded same-school download batch required.');
    }
    final operations=<_WriteOperation>[];
    for(final entry in records.entries) {
      final ref=this.collection(collection).doc(entry.key);
      ref.requireOriginProfile();
      final data=entry.value,deleted=data['_syncDeleted']==true;
      operations.add(_WriteOperation._(type:deleted?_WriteType.delete:_WriteType.set,
        collection:collection,documentId:entry.key,data:deleted?null:data,
        preservePending:true,
        tombstoneRevision:deleted?data['_syncRevision']?.toString():null,
        tombstoneUpdatedAt:deleted&&data['_syncUpdatedAt'] is int?data['_syncUpdatedAt'] as int:null));
    }
    return WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
      ()=>_database.applyOperations(operations));
  }

  /// Readback evidence only. A retained newer edit must never count as a download.
  Future<bool> syncedDocumentMatches(DocumentReference<Map<String,dynamic>> ref, Map<String,dynamic>? expected) async {
    ref.requireOriginProfile();
    final actual = (await ref.get()).data();
    ref.requireOriginProfile();
    if (expected == null) return actual == null;
    if (actual == null) return false;
    return _database._jsonStableMap(_encodeMap(actual)) == _database._jsonStableMap(_encodeMap(expected));
  }

  /// Explicit operator review only. Creates a new CAS operation; never ACKs
  /// the conflicting operation or deletes its retained copies.
  Future<void> enqueueReviewedConflict({required String queueId,
    required Map<String,dynamic> expected, required Map<String,dynamic> remote,
    required String choice, required String reason}) =>
      _database.enqueueReviewedConflict(queueId, expected, remote, choice, reason);

  /// Dedicated owner review transition; ordinary writes still cannot unblock
  /// a retained document conflict. Rechecks the exact queue inside disk commit.
  Future<void> commitReviewedDocument({required String id,
    required Map<String,dynamic> expected,required Map<String,dynamic> remote,
    required Map<String,dynamic> selected,required String choice,required String reason,
    required String localHash}) => _database.commitReviewedDocument(id,expected,remote,selected,choice,reason,localHash);

  /// Cached verified managed-session authorization supports offline admin review;
  /// the server reauthorizes the school before the protected cloud restore.
  Future<void> requestLocalRestore(String deletionOperationId, {required bool approved}) async {
    final saved = await CentralSchoolCloud.saved();
    final access = saved['verifiedAccess'];
    if (!approved || saved['managed'] != true || access is! Map ||
        access['success'] != true || access['allowed'] != true ||
        access['expiresAt'] is! int || (access['expiresAt'] as int)<=DateTime.now().millisecondsSinceEpoch ||
        access['schoolId'] != activeProfileIdentity['schoolSyncId'] ||
        saved['schoolId'] != access['schoolId'] || saved['uid'] != access['uid']) {
      throw StateError('Current verified school administrator approval required.');
    }
    await _database.localRestoreMutation(deletionOperationId, school:saved['schoolId'].toString());
  }

  Future<void> finishLocalRestore(String deletionOperationId, {required String expectedDeletedRevision,
      required String restoredRevision}) => _database.localRestoreMutation(deletionOperationId,
        school:activeProfileIdentity['schoolSyncId']?.toString() ?? '',
        expectedDeletedRevision:expectedDeletedRevision,restoredRevision:restoredRevision);

  Future<T> runTransaction<T>(
    Future<T> Function(Transaction transaction) action,
  ) async {
    final transaction = Transaction._(this);
    final result = await action(transaction);
    await transaction._commit();
    return result;
  }
}

class Query<T> {
  Query._({
    required this.firestore,
    required this.collectionPath,
    this.filters = const <_WhereFilter>[],
    this.orderField,
    this.orderDescending = false,
    this.limitCount,
  }) : originProfile=firestore.activeProfileId;

  final FirebaseFirestore firestore;
  final String collectionPath;
  final List<_WhereFilter> filters;
  final String? orderField;
  final bool orderDescending;
  final int? limitCount;
  final String originProfile;
  void requireOriginProfile(){if(firestore.activeProfileId!=originProfile)throw StateError('School profile changed; reopen this query.');}

  Query<T> where(
    String field, {
    Object? isEqualTo,
  }) {
    requireOriginProfile();
    return Query<T>._(
      firestore: firestore,
      collectionPath: collectionPath,
      filters: <_WhereFilter>[
        ...filters,
        _WhereFilter(
          field: field,
          equals: isEqualTo,
        ),
      ],
      orderField: orderField,
      orderDescending: orderDescending,
      limitCount: limitCount,
    );
  }

  Query<T> orderBy(
    String field, {
    bool descending = false,
  }) {
    requireOriginProfile();
    return Query<T>._(
      firestore: firestore,
      collectionPath: collectionPath,
      filters: filters,
      orderField: field,
      orderDescending: descending,
      limitCount: limitCount,
    );
  }

  Query<T> limit(int count) {
    requireOriginProfile();
    return Query<T>._(
      firestore: firestore,
      collectionPath: collectionPath,
      filters: filters,
      orderField: orderField,
      orderDescending: orderDescending,
      limitCount: count,
    );
  }

  Future<QuerySnapshot<T>> get() async {
    requireOriginProfile();
    final rawDocs =
        await firestore._database.readCollection(
      collectionPath,
    );
    requireOriginProfile();

    final docs = <QueryDocumentSnapshot<T>>[];

    for (final entry in rawDocs.entries) {
      final decoded = _decodeMap(entry.value);

      if (!_matches(decoded)) {
        continue;
      }

      docs.add(
        QueryDocumentSnapshot<T>._(
          id: entry.key,
          dataValue: decoded as T,
          reference: DocumentReference<T>._(
            firestore: firestore,
            collectionPath: collectionPath,
            documentId: entry.key,
          ),
        ),
      );
    }

    final field = orderField;

    if (field != null) {
      docs.sort((a, b) {
        final av = _sortableValue(
          (a.data() as dynamic)[field],
        );
        final bv = _sortableValue(
          (b.data() as dynamic)[field],
        );

        final result = _compareValues(av, bv);

        return orderDescending ? -result : result;
      });
    }

    final max = limitCount;

    final output = max != null && docs.length > max
        ? docs.sublist(0, max)
        : docs;

    return QuerySnapshot<T>._(output);
  }

  Stream<QuerySnapshot<T>> snapshots() async* {
    try {
      if(firestore.activeProfileId!=originProfile)return;
      yield await get();
      if(firestore.activeProfileId!=originProfile)return;
      await for (final _ in firestore._database.changesFor(collectionPath)) {
        if(firestore.activeProfileId!=originProfile)return;
        yield await get();
      }
    } on StateError {
      // Retire subscriptions from the old tenant without delivering the new
      // tenant's rows or raising an unhandled UI error during account switch.
      if(firestore.activeProfileId==originProfile)rethrow;
    }
  }

  bool _matches(
    Map<String, dynamic> data,
  ) {
    for (final filter in filters) {
      if (data[filter.field] != filter.equals) {
        return false;
      }
    }

    return true;
  }
}

class CollectionReference<T> extends Query<T> {
  CollectionReference._({
    required FirebaseFirestore firestore,
    required String collectionPath,
  }) : super._(
          firestore: firestore,
          collectionPath: collectionPath,
        );

  DocumentReference<T> doc([
    String? path,
  ]) {
    requireOriginProfile();
    final id = path == null || path.trim().isEmpty
        ? _autoDocumentId()
        : path.trim();

    return DocumentReference<T>._(
      firestore: firestore,
      collectionPath: collectionPath,
      documentId: id,
    );
  }

  Future<DocumentReference<T>> add(
    T data,
  ) async {
    final reference = doc();

    await reference.set(data);

    return reference;
  }
}

class DocumentReference<T> {
  DocumentReference._({
    required this.firestore,
    required this.collectionPath,
    required this.documentId,
  }) : originProfile=firestore.activeProfileId;

  final FirebaseFirestore firestore;
  final String collectionPath;
  final String documentId;
  final String originProfile;
  void requireOriginProfile(){if(firestore.activeProfileId!=originProfile)throw StateError('School profile changed; reopen this record.');}

  String get id => documentId;

  Future<DocumentSnapshot<T>> get() async {
    requireOriginProfile();
    final raw = await firestore._database.readDocument(
      collectionPath,
      documentId,
    );
    requireOriginProfile();

    if (raw == null) {
      return DocumentSnapshot<T>._(
        id: documentId,
        dataValue: null,
        reference: this,
      );
    }

    return DocumentSnapshot<T>._(
      id: documentId,
      dataValue: _decodeMap(raw) as T,
      reference: this,
    );
  }

  Stream<DocumentSnapshot<T>> snapshots() async* {
    try {
      if(firestore.activeProfileId!=originProfile)return;
      yield await get();
      if(firestore.activeProfileId!=originProfile)return;
      await for (final _ in firestore._database.changesFor(collectionPath)) {
        if(firestore.activeProfileId!=originProfile)return;
        yield await get();
      }
    } on StateError {
      // Retire subscriptions from the old tenant without delivering the new
      // tenant's rows or raising an unhandled UI error during account switch.
      if(firestore.activeProfileId==originProfile)rethrow;
    }
  }

  Future<void> set(
    T data, [
    SetOptions? options,
  ]) async {
    if (data is! Map) {
      throw ArgumentError(
        'Windows local database Map data require karta hai.',
      );
    }

    requireOriginProfile();
    await firestore._database.setDocument(
      collectionPath,
      documentId,
      Map<String, dynamic>.from(data as Map),
      merge: options?.merge == true,
    );
  }

  Future<void> update(
    Map<String, dynamic> data,
  ) async {
    requireOriginProfile();
    await firestore._database.updateDocument(
      collectionPath,
      documentId,
      data,
    );
  }

  Future<void> delete() async {
    requireOriginProfile();
    await firestore._database.deleteDocument(
      collectionPath,
      documentId,
    );
  }
}

class DocumentSnapshot<T> {
  DocumentSnapshot._({
    required this.id,
    required this.dataValue,
    required this.reference,
  });

  final String id;
  final T? dataValue;
  final DocumentReference<T> reference;

  bool get exists => dataValue != null;

  T? data() => dataValue;
}

class QueryDocumentSnapshot<T>
    extends DocumentSnapshot<T> {
  QueryDocumentSnapshot._({
    required String id,
    required T dataValue,
    required DocumentReference<T> reference,
  }) : super._(
          id: id,
          dataValue: dataValue,
          reference: reference,
        );

  @override
  T data() => dataValue as T;
}

class QuerySnapshot<T> {
  QuerySnapshot._(
    this.docs,
  );

  final List<QueryDocumentSnapshot<T>> docs;
}

class WriteBatch {
  WriteBatch._(this.firestore):originProfile=firestore.activeProfileId;
  final String originProfile;

  final FirebaseFirestore firestore;
  final List<_WriteOperation> _operations =
      <_WriteOperation>[];

  final Map<String, Map<String, Map<String, dynamic>?>> _expected = {};

  /// Check financial read dependencies inside the serialized storage owner,
  /// before any record/outbox changes. A concurrent sync cannot erase a balance.
  void requireUnchanged(
    DocumentReference<Map<String, dynamic>> reference,
    Map<String, dynamic>? expected,
  ) {
    reference.requireOriginProfile();
    if (reference.originProfile != originProfile) throw StateError('Foreign read dependency.');
    _expected.putIfAbsent(
      reference.collectionPath,
      () => {},
    )[reference.documentId] = expected == null
        ? null
        : _encodeMap(expected);
  }

  void set<T>(
    DocumentReference<T> reference,
    T data, [
    SetOptions? options,
  ]) {
    if (data is! Map) {
      throw ArgumentError('Batch set Map require karta hai.');
    }

    reference.requireOriginProfile();
    _operations.add(
      _WriteOperation.set(
        reference.collectionPath,
        reference.documentId,
        Map<String, dynamic>.from(data as Map),
        merge: options?.merge == true,
      ),
    );
  }

  void update<T>(
    DocumentReference<T> reference,
    Map<String, dynamic> data,
  ) {
    reference.requireOriginProfile();
    _operations.add(
      _WriteOperation.update(
        reference.collectionPath,
        reference.documentId,
        data,
      ),
    );
  }

  void delete<T>(
    DocumentReference<T> reference,
  ) {
    reference.requireOriginProfile();
    _operations.add(
      _WriteOperation.delete(
        reference.collectionPath,
        reference.documentId,
      ),
    );
  }

  Future<void> commit() async {
    if(firestore.activeProfileId!=originProfile)throw StateError('School profile changed during batch.');
    for (final collection in _expected.entries) {
      for (final id in collection.value.keys) {
        if (!_operations.any((o) => o.collection == collection.key && o.documentId == id))
          throw StateError('A guarded record must be included in the batch.');
      }
    }
    await firestore._database.applyOperations(
      _operations,
      expected: _expected,
    );
  }
}

class Transaction {
  Transaction._(this.firestore):originProfile=firestore.activeProfileId;
  final String originProfile;

  final FirebaseFirestore firestore;
  final List<_WriteOperation> _operations =
      <_WriteOperation>[];

  Future<DocumentSnapshot<T>> get<T>(
    DocumentReference<T> reference,
  ) {
    reference.requireOriginProfile();
    return reference.get();
  }

  void set<T>(
    DocumentReference<T> reference,
    T data, [
    SetOptions? options,
  ]) {
    if (data is! Map) {
      throw ArgumentError(
        'Transaction set Map require karta hai.',
      );
    }

    reference.requireOriginProfile();
    _operations.add(
      _WriteOperation.set(
        reference.collectionPath,
        reference.documentId,
        Map<String, dynamic>.from(data as Map),
        merge: options?.merge == true,
      ),
    );
  }

  void update<T>(
    DocumentReference<T> reference,
    Map<String, dynamic> data,
  ) {
    reference.requireOriginProfile();
    _operations.add(
      _WriteOperation.update(
        reference.collectionPath,
        reference.documentId,
        data,
      ),
    );
  }

  void delete<T>(
    DocumentReference<T> reference,
  ) {
    reference.requireOriginProfile();
    _operations.add(
      _WriteOperation.delete(
        reference.collectionPath,
        reference.documentId,
      ),
    );
  }

  Future<void> _commit() async {
    if(firestore.activeProfileId!=originProfile)throw StateError('School profile changed during transaction.');
    await firestore._database.applyOperations(
      _operations,
    );
  }
}

class _WhereFilter {
  const _WhereFilter({
    required this.field,
    required this.equals,
  });

  final String field;
  final Object? equals;
}

enum _WriteType {
  set,
  update,
  delete,
}

class _WriteOperation {
  const _WriteOperation._({
    required this.type,
    required this.collection,
    required this.documentId,
    this.data,
    this.merge = false,
    this.preservePending = false,
    this.acknowledgedRevision,
    this.canonicalRecord,
    this.tombstoneRevision,
    this.tombstoneUpdatedAt,
  });

  factory _WriteOperation.set(
    String collection,
    String documentId,
    Map<String, dynamic> data, {
    required bool merge,
  }) {
    return _WriteOperation._(
      type: _WriteType.set,
      collection: collection,
      documentId: documentId,
      data: data,
      merge: merge,
    );
  }

  factory _WriteOperation.update(
    String collection,
    String documentId,
    Map<String, dynamic> data,
  ) {
    return _WriteOperation._(
      type: _WriteType.update,
      collection: collection,
      documentId: documentId,
      data: data,
    );
  }

  factory _WriteOperation.delete(
    String collection,
    String documentId,
  ) {
    return _WriteOperation._(
      type: _WriteType.delete,
      collection: collection,
      documentId: documentId,
    );
  }

  final _WriteType type;
  final Map<String,dynamic>? canonicalRecord;
  final String collection;
  final String documentId;
  final Map<String, dynamic>? data;
  final bool merge;
  final bool preservePending;
  final String? acknowledgedRevision;
  final String? tombstoneRevision;
  final int? tombstoneUpdatedAt;
}

class _LocalSchoolDatabase {
  final Map<String, StreamController<void>> _signals =
      <String, StreamController<void>>{};

  Future<void> _writeTail = Future<void>.value();

  WindowsSqliteStore? _sqlite;
  Future<WindowsSqliteStore?>? _openingSqlite;
  String? _sqlitePath;
  Future<WindowsSqliteStore?> _sqliteStore() async {
    if (!WindowsLocalStorage.sqliteEnabled) return null;
    final directory = await WindowsLocalStorage.dataDirectory();
    final path = '${directory.path}${Platform.pathSeparator}${WindowsSqliteStore.databaseName}';
    if (_sqlitePath != path) {
      await _sqlite?.close(); _sqlite=null; _openingSqlite=null; _sqlitePath=path;
    }
    return _openingSqlite ??= (() async {
      // Existing installations stay on their original backend until explicit
      // installation consent. A review build must never migrate a real PC.
      final legacy=await _file();
      if (!await File(path).exists() && (await legacy.exists() ||
          await File('${legacy.path}.pending').exists() || await File('${legacy.path}.bak').exists())) return null;
      try {return _sqlite=await WindowsSqliteStore.open(path);}
      catch (_) {_openingSqlite=null;rethrow;}
    })();
  }
  Future<void> changeStorageLocation(String path) {
    final migration=_writeTail.then((_) async {
      await _sqlite?.close();_sqlite=null;_openingSqlite=null;_sqlitePath=null;
      await WindowsLocalStorage.changeLocation(path);
    });
    _writeTail=migration.then<void>((_) {},onError:(Object _,StackTrace __) {});
    return migration;
  }
  Future<Map<String,dynamic>> migrateToSqlite({required bool approved}) {
    final next=_writeTail.then((_) async {
      await _sqlite?.close();_sqlite=null;_openingSqlite=null;_sqlitePath=null;
      return WindowsSqliteMigration.migrate(await WindowsLocalStorage.dataDirectory(),approved:approved);
    });
    _writeTail=next.then<void>((_) {},onError:(Object _,StackTrace __) {});
    return next;
  }
  Future<File> _file() => WindowsLocalStorage.databaseFile();

  String _activeProfileId = 'unbound';
  Map<String, dynamic> _activeIdentity = const <String, dynamic>{};

  // Legacy standalone Local Storage OFF uses RAM only. Verified managed
  // school contexts use durable local-first storage independent of that flag.
  // Remote data can still be mirrored into this in-memory root for the
  // current app session, so Firebase + Google features remain usable without
  // leaving a local database behind on the PC.
  Map<String, dynamic> _memoryRoot = <String, dynamic>{
    'version': 2,
    'profiles': <String, dynamic>{},
  };

  String get activeProfileId => _activeProfileId;

  Map<String, dynamic> get activeProfileIdentity =>
      Map<String, dynamic>.from(_activeIdentity);

  Future<Map<String, dynamic>> exportActiveSchoolSnapshot() {
    final origin = _activeProfileId;
    final school = _activeIdentity['schoolSyncId']?.toString() ?? '';
    if (!validSchoolId(school))
      throw StateError('Verified school scope required for backup.');
    final next = _writeTail.then((_) async {
      if (_activeProfileId != origin ||
          _activeIdentity['schoolSyncId'] != school) {
        throw StateError('School changed before backup snapshot.');
      }
      final root = await _readRoot();
      final collections = _collections(root);
      final snapshot = <String, dynamic>{
        'version': 2,
        'profiles': {
          origin: {
            'identity': {'schoolSyncId': school},
            'collections': collections,
          },
        },
      };
      final frozen = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(snapshot)) as Map,
      );
      if (_activeProfileId != origin ||
          _activeIdentity['schoolSyncId'] != school) {
        throw StateError('School changed during backup snapshot.');
      }
      return frozen;
    });
    _writeTail = next.then<void>((_) {}).catchError((_) {});
    return next;
  }

  Future<void> switchProfile(String profileId,{Map<String,dynamic>? identity}) {
    final next=_writeTail.then((_)=>_switchProfileNow(profileId,identity:identity));
    _writeTail=next.catchError((_){});
    return next;
  }
  Future<void> _switchProfileNow(
    String profileId, {
    Map<String, dynamic>? identity,
  }) async {
    final clean = _safeProfileId(profileId);
    final nextIdentity = identity == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(identity);

    if (_activeProfileId == clean &&
        _jsonStableMap(_activeIdentity) ==
            _jsonStableMap(nextIdentity)) {
      return;
    }

    _activeProfileId = clean;
    _activeIdentity = nextIdentity;

    // Persist only profile metadata. Existing school data is never copied
    // between profiles. This is the core cross-school isolation guarantee.
    final root = await _readRoot();
    final profiles = _profiles(root);
    final rawProfile = profiles[clean];
    final profile = rawProfile is Map
        ? Map<String, dynamic>.from(rawProfile)
        : <String, dynamic>{};
    profile.putIfAbsent('collections', () => <String, dynamic>{});
    profile['identity'] = _encodeMap(nextIdentity);
    profile['lastOpenedAt'] = DateTime.now().toUtc().millisecondsSinceEpoch;
    profiles[clean] = profile;
    root['profiles'] = profiles;
    root['activeProfileHint'] = clean;
    await _writeRoot(root);

    // Every existing StreamBuilder must immediately reload from the new
    // profile, otherwise the previous school's cards could stay on screen.
    for (final controller in _signals.values) {
      if (!controller.isClosed) {
        controller.add(null);
      }
    }
  }

  Stream<void> changesFor(
    String collection,
  ) {
    return _signals
        .putIfAbsent(
          collection,
          () => StreamController<void>.broadcast(),
        )
        .stream;
  }

  Future<Map<String, dynamic>?> readSchoolRegistrationCache(String profileId, String schoolId) async {
    final root = await _readRoot();
    final profile = _profiles(root)[profileId];
    if (profile is! Map || profile['identity'] is! Map || profile['identity']['schoolSyncId'] != schoolId) {
      throw StateError('School cache provenance could not be verified.');
    }
    final collections = profile['collections'];
    final docs = collections is Map ? collections['school_config'] : null;
    final value = docs is Map ? docs['school_profile_cache'] : null;
    if (value is! Map) return null;
    final result = Map<String, dynamic>.from(value);
    if (result['schoolId'] != null && result['schoolId'] != schoolId) throw StateError('Foreign school cache blocked.');
    result.putIfAbsent('schoolId', () => schoolId);
    return result;
  }

  Future<Map<String, dynamic>?> readDocument(
    String collection,
    String documentId,
  ) async {
    if (await FirebaseFirestore.instance.localPersistenceEnabled()) {
      final sqlite=await _sqliteStore();
      if(sqlite!=null)return sqlite.readDocument(_activeProfileId,collection,documentId);
    }
    final root = await _readRoot();

    final collections =
        _collections(root);

    final docs = collections[collection];

    if (docs is! Map) {
      return null;
    }

    final value = docs[documentId];

    if (value is! Map) {
      return null;
    }

    return Map<String, dynamic>.from(value);
  }

  Future<Map<String, Map<String, dynamic>>>
      readCollection(
    String collection,
  ) async {
    if (await FirebaseFirestore.instance.localPersistenceEnabled()) {
      final sqlite=await _sqliteStore();
      if(sqlite!=null)return sqlite.readCollection(_activeProfileId,collection);
    }
    final root = await _readRoot();

    final raw =
        _collections(root)[collection];

    if (raw is! Map) {
      return <String, Map<String, dynamic>>{};
    }

    final output =
        <String, Map<String, dynamic>>{};

    for (final entry in raw.entries) {
      if (entry.value is Map) {
        output[entry.key.toString()] =
            Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
    }

    return output;
  }

  Future<void> setDocument(
    String collection,
    String documentId,
    Map<String, dynamic> data, {
    required bool merge,
  }) {
    return applyOperations(
      <_WriteOperation>[
        _WriteOperation.set(
          collection,
          documentId,
          data,
          merge: merge,
        ),
      ],
    );
  }

  Future<void> updateDocument(
    String collection,
    String documentId,
    Map<String, dynamic> data,
  ) {
    return applyOperations(
      <_WriteOperation>[
        _WriteOperation.update(
          collection,
          documentId,
          data,
        ),
      ],
    );
  }

  Future<void> deleteDocument(
    String collection,
    String documentId,
  ) {
    return applyOperations(
      <_WriteOperation>[
        _WriteOperation.delete(
          collection,
          documentId,
        ),
      ],
    );
  }

  Future<void> applyOperations(
    List<_WriteOperation> operations,
    {Map<String, Map<String, Map<String, dynamic>?>> expected = const {}}
  ) {
    if (operations.isEmpty) {
      return Future<void>.value();
    }

    final profileAtEnqueue=_activeProfileId;
    final userDirectorySave = WindowsLocalFirestoreSyncControl.explicitDirectorySave;
    final completer = Completer<void>();

    _writeTail = _writeTail.then((_) async {
      try {
        if(_activeProfileId!=profileAtEnqueue)throw StateError('School profile changed before queued write.');
        final retiringOwner = WindowsLocalFirestoreSyncControl.trackingEnabled && operations.any((o) =>
          o.type == _WriteType.delete && {'students_directory','teachers_directory'}.contains(o.collection));
        // ACKs and verified-cache writes must not deserialize every historical
        // receipt/baseline for every row. Keep the same serialized transaction,
        // generation CAS and exact-row queue comparison; narrow only owner paths
        // whose complete read/write set is known. Legacy JSON remains unchanged.
        Map<String,List<String>>? ownerScope;
        Set<String>? ownerCollections;
        final acknowledgementOnly = operations.every((o) =>
          o.type == _WriteType.delete && o.collection == '_windows_firebase_outbox' &&
          o.acknowledgedRevision != null && o.data?['operationId'] is String);
        final metadataOnly = operations.every((o) => const {
          '_windows_verified_cloud_records','_windows_sync_downloads',
          '_windows_sync_manifest','_windows_sync_status','_windows_sync_dependencies',
        }.contains(o.collection) && o.acknowledgedRevision == null);
        final downloadOnly = !WindowsLocalFirestoreSyncControl.trackingEnabled &&
          operations.every((o) => o.preservePending && !o.collection.startsWith('_windows_'));
        if (acknowledgementOnly) {
          final queueIds = operations.map((o)=>o.documentId).toSet().toList();
          final operationIds = operations.map((o)=>o.data!['operationId'] as String).toSet().toList();
          ownerScope = {
            '_windows_firebase_outbox':queueIds,'_windows_sync_baselines':queueIds,
            '_windows_sync_receipts':operationIds,'_windows_local_deletions':operationIds,
            '_windows_recycle_requests':operationIds.map((id)=>'local-restore-$id').toList(),
          };
          ownerCollections = ownerScope.keys.toSet();
          for(final operation in operations) {
            if(operation.canonicalRecord!=null && operation.data?['collection'] is String &&
                operation.data?['documentId'] is String) {
              final name=operation.data!['collection'] as String;
              ownerScope.putIfAbsent(name,()=>[]).add(operation.data!['documentId'] as String);
              ownerCollections.add(name);
            }
          }
        } else if (metadataOnly) {
          ownerScope = {for(final name in operations.map((o)=>o.collection).toSet())
            name:operations.where((o)=>o.collection==name).map((o)=>o.documentId).toSet().toList()};
          ownerCollections = ownerScope.keys.toSet();
        } else if (downloadOnly) {
          ownerScope = {for(final name in operations.map((o)=>o.collection).toSet())
            name:operations.where((o)=>o.collection==name).map((o)=>o.documentId).toSet().toList(),
            '_windows_sync_baselines':operations.map((o)=>base64Url.encode(
              utf8.encode('${o.collection}\\n${o.documentId}')).replaceAll('=', '')).toSet().toList()};
          // Preserve scans of legacy/noncanonical pending IDs and restore
          // coordinators, so a newer edit or explicit restore is still protected.
          ownerCollections = {...ownerScope.keys,'_windows_firebase_outbox',
            '_windows_local_deletions','_windows_recycle_requests'};
        }
        final root = await _readRoot(collections:ownerCollections ?? {
          ...operations.map((operation)=>operation.collection),
          '_windows_firebase_outbox','_windows_sync_baselines','_windows_sync_receipts',
          '_windows_sync_conflict_history','_windows_sync_resolution_history',
          '_windows_local_deletions','_windows_recycle_requests',
          if (retiringOwner) ...{'_windows_document_outbox','_local_student_documents','documents',
          'students_directory','teachers_directory',...studentOwnedCollections},
        },recordScope:ownerScope ?? {for(final name in operations.map((o)=>o.collection).where((n)=>!n.startsWith('_windows_') && !retiringOwner).toSet())name:operations.where((o)=>o.collection==name).map((o)=>o.documentId).toSet().toList()});
        if(_activeProfileId!=profileAtEnqueue)throw StateError('School profile changed during queued write.');
        final collections = _collections(root);
        for (final collection in expected.entries) {
          for (final record in collection.value.entries) {
            final actual = (collections[collection.key] as Map?)?[record.key];
            if (jsonEncode(actual) != jsonEncode(record.value))
              throw StateError(
                'Record changed before commit. Refresh and check history.',
              );
          }
        }

        final touched = <String>{};
        var trackedMutation = false;

        for (final operation in operations) {
          final restores = collections['_windows_recycle_requests'];
          final protected = restores is Map ? restores.values.where((r)=>r is Map &&
              r['localRestore'] == true && r['schoolId'] == _activeIdentity['schoolSyncId'] &&
              r['collection'] == operation.collection && r['documentId'] == operation.documentId).toList() : [];
          if (protected.any((r)=>(r as Map)['state'] != 'verified')) {
            if (operation.preservePending) continue;
            if (WindowsLocalFirestoreSyncControl.trackingEnabled && _shouldTrackForFirebase(operation.collection)) {
              throw StateError('Restore coordination pending; original deletion and snapshot retained.');
            }
          }
          // A stale tombstone has no restore revision; it cannot remove the
          // locally verified authorized restore. A subsequent user delete is
          // still tracked normally and replaces this baseline via its own ACK.
          if (operation.preservePending && operation.data == null && protected.isNotEmpty) {
            final current=(collections[operation.collection] as Map?)?[operation.documentId];
            final currentTime=current is Map?current['_syncUpdatedAt']:null;
            if(operation.tombstoneRevision==null || operation.tombstoneRevision!.isEmpty ||
                operation.tombstoneUpdatedAt==null || currentTime is! int ||
                operation.tombstoneUpdatedAt!<=currentTime || protected.any((r)=>
                  (r as Map)['recordRevision']==operation.tombstoneRevision ||
                  ((collections['_windows_local_deletions'] as Map?)?[r['deletionOperationId']] as Map?)?['deletedRevision']==operation.tombstoneRevision)) continue;
          }
          if(operation.preservePending) {
            final pending=collections['_windows_firebase_outbox'];
            if(pending is Map && pending.values.any((item)=>item is Map &&
                item['collection']==operation.collection && item['documentId']==operation.documentId)) continue;
          }
          if(operation.preservePending && (operation.data?['_syncRevision'] is String || operation.tombstoneRevision != null)) {
            final baselines = collections.putIfAbsent('_windows_sync_baselines',()=> <String,dynamic>{}) as Map;
            final key = base64Url.encode(utf8.encode('${operation.collection}\\n${operation.documentId}')).replaceAll('=', '');
            baselines[key] = {'revision':operation.data?['_syncRevision'] ?? operation.tombstoneRevision, 'deleted':operation.data == null,
              if(operation.data!=null)'record':_encodeMap(operation.data!),
              if(operation.data?['_syncRecreatesDeletedRevision'] is String) 'recreatedFrom':operation.data!['_syncRecreatesDeletedRevision']};
          }
          final collectionWasTouched=touched.contains(operation.collection);
          touched.add(operation.collection);

          final rawCollection =
              collections.putIfAbsent(
            operation.collection,
            () => <String, dynamic>{},
          );

          final docs =
              Map<String, dynamic>.from(
            rawCollection as Map,
          );

          collections[operation.collection] = docs;
          final beforeSave = docs[operation.documentId] is Map
              ? _encodeMap(Map<String,dynamic>.from(docs[operation.documentId] as Map))
              : null;
          final deletedSnapshot = operation.type == _WriteType.delete &&
              WindowsLocalFirestoreSyncControl.trackingEnabled &&
              _shouldTrackForFirebase(operation.collection) &&
              docs[operation.documentId] is Map
              ? Map<String,dynamic>.from(docs[operation.documentId] as Map)
              : null;

          switch (operation.type) {
            case _WriteType.delete:
              // Compare and remove under the same serialized disk write. A save
              // made while the cloud request was in flight must remain queued.
              if (operation.acknowledgedRevision != null && operation.data != null) {
                final sent = operation.data!, revision = operation.acknowledgedRevision!;
                final baselines = collections.putIfAbsent('_windows_sync_baselines',()=> <String,dynamic>{}) as Map;
                baselines[operation.documentId] = {'revision':revision,'deleted':sent['operation']=='delete',
                  if(sent['data'] is Map && sent['data']['_syncRecreatesDeletedRevision'] is String) 'recreatedFrom':sent['data']['_syncRecreatesDeletedRevision']};
                final canonical=operation.canonicalRecord;
                if(canonical!=null) {
                  if(canonical['schoolId']!=sent['schoolId'] || canonical['_syncRevision']!=revision ||
                    canonical['id']!=null && canonical['id']!=sent['documentId'] || canonical['_syncDeleted']==true)
                    throw StateError('Canonical acknowledgement identity did not verify.');
                  baselines[operation.documentId]['record']=_encodeMap(canonical);
                  final pending=docs[operation.documentId];
                  if(pending is Map && pending['operationId']==sent['operationId']) {
                    final records=collections.putIfAbsent(sent['collection'],()=> <String,dynamic>{}) as Map;
                    if(records[sent['documentId']] is Map && sent['operation']!='delete') {
                      records[sent['documentId']]=_encodeMap(canonical);
                      touched.add(sent['collection'] as String);
                    }
                  }
                }
                final receipts=collections.putIfAbsent('_windows_sync_receipts',()=> <String,dynamic>{}) as Map;
                if(sent['operationId'] is String)receipts.putIfAbsent(sent['operationId'],()=>{
                  'schoolId':sent['schoolId'],'operationId':sent['operationId'],
                  'collection':sent['collection'],'recordRevision':revision,
                  'acknowledgedAt':DateTime.now().millisecondsSinceEpoch});
                final snapshot = (collections['_windows_local_deletions'] as Map?)?[sent['operationId']];
                if (sent['operation'] == 'delete' && snapshot is Map &&
                    snapshot['schoolId'] == sent['schoolId'] &&
                    snapshot['collection'] == sent['collection'] &&
                    snapshot['documentId'] == sent['documentId']) {
                  snapshot['cloudDeletionVerified'] = true;
                  snapshot['deletedRevision'] = revision;
                  snapshot['acknowledgedAt'] = DateTime.now().millisecondsSinceEpoch;
                  final restore = (collections['_windows_recycle_requests'] as Map?)?['local-restore-${sent['operationId']}'];
                  if(restore is Map && restore['schoolId']==sent['schoolId'] && restore['state']=='awaitingDeleteAck') {
                    restore['state']='awaitingCloudRestore';restore['expectedDeletedRevision']=revision;
                  }
                }

                final queued = docs[operation.documentId];
                if (queued is Map && queued['operationId'] != sent['operationId'] &&
                    queued['baseCloudRevision'] == sent['baseCloudRevision']) {
                  queued['baseCloudRevision'] = revision;
                  if(canonical!=null && queued['data'] is Map && queued['wireData'] is! Map) {
                    final patch=buildRecordFieldPatch(sent['collection'] as String,canonical,
                      _decodeMap(Map<String,dynamic>.from(queued['data'])));
                    if(patch==null)queued.remove('fieldPatch');else queued['fieldPatch']=_encodeMap(patch);
                  }
                }
                if(queued is Map && queued['priorDeletion'] is Map &&
                    queued['priorDeletion']['operationId'] == sent['operationId']) {
                  if(queued['operation'] != 'delete' && queued['data'] is Map) {
                    queued['data']['_syncRecreatesDeletedRevision'] = revision;
                  }
                  queued.remove('priorDeletion');
                }
              }
              if(operation.data != null &&
                  (operation.acknowledgedRevision != null
                    ? (docs[operation.documentId] is! Map || (docs[operation.documentId] as Map)['operationId'] != operation.data!['operationId'])
                    : jsonEncode(docs[operation.documentId]) != jsonEncode(_encodeMap(operation.data!)))) continue;
              docs.remove(operation.documentId);
              break;

            case _WriteType.set:
              final incoming =
                  _encodeMap(operation.data ?? {});
              if (operation.collection == 'school_config' && operation.documentId == 'school_profile_cache' &&
                  docs[operation.documentId] is Map) {
                final prior = docs[operation.documentId] as Map;
                for (final key in schoolProfileCoreFields) {
                  if (incoming.containsKey(key) && (incoming[key] == null || incoming[key].toString().trim().isEmpty) &&
                      prior[key] != null && prior[key].toString().trim().isNotEmpty) incoming[key] = prior[key];
                }
              }
              final oldDocumentQueue=docs[operation.documentId];
              if(operation.collection=='_windows_document_outbox' && oldDocumentQueue is Map &&
                  {'conflict','needsAttention'}.contains(oldDocumentQueue['syncState'])) {
                final history=collections.putIfAbsent('_windows_sync_conflict_history',()=> <String,dynamic>{}) as Map;
                final key='document-'+base64Url.encode(utf8.encode(jsonEncode([
                  operation.documentId,oldDocumentQueue['documentRevision'],oldDocumentQueue['localPath']]))).replaceAll('=','');
                history.putIfAbsent(key,()=>Map<String,dynamic>.from(oldDocumentQueue));
                incoming['syncState']=oldDocumentQueue['syncState'];
              }

              if (operation.merge &&
                  docs[operation.documentId] is Map) {
                final current =
                    Map<String, dynamic>.from(
                  docs[operation.documentId] as Map,
                );

                _applyFields(
                  current,
                  incoming,
                );

                docs[operation.documentId] = current;
              } else {
                final fresh =
                    <String, dynamic>{};

                _applyFields(
                  fresh,
                  incoming,
                );

                docs[operation.documentId] = fresh;
              }
              break;

            case _WriteType.update:
              if (docs[operation.documentId] is! Map) {
                throw StateError(
                  'Local document ${operation.collection}/${operation.documentId} exist nahi karta.',
                );
              }

              final current =
                  Map<String, dynamic>.from(
                docs[operation.documentId] as Map,
              );

              final fields = _encodeMap(operation.data ?? {});
              if (operation.collection == 'school_config' && operation.documentId == 'school_profile_cache') {
                for (final key in schoolProfileCoreFields) {
                  if (fields.containsKey(key) && (fields[key] == null || fields[key].toString().trim().isEmpty) &&
                      current[key] != null && current[key].toString().trim().isNotEmpty) fields[key] = current[key];
                }
              }
              _applyFields(current, fields);

              docs[operation.documentId] = current;
              break;
          }

          if (WindowsLocalFirestoreSyncControl.trackingEnabled &&
              _shouldTrackForFirebase(operation.collection)) {
            if(beforeSave!=null && operation.type!=_WriteType.delete && docs[operation.documentId] is Map) {
              final candidate=Map<String,dynamic>.from(docs[operation.documentId] as Map);
              for(final key in ['createdAt','updatedAt']) {
                if(operation.data?[key] is _ServerTimestampValue) {
                  if(beforeSave.containsKey(key))candidate[key]=beforeSave[key];else candidate.remove(key);
                }
              }
              if(sameSavedRecord(operation.collection,beforeSave,candidate)) {
                docs[operation.documentId]=beforeSave;
                if(!collectionWasTouched)touched.remove(operation.collection);
                continue;
              }
            }
            // Runs inside the same serialized transaction as queue writes.
            // Double-clicks cannot rotate an in-flight operation or its ACK.
            // Restore/lifecycle intents still use their original safeguards.
            if (operation.type != _WriteType.delete && beforeSave != null &&
                docs[operation.documentId] is Map &&
                sameSavedRecord(operation.collection, beforeSave,
                    docs[operation.documentId] as Map)) {
              docs[operation.documentId] = beforeSave;
              if(!collectionWasTouched)touched.remove(operation.collection);
              continue;
            }
            _recordFirebaseOutbox(
              collections,
              operation,
              docs,
              userDirectorySave: userDirectorySave,
              beforeSave:beforeSave,
            );
            if (deletedSnapshot != null) {
              final queue = collections['_windows_firebase_outbox'] as Map;
              final key = base64Url.encode(utf8.encode('${operation.collection}\\n${operation.documentId}')).replaceAll('=', '');
              final intent = queue[key] as Map;
              final snapshots = collections.putIfAbsent('_windows_local_deletions',()=> <String,dynamic>{}) as Map;
              snapshots[intent['operationId']] = {
                'version':1,'schoolId':_activeIdentity['schoolSyncId'] ?? '',
                'collection':operation.collection,'documentId':operation.documentId,
                'operationId':intent['operationId'],'deletedAt':DateTime.now().millisecondsSinceEpoch,
                'snapshot':deletedSnapshot,'cloudDeletionVerified':false,
              };
              if(operation.collection=='students_directory') {
                final generation=deletedSnapshot['mobileStableId']?.toString()??operation.documentId;
                final aliases=(deletedSnapshot['previousStudentIds'] as List? ?? []).whereType<String>().toList();
                for(final category in studentOwnedCollections.where((c)=>c!='documents')) {
                  final related=collections[category];
                  if(related is Map) related.removeWhere((key,value)=>value is Map&&recordBelongsToStudent(category,key.toString(),value,operation.documentId,generation,aliases:aliases));
                }
                // Parent deletion owns cloud cascade. Keep pending documents on
                // their existing version-safe file-deletion owner until its ACK.
                queue.removeWhere((key,value)=>value is Map&&studentOwnedCollections.contains(value['collection'])&&value['collection']!='documents'&&value['data'] is Map&&recordBelongsToStudent(value['collection'],value['documentId'].toString(),value['data'],operation.documentId,generation,aliases:aliases));
                intent['deletedStudentGeneration']=generation;
                touched.addAll(studentOwnedCollections);
              }
              final personKey=operation.collection=='students_directory'?'mobileStableId':
                operation.collection=='teachers_directory'?'teacherId':null;
              if(personKey!=null && deletedSnapshot[personKey] is String)
                intent['deletedRecordIdentity']={personKey:deletedSnapshot[personKey]};
              // The snapshot, hidden local row and original delete intent commit
              // together. Never expire financial evidence or delete file bytes here.
            }
            trackedMutation = true;
          }
        }

        if (retiringOwner && _retireDeletedOwnerDocuments(collections)) {
          touched.addAll({'_windows_document_outbox','_local_student_documents','_windows_sync_conflict_history'});
          trackedMutation = true;
        }
        if(touched.isEmpty && !trackedMutation) {completer.complete();return;}
        _storeCollections(
          root,
          collections,
        );

        await _writeRoot(root);

        for (final collection in touched) {
          final controller = _signals[collection];

          if (controller != null &&
              !controller.isClosed) {
            controller.add(null);
          }
        }

        if (trackedMutation) {
          final callback =
              WindowsLocalFirestoreSyncControl
                  .onTrackedMutation;
          if (callback != null) {
            // A Save gesture's authority ends at its own write. Dart zones
            // otherwise propagate it into deferred sync/card preparation.
            runZoned(() {
              Future<void>.microtask(() async {
                try {
                  await callback();
                } catch (_) {}
              });
            }, zoneValues:{WindowsLocalFirestoreSyncControl._userSaveKey:false});
          }
        }

        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });

    return completer.future;
  }

  Future<void> applyVerifiedStudentDeletion(String school,String id,String generation,String revision) {
    final origin=_activeProfileId,completion=Completer<void>();
    _writeTail=_writeTail.then((_)async{
      try {
        if(_activeProfileId!=origin||_activeIdentity['schoolSyncId']!=school||generation.isEmpty||revision.isEmpty)throw StateError('Verified school deletion required.');
        final root=await _readRoot();
        if(_activeProfileId!=origin)throw StateError('School changed during deletion.');
        final collections=_collections(root);
        final paths=purgeStudentGeneration(collections,school,id,generation);
        final cleanup=collections.putIfAbsent('_windows_student_file_cleanup',()=> <String,dynamic>{}) as Map;
        final cleanupId=sha256.convert(utf8.encode(jsonEncode([school,id,generation,revision]))).toString();
        final prior=cleanup[cleanupId];
        if(prior is Map)paths.addAll((prior['paths'] as List? ?? []).whereType<String>());
        paths.removeWhere((path)=>studentCleanupPathReferenced(collections,path));
        if(paths.isNotEmpty)cleanup[cleanupId]={'schoolId':school,'studentId':id,'generation':generation,'revision':revision,'paths':paths.toList()};
        _storeCollections(root,collections);await _writeRoot(root);
        if(_activeProfileId!=origin)throw StateError('School changed after deletion commit.');
        // Only app-managed copies may be removed; never a picked source file.
        final folder=await WindowsLocalStorage.localFilesDirectory();
        final safeProfile=origin.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'),'_').replaceAll(RegExp(r'\s+'),' ');
        final profileFolder=Directory('${folder.absolute.path}${Platform.pathSeparator}${safeProfile.isEmpty?'file':safeProfile}');
        final prefix=profileFolder.absolute.path+Platform.pathSeparator;
        for(final path in paths) {
          final file=File(path);
          if(file.absolute.path.startsWith(prefix)&&await file.exists()) {
            final resolved=await file.resolveSymbolicLinks();
            final ownRoot=await profileFolder.resolveSymbolicLinks();
            if(resolved.startsWith(ownRoot+Platform.pathSeparator))await file.delete();
          }
        }
        if(cleanup.containsKey(cleanupId)) {
          // The purge commit advanced SQLite's generation. A second write of
          // that old root is stale even though both writes share _writeTail.
          // Read the committed state before retiring only this cleanup intent;
          // keep the generation guard so an external writer cannot be lost.
          final committedRoot=await _readRoot();
          if(_activeProfileId!=origin)throw StateError('School changed during file cleanup.');
          final committedCollections=_collections(committedRoot);
          final committedCleanup=committedCollections['_windows_student_file_cleanup'];
          if(committedCleanup is Map && committedCleanup.remove(cleanupId)!=null) {
            _storeCollections(committedRoot,committedCollections);
            await _writeRoot(committedRoot);
          }
        }
        for(final signal in _signals.values)if(!signal.isClosed)signal.add(null);
        completion.complete();
      }catch(error,stack){completion.completeError(error,stack);}
    });
    return completion.future;
  }

  bool _retireDeletedOwnerDocuments(Map<String,dynamic> collections) =>
      retireDeletedOwnerDocuments(collections, _activeIdentity['schoolSyncId']?.toString() ?? '');

  Future<void> reconcileDeletedOwnerDocuments() {
    final origin = _activeProfileId, completer = Completer<void>();
    _writeTail = _writeTail.then((_) async {
      try {
        if (_activeProfileId != origin) throw StateError('School changed before deletion reconciliation.');
        final root = await _readRoot(collections:{'_windows_local_deletions',
          '_windows_document_outbox','_local_student_documents','documents',
          'students_directory','teachers_directory','_windows_sync_conflict_history'});
        if (_activeProfileId != origin) throw StateError('School changed during deletion reconciliation.');
        final collections = _collections(root);
        if (_retireDeletedOwnerDocuments(collections)) {
          _storeCollections(root, collections); await _writeRoot(root);
          for (final name in ['_windows_document_outbox','_local_student_documents','_windows_sync_conflict_history']) {
            final signal = _signals[name]; if(signal != null && !signal.isClosed) signal.add(null);
          }
        }
        completer.complete();
      } catch(error, stack) { completer.completeError(error, stack); }
    });
    return completer.future;
  }

  Future<void> localRestoreMutation(String deletionId, {required String school,
      String? expectedDeletedRevision, String? restoredRevision}) {
    final origin = _activeProfileId;
    final completer = Completer<void>();
    _writeTail = _writeTail.then((_) async {
      try {
        if (school.isEmpty || _activeIdentity['schoolSyncId'] != school || _activeProfileId != origin) {
          throw StateError('Same school context required.');
        }
        final root = await _readRoot();
        if (_activeProfileId != origin) throw StateError('School changed during restore.');
        final collections = _collections(root);
        final evidence = (collections['_windows_local_deletions'] as Map?)?[deletionId];
        if (evidence is! Map || evidence['version'] != 1 || evidence['schoolId'] != school ||
            evidence['operationId'] != deletionId || evidence['snapshot'] is! Map ||
            evidence['collection'] is! String || evidence['documentId'] is! String) {
          throw StateError('Verified same-school deletion evidence required.');
        }
        final collection = evidence['collection'] as String, id = evidence['documentId'] as String;
        if (!_shouldTrackForFirebase(collection)) throw StateError('School record required.');
        final snapshot = Map<String,dynamic>.from(evidence['snapshot'] as Map);
        if (snapshot['schoolId'] != null && snapshot['schoolId'] != school) throw StateError('Mixed school snapshot.');
        final requests = collections.putIfAbsent('_windows_recycle_requests',()=> <String,dynamic>{}) as Map;
        final requestId = 'local-restore-'+deletionId;
        final previous = requests[requestId];
        final docs = collections.putIfAbsent(collection,()=> <String,dynamic>{}) as Map;
        final queue = collections['_windows_firebase_outbox'];
        final pending = queue is Map ? queue.values.where((r)=>r is Map && r['collection']==collection && r['documentId']==id).toList() : [];
        final documentQueue = collections['_windows_document_outbox'];
        if (documentQueue is Map && documentQueue.values.any((r)=>r is Map && r['documentId']==id)) {
          throw StateError('Pending document bytes require separate review.');
        }
        if (restoredRevision == null) {
          if (evidence['deletedAt'] is! int || DateTime.now().millisecondsSinceEpoch < (evidence['deletedAt'] as int) ||
              DateTime.now().millisecondsSinceEpoch-(evidence['deletedAt'] as int)>const Duration(hours:24).inMilliseconds) {
            throw StateError('Local restore window expired or clock requires review; evidence retained.');
          }
          if (previous != null) throw StateError('Restore request already retained; retry existing request.');
          if (docs[id] != null || pending.any((r)=>r['operation']!='delete' || r['operationId']!=deletionId ||
              {'conflict','needsAttention'}.contains(r['syncState']))) throw StateError('Newer local version or deletion conflict requires review.');
          if (evidence['cloudDeletionVerified'] != true && pending.isEmpty) throw StateError('Original deletion intent missing.');
          final deferLocal = {'documents','fee_payments','fee_ledger','teacher_salary','school_expenses'}.contains(collection);
          if (!deferLocal) docs[id] = snapshot;
          requests[requestId] = {'version':1,'localRestore':true,'schoolId':school,
            'collection':collection,'documentId':id,'deletionOperationId':deletionId,
            'operationId':base64Url.encode(List<int>.generate(24,(_)=>Random.secure().nextInt(256))).replaceAll('=',''),
            'state':evidence['cloudDeletionVerified']==true?'awaitingCloudRestore':'awaitingDeleteAck',
            'localVerified':!deferLocal,'administratorApproved':true,
            'approvedAt':DateTime.now().millisecondsSinceEpoch};
        } else {
          if (previous is! Map || previous['schoolId'] != school || evidence['cloudDeletionVerified'] != true ||
              evidence['deletedRevision'] != expectedDeletedRevision || expectedDeletedRevision == null ||
              restoredRevision.isEmpty || restoredRevision == expectedDeletedRevision || pending.isNotEmpty) {
            throw StateError('Authoritative matching deletion and restore revisions required.');
          }
          if (previous['state']=='verified') {
            if(previous['recordRevision']!=restoredRevision)throw StateError('Different restore receipt.');
            completer.complete();return;
          }
          if (docs[id] != null && _jsonStableMap(Map<String,dynamic>.from(docs[id] as Map)) != _jsonStableMap(snapshot)) {
            throw StateError('Newer local version retained.');
          }
          docs[id] = {...snapshot,'_syncRevision':restoredRevision}..remove('_syncUpdatedAt');
          previous['state']='verified';previous['localVerified']=true;
          previous['recordRevision']=restoredRevision;previous['verifiedAt']=DateTime.now().millisecondsSinceEpoch;
          final baselines=collections.putIfAbsent('_windows_sync_baselines',()=> <String,dynamic>{}) as Map;
          final key=base64Url.encode(utf8.encode('$collection\\n$id')).replaceAll('=','');
          baselines[key]={'revision':restoredRevision};
        }
        _storeCollections(root,collections);await _writeRoot(root);
        if(_activeProfileId!=origin)throw StateError('School changed after restore write.');
        final persisted=_collections(await _readRoot());
        if(_activeProfileId!=origin)throw StateError('School changed during restore readback.');
        final durableRequest=(persisted['_windows_recycle_requests'] as Map?)?[requestId];
        if(durableRequest is! Map || _jsonStableMap(Map<String,dynamic>.from(durableRequest))!=
            _jsonStableMap(Map<String,dynamic>.from(requests[requestId] as Map))) {
          throw StateError('Durable restore request readback required; original evidence retained.');
        }
        final storedDocument=(persisted[collection] as Map?)?[id];
        if(docs[id]!=null && (storedDocument is! Map ||
            _jsonStableMap(Map<String,dynamic>.from(storedDocument))!=_jsonStableMap(Map<String,dynamic>.from(docs[id] as Map)))) {
          throw StateError('Durable local restore record readback required.');
        }
        for(final name in [collection,'_windows_recycle_requests']) {
          final signal=_signals[name];if(signal!=null&&!signal.isClosed)signal.add(null);
        }
        completer.complete();
      } catch(error,stack) {completer.completeError(error,stack);}
    });
    return completer.future;
  }

  Future<Map<String,dynamic>?> bindOutboxWireData(String id,Map<String,dynamic> expected,
      Map<String,dynamic> data,String mode) {
    final origin=_activeProfileId,school=_activeIdentity['schoolSyncId'];
    final original=_encodeMap(expected),wire=_encodeMap(data),done=Completer<Map<String,dynamic>?>();
    _writeTail=_writeTail.then((_)async {
      try {
        if(origin!=_activeProfileId||expected['schoolId']!=school||
          !{'snapshot2','fieldPatch1'}.contains(mode))throw StateError('Original school wire binding required');
        final root=await _readRoot(collections:{'_windows_firebase_outbox'});
        if(origin!=_activeProfileId)throw StateError('School changed during wire binding');
        final collections=_collections(root),queue=collections['_windows_firebase_outbox'];
        final current=queue is Map?queue[id]:null;
        if(current is! Map||_jsonStableMap(Map<String,dynamic>.from(current))!=_jsonStableMap(original)) {
          done.complete(null);return;
        }
        if(current['wireData'] is Map) {done.complete(_decodeMap(Map<String,dynamic>.from(current)));return;}
        final bound={...Map<String,dynamic>.from(current),'wireMode':mode,'wireData':wire};
        queue[id]=bound;_storeCollections(root,collections);await _writeRoot(root);
        done.complete(_decodeMap(bound));
      } catch(error,stack){done.completeError(error,stack);}
    });return done.future;
  }

  Future<bool> recordOutboxFailure(String queueId, Map<String,dynamic> expected,
      {required String state, required String error, String? failureCategory,
      int? retryCount, int? retryAtMillis, Map<String,dynamic>? diagnostic}) {
    final origin = _activeProfileId;
    final school = _activeIdentity['schoolSyncId'];
    // Snapshot before queueing: callers cannot alter the comparison while waiting.
    final encodedExpected = _encodeMap(expected);
    final safeDiagnostic = {
      if(diagnostic?['failureStage']=='recordRequestAndAck') 'failureStage':'recordRequestAndAck',
      if(diagnostic?['failureCode'] is String && RegExp(r'^[A-Za-z0-9_]{1,80}$').hasMatch(diagnostic!['failureCode']))
        'failureCode':diagnostic['failureCode'],
      if(diagnostic?['failureHttpStatus'] is int && diagnostic!['failureHttpStatus']>=400 && diagnostic['failureHttpStatus']<=599)
        'failureHttpStatus':diagnostic['failureHttpStatus'],
    };
    final completer = Completer<bool>();
    _writeTail = _writeTail.then((_) async {
      try {
        if (_activeProfileId != origin ||
            (encodedExpected['schoolId'] != null &&
              encodedExpected['schoolId'] != (school ?? '')) ||
            !{'retry','conflict','needsAttention'}.contains(state) ||
            (retryCount != null && retryCount < 0) ||
            (retryAtMillis != null && retryAtMillis <= 0)) {
          throw StateError('Original same-school pending failure required.');
        }
        final root = await _readRoot(collections:{'_windows_firebase_outbox'});
        if (_activeProfileId != origin) throw StateError('School changed during failure capture.');
        final collections = _collections(root), queue = collections['_windows_firebase_outbox'];
        final current = queue is Map ? queue[queueId] : null;
        if (current is! Map || _jsonStableMap(Map<String,dynamic>.from(current)) !=
            _jsonStableMap(encodedExpected)) {
          completer.complete(false);
          return;
        }
        queue[queueId] = {...Map<String,dynamic>.from(current),
          'syncState':state,'lastError':error,
          if(diagnostic!=null) ...{
            'failureStage':safeDiagnostic['failureStage'],
            'failureCode':safeDiagnostic['failureCode'],
            'failureHttpStatus':safeDiagnostic['failureHttpStatus'],
          },
          if (failureCategory != null) 'failureCategory':failureCategory,
          if (retryCount != null) 'retryCount':retryCount,
          if (retryAtMillis != null) 'retryAtMillis':retryAtMillis};
        _storeCollections(root,collections);
        await _writeRoot(root);
        final signal = _signals['_windows_firebase_outbox'];
        if (signal != null && !signal.isClosed) signal.add(null);
        completer.complete(true);
      } catch (error,stack) { completer.completeError(error,stack); }
    });
    return completer.future;
  }

  Future<bool> recordOutboxConflict(String queueId,
      Map<String,dynamic> expected, Map<String,dynamic> remote) {
    final origin = _activeProfileId, school = _activeIdentity['schoolSyncId'];
    final completer = Completer<bool>();
    _writeTail = _writeTail.then((_) async {
      try {
        final collection = expected['collection'], id = expected['documentId'];
        final operationId = expected['operationId'], revision = remote['_syncRevision'];
        if (_activeProfileId != origin || school is! String || school.isEmpty ||
            expected['schoolId'] != school || remote['schoolId'] != school ||
            collection is! String || collection.isEmpty || collection.startsWith('_') ||
            id is! String || id.isEmpty || operationId is! String || operationId.isEmpty ||
            revision is! String || revision.isEmpty) {
          throw StateError('Original same-school operation and verified revision required.');
        }
        final parentId=expected['data'] is Map?expected['data']['studentId']:null;
        final firstCreate=firstCommittedCreateWins(expected,remote);
        final freshStudent = expected['collection']=='students_directory' &&
            (firstCreate || automaticDuplicateReadback(expected, remote) && identicalFreshStudent(expected, remote));
        final childCollections = <String>{...studentOwnedCollections,
          '_local_student_documents', '_windows_document_outbox'};
        final root = await _readRoot(collections:{collection,'_windows_firebase_outbox',
          '_windows_sync_conflicts','_windows_sync_conflict_history','_windows_sync_baselines','_windows_recycle_requests','_windows_local_deletions',if(parentId is String)'students_directory',
          if(freshStudent)...childCollections},recordScope:{collection:[id],if(parentId is String&&collection!='students_directory')'students_directory':[parentId]});
        if (_activeProfileId != origin) throw StateError('School changed during conflict capture.');
        final collections = _collections(root), queue = collections['_windows_firebase_outbox'];
        final current = queue is Map ? queue[queueId] : null;
        final parent=(collections['students_directory'] as Map?)?[parentId];
        if(current is Map&&reusesDeletedStudentRecord(current,remote,parent is Map?parent:null)){completer.complete(false);return;}
        if (current is! Map ||
            _jsonStableMap(Map<String,dynamic>.from(current)) != _jsonStableMap(_encodeMap(expected))) {
          completer.complete(false);
          return;
        }
        if(replacesDeletedStudent(current,remote)||deletesSameStudentGeneration(current,remote)) {
          if(current['syncState']=='conflict'||current['syncState']=='needsAttention') {
            queue[queueId]={...Map<String,dynamic>.from(current),'syncState':'pending','retryCount':0}
              ..remove('lastError')..remove('failureCategory');
            _storeCollections(root,collections);await _writeRoot(root);
          }
          completer.complete(false);return;
        }
        // Recover legacy delete identity only from its original atomic snapshot.
        final evidence=(collections['_windows_local_deletions'] as Map?)?[operationId];
        final recoveredIdentity=current['collection']=='teachers_directory' && current['operation']=='delete' &&
          evidence is Map && evidence['operationId']==operationId && evidence['schoolId']==school &&
          evidence['collection']==collection && evidence['documentId']==id && evidence['snapshot'] is Map &&
          evidence['snapshot']['teacherId'] is String
            ? <String,dynamic>{'teacherId':evidence['snapshot']['teacherId']} : current['deletedRecordIdentity'];
        if(sameDeletedDirectoryOwner({...current,'deletedRecordIdentity':recoveredIdentity},remote)) {
          final history=collections.putIfAbsent('_windows_sync_conflict_history',()=> <String,dynamic>{}) as Map;
          history.putIfAbsent(operationId,()=>_encodeMap({...current,'verifiedCloud':remote,
            'resolution':'explicit deletion follows the same verified person'}));
          queue[queueId]={...Map<String,dynamic>.from(current),
            'baseCloudRevision':revision,'syncState':'pending','retryCount':0,
            'deletedRecordIdentity':recoveredIdentity}
            ..remove('lastError')..remove('failureCategory')..remove('wireData')..remove('wireMode');
          _storeCollections(root,collections);await _writeRoot(root);
          completer.complete(false);return;
        }
        // A different PC may already have published this exact intended value.
        // Reconciliation is a verified readback, not an ACK for our operation.
        // Commit cloud cache, baseline, audit and queue retirement in one writer.
        // Same-operation lost-ACK retries still use the original server receipt.
        final linkedStudent = freshStudent && (
          childCollections.any((name) {
            final rows = collections[name];
            return rows is Map && rows.entries.any((entry) => entry.value is Map &&
              recordBelongsToStudent(name, entry.key.toString(), entry.value as Map,
                id, ((expected['data'] as Map)['mobileStableId'] as String? ?? '')));
          }) ||
          (queue.values.any((row) => row is Map &&
            !(row['collection'] == 'students_directory' && row['documentId'] == id) &&
            row['data'] is Map && recordBelongsToStudent(
              row['collection'].toString(), row['documentId'].toString(), row['data'] as Map,
              id, ((expected['data'] as Map)['mobileStableId'] as String? ?? ''))))
        );
        if ((automaticDuplicateReadback(expected, remote) || firstCreate || recordFieldIntentSatisfied(expected,remote)) &&
            remote['_syncOperationId'] != operationId && !linkedStudent) {
          final local = (collections[collection] as Map?)?[id];
          if (local is Map &&
              sameSavedRecord(collection, _decodeMap(Map<String,dynamic>.from(local)),
                  expected['data'] as Map)) {
            final history = collections.putIfAbsent('_windows_sync_conflict_history',
                () => <String,dynamic>{}) as Map;
            history[operationId] = _encodeMap({...expected,
              'verifiedCloud': remote,
              'resolution': automaticDuplicateReadback(expected,remote)?'automatic identical authenticated readback':
                firstCreate?'first committed create retained':
                recordFieldIntentSatisfied(expected,remote)?'changed fields already verified in cloud':
                'automatic identical authenticated readback',
              'resolvedAt': DateTime.now().millisecondsSinceEpoch});
            (collections[collection] as Map)[id] = _encodeMap(remote);
            queue.remove(queueId);
            final baselines = collections.putIfAbsent('_windows_sync_baselines',
                () => <String,dynamic>{}) as Map;
            baselines[queueId] = {'revision': revision, 'deleted': false,'record':_encodeMap(remote)};
            _storeCollections(root, collections);
            await _writeRoot(root);
            for (final name in [collection, '_windows_firebase_outbox']) {
              final signal = _signals[name];
              if (signal != null && !signal.isClosed) signal.add(null);
            }
            completer.complete(false);
            return;
          }
        }
        // A verified inventory can contain our committed operation after its
        // response was lost; another device may also have completed a delete.
        // Retry the ORIGINAL request so the server verifies
        // its request hash and returns the real ACK; inventory alone is no ACK.
        final remoteGeneration = remote['_syncRecreatesDeletedRevision'];
        final localGeneration = current['operation'] == 'delete' ? current['recordGeneration'] :
            current['data'] is Map ? current['data']['_syncRecreatesDeletedRevision'] : null;
        final replacedGeneration = remote['_syncDeleted'] != true && remoteGeneration is String &&
            remoteGeneration.isNotEmpty && localGeneration != remoteGeneration && current['priorDeletion'] == null;
        if ((remote['_syncDeleted'] == true && current['operation'] != 'delete' || replacedGeneration) &&
            collection != 'students_directory') {
          final restores = collections['_windows_recycle_requests'];
          final localRow = (collections[collection] as Map?)?[id];
          final localTime = localRow is Map ? localRow['_syncUpdatedAt'] : null;
          if (restores is Map && restores.values.any((r) => r is Map &&
              r['localRestore'] == true && r['schoolId'] == school &&
              r['collection'] == collection && r['documentId'] == id &&
              (r['state'] != 'verified' || remote['_syncUpdatedAt'] is! int ||
               localTime is! int || remote['_syncUpdatedAt'] <= localTime ||
               r['recordRevision'] == revision))) {
            completer.complete(false);return;
          }

          final data = current['data'];
          if (data is Map && (data['_syncRecreatesDeletedRevision'] == revision ||
              data['_syncRecreatesDeletedOperationId'] != null && data['_syncRecreatesDeletedOperationId'] == remote['_syncOperationId'] ||
              current['priorDeletion'] is Map && data['_syncRecreatesDeletedOperationId'] != null &&
              data['_syncRecreatesDeletedOperationId'] == current['priorDeletion']['operationId'])) {
            // An older Script may have rejected this exact fresh-entry intent
            // before its upgrade. Re-admit the unchanged request for real ACK.
            if(current['syncState']=='conflict') {
              final history = collections.putIfAbsent('_windows_sync_conflict_history',
                  () => <String,dynamic>{}) as Map;
              history.putIfAbsent(operationId, () => Map<String,dynamic>.from(current));
              queue[queueId] = {...Map<String,dynamic>.from(current),'syncState':'pending','retryCount':0}
                ..remove('lastError')..remove('failureCategory')..remove('retryAtMillis');
              _storeCollections(root,collections);await _writeRoot(root);
              final signal = _signals['_windows_firebase_outbox'];
              if(signal != null && !signal.isClosed)signal.add(null);
            }
            completer.complete(false);return;
          }
          // Authenticated deletion wins over an offline edit. Retain the entire
          // superseded operation and local values as audit, never upload it again.
          final history = collections.putIfAbsent('_windows_sync_conflict_history',
              () => <String,dynamic>{}) as Map;
          history.putIfAbsent(operationId, () => {...Map<String,dynamic>.from(current),
            'retiredByDeletionRevision':replacedGeneration ? remoteGeneration : revision});
          (collections[collection] as Map?)?.remove(id);
          queue.remove(queueId);
          final baselines = collections.putIfAbsent('_windows_sync_baselines',
              () => <String,dynamic>{}) as Map;
          baselines[queueId] = {'revision':revision,'deleted':remote['_syncDeleted']==true,
            if(remoteGeneration is String) 'recreatedFrom':remoteGeneration};
          _storeCollections(root,collections);await _writeRoot(root);
          for (final name in [collection,'_windows_firebase_outbox']) {
            final signal = _signals[name];
            if (signal != null && !signal.isClosed) signal.add(null);
          }
          completer.complete(false);return;
        }
        // A committed operation can exhaust transport retries after repeated
        // lost ACKs. Its authenticated operation identity admits only a replay
        // of the original request; the server still validates its request hash.
        // Validation/authentication/unknown attention states remain for review.
        final committedTransportRetry = remote['_syncOperationId'] == operationId &&
            (remote['_syncDeleted'] == true) == (current['operation'] == 'delete') &&
            current['syncState'] == 'needsAttention' &&
            {'timeout','server','networkPath'}.contains(current['failureCategory']);
        if (revision == (current['baseCloudRevision'] ?? '') ||
            remote['_syncDeleted'] != true && current['syncState']=='needsAttention' &&
              !committedTransportRetry) {
          completer.complete(false);return;
        }
        final completedDeletion = current['operation'] == 'delete' && remote['_syncDeleted'] == true;
        if (completedDeletion || (remote['_syncOperationId'] == operationId &&
            (remote['_syncDeleted'] == true) == (current['operation'] == 'delete'))) {
          if ({'conflict','needsAttention'}.contains(current['syncState'])) {
            final history = collections.putIfAbsent('_windows_sync_conflict_history',
                () => <String,dynamic>{}) as Map;
            history.putIfAbsent(operationId, () => Map<String,dynamic>.from(current));
            queue[queueId] = {...Map<String,dynamic>.from(current),
              'syncState':'pending','retryCount':0}..remove('lastError')..remove('failureCategory')..remove('retryAtMillis');
            _storeCollections(root,collections);
            await _writeRoot(root);
            final signal = _signals['_windows_firebase_outbox'];
            if (signal != null && !signal.isClosed) signal.add(null);
          }
          completer.complete(false);
          return;
        }
        final localRecords = collections[collection];
        final local = localRecords is Map ? localRecords[id] : null;
        final history = collections.putIfAbsent('_windows_sync_conflicts',()=> <String,dynamic>{}) as Map;
        final conflictId = '$operationId-${sha256.convert(utf8.encode(revision))}';
        history[conflictId] = _encodeMap({'schoolId':school,'collection':collection,
          'documentId':id,'local':local,'remote':remote,
          'detectedAt':DateTime.now().millisecondsSinceEpoch});
        queue[queueId] = {...Map<String,dynamic>.from(current),
          'syncState':'conflict','lastError':'Record revision conflict',
          'failureCategory':'conflict',
          // Only authenticated reconciliation supplies this CAS base. Saving
          // unchanged data never consumes it; changed Save retains both copies.
          if ({'students_directory','teachers_directory'}.contains(collection) &&
              remote['id'] == id &&
              (remote['documentId'] == null || remote['documentId'] == id) &&
              remote['_syncDeleted'] != true &&
              remote['replacesStudentGeneration'] == null &&
              !remote.keys.any((key)=>key.toString().startsWith('_syncRecreates')))
            'directoryConflictBase': {
              'schoolId':school,'documentId':id,'revision':revision,
              'identityField':collection=='students_directory'?'mobileStableId':'teacherId',
              'identity':remote[collection=='students_directory'?'mobileStableId':'teacherId'],
            }
          else 'directoryConflictBase':null};
        _storeCollections(root,collections);
        await _writeRoot(root);
        for (final name in ['_windows_firebase_outbox','_windows_sync_conflicts']) {
          final signal = _signals[name];
          if (signal != null && !signal.isClosed) signal.add(null);
        }
        completer.complete(true);
      } catch (error,stack) { completer.completeError(error,stack); }
    });
    return completer.future;
  }

  Future<Map<String,dynamic>?> migrateOutboxIdentity(String queueId,
      Map<String,dynamic> expected, String schoolId) {
    final origin = _activeProfileId;
    final completer = Completer<Map<String,dynamic>?>();
    _writeTail = _writeTail.then((_) async {
      try {
        if (_activeProfileId != origin || schoolId.isEmpty ||
            _activeIdentity['schoolSyncId'] != schoolId ||
            (expected['schoolId'] != null && expected['schoolId'] != schoolId)) {
          throw StateError('Original same-school pending binding required.');
        }
        final root = await _readRoot(collections:{'_windows_firebase_outbox'});
        if (_activeProfileId != origin) throw StateError('School changed during pending migration.');
        final collections = _collections(root), queue = collections['_windows_firebase_outbox'];
        final current = queue is Map ? queue[queueId] : null;
        if (current is! Map || _jsonStableMap(Map<String,dynamic>.from(current)) !=
            _jsonStableMap(_encodeMap(expected))) {
          completer.complete(null);
          return;
        }
        if (current['schoolId'] != null && current['schoolId'] != schoolId) {
          throw StateError('Pending operation belongs to another school.');
        }
        final migrated = Map<String,dynamic>.from(current);
        final operationId = migrated['operationId'];
        if (operationId != null && (operationId is! String || operationId.isEmpty)) {
          throw StateError('Original pending operation identity requires review.');
        }
        migrated['operationId'] ??= base64Url.encode(
          List<int>.generate(24,(_) => Random.secure().nextInt(256))).replaceAll('=','');
        migrated['schoolId'] ??= schoolId;
        migrated['baseCloudRevision'] ??= '';
        queue[queueId] = migrated;
        _storeCollections(root,collections);
        await _writeRoot(root);
        final signal = _signals['_windows_firebase_outbox'];
        if (signal != null && !signal.isClosed) signal.add(null);
        completer.complete(_decodeMap(migrated));
      } catch (error,stack) { completer.completeError(error,stack); }
    });
    return completer.future;
  }

  Future<void> enqueueReviewedConflict(String queueId, Map<String,dynamic> expected,
      Map<String,dynamic> remote, String choice, String reason) {
    final origin=_activeProfileId, school=_activeIdentity['schoolSyncId'];
    final completer=Completer<void>();
    _writeTail=_writeTail.then((_) async {
      try {
        if (_activeProfileId!=origin || school is! String || school.isEmpty ||
            expected['schoolId']!=school || remote['schoolId']!=school ||
            remote['id']!=expected['documentId'] || remote['_syncDeleted']==true || expected['data'] is! Map ||
            !{'local','cloud'}.contains(choice) || reason.trim().isEmpty || reason.length>1000 ||
            remote['_syncRevision'] is! String || (remote['_syncRevision'] as String).isEmpty ||
            expected['collection']=='documents' || expected['operation']=='delete') {
          throw StateError('Verified same-school record and explicit review required. Documents/deletions require separate original-file review.');
        }
        final root=await _readRoot();
        if(_activeProfileId!=origin)throw StateError('School changed during conflict review.');
        final collections=_collections(root), queue=collections['_windows_firebase_outbox'];
        final current=queue is Map ? queue[queueId] : null;
        if(current is! Map || current['syncState']!='conflict' ||
            jsonEncode(current)!=jsonEncode(_encodeMap(expected))) {
          throw StateError('Pending version changed; reopen conflict review.');
        }
        final collection=expected['collection'] as String, id=expected['documentId'] as String;
        final history=collections.putIfAbsent('_windows_sync_conflict_history',()=> <String,dynamic>{}) as Map;
        final oldOperation=expected['operationId'];
        if(oldOperation is! String || oldOperation.isEmpty)throw StateError('Original operation identity required.');
        history.putIfAbsent(oldOperation,()=>_encodeMap(expected));
        final selected=Map<String,dynamic>.from(choice=='local' ? expected['data'] as Map : remote);
        selected.removeWhere((key,value)=>key.startsWith('_sync'));
        selected['schoolId']=school;
        final newOperation=base64Url.encode(List<int>.generate(24,(_)=>Random.secure().nextInt(256))).replaceAll('=','');
        final audit=collections.putIfAbsent('_windows_sync_resolution_history',()=> <String,dynamic>{}) as Map;
        audit[newOperation]=_encodeMap({'schoolId':school,'originalOperationId':oldOperation,
          'queueId':queueId,'local':expected,'remote':remote,'choice':choice,'reason':reason.trim(),
          'reviewedAt':DateTime.now().millisecondsSinceEpoch,'status':'awaitingCloudAck'});
        queue[queueId]=_encodeMap({...expected,'operationId':newOperation,'baseCloudRevision':remote['_syncRevision'],
          'data':selected,'syncState':'pending','retryCount':0,'lastError':null,
          'reviewedFromOperationId':oldOperation,'queuedAt':DateTime.now().millisecondsSinceEpoch});
        final docs=collections.putIfAbsent(collection,()=> <String,dynamic>{}) as Map;
        docs[id]=_encodeMap(selected);
        _storeCollections(root,collections);await _writeRoot(root);
        for(final name in [collection,'_windows_firebase_outbox']){final signal=_signals[name];if(signal!=null&&!signal.isClosed)signal.add(null);}
        completer.complete();
      }catch(error,stack){completer.completeError(error,stack);}
    });
    return completer.future;
  }

  Future<void> commitReviewedDocument(String id,Map<String,dynamic> expected,
      Map<String,dynamic> remote,Map<String,dynamic> selected,String choice,String reason,String localHash) {
    final origin=_activeProfileId,school=_activeIdentity['schoolSyncId'];
    final completer=Completer<void>();
    _writeTail=_writeTail.then((_)async{
      try{
        if(_activeProfileId!=origin || school is! String || school.isEmpty || _activeIdentity['blocked']==true ||
            expected['schoolId']!=school || remote['schoolId']!=school || selected['schoolId']!=school ||
            remote['id']!=id || selected['documentId']!=id || expected['syncState']!='conflict' || expected['deleted']==true ||
            remote['_syncDeleted']==true || !{'local','cloud'}.contains(choice) || reason.trim().isEmpty || reason.length>1000 ||
            remote['_syncRevision'] is! String || remote['_syncRevision'].isEmpty || remote['documentRevision'] is! String || remote['documentRevision'].isEmpty ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(localHash))throw StateError('Explicit verified school document review required.');
        final historyKey='document-$id-${expected['documentRevision']}';
        final root=await _readRoot(collections:{'_windows_document_outbox','_local_student_documents','_windows_sync_conflict_history','_windows_sync_receipts'},
          recordScope:{'_windows_document_outbox':[id],'_local_student_documents':[id],'_windows_sync_conflict_history':[historyKey],
            '_windows_sync_receipts':['cloud-choice-$historyKey']});
        if(_activeProfileId!=origin)throw StateError('School changed during document review commit.');
        final collections=_collections(root),queue=collections['_windows_document_outbox'];
        final current=queue is Map?queue[id]:null,local=(collections['_local_student_documents'] as Map?)?[id];
        if(current is! Map || local is! Map || _jsonStableMap(Map<String,dynamic>.from(current))!=_jsonStableMap(_encodeMap(expected)) ||
            local['documentRevision']!=expected['documentRevision'] || local['localPath']!=expected['localPath']) {
          throw StateError('Pending generation changed during review commit.');
        }
        for(final key in ['studentId','documentKind','ownerRole','personId']){
          if(expected[key]!=remote[key] || selected[key]!=remote[key])throw StateError('Document review ownership mismatch.');
        }
        if(choice=='local' && (selected['syncState']!='Pending' || selected['documentRevision']==expected['documentRevision'] ||
            selected['baseCloudRevision']!=remote['documentRevision'] || selected['reviewedRecordRevision']!=remote['_syncRevision'] ||
            selected['localPath']!=expected['localPath']))throw StateError('Reviewed local CAS generation required.');
        if(choice=='cloud' && (selected['syncState']!='Synced' || selected['documentRevision']!=remote['documentRevision'] ||
            selected['contentHash']!=remote['contentHash'] || selected['localPath']==expected['localPath']))throw StateError('Verified retained cloud copy required.');
        final key='document-$id-${expected['documentRevision']}';
        final history=collections.putIfAbsent('_windows_sync_conflict_history',()=> <String,dynamic>{}) as Map;
        history.putIfAbsent(key,()=>_encodeMap({...expected,'verifiedCloud':remote,'resolution':'owner selected $choice',
          'reason':reason.trim(),'reviewedAt':DateTime.now().millisecondsSinceEpoch,'localContentHash':localHash}));
        if(choice=='local')queue![id]=_encodeMap(selected);
        else{
          final receipts=collections.putIfAbsent('_windows_sync_receipts',()=> <String,dynamic>{}) as Map;
          receipts['cloud-choice-$key']=_encodeMap({'schoolId':school,'documentId':id,'collection':'documents',
            'operationId':remote['documentRevision'],'recordRevision':remote['_syncRevision'],'contentHash':remote['contentHash'],
            'verification':'owner selected authenticated cloud bytes','rejectedLocalRevision':expected['documentRevision']});
          queue!.remove(id); // This exact reviewed generation only; original remains in history/files.
        }
        (collections['_local_student_documents'] as Map)[id]=_encodeMap(selected);
        _storeCollections(root,collections);await _writeRoot(root);
        for(final name in ['_windows_document_outbox','_local_student_documents','_windows_sync_conflict_history','_windows_sync_receipts']){
          final signal=_signals[name];if(signal!=null&&!signal.isClosed)signal.add(null);
        }
        completer.complete();
      }catch(error,stack){completer.completeError(error,stack);}
    });
    return completer.future;
  }

  bool _shouldTrackForFirebase(
    String collection,
  ) {
    if (collection.startsWith('_windows_')) {
      return false;
    }

    if (collection.startsWith('_local_')) {
      return false;
    }

    return true;
  }

  void _recordFirebaseOutbox(
    Map<String, dynamic> collections,
    _WriteOperation operation,
    Map<String, dynamic> finalDocs, {
    required bool userDirectorySave,
    Map<String,dynamic>? beforeSave,
  }) {
    if (operation.type != _WriteType.delete && operation.collection == 'school_config' &&
        operation.documentId == 'school_profile_cache') {
      // Keep legacy branding locally, but never turn an asset-only cache into a mutation.
      if (blankSchoolProfile(finalDocs[operation.documentId] as Map)) return;
    }
    final rawQueue = collections.putIfAbsent(
      '_windows_firebase_outbox',
      () => <String, dynamic>{},
    );

    final queue = Map<String, dynamic>.from(
      rawQueue as Map,
    );

    collections['_windows_firebase_outbox'] =
        queue;

    final key = base64Url
        .encode(
          utf8.encode(
            '${operation.collection}\\n'
            '${operation.documentId}',
          ),
        )
        .replaceAll('=', '');

    final isDelete =
        operation.type == _WriteType.delete;

    final previous = queue[key];
    if(operation.collection=='students_directory' && !isDelete && finalDocs[operation.documentId] is Map) {
      final data=finalDocs[operation.documentId] as Map;
      final deletions=collections['_windows_local_deletions'];
      final matches=deletions is Map?deletions.values.where((d)=>d is Map&&d['schoolId']==_activeIdentity['schoolSyncId']&&d['collection']=='students_directory'&&d['documentId']==operation.documentId&&d['snapshot'] is Map).toList():[];
      matches.sort((a,b)=>(b['deletedAt'] as num).compareTo(a['deletedAt'] as num));
      if(matches.isNotEmpty&&data['mobileStableId']!=null) {
        final old=(matches.first['snapshot'] as Map)['mobileStableId']??operation.documentId;
        if(old!=data['mobileStableId']) data['replacesStudentGeneration']=old;
      }
    }
    if(previous is Map && {'conflict','needsAttention'}.contains(previous['syncState'])) {
      final history=collections.putIfAbsent('_windows_sync_conflict_history',()=> <String,dynamic>{}) as Map;
      final operationId=previous['operationId'];
      if(operationId is String)history.putIfAbsent(operationId,()=>Map<String,dynamic>.from(previous));
    }

    final priorDeletion = previous is Map
        ? previous['priorDeletion'] ?? (previous['operation'] == 'delete' ? Map<String,dynamic>.from(previous) : null)
        : null;
    final baseline = collections['_windows_sync_baselines'];
    final baselineEntry = baseline is Map ? baseline[key] : null;
    if (!isDelete && baselineEntry is Map && baselineEntry['recreatedFrom'] is String &&
        finalDocs[operation.documentId] is Map) {
      (finalDocs[operation.documentId] as Map)['_syncRecreatesDeletedRevision'] = baselineEntry['recreatedFrom'];
    }
    if (!isDelete && previous is Map && previous['data'] is Map &&
        finalDocs[operation.documentId] is Map) {
      for (final field in ['_syncRecreatesDeletedRevision','_syncRecreatesDeletedOperationId']) {
        if ((previous['data'] as Map)[field] is String) {
          (finalDocs[operation.documentId] as Map)[field] = previous['data'][field];
        }
      }
    }
    if (!isDelete && previous is Map && previous['operation'] == 'delete' &&
        finalDocs[operation.documentId] is Map) {
      (finalDocs[operation.documentId] as Map)['_syncRecreatesDeletedOperationId'] = priorDeletion is Map ? priorDeletion['operationId'] : previous['operationId'];
    }
    final deletionHistory = collections['_windows_local_deletions'];
    final verifiedLegacyDeletion = baselineEntry is Map && deletionHistory is Map &&
        deletionHistory.values.any((d) => d is Map && d['schoolId'] == _activeIdentity['schoolSyncId'] &&
          d['collection'] == operation.collection && d['documentId'] == operation.documentId &&
          d['cloudDeletionVerified'] == true && d['deletedRevision'] is String &&
          d['deletedRevision'] == baselineEntry['revision']);
    if (!isDelete && previous is! Map && baselineEntry is Map &&
        (baselineEntry['deleted'] == true || verifiedLegacyDeletion) && baselineEntry['revision'] is String &&
        finalDocs[operation.documentId] is Map) {
      // Only a save made AFTER observing this deletion may recreate this slot.
      (finalDocs[operation.documentId] as Map)['_syncRecreatesDeletedRevision'] = baselineEntry['revision'];
    }
    final explicitDirectorySave = userDirectorySave && previous is Map && !isDelete &&
        finalDocs[operation.documentId] is Map &&
        previous['schoolId'] == _activeIdentity['schoolSyncId'] &&
        canSaveDirectoryConflict(previous, finalDocs[operation.documentId] as Map);
    final correctedValidation = userDirectorySave && previous is Map && !isDelete &&
        previous['syncState'] == 'needsAttention' &&
        previous['failureCategory'] == 'validation';
    final blocked = previous is Map &&
        {'conflict','needsAttention'}.contains(previous['syncState']) &&
        !explicitDirectorySave && !correctedValidation && !isDelete;
    final baseRecord=baselineEntry is Map && baselineEntry['record'] is Map
      ? _decodeMap(Map<String,dynamic>.from(baselineEntry['record'])) : null;
    final changes=!isDelete && baseRecord!=null && finalDocs[operation.documentId] is Map
      ? buildRecordFieldPatch(operation.collection,baseRecord,
          _decodeMap(Map<String,dynamic>.from(finalDocs[operation.documentId] as Map))) : null;
    queue[key] = <String, dynamic>{
      'operationId': base64Url.encode(List<int>.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', ''),
      'schoolId': _activeIdentity['schoolSyncId'] ?? '',
      'baseCloudRevision': explicitDirectorySave ? previous['directoryConflictBase']['revision'] :
          previous is Map ? previous['baseCloudRevision'] ?? '' :
          baselineEntry is Map ? baselineEntry['revision'] ?? '' : '',
      'syncState':blocked ? previous['syncState'] : 'pending', 'retryCount':0,
      if(changes!=null)'fieldPatch':_encodeMap(changes),
      if(!isDelete && (previous is Map && previous['createIntent']==true ||
          previous is! Map && beforeSave==null && (baselineEntry is! Map || (baselineEntry['revision']??'')=='')))
        'createIntent':true,
      if (blocked) ...{
        for (final field in ['lastError','failureCategory','failureCode','failureStage','failureHttpStatus','directoryConflictBase'])
          if (previous[field] != null) field: previous[field],
      },
      if (explicitDirectorySave) 'savedOverConflictOperationId':previous['operationId'],
      if(priorDeletion is Map) 'priorDeletion':Map<String,dynamic>.from(priorDeletion),
      if(isDelete && (previous is Map && previous['data'] is Map && previous['data']['_syncRecreatesDeletedRevision'] is String || baselineEntry is Map && baselineEntry['recreatedFrom'] is String))
        'recordGeneration':previous is Map && previous['data'] is Map && previous['data']['_syncRecreatesDeletedRevision'] is String ? previous['data']['_syncRecreatesDeletedRevision'] : baselineEntry['recreatedFrom'],
      'collection': operation.collection,
      'documentId': operation.documentId,
      'operation': isDelete ? 'delete' : 'set',
      if (!isDelete &&
          finalDocs[operation.documentId] is Map)
        'data': Map<String, dynamic>.from(
          finalDocs[operation.documentId] as Map,
        ),
      'queuedAt': <String, dynamic>{
        '__vidya_type': 'timestamp',
        'ms': DateTime.now()
            .toUtc()
            .millisecondsSinceEpoch,
      },
    };
  }

  void _applyFields(
    Map<String, dynamic> target,
    Map<String, dynamic> incoming,
  ) {
    for (final entry in incoming.entries) {
      if (_isDeleteMarker(entry.value)) {
        target.remove(entry.key);
      } else {
        target[entry.key] = entry.value;
      }
    }
  }

  Future<Map<String, dynamic>> _readRoot({Set<String>? collections,Map<String,List<String>>? recordScope}) async {
    if (!await FirebaseFirestore.instance.localPersistenceEnabled()) {
      return _cloneRoot(_memoryRoot);
    }

    final sqlite = await _sqliteStore();
    if (sqlite != null) return sqlite.readRoot(_activeProfileId, collections:collections,recordScope:recordScope);
    final file = await _file();
    try {
      if (!await file.exists() && await File('${file.path}.pending').exists()) {
        final recovered=jsonDecode(await File('${file.path}.pending').readAsString());
        if(recovered is! Map || (recovered['profiles'] is! Map && recovered['collections'] is! Map))throw const FormatException('Pending database is invalid.');
        final root=Map<String,dynamic>.from(recovered);_upgradeRootInMemory(root);return root;
      }
      if (!await file.exists()) {
        if(await File('${file.path}.bak').exists())throw const FormatException('Recover previous database generation.');
        WindowsServiceStatus.instance.healthy(
          WindowsServiceType.localStorage,
          'Local database ready: ${file.path}',
        );
        return <String, dynamic>{
          'version': 2,
          'profiles': <String, dynamic>{},
        };
      }

      final decoded = jsonDecode(
        await file.readAsString(),
      );

      if (decoded is Map && (decoded['profiles'] is Map || decoded['collections'] is Map)) {
        final root = Map<String, dynamic>.from(decoded);
        _upgradeRootInMemory(root);
        WindowsServiceStatus.instance.healthy(
          WindowsServiceType.localStorage,
          'Local database read OK: ${file.path}',
        );
        return root;
      }
      throw const FormatException('Local database root invalid hai.');
    } catch (primaryError) {
      WindowsServiceStatus.instance.unhealthy(
        WindowsServiceType.localStorage,
        'Local database read problem: $primaryError',
      );

      final pending=File('${file.path}.pending');
      try {if(await pending.exists()){
        final decoded=jsonDecode(await pending.readAsString());
        if(decoded is Map && (decoded['profiles'] is Map || decoded['collections'] is Map)){final root=Map<String,dynamic>.from(decoded);_upgradeRootInMemory(root);return root;}
      }}catch(_){}
      final backup = File('${file.path}.bak');
      try {
        if (await backup.exists()) {
          final decoded = jsonDecode(
            await backup.readAsString(),
          );
          if (decoded is Map && (decoded['profiles'] is Map || decoded['collections'] is Map)) {
            final root = Map<String, dynamic>.from(decoded);
            _upgradeRootInMemory(root);
            return root;
          }
        }
      } catch (_) {}

      throw StateError('Local database recovery required. Original and backup retained; writes blocked.');
    }
  }

  Map<String, dynamic> _cloneRoot(Map<String, dynamic> source) {
    try {
      final decoded = jsonDecode(jsonEncode(source));
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return <String, dynamic>{
      'version': 2,
      'profiles': <String, dynamic>{},
    };
  }

  /// Clears only the non-persistent session cache used while Local Storage is
  /// OFF. Disk data is never deleted by this method.
  Future<void> enableDurableProfile() {
    final origin = _activeProfileId;
    final next = _writeTail.then((_) async {
      if (_activeProfileId != origin) throw StateError('School changed.');
      if (await FirebaseFirestore.instance.localPersistenceEnabled()) return;
      final memory = _cloneRoot(_memoryRoot);
      await WindowsRuntimeFlags.setDurableSchoolProfile(origin, true);
      try {
        final disk = await _readRoot();
        final profiles = Map<String, dynamic>.from(disk['profiles'] as Map? ?? {});
        final current = (memory['profiles'] as Map?)?[origin] as Map?;
        if (current != null) {
          final saved = Map<String, dynamic>.from(profiles[origin] as Map? ?? {});
          final collections = Map<String, dynamic>.from(saved['collections'] as Map? ?? {});
          for (final entry in (current['collections'] as Map? ?? {}).entries) {
            final records = Map<String, dynamic>.from(collections[entry.key] as Map? ?? {});
            for (final record in (entry.value as Map).entries) {
              if (records.containsKey(record.key) &&
                  _jsonStableMap({'data': records[record.key]}) != _jsonStableMap({'data': record.value})) {
                throw StateError('Existing durable school data conflicts with this session; both retained.');
              }
              records[record.key] = record.value;
            }
            collections[entry.key.toString()] = records;
          }
          profiles[origin] = {...saved, ...Map<String, dynamic>.from(current), 'collections': collections};
        }
        disk['profiles'] = profiles;
        await _writeRoot(disk);
      } catch (_) {
        await WindowsRuntimeFlags.setDurableSchoolProfile(origin, false);
        rethrow;
      }
    });
    _writeTail = next.catchError((_) {});
    return next;
  }

  Future<void> resetVolatileSession() async {
    await _writeTail;
    await _sqlite?.close();_sqlite=null;_openingSqlite=null;_sqlitePath=null;
    _memoryRoot = <String, dynamic>{
      'version': 2,
      'profiles': <String, dynamic>{},
    };
    for (final controller in _signals.values) {
      if (!controller.isClosed) controller.add(null);
    }
  }

  void _upgradeRootInMemory(
    Map<String, dynamic> root,
  ) {
    final profilesRaw = root['profiles'];
    final profiles = profilesRaw is Map
        ? Map<String, dynamic>.from(profilesRaw)
        : <String, dynamic>{};

    // v1 used one global `collections` map. Never attach that old data to a
    // newly selected school because it may belong to a demo/another school.
    // Preserve it under a quarantined legacy profile instead of deleting it.
    final legacyCollections = root['collections'];
    if (legacyCollections is Map && legacyCollections.isNotEmpty) {
      profiles.putIfAbsent(
        'legacy_v1_quarantine',
        () => <String, dynamic>{
          'identity': <String, dynamic>{
            'mode': 'legacy-quarantine',
            'note': 'Pre-isolation data preserved; never auto-activated.',
          },
          'collections': Map<String, dynamic>.from(legacyCollections),
        },
      );
    }

    root.remove('collections');
    root['version'] = 2;
    root['profiles'] = profiles;
  }

  Map<String, dynamic> _profiles(
    Map<String, dynamic> root,
  ) {
    final value = root['profiles'];
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return <String, dynamic>{};
  }

  Map<String, dynamic> _collections(
    Map<String, dynamic> root,
  ) {
    final profiles = _profiles(root);
    final rawProfile = profiles[_activeProfileId];
    if (rawProfile is! Map) {
      return <String, dynamic>{};
    }

    final profile = Map<String, dynamic>.from(rawProfile);
    final value = profile['collections'];
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return <String, dynamic>{};
  }

  void _storeCollections(
    Map<String, dynamic> root,
    Map<String, dynamic> collections,
  ) {
    final profiles = _profiles(root);
    final rawProfile = profiles[_activeProfileId];
    final profile = rawProfile is Map
        ? Map<String, dynamic>.from(rawProfile)
        : <String, dynamic>{};

    profile['collections'] = collections;
    profile['identity'] = _encodeMap(_activeIdentity);
    profile['lastWriteAt'] = DateTime.now().toUtc().millisecondsSinceEpoch;
    profiles[_activeProfileId] = profile;
    root['profiles'] = profiles;
    root['version'] = 2;
    root['activeProfileHint'] = _activeProfileId;
  }

  String _safeProfileId(String input) {
    final value = input.trim();
    if (value.isEmpty) return 'unbound';
    return value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  }

  String _jsonStableMap(Map<String, dynamic> value) {
    dynamic clean(dynamic input) {
      if (input is Map) {
        final keys = input.keys.map((e) => e.toString()).toList()..sort();
        return <String, dynamic>{
          for (final key in keys) key: clean(input[key]),
        };
      }
      if (input is Iterable) return input.map(clean).toList();
      return input;
    }

    return jsonEncode(clean(value));
  }

  Future<void> _writeRoot(
    Map<String, dynamic> root,
  ) async {
    if (!await FirebaseFirestore.instance.localPersistenceEnabled()) {
      _memoryRoot = _cloneRoot(root);
      return;
    }

    final sqlite = await _sqliteStore();
    if(sqlite!=null){
      await sqlite.writeRoot(root);
      WindowsServiceStatus.instance.healthy(WindowsServiceType.localStorage,'Local SQLite transaction committed.');
      return;
    }
    final file = await _file();
    try {
      await file.parent.create(recursive: true);

      final pending = File('${file.path}.pending');
      final backup = File('${file.path}.bak');

      await pending.writeAsString(
        jsonEncode(root),
        flush: true,
      );

      if (await file.exists()) {
        try {
          await file.copy(backup.path);
        } catch (_) {}
        await file.delete();
      }

      await pending.rename(file.path);
      WindowsServiceStatus.instance.healthy(
        WindowsServiceType.localStorage,
        'Local database write OK: ${file.path}',
      );
    } catch (e) {
      WindowsServiceStatus.instance.unhealthy(
        WindowsServiceType.localStorage,
        'Local database write problem: $e',
      );
      rethrow;
    }
  }

}

Map<String, dynamic> _encodeMap(
  Map<String, dynamic> input,
) {
  final output = <String, dynamic>{};

  for (final entry in input.entries) {
    output[entry.key] =
        _encodeValue(entry.value);
  }

  return output;
}

dynamic _encodeValue(
  dynamic value,
) {
  if (value is _ServerTimestampValue) {
    return <String, dynamic>{
      '__vidya_type': 'timestamp',
      'ms': DateTime.now()
          .toUtc()
          .millisecondsSinceEpoch,
    };
  }

  if (value is _DeleteFieldValue) {
    return <String, dynamic>{
      '__vidya_type': 'delete',
    };
  }

  if (value is Timestamp) {
    return <String, dynamic>{
      '__vidya_type': 'timestamp',
      'ms': value.millisecondsSinceEpoch,
    };
  }

  if (value is DateTime) {
    return <String, dynamic>{
      '__vidya_type': 'datetime',
      'ms': value
          .toUtc()
          .millisecondsSinceEpoch,
    };
  }

  if (value is Map) {
    return value.map(
      (key, item) => MapEntry(
        key.toString(),
        _encodeValue(item),
      ),
    );
  }

  if (value is Iterable) {
    return value
        .map(_encodeValue)
        .toList();
  }

  return value;
}

Map<String, dynamic> _decodeMap(
  Map<String, dynamic> input,
) {
  final output = <String, dynamic>{};

  for (final entry in input.entries) {
    output[entry.key] =
        _decodeValue(entry.value);
  }

  return output;
}

dynamic _decodeValue(
  dynamic value,
) {
  if (value is Map) {
    final map =
        Map<String, dynamic>.from(value);

    if (map['__vidya_type'] == 'timestamp') {
      final ms =
          (map['ms'] as num?)?.toInt() ?? 0;

      return Timestamp.fromDate(
        DateTime.fromMillisecondsSinceEpoch(
          ms,
          isUtc: true,
        ),
      );
    }

    if (map['__vidya_type'] == 'datetime') {
      final ms =
          (map['ms'] as num?)?.toInt() ?? 0;

      return DateTime.fromMillisecondsSinceEpoch(
        ms,
        isUtc: true,
      ).toLocal();
    }

    return map.map(
      (key, item) => MapEntry(
        key,
        _decodeValue(item),
      ),
    );
  }

  if (value is List) {
    return value
        .map(_decodeValue)
        .toList();
  }

  return value;
}

bool _isDeleteMarker(
  dynamic value,
) {
  return value is Map &&
      value['__vidya_type'] == 'delete';
}

dynamic _sortableValue(
  dynamic value,
) {
  if (value is Timestamp) {
    return value.millisecondsSinceEpoch;
  }

  if (value is DateTime) {
    return value.millisecondsSinceEpoch;
  }

  return value;
}

int _compareValues(
  dynamic a,
  dynamic b,
) {
  if (identical(a, b)) return 0;
  if (a == null) return -1;
  if (b == null) return 1;

  if (a is num && b is num) {
    return a.compareTo(b);
  }

  return a.toString().compareTo(
        b.toString(),
      );
}

String _autoDocumentId() {
  final now =
      DateTime.now().microsecondsSinceEpoch
          .toRadixString(36);
  final random =
      Random.secure()
          .nextInt(1 << 32)
          .toRadixString(36);

  return '$now$random';
}
