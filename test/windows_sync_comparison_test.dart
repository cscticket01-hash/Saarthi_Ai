import 'dart:io';
import 'dart:convert';

import '../lib/windows_sync_recovery.dart';
import '../lib/sync_recovery_policy.dart';

import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_sync_comparison.dart';

void main() {
  test('actual Apps Script deletion shapes verify exact mutation ACK plus readback', () {
    final cases = jsonDecode(File('test/fixtures/managed_document_delete_contract.json').readAsStringSync()) as List;
    for(final c in cases) {
      final payload = Map<String,dynamic>.from(c['payload'] as Map);
      final reply = Map<String,dynamic>.from(c['readback'] as Map);
      final ack = <String,dynamic>{...Map<String,dynamic>.from(c['deleteResponse'] as Map),
        'collection':'documents','documentId':payload['documentId'],'operationId':payload['deleteOperationId']};
      Map receipt(Map response, Map? proof) => documentAcknowledgementFromReadback(payload,response,deleteAcknowledgement:proof);
      expect(verifiedDocumentAcknowledgement(payload,receipt(reply,ack)),true,reason:c['name']);
      // _handleCentral removes action before dispatch. Its receipt verifier
      // must use the captured action, just as the outer queue still does.
      final dispatched = Map<String,dynamic>.from(payload)..remove('action');
      expect(verifiedDocumentAcknowledgement(dispatched,receipt(reply,ack)),false);
      expect(verifiedDocumentAcknowledgement(dispatched,receipt(reply,ack),
        action:'delete_student_document'),true,reason:'dispatch ${c['name']}');
      expect(verifiedDocumentAcknowledgement(dispatched,receipt(reply,null),
        action:'delete_student_document'),false);
      expect(verifiedDocumentAcknowledgement(dispatched,
        receipt(reply,{...ack,'recordRevision':'wrong'}),
        action:'delete_student_document'),false);
      expect(verifiedDocumentAcknowledgement(payload,receipt(reply,null)),false);
      for(final change in [
        {'success':false},{'syncProtocol':1},{'schoolId':'foreign'},{'collection':'students_directory'},
        {'documentId':'other'},{'operationId':'b'*64},{'recordRevision':'different'},
      ]) expect(verifiedDocumentAcknowledgement(payload,receipt(reply,{...ack,...change})),false);
      final row = Map<String,dynamic>.from((reply['records'] as Map)[payload['documentId']] as Map);
      for(final change in [{'_syncDeleted':false},{'_syncRevision':'different'},{'schoolId':'foreign'},
        {'documentRevision':'unrelated-generation'},{'documentId':'other'}]) {
        expect(verifiedDocumentAcknowledgement(payload,receipt({...reply,'records':{payload['documentId']:{...row,...change}}},ack)),false);
      }
      if(c['name']!='existing') {
        expect(row.containsKey('documentRevision'),false);
        expect(verifiedDocumentAcknowledgement({...payload,'baseCloudRevision':'unverified-nonempty'},receipt(reply,ack)),false);
      }
    }
  });
  test('document differences report content and identity fields, never local file paths', () {
    final local = {'schoolId':'s','documentRevision':'a','contentHash':'hash','localPath':'private'};
    final cloud = {'schoolId':'s','documentRevision':'b','contentHash':'hash'};
    expect(documentDifferenceFields(local,cloud),['documentRevision']);
  });

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
      'baseCloudRevision': 'op', 'deleteOperationId':'a'*64};
    final tombstone = {'schoolId': 's', '_syncDeleted': true,
      '_syncRevision': 'deleted-receipt', 'documentRevision': 'op'};
    expect(verifiedDocumentAcknowledgement(deletion,
      documentAcknowledgementFromReadback(deletion,
        {...reply, 'records': {'d': tombstone}}, deleteAcknowledgement:{
          'success':true,'syncProtocol':2,'schoolId':'s','collection':'documents','documentId':'d',
          'operationId':'a'*64,'recordRevision':'deleted-receipt'})), isTrue);
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
