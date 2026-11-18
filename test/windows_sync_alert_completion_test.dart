import 'package:flutter_test/flutter_test.dart';
import '../lib/cloud_transfer_status.dart';

void main() {
  test('completed Drive writes disappear from the alert panel without erasing history', () {
    final status = <String, dynamic>{
      'driveHistoryLocal': true,
      'driveSaveHistory': <Map<String, dynamic>>[
        {
          'id': 'completedreceipt0001',
          'recordId': 'Class_9_Roll_15',
          'collection': 'students_directory',
          'state': 'completed',
          'completedAt': 1793780000000,
        },
        {
          'id': 'completedreceipt0002',
          'recordId': 'doc-1',
          'collection': 'documents',
          'state': 'completed',
          'completedAt': 1793780000000,
        },
      ],
    };
    expect(driveSaveMessages(status), isEmpty,
        reason: 'Success entries should not be red warnings.');
    expect((status['driveSaveHistory'] as List).length, 2,
        reason: 'Presentation cleanup must not delete durable history.');
  });

  test('pending transfers and unresolved review entries remain visible', () {
    final status = <String, dynamic>{
      'driveHistoryLocal': true,
      'driveSaveHistory': <Map<String, dynamic>>[
        {
          'id': 'completedreceipt0001',
          'recordId': 'old',
          'collection': 'students_directory',
          'state': 'completed',
          'completedAt': 1793780000000,
        },
        {
          'id': 'pendingreceipt00001',
          'recordId': 'new',
          'collection': 'documents',
          'state': 'pending',
          'cloudflareAccepted': true,
        },
        {
          'id': 'reviewreceipt000001',
          'recordId': 'stuck',
          'collection': 'teachers_directory',
          'state': 'needsAttention',
        },
      ],
    };
    expect(driveSaveMessages(status), <String>[
      'Cloudflare saved · Drive save pending · documents · new',
      'Drive save needs review · teachers_directory · stuck',
    ]);
    final summary = cloudTransferMessage({
      'enabled': true,
      'notices': {'pending': 0, 'needsAttention': 0},
      'delivery': {'pendingPartitions': 1, 'needsAttention': 0},
    });
    expect(summary, contains('Google Drive transfer pending'));
    expect(summary, isNot(contains('Cloudflare saved')),
        reason: 'Aggregate backend backlog must not falsely confirm the current student upload.');
  });

  test('measured Drive progress never invents bytes or early completion', () {
    Map<String,dynamic> status(Map<String,dynamic> row) => {
      'driveHistoryLocal':true,
      'driveSaveHistory':[{'id':'receipt012345678901','state':'pending',...row}],
    };
    expect(measuredDriveProgress(status({}))?['state'],'verifying');
    expect(measuredDriveProgress(status({
      'driveProgress':{'version':1,'acknowledgedBytes':512,'totalBytes':1024},
    }))?['percent'],50);
    expect(measuredDriveProgress(status({
      'driveProgress':{'version':1,'acknowledgedBytes':1024,'totalBytes':1024},
    }))?['percent'],isNull);
    expect(measuredDriveProgress(status({
      'driveProgress':{'version':1,'acknowledgedBytes':999,'totalBytes':1024},
    }))?['percent'],97);
    expect(measuredDriveProgress({
      'unavailable':true,'driveHistoryLocal':true,
      'driveSaveHistory':[{'id':'receipt012345678901','state':'pending',
        'driveProgress':{'version':1,'acknowledgedBytes':512,'totalBytes':1024}}],
    }),isNull);
    expect(measuredDriveProgress({
      'driveHistoryLocal':true,'driveSaveHistory':[{
        'id':'receipt012345678901','state':'completed',
        'driveDurationMillis':12500,
      }],
    }),{'state':'completed','percent':100,'durationMillis':12500});
  });
  test('background backup attention is not presented as current local upload success', () {
    expect(cloudTransferMessage({
      'enabled': true,
      'notices': {'pending': 0, 'needsAttention': 1},
      'delivery': {'pendingPartitions': 0, 'needsAttention': 1},
    }), allOf(contains('need school review'), isNot(contains('Cloudflare saved'))));
  });
  test('resolved transfers yield no alert when all queues are clear', () {
    expect(cloudTransferMessage({
      'enabled': true,
      'notices': {'pending': 0, 'needsAttention': 0},
      'delivery': {'pendingPartitions': 0, 'needsAttention': 0},
    }), isNull);
  });
}
