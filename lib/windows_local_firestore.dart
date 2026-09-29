import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  CollectionReference<Map<String, dynamic>> collection(
    String path,
  ) {
    return CollectionReference<Map<String, dynamic>>._(
      firestore: this,
      collectionPath: path,
    );
  }

  WriteBatch batch() => WriteBatch._(this);

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
  });

  final FirebaseFirestore firestore;
  final String collectionPath;
  final List<_WhereFilter> filters;
  final String? orderField;
  final bool orderDescending;
  final int? limitCount;

  Query<T> where(
    String field, {
    Object? isEqualTo,
  }) {
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
    final rawDocs =
        await firestore._database.readCollection(
      collectionPath,
    );

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
  });

  final FirebaseFirestore firestore;
  final String collectionPath;
  final String documentId;

  String get id => documentId;

  Future<DocumentSnapshot<T>> get() async {
    final raw = await firestore._database.readDocument(
      collectionPath,
      documentId,
    );

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

  Future<void> set(
    T data, [
    SetOptions? options,
  ]) async {
    if (data is! Map) {
      throw ArgumentError(
        'Windows local database Map data require karta hai.',
      );
    }

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
    await firestore._database.updateDocument(
      collectionPath,
      documentId,
      data,
    );
  }

  Future<void> delete() async {
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
  WriteBatch._(this.firestore);

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
    _operations.add(
      _WriteOperation.delete(
        reference.collectionPath,
        reference.documentId,
      ),
    );
  }

  Future<void> commit() async {
    await firestore._database.applyOperations(
      _operations,
    );
  }
}

class Transaction {
  Transaction._(this.firestore);

  final FirebaseFirestore firestore;
  final List<_WriteOperation> _operations =
      <_WriteOperation>[];

  Future<DocumentSnapshot<T>> get<T>(
    DocumentReference<T> reference,
  ) {
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
    _operations.add(
      _WriteOperation.delete(
        reference.collectionPath,
        reference.documentId,
      ),
    );
  }

  Future<void> _commit() {
    return firestore._database.applyOperations(
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
}

class _LocalJsonDatabase {
  final Map<String, StreamController<void>> _signals =
      <String, StreamController<void>>{};

  Future<void> _writeTail = Future<void>.value();

  File get _file {
    final base =
        Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'];

    if (base == null) {
      throw StateError(
        'Windows application data folder unavailable.',
      );
    }

    return File(
      '$base${Platform.pathSeparator}'
      'VidyaSaarthi${Platform.pathSeparator}'
      'local_database_v1.json',
    );
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

    final completer = Completer<void>();

    _writeTail = _writeTail.then((_) async {
      try {
        final root = await _readRoot();
        final collections = _collections(root);
        final touched = <String>{};

        for (final operation in operations) {
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
        }

        root['collections'] = collections;

        await _writeRoot(root);

        for (final collection in touched) {
          final controller = _signals[collection];

          if (controller != null &&
              !controller.isClosed) {
            controller.add(null);
          }
        }

        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });

    return completer.future;
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
    try {
      if (!await _file.exists()) {
        return <String, dynamic>{
          'version': 1,
          'collections': <String, dynamic>{},
        };
      }

      final decoded = jsonDecode(
        await _file.readAsString(),
      );

      if (decoded is Map) {
        final root =
            Map<String, dynamic>.from(decoded);

        root.putIfAbsent(
          'collections',
          () => <String, dynamic>{},
        );

        return root;
      }
    } catch (_) {
      final backup = File('${_file.path}.bak');

      try {
        if (await backup.exists()) {
          final decoded = jsonDecode(
            await backup.readAsString(),
          );

          if (decoded is Map) {
            return Map<String, dynamic>.from(
              decoded,
            );
          }
        }
      } catch (_) {}
    }

    return <String, dynamic>{
      'version': 1,
      'collections': <String, dynamic>{},
    };
  }

  Map<String, dynamic> _collections(
    Map<String, dynamic> root,
  ) {
    final value = root['collections'];

    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }

    return <String, dynamic>{};
  }

  Future<void> _writeRoot(
    Map<String, dynamic> root,
  ) async {
    await _file.parent.create(
      recursive: true,
    );

    final pending =
        File('${_file.path}.pending');
    final backup =
        File('${_file.path}.bak');

    await pending.writeAsString(
      jsonEncode(root),
      flush: true,
    );

    if (await _file.exists()) {
      try {
        await _file.copy(backup.path);
      } catch (_) {}

      await _file.delete();
    }

    await pending.rename(_file.path);
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
