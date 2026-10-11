import 'dart:convert';
import 'dart:math';

/// One dialog's original financial intent. The durable existing expense/queue
/// stores remain authoritative; this helper never marks a provider ACK.
class WindowsExpenseIntent {
  WindowsExpenseIntent({DateTime? createdAt}) : capturedAt = createdAt ?? DateTime.now() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expenseId = 'EXP-${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20)}';
  }
  final DateTime capturedAt;
  late final String expenseId;
  Map<String, dynamic>? _submitted;

  Map<String, dynamic> prepare({required String title, required String category,
      required double amount, required String paidTo, required String note}) {
    if (title.trim().isEmpty || !amount.isFinite || amount <= 0) {
      throw ArgumentError('Enter a title and a finite positive expense amount.');
    }
    final payload = <String, dynamic>{
      'action': 'save_school_expense', 'expenseId': expenseId,
      'title': title.trim(), 'category': category, 'amount': amount,
      'paidTo': paidTo.trim(), 'note': note.trim(),
      'dateText': capturedAt.toIso8601String().split('T').first,
      'timestamp': capturedAt.millisecondsSinceEpoch,
    };
    if (_submitted != null && jsonEncode(payload) != jsonEncode(_submitted)) {
      throw StateError('This expense was already submitted with different details. Its outcome may be pending. Retry the original details and review before creating a correction.');
    }
    _submitted ??= Map<String, dynamic>.from(payload);
    return Map<String, dynamic>.from(_submitted!);
  }
}
