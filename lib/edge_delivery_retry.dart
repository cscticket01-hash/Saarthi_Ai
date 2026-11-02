/// A retained server retry is not an ACK, nor a failed network connection.
/// Only fixed categories cross into local diagnostics; never raw server text.
({String code, int retryAfterMs})? edgeDeliveryRetry(Object? value, DateTime now) {
  if (value is! Map || value['state'] != 'retry') return null;
  final due = value['retryAtMillis'];
  if (due is! int || due <= now.millisecondsSinceEpoch) return null;
  const known = {
    'SCRIPT_TIMEOUT', 'SCRIPT_TRANSPORT_ERROR', 'SCRIPT_RESPONSE_READ_FAILED',
    'SCRIPT_HTTP_ERROR', 'SCRIPT_OPERATION_FAILED', 'SCRIPT_TYPE_ERROR',
    'SCRIPT_PARSE_ERROR', 'SCRIPT_SHEET_RECOVERY_REQUIRED',
    'SCRIPT_STUDENT_PARENT_PENDING', 'SCRIPT_STORAGE_NOT_PREPARED',
    'SCRIPT_MIGRATION_PENDING', 'ACK_UNVERIFIED', 'EDGE_DELIVERY_PENDING',
  };
  final code = known.contains(value['failureCode'])
      ? value['failureCode'] as String : 'EDGE_DELIVERY_PENDING';
  return (code: code,
      retryAfterMs: (due - now.millisecondsSinceEpoch).clamp(0, 86400000).toInt());
}
