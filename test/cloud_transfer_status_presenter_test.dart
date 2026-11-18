import 'package:flutter_test/flutter_test.dart';
import '../lib/cloud_transfer_status.dart';

void main() {
  const recordId = 'student-12';
  const receiptId = 'operation-1234567890';

  test('completed Drive receipts never appear as errors or stacked success alerts', () {
    final history = {
      'driveHistoryLocal': true,
      'driveSaveHistory': [
        for (var n = 0; n < 12; n++)
          {
            'id': '$receiptId-$n',
            'collection': 'students_directory',
            'recordId': '$recordId-$n',
            'state': 'completed',
            'completedAt': 1700000000000 + n,
          },
      ],
    };
    expect(driveSaveMessages(history), isEmpty);
  });

  test('pending and needs-review Drive receipts remain visible after success filtering', () {
    final history = {
      'driveHistoryLocal': true,
      'driveSaveHistory': [
        {'id': receiptId, 'collection': 'students_directory',
          'recordId': recordId, 'state': 'completed', 'completedAt': 1700000000000},
        {'id': 'operation-1234567891', 'collection': 'documents',
          'recordId': 'file-1', 'state': 'pending', 'cloudflareAccepted': true},
        {'id': 'operation-1234567892', 'collection': 'teachers_directory',
          'recordId': 'teacher-1', 'state': 'needsAttention'},
      ],
    };
    final visible = driveSaveMessages(history);
    expect(visible, hasLength(2));
    expect(visible.first, contains('Cloudflare saved · Drive save pending'));
    expect(visible.last, contains('Drive save needs review'));
    expect(visible.join(' '), isNot(contains('Drive save completed')));
  });
}
