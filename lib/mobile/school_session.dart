import 'school_request_deadlines.dart';
import '../qr_authentication_engine.dart';
import '../qr_card_authorization.dart';
import 'attendance_store.dart';
import '../attendance_schedule.dart';

import 'package:flutter/foundation.dart';

import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../platform/github_updates.dart';
import '../school_qr_link.dart';
export '../school_qr_link.dart';
import '../school_backend_transport.dart';

/// An authoritative denial must never be mistaken for a transient outage.
class SchoolAccessDenied extends StateError {
  SchoolAccessDenied(super.message);
}

/// Attendance policy refusals retain the exact original capture for school review.
/// Messages are local constants, never arbitrary server exception text.
class AttendanceRejected extends StateError {
  AttendanceRejected(this.code, {this.reference = ''})
    : super(
        _reasons[code] ??
            'Attendance request was rejected. Ask the school to review it.',
      );
  final String code, reference;
  static const _reasons = <String, String>{
    'ATTENDANCE_SCHOOL_CLOSED': 'School is closed for this attendance day.',
    'ATTENDANCE_LOCATION_ACCURACY':
        'Location accuracy or school location settings do not meet the attendance policy.',
    'ATTENDANCE_OUTSIDE_SCHOOL':
        'The captured location is outside the school attendance radius.',
    'ATTENDANCE_SCHEDULE_CLOSED':
        'Student attendance is outside the school schedule.',
    'ATTENDANCE_CAPTURE_REVIEW': 'Attendance capture date needs school review.',
  };
  static String? reason(Map<String, dynamic> response, int status) {
    final code = response['code'];
    if (_reasons.containsKey(code)) return code as String;
    // Older deployed brokers send these verified policy refusals without codes.
    const legacy = {
      'School is closed today. Attendance is disabled for everyone':
          'ATTENDANCE_SCHOOL_CLOSED',
      'Accurate school location required': 'ATTENDANCE_LOCATION_ACCURACY',
      'Attendance can be marked only within the school location':
          'ATTENDANCE_OUTSIDE_SCHOOL',
    };
    return legacy[response['message']] ??
        (status == 400 ? 'ATTENDANCE_REQUEST_REJECTED' : null);
  }

  String get retainedMessage =>
      '$message Original capture retained for school review.'
      '${reference.isEmpty ? '' : ' Ref: $reference'}';
}

/// A verified server response arrived, but its local cache commit failed.
/// This must not be described as an upstream request timeout.
class SchoolCacheFailure extends StateError {
  SchoolCacheFailure()
    : super(
        'School response arrived, but local cache verification failed. Previously verified cached data is retained.',
      );
}

/// Login can wait behind a school's Script lock (up to 30s) and then its
/// authenticated session write. Do not abandon it at the dashboard's 25s budget.
/// No automatic login replay: a late response cannot authorize a timed-out client.
class SchoolLoginTimeout extends TimeoutException {
  SchoolLoginTimeout()
    : super(
        'School login did not finish in time. Try again; your school data is retained.',
        const Duration(seconds: 105),
      );
}

enum SchoolConnectionState {
  connected,
  syncing,
  cachedOffline,
  connectionError,
}

class SchoolSession {
  SchoolSession({
    http.Client? client,
    this.cacheDirectory,
    AttendanceStore? attendanceStore,
    Future<void> Function(String value)? persistSession,
    this.cardPublicKey = QrCardAuthorization.configuredPublicKey,
  }) : _client = client ?? http.Client(),
       _attendanceStore = attendanceStore ?? AttendanceStore(),
       _persistSession = persistSession;
  final Future<void> Function(String value)? _persistSession;
  final http.Client _client;
  final String cardPublicKey;
  final AttendanceStore _attendanceStore;
  Future<void>? _attendanceFlush;
  bool syncPaused = false;
  Future<void> setSyncPaused(bool paused) async {
    syncPaused = paused;
    if (paused) _recoveryTimer?.cancel();
    connectionChanges.value++;
    await _persist();
    if (!paused) await refreshDashboard(afterSignal: true);
  }

  Future<Map<String, dynamic>> refreshIfIdleDue({DateTime? now}) {
    final at = now ?? DateTime.now();
    if (syncPaused ||
        lastDashboardVerifiedAt != null &&
            at.difference(lastDashboardVerifiedAt!) <
                const Duration(hours: 1)) {
      return Future.value(dashboard);
    }
    return refreshDashboard();
  }

  String? _cachedAttendancePermit;
  String? _cardAuthorizationToken, _cardOfflineLease;
  int _cardOfflineUntil = 0;
  bool _cardReaderEnforced = false;
  Future<void> _adoptCardAuthorization(
    Map<String, dynamic> response, {
    String? session,
    bool restoring = false,
  }) async {
    final current = link, generation = _generation;
    if (current == null) return;
    if (response['cardReaderEnforced'] == true) {
      final receipt = response['cardAuthorizationToken'],
          offline = response['cardOfflineLease'];
      if (receipt is! String ||
          offline is! String ||
          receipt.isEmpty ||
          offline.isEmpty ||
          response['cardIssueId'] !=
              (current.cardIssueId.isEmpty ? null : current.cardIssueId)) {
        throw SchoolAccessDenied(
          'Fresh card verification is incomplete. School data is retained.',
        );
      }
      final at = DateTime.now().millisecondsSinceEpoch,
          token = session ?? schoolToken;
      final onlineExpires = await QrCardAuthorization.verifyOnline(
        receipt,
        current,
        deviceId: deviceId,
        sessionToken: token,
        now: at,
        publicKey: cardPublicKey,
      );
      final expires = await QrCardAuthorization.verifyOffline(
        offline,
        current,
        deviceId: deviceId,
        sessionToken: token,
        now: at,
        publicKey: cardPublicKey,
      );
      if (generation != _generation || !identical(current, link))
        throw SchoolAccessDenied('School session changed.');
      if (!restoring &&
          (onlineExpires == null ||
              expires == null ||
              expires > onlineExpires)) {
        throw SchoolAccessDenied(
          'Signed card verification failed. School data is retained.',
        );
      }
      _cardReaderEnforced = true;
      _cardAuthorizationToken = receipt;
      _cardOfflineLease = offline;
      _cardOfflineUntil =
          onlineExpires == null || expires == null || expires > onlineExpires
          ? 0
          : expires;
    } else if (_cardReaderEnforced || current.cardIssueId.isNotEmpty) {
      throw SchoolAccessDenied(
        'Issued card verification is unavailable. School data is retained.',
      );
    }
  }

  String? get _currentAttendancePermit {
    final token = _cachedAttendancePermit, current = link;
    if (token == null || current == null || !cachedAccessAllowed) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 2 ||
          token.length > 3000 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(parts[1]))
        return null;
      final p =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
              )
              as Map;
      if (p['purpose'] != 'attendance' ||
          p['schoolId'] != current.schoolId ||
          p['role'] != current.role ||
          p['documentId'] != current.personId ||
          p['expiresAt'] is! int ||
          p['expiresAt'] <= DateTime.now().millisecondsSinceEpoch + 2000 ||
          p['expiresAt'] > _expiresAt ||
          p['sessionHash'] !=
              sha256.convert(utf8.encode(schoolToken)).toString() ||
          p['qrHash'] !=
              sha256
                  .convert(
                    utf8.encode(
                      '${current.role}/${current.personId}/${current.linkToken}',
                    ),
                  )
                  .toString())
        return null;
      return token;
    } catch (_) {
      return null;
    }
  }

  final attendanceChanges = ValueNotifier<int>(0);
  bool attendanceStatusReady = false;
  int attendancePending = 0, attendanceAccepted = 0;
  String attendanceFailure = '';
  DateTime? lastAttendanceAck;
  String? get _attendanceOwner => link?.managed == true && loggedIn
      ? AttendanceStore.owner(
          link!.endpoint,
          link!.schoolId,
          link!.role,
          link!.personId,
        )
      : null;

  String _attendanceStatusDay = '';
  String? _attendanceStatusOwner;
  bool _capturedToday = false, _exitedToday = false;
  String _historyDay = '';
  String? _historyOwner;
  bool _historyEntry = false, _historyExit = false;
  String get attendanceLockReason => attendanceLockFor('entry');
  String attendanceLockFor(String mode) {
    final day = attendanceDay(DateTime.now());
    if (!attendanceStatusReady ||
        _attendanceStatusOwner != _attendanceOwner ||
        _attendanceStatusDay != day) {
      return 'Checking today’s attendance…';
    }
    final status = dashboard['attendanceStatus'];
    final entered =
        _capturedToday ||
        (_historyOwner == _attendanceOwner &&
            _historyDay == day &&
            _historyEntry) ||
        status is Map && status['day'] == day && status['recorded'] == true;
    final exited =
        _exitedToday ||
        (_historyOwner == _attendanceOwner &&
            _historyDay == day &&
            _historyExit);
    if (mode == 'exit' ? exited : entered) {
      return '${mode == 'exit' ? 'Check-out' : 'Check-in'} captured today. Locked until tomorrow, including pending submissions.';
    }
    if (mode == 'exit' && !entered) return 'Check in before checking out.';
    if (link?.role == 'student') {
      if (status is! Map) {
        return 'Refresh school attendance settings before marking attendance.';
      }
      if (status['version'] != 1) {
        return 'School attendance update required. Ask the school to update its attendance backend.';
      }
      if (!attendanceWindowAllows(status['schedule'], DateTime.now())) {
        return 'Student attendance is locked outside the school schedule (India time).';
      }
    }
    return '';
  }

  String get attendanceScheduleLabel {
    final status = dashboard['attendanceStatus'];
    if (link?.role != 'student' || status is! Map || status['version'] != 1)
      return '';
    final w = status['schedule'];
    if (w == null || w is Map && w['enabled'] == false)
      return 'Student attendance: no daily time limit.';
    if (w is! Map || w['startMinute'] is! int || w['endMinute'] is! int)
      return '';
    String clock(int n) =>
        '${(n ~/ 60).toString().padLeft(2, '0')}:${(n % 60).toString().padLeft(2, '0')}';
    return 'Student attendance: ${clock(w['startMinute'])}–${clock(w['endMinute'])} IST. Locks at closing time.';
  }

  Future<void> refreshAttendanceStatus() async {
    final owner = _attendanceOwner;
    if (owner == null) {
      attendancePending = 0;
      attendanceAccepted = 0;
      return;
    }
    final day = attendanceDay(DateTime.now());
    final captured = await _attendanceStore.capturedOn(
      owner,
      day,
      mode: 'entry',
    );
    final exited = await _attendanceStore.capturedOn(owner, day, mode: 'exit');
    final rows = await _attendanceStore.pending(owner);
    final summary = await _attendanceStore.summary(owner);
    if (owner != _attendanceOwner) return;
    _attendanceStatusOwner = owner;
    _attendanceStatusDay = day;
    _capturedToday = captured;
    _exitedToday = exited;
    attendanceStatusReady = true;
    attendancePending = (summary['pending'] as num).toInt();
    attendanceAccepted = (summary['accepted'] as num? ?? 0).toInt();
    if (summary['ack'] is num)
      lastAttendanceAck = DateTime.fromMillisecondsSinceEpoch(
        (summary['ack'] as num).toInt(),
      );
    attendanceFailure = rows
        .where((r) => (r['error'] as String).isNotEmpty)
        .map((r) => r['error'] as String)
        .take(1)
        .join();
    attendanceChanges.value++;
  }

  Map<String, dynamic> _attendanceHistoryCache = {};
  final _attendanceHistoryFlights =
      <String, Future<List<Map<String, dynamic>>>>{};
  List<Map<String, dynamic>>? cachedAttendanceHistory(String month) {
    if (!cachedAccessAllowed || _attendanceHistoryCache[month] is! List)
      return null;
    return (_attendanceHistoryCache[month] as List)
        .whereType<Map>()
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  Future<List<Map<String, dynamic>>> attendanceHistory(String month) {
    if (!RegExp(r'^\d{4}-\d{2}$').hasMatch(month))
      throw StateError('Select a month.');
    final existing = _attendanceHistoryFlights[month];
    if (existing != null) return existing;
    final pending = _fetchAttendanceHistory(month);
    _attendanceHistoryFlights[month] = pending;
    return pending.whenComplete(() {
      if (identical(_attendanceHistoryFlights[month], pending))
        _attendanceHistoryFlights.remove(month);
    });
  }

  Future<List<Map<String, dynamic>>> _fetchAttendanceHistory(
    String month,
  ) async {
    final current = link, generation = _generation;
    final result = await schoolCall('mobile_attendance_list', {'month': month});
    if (generation != _generation || !identical(current, link))
      throw SchoolAccessDenied('School session changed.');
    final value = result['attendance'];
    if (value is! List ||
        value.any(
          (r) =>
              r is! Map ||
              r['date'] is! String ||
              !(r['date'] as String).startsWith('$month-'),
        ))
      throw StateError(
        'Invalid school attendance history; saved history retained.',
      );
    final rows = value.map((r) => Map<String, dynamic>.from(r as Map)).toList();
    final before = _attendanceHistoryCache;
    final updated = {...before, month: rows};
    final months = updated.keys.toList()..sort();
    while (months.length > 18) updated.remove(months.removeAt(0));
    _attendanceHistoryCache = updated;
    try {
      await _persist();
    } catch (_) {
      if (generation == _generation) _attendanceHistoryCache = before;
      rethrow;
    }
    if (generation != _generation || !identical(current, link))
      throw SchoolAccessDenied('School session changed.');
    final day = attendanceDay(DateTime.now());
    if (month == day.substring(0, 7)) {
      _historyDay = day;
      _historyOwner = _attendanceOwner;
      _historyEntry = rows.any((r) => r['date'] == day && r['checkIn'] != null);
      _historyExit = rows.any((r) => r['date'] == day && r['checkOut'] != null);
      attendanceChanges.value++;
    }
    return rows;
  }

  Future<void> retryAttendance() async {
    final owner = _attendanceOwner;
    if (owner == null || !cachedAccessAllowed)
      throw SchoolAccessDenied('Verified school access required.');
    await _attendanceStore.retryReview(owner);
    await flushAttendance();
    await refreshAttendanceStatus();
  }

  Future<void> saveAttendance(
    Map<String, dynamic> gps,
    int capturedAt,
    String mode,
  ) async {
    final owner = _attendanceOwner, current = link, generation = _generation;
    if (owner == null || current == null || !cachedAccessAllowed)
      throw SchoolAccessDenied('Verified school access required.');
    await refreshAttendanceStatus();
    if (generation != _generation || !identical(current, link))
      throw SchoolAccessDenied('School session changed.');
    if (attendanceLockFor(mode).isNotEmpty)
      throw StateError(attendanceLockFor(mode));
    if (!['entry', 'exit'].contains(mode) || capturedAt <= 0)
      throw StateError('Invalid attendance capture.');
    final day = DateTime.fromMillisecondsSinceEpoch(
      capturedAt,
      isUtc: true,
    ).add(const Duration(hours: 5, minutes: 30));
    final date =
        '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    if (date != attendanceDay(DateTime.now()) ||
        current.role == 'student' &&
            !attendanceWindowAllows(
              (dashboard['attendanceStatus'] as Map?)?['schedule'],
              DateTime.fromMillisecondsSinceEpoch(capturedAt),
            )) {
      throw StateError(
        'Attendance capture is outside today’s school schedule.',
      );
    }
    final approval = <String, dynamic>{};
    if (_cardReaderEnforced || current.cardIssueId.isNotEmpty) {
      final permit = _currentAttendancePermit, offline = _cardOfflineLease;
      final expires = await QrCardAuthorization.verifyOffline(
        offline,
        current,
        deviceId: deviceId,
        sessionToken: schoolToken,
        now: capturedAt,
        publicKey: cardPublicKey,
      );
      if (permit == null ||
          offline == null ||
          expires == null ||
          capturedAt > DateTime.now().millisecondsSinceEpoch + 120000)
        throw SchoolAccessDenied(
          'Original attendance approval is unavailable.',
        );
      approval.addAll({
        'originalAttendancePermit': permit,
        'originalPermitHash': sha256.convert(utf8.encode(permit)).toString(),
        'originalCardOfflineLease': offline,
      });
    }
    if (generation != _generation || !identical(current, link))
      throw SchoolAccessDenied('School session changed.');
    await _attendanceStore.save(owner, date, mode, capturedAt, {
      ...gps,
      ...approval,
      if (current.cardIssueId.isNotEmpty) 'cardIssueId': current.cardIssueId,
    }, oncePerMode: true);
    if (generation != _generation || !identical(current, link))
      throw SchoolAccessDenied(
        'School session changed; original capture retained.',
      );
    await refreshAttendanceStatus();
    unawaited(flushAttendance().catchError((_) {}));
  }

  Future<void> flushAttendance() {
    final running = _attendanceFlush;
    if (running != null) return running;
    final pending = _flushAttendance().catchError((Object error) {
      attendanceFailure =
          'Attendance storage unavailable. Existing captures are retained; retry after reopening the app.';
      attendanceChanges.value++;
      throw error;
    });
    _attendanceFlush = pending;
    return pending.whenComplete(() {
      if (identical(_attendanceFlush, pending)) _attendanceFlush = null;
    });
  }

  Future<void> _flushAttendance() async {
    final current = link;
    final owner = _attendanceOwner;
    final generation = _generation;
    if (syncPaused || current == null || owner == null) return;
    if (!await _attendanceStore.hasDue(
      owner,
      DateTime.now().millisecondsSinceEpoch,
    )) {
      await refreshAttendanceStatus();
      return;
    }
    Map<String, dynamic> refreshed;
    final cachedPermit = _currentAttendancePermit;
    try {
      refreshed = cachedPermit == null
          ? await schoolCall('mobile_refresh', {})
          : {'attendancePermit': cachedPermit};
    } catch (_) {
      await refreshAttendanceStatus();
      return;
    }
    if (generation != _generation || owner != _attendanceOwner) return;
    final permitToken = refreshed['attendancePermit'];
    if (permitToken is! String) return; // Older broker: no fake acceptance.
    Map permit;
    try {
      permit =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(
                    base64Url.normalize(permitToken.split('.').first),
                  ),
                ),
              )
              as Map;
    } catch (_) {
      return;
    }
    if (permit['schoolId'] != current.schoolId ||
        permit['role'] != current.role ||
        permit['documentId'] != current.personId)
      return;
    for (var batch = 0; batch < 25; batch++) {
      if (syncPaused || generation != _generation || owner != _attendanceOwner)
        break;
      final at = DateTime.now().millisecondsSinceEpoch;
      final lease = base64UrlEncode(
        List.generate(24, (_) => Random.secure().nextInt(256)),
      );
      final row = await _attendanceStore.claim(owner, at, lease);
      if (row == null) break;
      final id = row['id'] as String;
      if (syncPaused) {
        await _attendanceStore.finish(owner, id, lease, {'nextAt': at});
        break;
      }
      final attempts = (row['attempts'] as int) + 1;
      try {
        final payload = Map<String, dynamic>.from(
          jsonDecode(row['payload'] as String),
        );
        final request = {
          ...payload,
          'role': current.role,
          'personId': current.personId,
          'linkToken': current.linkToken,
          'mode': row['mode'],
          'attendancePermit':
              payload['originalAttendancePermit'] ?? permitToken,
        };
        if (row['state'] == 'pending') {
          if (payload['cardIssueId'] != null &&
              payload['cardIssueId'] != current.cardIssueId)
            throw StateError(
              'Attendance card changed; school review required; original capture retained.',
            );
          if (_cardReaderEnforced || current.cardIssueId.isNotEmpty) {
            final original = payload['originalAttendancePermit'],
                proof = payload['originalCardOfflineLease'];
            if (original is! String ||
                proof is! String ||
                payload['originalPermitHash'] !=
                    sha256.convert(utf8.encode(original)).toString())
              throw StateError(
                'Original attendance approval needs school review; capture retained.',
              );
            final captured = payload['clientCapturedAt'];
            final originalExpiry = captured is int
                ? await QrCardAuthorization.verifyOffline(
                    proof,
                    current,
                    deviceId: deviceId,
                    sessionToken: schoolToken,
                    now: captured,
                    publicKey: cardPublicKey,
                  )
                : null;
            final oldPermit =
                jsonDecode(
                      utf8.decode(
                        base64Url.decode(
                          base64Url.normalize(original.split('.').first),
                        ),
                      ),
                    )
                    as Map;
            if (originalExpiry == null ||
                originalExpiry <= at ||
                oldPermit['expiresAt'] is! int ||
                oldPermit['expiresAt'] <= at)
              throw StateError(
                'Original attendance approval expired; school review required; capture retained.',
              );
          }
          if (row['day'] != permit['day'])
            throw StateError(
              'Attendance day needs school review; original capture retained.',
            );
          final expectedId = sha256
              .convert(
                utf8.encode(
                  jsonEncode([
                    current.schoolId,
                    permit['role'],
                    permit['personId'],
                    row['day'],
                    row['mode'],
                  ]),
                ),
              )
              .toString();
          final ack = await schoolCall('mobile_mark_attendance', request);
          if (ack['syncProtocol'] != 2 ||
              ack['accepted'] != true ||
              ack['operationId'] != expectedId)
            throw StateError(
              'Attendance acceptance verification failed; capture retained.',
            );
          await _attendanceStore.finish(owner, id, lease, {
            'state': 'accepted',
            'operationId': expectedId,
            'attempts': attempts,
            'nextAt': at + 10000,
            'error': '',
          });
        } else {
          final ack = await schoolCall('mobile_attendance_status', {
            ...request,
            'operationIds': [row['operationId']],
          });
          final values = ack['operations'];
          if (ack['syncProtocol'] != 2 || values is! List || values.length != 1)
            throw StateError('Attendance ACK verification failed.');
          final operation = values.single as Map;
          if (operation['operationId'] != row['operationId'])
            throw StateError('Attendance ACK identity mismatch.');
          final completed =
              operation['state'] == 'completed' &&
              operation['completedAt'] is num &&
              operation['createdAt'] is num &&
              operation['completedAt'] >= operation['createdAt'];
          if (operation['state'] == 'needsAttention')
            throw StateError(
              'Attendance needs school review; capture retained.',
            );
          await _attendanceStore.finish(owner, id, lease, {
            'state': completed ? 'completed' : 'accepted',
            'attempts': attempts,
            'nextAt':
                at +
                min(30000, 5000 * pow(2, min(max(0, attempts - 2), 3)).toInt()),
            'error': '',
            if (completed) 'completedAt': operation['completedAt'],
          });
          if (completed && generation == _generation)
            lastAttendanceAck = DateTime.fromMillisecondsSinceEpoch(
              (operation['completedAt'] as num).toInt(),
            );
        }
      } catch (error) {
        _cachedAttendancePermit = null;
        final review =
            error is AttendanceRejected ||
            error is SchoolAccessDenied ||
            (error is SchoolApiFailure && !error.retryable) ||
            error is StateError && error.message.contains('school review');
        final delay = min(3600000, 5000 * pow(2, min(attempts, 9)).toInt());
        await _attendanceStore.finish(owner, id, lease, {
          'attempts': attempts,
          'nextAt': at + delay + Random.secure().nextInt(max(1, delay ~/ 2)),
          if (review) 'state': 'needsAttention',
          'error': error is AttendanceRejected
              ? error.retainedMessage
              : review
              ? 'Attendance needs school review; capture retained.'
              : 'Attendance unavailable; capture retained for automatic retry.',
        });
        // A shared outage must not send the remaining 24 captures to the same failed server.
        if (generation != _generation || !review) break;
      }
    }
    await refreshAttendanceStatus();
  }

  final Future<Directory> Function()? cacheDirectory;
  Map<String, dynamic> dashboard = {};
  SchoolConnectionState connectionState = SchoolConnectionState.cachedOffline;
  String connectionMessage =
      'Cached school data; cloud verification has not completed.';
  int _refreshFailures = 0;
  int _dashboardQuotaAttempts = 0, _dashboardQuotaRetryAt = 0;
  DateTime? get dashboardQuotaRetryAt => _dashboardQuotaRetryAt > 0
      ? DateTime.fromMillisecondsSinceEpoch(_dashboardQuotaRetryAt) : null;
  Timer? _recoveryTimer;
  final connectionChanges = ValueNotifier<int>(0);
  DateTime? lastDashboardVerifiedAt;
  bool dashboardCleanupDeferred = false;
  DateTime? _pushRegisteredAt;
  String? _registeredPushToken;
  Duration? lastDashboardRefreshDuration;
  Map<String, dynamic> _pdfCache = {};
  Map<String, Uint8List> _pdfMemory = {};
  Future<Map<String, dynamic>>? _refresh;
  Future<Map<String, dynamic>>? _signalRefresh;
  Future<void>? _renewal;
  Future<void> _storageTail = Future<void>.value();
  int _expiresAt = 0;
  int _policyExpiresAt = 0;
  bool get cachedAccessAllowed =>
      loggedIn &&
      ((!_cardReaderEnforced && link!.cardIssueId.isEmpty) ||
          DateTime.now().millisecondsSinceEpoch < _cardOfflineUntil) &&
      DateTime.now().millisecondsSinceEpoch < _expiresAt &&
      (_policyExpiresAt == 0 ||
          DateTime.now().millisecondsSinceEpoch < _policyExpiresAt);
  int _generation = 0;
  static final instance = SchoolSession();
  static const _secure = FlutterSecureStorage();
  SchoolLink? link;
  String schoolToken = '', deviceId = '';
  Map<String, dynamic>? messaging;
  Map<String, dynamic> person = {};
  String schoolName = '';
  static const version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0',
  );
  bool get loggedIn => link != null && schoolToken.isNotEmpty;
  Future<void> restore() async {
    deviceId =
        await _secure.read(key: 'vs_mobile_device') ??
        base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256)));
    await _secure.write(key: 'vs_mobile_device', value: deviceId);
    final raw = await _secure.read(key: 'vs_mobile_session');
    if (raw == null) return;
    try {
      final d = jsonDecode(raw);
      final restoredLink = QrAuthenticationEngine.decode(d['qr']);
      QrAuthenticationEngine.validateSession(
        restoredLink,
        Map<String, dynamic>.from(d),
        now: DateTime.now().millisecondsSinceEpoch,
        restored: true,
      );
      link = restoredLink;
      schoolToken = d['schoolToken'];
      // Student-facing pause control was retired; always resume background sync.
      syncPaused = false;
      await _adoptCardAuthorization(
        Map<String, dynamic>.from(d),
        restoring: true,
      );
      messaging = d['messaging'] is Map
          ? Map<String, dynamic>.from(d['messaging'])
          : null;
      person = Map<String, dynamic>.from(d['person'] ?? {});
      schoolName = d['schoolName'] ?? link!.projectId;
      _expiresAt = (d['expiresAt'] as num).toInt();
      _policyExpiresAt = (d['policyExpiresAt'] as num? ?? 0).toInt();
      if (d['cacheSchool'] == link!.projectId &&
          d['cachePerson'] == link!.personId) {
        dashboard = Map<String, dynamic>.from(d['dashboard'] as Map? ?? {});
        _dashboardQuotaAttempts = (d['dashboardQuotaAttempts'] as int? ?? 0).clamp(0, 5).toInt();
        _dashboardQuotaRetryAt = d['dashboardQuotaRetryAt'] as int? ?? 0;
        if (d['cacheRole'] == link!.role)
          _attendanceHistoryCache = Map<String, dynamic>.from(
            d['attendanceHistory'] as Map? ?? {},
          );
        if (d['lastDashboardVerifiedAt'] is num)
          lastDashboardVerifiedAt = DateTime.fromMillisecondsSinceEpoch(
            (d['lastDashboardVerifiedAt'] as num).toInt(),
          );
        _pdfCache = Map<String, dynamic>.from(d['pdfCache'] as Map? ?? {});
      }
    } catch (_) {
      await clear();
    }
  }

  static Map<String, dynamic> _decodeSchoolResponse(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    throw StateError(
      'School service returned an invalid response. Try again; if it continues, contact the school administrator.',
    );
  }

  Future<Map<String, dynamic>> schoolCall(
    String action,
    Map<String, dynamic> body,
  ) async {
    final current = link;
    final generation = _generation;
    if (current == null) throw StateError('Scan your school ID first.');
    if (loggedIn &&
        action != 'mobile_login' &&
        action != 'mobile_refresh' &&
        action != 'mobile_logout' &&
        _expiresAt <= DateTime.now().millisecondsSinceEpoch) {
      await _renewSession();
    }
    void unchanged() {
      if (generation != _generation || !identical(current, link))
        throw StateError('School session changed. Scan your ID again.');
    }

    if (current.managed) {
      final requestTimeout = managedSchoolRequestTimeout(action);
      final r = await _client
          .post(
            Uri.parse(current.endpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': 'managed/mobile',
              'schoolId': current.schoolId,
              'request': {
                ...body,
                'action': action,
                'sessionToken': schoolToken,
                'deviceId': deviceId,
                if (_cardAuthorizationToken != null)
                  'cardAuthorizationToken': _cardAuthorizationToken,
                if (current.cardIssueId.isNotEmpty)
                  'cardIssueId': current.cardIssueId,
              },
            }),
          )
          .timeout(
            requestTimeout,
            onTimeout: () => throw action == 'mobile_login'
                ? SchoolLoginTimeout()
                : TimeoutException(
                    'School request did not finish in time.',
                    requestTimeout,
                  ),
          );
      unchanged();
      if (r.statusCode >= 500 || r.statusCode == 429) {
        Map<String, dynamic> safe = {};
        try {
          safe = _decodeSchoolResponse(r.body);
        } catch (_) {}
        throw SchoolApiFailure(
          r.statusCode,
          code: safe['code']?.toString() ?? '',
          requestId: safe['requestId']?.toString() ?? '',
        );
      }
      final d = _decodeSchoolResponse(r.body);
      if (action == 'mobile_mark_attendance' &&
          (r.statusCode == 400 || r.statusCode == 409)) {
        final code = AttendanceRejected.reason(d, r.statusCode);
        if (code != null) {
          final ref = d['requestId']?.toString() ?? '';
          throw AttendanceRejected(
            code,
            reference: RegExp(r'^[a-f0-9-]{36}$').hasMatch(ref) ? ref : '',
          );
        }
      }
      if (r.statusCode == 401 || r.statusCode == 403) {
        await clear();
        throw SchoolAccessDenied(
          d['message']?.toString() ?? 'School access is inactive.',
        );
      }
      if (r.statusCode != 200 || d['success'] != true)
        throw StateError(
          d is Map
              ? d['message']?.toString() ?? 'Unable to connect'
              : 'Unable to connect',
        );
      if (d['schoolId'] != current.schoolId ||
          d['projectId'] != current.schoolId) {
        await clear();
        throw SchoolAccessDenied('School identity mismatch');
      }
      if (action != 'mobile_login') {
        await _adoptCardAuthorization(Map<String, dynamic>.from(d));
        unchanged();
      }
      if (d['policyExpiresAt'] is num)
        _policyExpiresAt = (d['policyExpiresAt'] as num).toInt();
      if (action != 'mobile_login' && d['attendancePermit'] is String)
        _cachedAttendancePermit = d['attendancePermit'] as String;
      if (d['attendanceStatus'] is Map) {
        dashboard = {...dashboard, 'attendanceStatus': d['attendanceStatus']};
      }
      return Map<String, dynamic>.from(d);
    }
    final r = await _client
        .post(
          Uri.parse(current.scriptUrl),
          headers: {'Content-Type': 'text/plain;charset=utf-8'},
          body: jsonEncode({
            ...body,
            'action': action,
            'projectId': current.projectId,
            'sessionToken': schoolToken,
          }),
        )
        .timeout(const Duration(seconds: 30));
    // Google Apps Script redirects POST responses to a one-time content URL.
    final response = r.isRedirect && r.headers['location'] != null
        ? await _redirect(r.headers['location']!)
        : r;
    unchanged();
    final d = _decodeSchoolResponse(response.body);
    if (d is! Map || d['success'] != true)
      throw StateError(
        d is Map
            ? d['message']?.toString() ?? 'School service unavailable'
            : 'School service unavailable',
      );
    if (d['projectId'] != current.projectId) {
      await clear();
      throw SchoolAccessDenied('School identity mismatch. Login blocked.');
    }
    return Map<String, dynamic>.from(d);
  }

  Future<void> registerNotificationDevice(String token) async {
    if (!loggedIn || link?.managed != true) return;
    final origin = _generation;
    if (_registeredPushToken == token &&
        _pushRegisteredAt != null &&
        DateTime.now().difference(_pushRegisteredAt!) < const Duration(days: 1))
      return;
    final verified = await schoolCall('mobile_refresh', {
      'fcmToken': token,
      'deviceId': deviceId,
    });
    final expires = verified['expiresAt'];
    if (expires is! num || expires <= DateTime.now().millisecondsSinceEpoch)
      throw StateError('Verified notification session renewal failed.');
    if (origin == _generation) {
      _expiresAt = expires.toInt();
      await _persist();
      if (origin != _generation) return;
      _registeredPushToken = token;
      _pushRegisteredAt = DateTime.now();
    }
  }

  Future<http.Response> _redirect(String location) async {
    final uri = Uri.parse(location);
    requireSchoolBackendUri(uri);
    return _client.get(uri).timeout(const Duration(seconds: 20));
  }

  Future<void> _renewSession() async {
    final running = _renewal;
    if (running != null) return running;
    final generation = _generation;
    final pending = () async {
      final result = await schoolCall('mobile_refresh', {});
      if (generation != _generation)
        throw SchoolAccessDenied('School session changed.');
      final expiry = result['expiresAt'];
      if (expiry is! num ||
          !expiry.isFinite ||
          expiry <= DateTime.now().millisecondsSinceEpoch) {
        throw StateError('Unable to renew school session. Try again later.');
      }
      _expiresAt = expiry.toInt();
      await _persist();
    }();
    _renewal = pending;
    try {
      await pending;
    } finally {
      if (identical(_renewal, pending)) _renewal = null;
    }
  }

  Future<Map<String, dynamic>> platformCall(
    String action,
    Map<String, dynamic> body,
  ) async {
    if (action == 'updates/latest') return latestAndroidUpdate();
    if (action == 'mobile/heartbeat')
      return schoolCall('mobile_heartbeat', {'version': version});
    if (action == 'complaint/create')
      return schoolCall('mobile_complaint', body);
    if (action == 'complaint/list')
      return schoolCall('mobile_complaints', body);
    throw ArgumentError('Unknown mobile action');
  }

  Future<void> login(
    SchoolLink newLink, {
    String studentClass = '',
    String roll = '',
    String dob = '',
    String fcmToken = '',
  }) async {
    await clear();
    link = newLink;
    if (deviceId.isEmpty) {
      deviceId = base64UrlEncode(
        List.generate(32, (_) => Random.secure().nextInt(256)),
      );
      await _secure.write(key: 'vs_mobile_device', value: deviceId);
    }
    final generation = _generation;
    late final Map<String, dynamic> login;
    try {
      login = await QrAuthenticationEngine.authenticate(
        newLink,
        (body) => schoolCall('mobile_login', body),
        studentClass: studentClass,
        roll: roll,
        dob: dob,
      );
    } catch (_) {
      if (generation == _generation) await clear();
      rethrow;
    }
    if (login['sessionToken'] is! String ||
        (login['sessionToken'] as String).isEmpty ||
        login['expiresAt'] is! num ||
        (login['expiresAt'] as num) <= DateTime.now().millisecondsSinceEpoch) {
      await clear();
      throw StateError('School returned an invalid login session.');
    }
    try {
      schoolToken = login['sessionToken'] as String;
      await _adoptCardAuthorization(login, session: schoolToken);
      if (login['attendancePermit'] is String)
        _cachedAttendancePermit = login['attendancePermit'] as String;
      _expiresAt = (login['expiresAt'] as num).toInt();
      person = Map<String, dynamic>.from(login['person'] ?? {});
      schoolName = login['schoolName']?.toString() ?? newLink.projectId;
      messaging = login['messaging'] is Map
          ? Map<String, dynamic>.from(login['messaging'])
          : null;
      if (messaging != null && messaging!['projectId'] != newLink.projectId) {
        await clear();
        throw StateError('School messaging project mismatch');
      }
      await _persist();
    } catch (_) {
      if (generation == _generation) await clear();
      rethrow;
    }
  }

  Future<void> _persist() async {
    if (!loggedIn) return;
    final generation = _generation;
    final value = jsonEncode({
      'qr': link!.rawQr,
      'schoolToken': schoolToken,
      'messaging': messaging,
      'person': person,
      'schoolName': schoolName,
      'expiresAt': _expiresAt,
      'policyExpiresAt': _policyExpiresAt,
      'cardReaderEnforced': _cardReaderEnforced,
      'cardIssueId': link!.cardIssueId.isEmpty ? null : link!.cardIssueId,
      if (_cardAuthorizationToken != null)
        'cardAuthorizationToken': _cardAuthorizationToken,
      if (_cardOfflineLease != null) 'cardOfflineLease': _cardOfflineLease,
      'cacheSchool': link!.projectId,
      'cachePerson': link!.personId,
      'cacheRole': link!.role,
      'attendanceHistory': _attendanceHistoryCache,
      'dashboard': dashboard,
      'syncPaused': syncPaused,
      'dashboardQuotaAttempts': _dashboardQuotaAttempts,
      'dashboardQuotaRetryAt': _dashboardQuotaRetryAt,
      'lastDashboardVerifiedAt':
          lastDashboardVerifiedAt?.millisecondsSinceEpoch,
      'pdfCache': _pdfCache,
    });
    final write = _storageTail.then((_) async {
      if (generation == _generation) {
        if (_persistSession != null)
          await _persistSession!(value);
        else
          await _secure.write(key: 'vs_mobile_session', value: value);
      }
    });
    _storageTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    await write;
  }

  /// One coalesced refresh of versioned, permission-filtered school content.
  /// Failed refreshes preserve the last durable verified generation.
  Future<Map<String, dynamic>> refreshDashboard({bool afterSignal = false}) {
    if (syncPaused) return Future.value(dashboard);
    if (_dashboardQuotaRetryAt > DateTime.now().millisecondsSinceEpoch) {
      return Future.error(SchoolApiFailure(429, code: 'SCRIPT_QUOTA_EXCEEDED'));
    }
    final running = _refresh;
    if (running != null) {
      if (!afterSignal) return running;
      final queued = _signalRefresh;
      if (queued != null) return queued;
      final origin = _generation;
      Future<Map<String, dynamic>> next() async {
        if (origin != _generation)
          throw SchoolAccessDenied('School session changed.');
        _signalRefresh = null;
        return refreshDashboard(afterSignal: true);
      }

      final follow = running.then(
        (_) => next(),
        onError: (Object _, StackTrace __) => next(),
      );
      _signalRefresh = follow;
      follow.then(
        (_) {
          if (identical(_signalRefresh, follow)) _signalRefresh = null;
        },
        onError: (Object _, StackTrace __) {
          if (identical(_signalRefresh, follow)) _signalRefresh = null;
        },
      );
      return follow;
    }
    final origin = _generation;
    connectionState = SchoolConnectionState.syncing;
    final watch = Stopwatch()..start();
    final pending = _refreshDashboard(afterSignal: afterSignal);
    _refresh = pending;
    connectionMessage =
        'Checking the latest school dashboard; previously verified data remains available.';
    connectionChanges.value++;
    pending.then(
      (_) {
        watch.stop();
        if (origin != _generation) return;
        lastDashboardRefreshDuration = watch.elapsed;
        _refreshFailures = 0;
        _recoveryTimer?.cancel();
        connectionMessage = dashboardCleanupDeferred
            ? 'School cloud verified. Optional local file cleanup is deferred.'
            : 'School cloud verified.';
        connectionState = SchoolConnectionState.connected;
        connectionChanges.value++;
        if (identical(_refresh, pending)) _refresh = null;
      },
      onError: (Object error, StackTrace __) {
        watch.stop();
        if (origin != _generation) return;
        lastDashboardRefreshDuration = watch.elapsed;
        // A failed API request does not prove the phone has no internet.
        connectionState = SchoolConnectionState.connectionError;
        connectionMessage = error is SchoolCacheFailure
            ? error.message
            : error is SchoolApiFailure
            ? error.userMessage
            : error is TimeoutException
            ? 'Latest school dashboard refresh took too long; its response is unverified. Previously verified cached data is retained.'
            : error is SocketException || error is http.ClientException
            ? 'Network connection to the school server failed. Check connectivity; cached data is retained.'
            : 'School connection needs review. Cached data is retained.';
        final temporary =
            error is TimeoutException ||
            error is SocketException ||
            error is http.ClientException ||
            (error is SchoolApiFailure && error.retryable);
        _refreshFailures++;
        _recoveryTimer?.cancel();
        if (temporary && _refreshFailures <= 5 && cachedAccessAllowed) {
          final quotaWait = _dashboardQuotaRetryAt - DateTime.now().millisecondsSinceEpoch;
          _recoveryTimer = Timer(quotaWait > 0
              ? Duration(milliseconds: quotaWait)
              : schoolRetryDelay(_refreshFailures), () {
            if (origin == _generation && cachedAccessAllowed) {
              unawaited(refreshDashboard().catchError((Object _) => dashboard));
            }
          });
        }
        connectionChanges.value++;
        if (identical(_refresh, pending)) _refresh = null;
      },
    );
    return pending;
  }

  Future<Map<String, dynamic>> _dashboardRequest(Map<String, dynamic> body) async {
    final generation = _generation;
    try {
      return await schoolCall('mobile_dashboard', body);
    } catch (error) {
      if (generation == _generation && error is SchoolApiFailure &&
          (error.status == 429 || error.code == 'SCRIPT_QUOTA_EXCEEDED')) {
        _dashboardQuotaAttempts = (_dashboardQuotaAttempts + 1).clamp(1, 5).toInt();
        _dashboardQuotaRetryAt = DateTime.now().add(
          schoolRetryDelay(_dashboardQuotaAttempts, quota: true),
        ).millisecondsSinceEpoch;
        // Same durable identity-bound cache commit; no document or attendance
        // acknowledgement is created by a dashboard quota refusal.
        try { await _persist(); } catch (_) {
          // The in-memory gate remains closed even if local storage is full.
          connectionMessage = 'School quota cooldown could not be saved locally. Cached data retained.';
        }
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _refreshDashboard({
    bool afterSignal = false,
  }) async {
    unawaited(flushAttendance().catchError((_) {}));
    final generation = _generation;
    // Legacy responses can leave list metadata (notably noticeIds: []) in
    // the retained cache. Empty lists vacuously pass the row checks below,
    // but are not Script data groups and must never become checkpoints.
    final groups = <String>{
      'school',
      'templates',
      'notices',
      'calendar',
      'documents',
      'examinations',
      if (link?.role == 'student') ...{
        'reportCards',
        'fees',
        'payments',
        'feeStructures',
      },
      if (link?.role == 'teacher') 'salary',
    };
    final groupCheckpoints = <String, Map<String, String>>{};
    for (final entry in dashboard.entries) {
      if (!groups.contains(entry.key) || entry.value is! List) continue;
      final rows = (entry.value as List).whereType<Map>().toList();
      if (rows.any(
        (r) =>
            r['_mobileRecordId'] is! String ||
            r['_mobileRecordRevision'] is! String,
      ))
        continue;
      // Whole-group fallback: large caches must not make refresh permanently
      // fail, and an arbitrary truncated ID list could acknowledge removals.
      if (rows.length > 1000) continue;
      final checkpoint = <String, String>{
        for (final row in rows) row['_mobileRecordId'] as String:
          row['_mobileRecordRevision'] as String,
      };
      final candidate = {...groupCheckpoints, entry.key: checkpoint};
      if (candidate.values.fold<int>(0, (n, values) => n + values.length) > 1000 ||
          utf8.encode(jsonEncode(candidate)).length > 120000) continue;
      groupCheckpoints[entry.key] = checkpoint;
    }
    final legacyNotices = <String, String>{};
    if (dashboard['mobileRecordDeltaVersion'] != 1 && dashboard['notices'] is List &&
        (dashboard['notices'] as List).length <= 1000) {
      for (final notice in (dashboard['notices'] as List).whereType<Map>()) {
        if (notice['id'] is String && notice['_noticeRevision'] is String) {
          legacyNotices[notice['id'] as String] = notice['_noticeRevision'] as String;
        }
      }
      if (utf8.encode(jsonEncode(legacyNotices)).length > 40000) legacyNotices.clear();
    }
    final result = await _dashboardRequest({
      'mobileRecordDeltaVersion': 1,
      'knownGroupRecordRevisions': groupCheckpoints,
      if (afterSignal) 'afterSignal': true,
      if (dashboard['revision'] is String)
        'knownRevision': dashboard['revision'],
      if (dashboard['revisions'] is Map)
        'knownRevisions': {
          for (final entry in (dashboard['revisions'] as Map).entries)
            if (groups.contains(entry.key) &&
                (dashboard['mobileRecordDeltaVersion'] != 1 ||
                    dashboard[entry.key] is! List ||
                    groupCheckpoints.containsKey(entry.key)))
              entry.key: entry.value,
        },
      if (legacyNotices.isNotEmpty) 'knownNoticeRevisions': legacyNotices,
    });
    if (generation != _generation)
      throw SchoolAccessDenied('School session changed.');
    final old = dashboard, oldPerson = person;
    final previousVerified = lastDashboardVerifiedAt;
    final oldPdfs = Map<String, dynamic>.from(_pdfCache);
    final merged = {...dashboard, ...result};
    final removedPdfs = <String, dynamic>{};
    if (result['groupRecordDeltas'] != null) {
      if (result['mobileRecordDeltaVersion'] != 1 ||
          result['groupRecordDeltas'] is! Map) {
        throw StateError('Invalid mobile delta version.');
      }
      for (final entry in (result['groupRecordDeltas'] as Map).entries) {
        final key = entry.key;
        final meta = entry.value;
        if (key is! String ||
            meta is! Map ||
            meta['ids'] is! List ||
            result[key] is! List) {
          throw StateError('Invalid mobile record delta.');
        }
        final ids = (meta['ids'] as List);
        if (ids.any((id) => id is! String || id.isEmpty) ||
            ids.toSet().length != ids.length) {
          throw StateError('Invalid mobile record identities.');
        }
        final rows = <String, Map>{};
        for (final row in (dashboard[key] as List? ?? []).whereType<Map>()) {
          if (ids.contains(row['_mobileRecordId']))
            rows[row['_mobileRecordId'] as String] = row;
        }
        final changedIds = <String>{};
        for (final row in result[key] as List) {
          if (row is! Map ||
              row['_mobileRecordId'] is! String ||
              row['_mobileRecordRevision'] is! String ||
              !ids.contains(row['_mobileRecordId']) ||
              !changedIds.add(row['_mobileRecordId'] as String)) {
            throw StateError('Invalid changed mobile record.');
          }
          rows[row['_mobileRecordId'] as String] = row;
        }
        if (ids.any((id) => !rows.containsKey(id)))
          throw StateError('Incomplete mobile record baseline.');
        merged[key] = [for (final id in ids) rows[id]];
      }
    }
    if (result['unchanged'] != true) {
      if (result['noticesDelta'] == true && result['noticeIds'] is List) {
        final ids = (result['noticeIds'] as List).whereType<String>().toList();
        final rows = <String, Map>{};
        for (final row
            in (dashboard['notices'] as List? ?? []).whereType<Map>()) {
          if (row['id'] is String && ids.contains(row['id']))
            rows[row['id']] = row;
        }
        for (final row in (result['notices'] as List? ?? []).whereType<Map>()) {
          if (row['id'] is String && ids.contains(row['id']))
            rows[row['id']] = row;
        }
        merged['notices'] = [
          for (final id in ids)
            if (rows[id] != null) rows[id],
        ];
      }
      if (result.containsKey('idCardPackage') &&
          result['idCardPackage'] == null &&
          _pdfCache.containsKey('idCard')) {
        removedPdfs['idCard'] = _pdfCache['idCard'];
      }
      if (result['reportCards'] is List) {
        final current = (merged['reportCards'] as List)
            .whereType<Map>()
            .map(
              (r) =>
                  'report:${r['id'] ?? r['reportCardId'] ?? r['examName'] ?? 'current'}',
            )
            .toSet();
        for (final key in _pdfCache.keys.where(
          (key) => key.startsWith('report:') && !current.contains(key),
        )) {
          removedPdfs[key] = _pdfCache[key];
        }
      }
    }
    if (jsonEncode(merged).length > 2 * 1024 * 1024)
      throw StateError('School response exceeds cache safety limit.');
    dashboard = merged;
    person = Map<String, dynamic>.from(dashboard['person'] as Map? ?? person);
    for (final key in removedPdfs.keys) _pdfCache.remove(key);
    lastDashboardVerifiedAt = DateTime.now();
    final previousQuotaAt = _dashboardQuotaRetryAt, previousQuotaAttempts = _dashboardQuotaAttempts;
    _dashboardQuotaRetryAt = 0;_dashboardQuotaAttempts = 0;
    try {
      // One cache commit binds content and its verified timestamp. No second
      // write can fail after the new dashboard has already been accepted.
      await _persist();
    } catch (_) {
      if (generation != _generation)
        throw SchoolAccessDenied('School session changed.');
      dashboard = old;
      person = oldPerson;
      lastDashboardVerifiedAt = previousVerified;
      _dashboardQuotaRetryAt = previousQuotaAt;_dashboardQuotaAttempts = previousQuotaAttempts;
      _pdfCache = oldPdfs;
      throw SchoolCacheFailure();
    }
    if (generation != _generation)
      throw SchoolAccessDenied('School session changed.');
    dashboardCleanupDeferred = false;
    for (final key in removedPdfs.keys) _pdfMemory.remove(key);
    // Only acknowledged removal invalidates private files. Temporary outages
    // never enter this path; unlink only files no longer referenced in this tenant.
    for (final metadata in removedPdfs.values.whereType<Map>()) {
      if (generation != _generation) break;
      final hash = metadata['hash'];
      if (hash is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) &&
          !_pdfCache.values.whereType<Map>().any((m) => m['hash'] == hash)) {
        try {
          final file = File('${(await _files()).path}/$hash.pdf');
          if (await file.exists()) await file.delete();
        } catch (_) {
          // An orphan-cleanup failure cannot undo the committed dashboard ACK.
          // Its file remains retained and no longer referenced by active cache.
          dashboardCleanupDeferred = true;
        }
      }
    }
    if (generation != _generation)
      throw SchoolAccessDenied('School session changed.');
    return dashboard;
  }

  /// Fetch the exact school-published PDF, never independently render an ID.
  Future<Uint8List?> publishedIdCard() async {
    final manifest = dashboard['idCardPackage'];
    if (manifest is! Map)
      return dashboard.containsKey('idCardPackage')
          ? null
          : cachedPdf('idCard');
    final revision = manifest['documentRevision']?.toString() ?? '';
    final hash = manifest['contentHash']?.toString() ?? '';
    if (revision.isEmpty || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))
      throw StateError(
        'Published ID metadata is incomplete. Ask the school to Sync.',
      );
    if (cachedPdfVersion('idCard') == revision) {
      final existing = await cachedPdf('idCard');
      if (existing != null) return existing;
    }
    final generation = _generation;
    final result = await schoolCall('mobile_document', {
      'documentId': manifest['documentId'],
    });
    if (generation != _generation)
      throw SchoolAccessDenied('School session changed.');
    if (result['documentRevision'] != revision ||
        result['mime'] != 'application/pdf' ||
        result['contentHash'] != hash)
      throw StateError('Published ID changed. Refresh school data and retry.');
    Uint8List bytes;
    try {
      bytes = Uint8List.fromList(base64Decode(result['base64'].toString()));
    } on FormatException {
      throw StateError('Published ID verification failed. Please retry.');
    }
    bool current() {
      final latest = dashboard['idCardPackage'];
      return generation == _generation &&
          latest is Map &&
          latest['documentId'] == manifest['documentId'] &&
          latest['documentRevision'] == revision &&
          latest['contentHash'] == hash;
    }

    await cachePdf(
      'idCard',
      revision,
      bytes,
      expectedHash: hash,
      accept: current,
    );
    if (!current())
      throw StateError('Published ID changed. Refresh school data and retry.');
    return bytes;
  }

  Future<Directory> _files() async {
    final base =
        await (cacheDirectory?.call() ?? getApplicationSupportDirectory());
    final owner = sha256
        .convert(
          utf8.encode('${link!.projectId}/${link!.role}/${link!.personId}'),
        )
        .toString();
    return Directory('${base.path}/verified-school-content/$owner');
  }

  Future<Uint8List?> cachedPdf(String key) async {
    if (!cachedAccessAllowed) return null;
    if (_pdfMemory.containsKey(key)) return _pdfMemory[key];
    final metadata = _pdfCache[key];
    if (metadata is! Map ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(metadata['hash']?.toString() ?? ''))
      return null;
    final origin = _generation;
    final file = File('${(await _files()).path}/${metadata['hash']}.pdf');
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (origin != _generation || !cachedAccessAllowed) return null;
    if (sha256.convert(bytes).toString() != metadata['hash']) return null;
    _pdfMemory[key] = bytes;
    return bytes;
  }

  String? cachedPdfVersion(String key) =>
      (_pdfCache[key] as Map?)?['version']?.toString();
  Future<void> cachePdf(
    String key,
    String version,
    Uint8List bytes, {
    required String expectedHash,
    bool Function()? accept,
  }) async {
    final origin = _generation;
    if (!cachedAccessAllowed)
      throw SchoolAccessDenied('Verified school access required.');
    if (bytes.length > 20 * 1024 * 1024 ||
        bytes.length < 12 ||
        !String.fromCharCodes(bytes.take(5)).startsWith('%PDF-') ||
        !String.fromCharCodes(
          bytes.skip(bytes.length > 2048 ? bytes.length - 2048 : 0),
        ).contains('%%EOF') ||
        sha256.convert(bytes).toString() != expectedHash)
      throw StateError(
        'Published document verification failed; previous copy retained.',
      );
    final directory = await _files();
    await directory.create(recursive: true);
    final file = File('${directory.path}/$expectedHash.pdf');
    final temporary = File('${file.path}.$origin.pending');
    await temporary.writeAsBytes(bytes, flush: true);
    if (origin != _generation)
      throw SchoolAccessDenied('School session changed.');
    if (!await file.exists())
      await temporary.rename(file.path);
    else
      await temporary.delete();
    if (accept != null && !accept())
      throw StateError(
        'Published document changed during download. Please retry.',
      );
    final old = _pdfCache[key];
    _pdfCache[key] = {'version': version, 'hash': expectedHash};
    try {
      await _persist();
    } catch (_) {
      if (old == null)
        _pdfCache.remove(key);
      else
        _pdfCache[key] = old;
      rethrow;
    }
    if (origin != _generation)
      throw SchoolAccessDenied('School session changed.');
    _pdfMemory[key] = bytes;
  }

  Future<void> logout() async {
    if (loggedIn) {
      try {
        await schoolCall('mobile_logout', {});
      } catch (_) {}
    }
    await clear();
  }

  Future<void> clear() async {
    _generation++;
    _recoveryTimer?.cancel();
    _refreshFailures = 0;
    _dashboardQuotaRetryAt = 0;_dashboardQuotaAttempts = 0;
    syncPaused = false;
    _cachedAttendancePermit = null;
    _attendanceStatusDay = '';
    _capturedToday = false;
    _exitedToday = false;
    _historyDay = '';
    _historyOwner = null;
    _historyEntry = false;
    _historyExit = false;
    attendanceStatusReady = false;
    _cardAuthorizationToken = null;
    _cardOfflineLease = null;
    _cardOfflineUntil = 0;
    _cardReaderEnforced = false;
    attendanceStatusReady = false;
    attendancePending = 0;
    attendanceAccepted = 0;
    attendanceFailure = '';
    lastAttendanceAck = null;
    attendanceChanges.value++;
    link = null;
    schoolToken = '';
    messaging = null;
    _registeredPushToken = null;
    _pushRegisteredAt = null;
    person = {};
    schoolName = '';
    dashboard = {};
    _attendanceHistoryCache = {};
    _attendanceHistoryFlights.clear();
    connectionState = SchoolConnectionState.cachedOffline;
    lastDashboardVerifiedAt = null;
    dashboardCleanupDeferred = false;
    _pdfCache = {};
    _pdfMemory = {};
    _refresh = null;
    _signalRefresh = null;
    _renewal = null;
    _expiresAt = 0;
    _policyExpiresAt = 0;
    final deletion = _storageTail.then(
      (_) => _secure.delete(key: 'vs_mobile_session'),
    );
    _storageTail = deletion.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    await deletion;
  }
}
