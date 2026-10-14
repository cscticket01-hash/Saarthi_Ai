import 'dart:io';

import '../lib/windows_sync_recovery.dart';
import '../lib/sync_recovery_policy.dart';

import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_sync_comparison.dart';

void main() {
  test('managed map-key readback verifies documents without embedded id', () {
    final payload = {
      'action': 'upload_student_document', 'documentId': 'd', 'schoolId': 's',
      'documentRevision': 'op', 'contentHash': 'a' * 64,
    };
    final row = {...payload, '_syncRevision': 'receipt'};
    final reply = {'success': true, 'schoolId': 's', 'syncProtocol': 2,
      'records': {'d': row}};
    Map receipt(Map response) => documentAcknowledgementFromReadback(payload, response);
    expect(verifiedDocumentAcknowledgement(payload, receipt(reply)), isTrue);
    expect(row.containsKey('id'), isFalse); // Never mutate readback/source data.
    for (final bad in [
      {...reply, 'schoolId': 'other'},
      {...reply, 'success': false},
      {...reply, 'syncProtocol': 1},
      {...reply, 'records': {'other': row}},
      for (final change in [
        {'id': 'other'}, {'documentId': 'other'}, {'schoolId': 'other'},
        {'_syncRevision': ''}, {'contentHash': 'b' * 64},
        {'documentRevision': 'other'}, {'studentId': 'other'},
      ]) {...reply, 'records': {'d': {...row, ...change}}},
    ]) {
      expect(verifiedDocumentAcknowledgement(payload, receipt(bad)), isFalse);
    }
    final deletion = {...payload, 'action': 'delete_student_document',
      'baseCloudRevision': 'op'};
    final tombstone = {'schoolId': 's', '_syncDeleted': true,
      '_syncRevision': 'deleted-receipt', 'documentRevision': 'op'};
    expect(verifiedDocumentAcknowledgement(deletion,
      documentAcknowledgementFromReadback(deletion,
        {...reply, 'records': {'d': tombstone}})), isTrue);
  });
  test(
    'only same-school durable readback may update document ACK evidence',
    () {
      final payload = {
        'action': 'upload_student_document',
        'documentId': 'd',
        'schoolId': 's',
        'documentRevision': 'op',
        'contentHash': 'a' * 64,
      };
      final reply = {
        'success': true,
        'cloudVerified': true,
        'schoolId': 's',
        'document': {...payload, 'id': 'd', '_syncRevision': 'receipt'},
      };
      expect(verifiedDocumentAcknowledgement(payload, reply), isTrue);
      expect(
        verifiedDocumentAcknowledgement(payload, {'success': true}),
        isFalse,
      );
      expect(
        verifiedDocumentAcknowledgement(payload, {
          ...reply,
          'schoolId': 'other',
        }),
        isFalse,
      );
      expect(
        verifiedDocumentAcknowledgement(payload, {
          ...reply,
          'cloudVerified': false,
        }),
        isFalse,
      );
    },
  );
  test(
    'invalid records and missing files require review, never automatic retry',
    () {
      expect(
        windowsSyncRecovery(const FileSystemException('secret path')).kind,
        SyncFailureKind.fileMissing,
      );
      expect(
        SyncRecoveryDecision.classify(status: 422).kind,
        SyncFailureKind.validation,
      );
      expect(SyncRecoveryDecision.classify(status: 422).retry, isFalse);
      expect(
        SyncRecoveryDecision.classify(status: 502).kind,
        SyncFailureKind.server,
      );
      expect(
        SyncRecoveryDecision.classify(status: 403).kind,
        SyncFailureKind.authorization,
      );
      expect(
        SyncRecoveryDecision.classify(networkPathFailed: true).kind,
        SyncFailureKind.networkPath,
      );
    },
  );
  final row = {
    'schoolId': 'school-a',
    'documentRevision': 'operation-a',
    'contentHash': 'a' * 64,
    'studentId': 'student-a',
    'documentName': 'ID',
  };
  test('exact replay is idempotent, metadata or bytes divergence is not', () {
    expect(
      identicalDocumentPayload(row, {...row, '_syncRevision': 'receipt'}),
      isTrue,
    );
    for (final changed in [
      {'contentHash': 'b' * 64},
      {'studentId': 'other'},
      {'documentName': 'changed'},
      {'schoolId': 'other'},
      {'_syncDeleted': true},
    ]) {
      expect(identicalDocumentPayload(row, {...row, ...changed}), isFalse);
    }
  });
  test(
    'canonical comparison ignores key order, never invents revision ordering',
    () {
      final local = {'schoolId': 's', 'amount': 100};
      expect(
        compareSyncVersions(
          {'schoolId': 's', 'data': local},
          {'amount': 100, 'schoolId': 's', '_syncRevision': 'uuid'},
        ),
        'identical',
      );
      expect(
        compareSyncVersions(
          {'schoolId': 's', 'data': local},
          {'amount': 200, 'schoolId': 's', '_syncRevision': 'uuid'},
        ),
        contains('differs'),
      );
    },
  );
}
