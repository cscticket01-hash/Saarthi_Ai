/// Only a recent, server-created operation still being processed gets a short
/// confirmation interval. This does not resubmit it or grant a completion ACK.
/// Retry/unknown states and long-running work retain the existing backoff.
Duration attendanceConfirmationDelay({
  required String? state,
  required Object? createdAt,
  required int attempts,
  required int now,
}) {
  if (attendanceUsesFastConfirmation(
    state: state,
    createdAt: createdAt,
    now: now,
  )) {
    return const Duration(seconds: 5);
  }
  final exponent = (attempts - 2).clamp(0, 3).toInt();
  return Duration(
    milliseconds: (5000 * (1 << exponent)).clamp(5000, 30000).toInt(),
  );
}

bool attendanceUsesFastConfirmation({
  required String? state,
  required Object? createdAt,
  required int now,
}) =>
    (state == 'pending' || state == 'processing') &&
    createdAt is int &&
    createdAt > 0 &&
    createdAt <= now &&
    now - createdAt < 30000;
