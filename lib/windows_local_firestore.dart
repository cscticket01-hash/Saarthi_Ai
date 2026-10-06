import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'windows_local_storage.dart';
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

class Timestamp {
  Timestamp.fromDate(DateTime value)
      : _value = value.toUtc();

  Timestamp.now()
      : _value = DateTime.now().toUtc();

  final DateTime _value;

  DateTime toDate() => _value.toLocal();

  int get millisecondsSinceEpoch =>
      _value.millisecondsSinceEpoch;
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

  final _LocalJsonDatabase _database =
      _LocalJsonDatabase();

  String get activeProfileId =>
      _database.activeProfileId;

  Map<String, dynamic> get activeProfileIdentity =>
      _database.activeProfileIdentity;

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
  Future<int>? _persistenceResolution;

  Future<bool> localPersistenceEnabled() async {
    final origin = activeProfileId;
    final identity = activeProfileIdentity;
    if (!validSchoolId(identity['schoolSyncId']?.toString() ?? '')) {
      return WindowsRuntimeFlags.localStorageEnabled();
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
    return mode == 1 || mode == 0 && await WindowsRuntimeFlags.localStorageEnabled();
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

  Future<void> resetVolatileSession() => _database.resetVolatileSession();

  CollectionReference<Map<String, dynamic>> collection(
    String path,
  ) {
    return CollectionReference<Map<String, dynamic>>._(
      firestore: this,
      collectionPath: path,
    );
  }

  WriteBatch batch() => WriteBatch._(this);

  Future<void> acknowledgeOutbox(DocumentReference<Map<String,dynamic>> ref, Map<String,dynamic> expected, {String? revision}) {
    ref.requireOriginProfile();
    if(ref.collectionPath!='_windows_firebase_outbox') throw ArgumentError('Outbox reference required');
    return _database.applyOperations([_WriteOperation._(type:_WriteType.delete,
      collection:ref.collectionPath, documentId:ref.id, data:expected, acknowledgedRevision:revision)]);
  }

  /// Check the live outbox inside the serialized disk write, not a stale pull snapshot.
  Future<void> applySyncedDocument(DocumentReference<Map<String,dynamic>> ref, Map<String,dynamic>? data) {
    ref.requireOriginProfile();
    return WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>_database.applyOperations([
      _WriteOperation._(type:data==null?_WriteType.delete:_WriteType.set,
        collection:ref.collectionPath,documentId:ref.id,data:data,preservePending:true),
    ]));
  }

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
    yield await get();

    await for (final _ in firestore._database
        .changesFor(collectionPath)) {
      yield await get();
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
    yield await get();

    await for (final _ in firestore._database
        .changesFor(collectionPath)) {
      yield await get();
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
    await firestore._database.applyOperations(
      _operations,
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
  final String collection;
  final String documentId;
  final Map<String, dynamic>? data;
  final bool merge;
  final bool preservePending;
  final String? acknowledgedRevision;
}

class _LocalJsonDatabase {
  final Map<String, StreamController<void>> _signals =
      <String, StreamController<void>>{};

  Future<void> _writeTail = Future<void>.value();

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
  ) {
    if (operations.isEmpty) {
      return Future<void>.value();
    }

    final profileAtEnqueue=_activeProfileId;
    final completer = Completer<void>();

    _writeTail = _writeTail.then((_) async {
      try {
        if(_activeProfileId!=profileAtEnqueue)throw StateError('School profile changed before queued write.');
        final root = await _readRoot();
        if(_activeProfileId!=profileAtEnqueue)throw StateError('School profile changed during queued write.');
        final collections = _collections(root);
        final touched = <String>{};
        var trackedMutation = false;

        for (final operation in operations) {
          if(operation.preservePending) {
            final pending=collections['_windows_firebase_outbox'];
            if(pending is Map && pending.values.any((item)=>item is Map &&
                item['collection']==operation.collection && item['documentId']==operation.documentId)) continue;
          }
          if(operation.preservePending && operation.data?['_syncRevision'] is String) {
            final baselines = collections.putIfAbsent('_windows_sync_baselines',()=> <String,dynamic>{}) as Map;
            final key = base64Url.encode(utf8.encode('${operation.collection}\\n${operation.documentId}')).replaceAll('=', '');
            baselines[key] = {'revision':operation.data!['_syncRevision']};
          }
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

          switch (operation.type) {
            case _WriteType.delete:
              // Compare and remove under the same serialized disk write. A save
              // made while the cloud request was in flight must remain queued.
              if (operation.acknowledgedRevision != null && operation.data != null) {
                final sent = operation.data!, revision = operation.acknowledgedRevision!;
                final baselines = collections.putIfAbsent('_windows_sync_baselines',()=> <String,dynamic>{}) as Map;
                baselines[operation.documentId] = {'revision':revision};
                final queued = docs[operation.documentId];
                if (queued is Map && queued['operationId'] != sent['operationId'] &&
                    queued['baseCloudRevision'] == sent['baseCloudRevision']) {
                  queued['baseCloudRevision'] = revision;
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

              _applyFields(
                current,
                _encodeMap(operation.data ?? {}),
              );

              docs[operation.documentId] = current;
              break;
          }

          if (WindowsLocalFirestoreSyncControl.trackingEnabled &&
              _shouldTrackForFirebase(operation.collection)) {
            _recordFirebaseOutbox(
              collections,
              operation,
              docs,
            );
            trackedMutation = true;
          }
        }

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
            Future<void>.microtask(() async {
              try {
                await callback();
              } catch (_) {}
            });
          }
        }

        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
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
    Map<String, dynamic> finalDocs,
  ) {
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
    final baseline = collections['_windows_sync_baselines'];
    final baselineEntry = baseline is Map ? baseline[key] : null;
    queue[key] = <String, dynamic>{
      'operationId': base64Url.encode(List<int>.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', ''),
      'schoolId': _activeIdentity['schoolSyncId'] ?? '',
      'baseCloudRevision': previous is Map ? previous['baseCloudRevision'] ?? '' :
          baselineEntry is Map ? baselineEntry['revision'] ?? '' : '',
      'syncState':'pending', 'retryCount':0,
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

  Future<Map<String, dynamic>> _readRoot() async {
    if (!await FirebaseFirestore.instance.localPersistenceEnabled()) {
      return _cloneRoot(_memoryRoot);
    }

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
  Future<void> resetVolatileSession() async {
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
